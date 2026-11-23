"""Real auth/branch dependencies in an isolated ASGI application (no TCP)."""

import json
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from uuid import uuid4

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, insert, select, text
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.api.v1 import qa_business_cash_relay as relay
from app.core import qa_business_ledger, qa_directory
from app.core.database import get_db
from app.core.security import create_access_token
from app.domain.entities.auth_entities import Organization, User, UserSession
from app.domain.entities.branch_entities import BranchMember
from app.domain.entities.merchant_entities import MerchantLink
from app.domain.services import local_business_cash as cash, qa_cash_admission as link, section_entitlements
from app.domain.services.branch_service import issue_scope_token
from tests.unit.test_qa_business_ledger import engine, _directory_registered, _seed  # noqa: F401


@pytest.mark.asyncio
async def test_cash_link_admits_every_device_only_after_both_reservations(engine, monkeypatch):
    email = f"signup-{uuid4().hex[:24]}@example.test"
    monkeypatch.setattr(qa_directory, "INVITES", frozenset({email}))
    monkeypatch.setattr(qa_business_ledger, "INVITES", frozenset({email}))
    for flag in ("FYONA_QA_ENROLL_NEW_LEDGER", "FYONA_QA_CASH_RELAY", "FYONA_QA_CASH_LINK"):
        monkeypatch.setenv(flag, "1")
    org, owner, branch, sibling = await _seed(engine, email)
    await _directory_registered(engine, org, owner, branch)
    await qa_business_ledger.install(engine)
    primary, replica, outsider, account = [uuid4() for _ in range(4)]
    expires = datetime.now(timezone.utc) + timedelta(hours=1)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker.begin() as db:
        await qa_business_ledger.bind_new_ledger_branch(
            db, SimpleNamespace(id=owner, email=email, role="owner", organization_id=org),
            SimpleNamespace(id=branch, organization_id=org, is_default=False, is_active=True, is_archived=False),
        )
        for device in (primary, replica, outsider):
            db.add(UserSession(id=device, user_id=owner, refresh_token=str(uuid4()), expires_at=expires))
    scope = cash.CashScope(org, branch)
    a, b, other = [cash.CashReplica(owner, session) for session in (primary, replica, outsider)]
    async with engine.begin() as conn:
        await conn.run_sync(cash.metadata.create_all)
        # A branch outside the device store has no plan at all.
        assert await link.read_plan(conn, cash.CashScope(org, sibling), a) is None
        fresh = await link.read_plan(conn, scope, a)
        assert fresh["state"] == "pending" and fresh["account_id"] is None
        assert fresh["role"] == "primary"
        # Every device of the account is served; a foreign account is not.
        assert await link.read_plan(conn, scope, other) is not None
        assert await link.read_plan(conn, scope, cash.CashReplica(uuid4(), outsider)) is None
        digest = link._digest(scope, account, "SAR", 150000)
        with pytest.raises(cash.CashAccessDenied):
            await link.prepared(conn, scope, other, plan=fresh["id"],
                                digest=digest, account_id=account)
        # Nothing counted means nothing reported: no opening fact is invented.
        with pytest.raises(cash.CashAccessDenied):
            await link.prepared(conn, scope, b, plan=fresh["id"], digest=digest, account_id=account)
        reported = await link.prepared(
            conn, scope, a, plan=fresh["id"], digest=digest, account_id=account,
            currency="SAR", balance_minor=150000,
            check_ref="RCN-20261122-AB12CD34",
        )
        assert reported["state"] == "pending" and reported["account_id"] == str(account)
        # A second device adopts exactly those facts after its own reservation.
        assert (await link.prepared(conn, scope, b, plan=fresh["id"], digest=digest,
                                    account_id=account))["state"] == "ready"
        assert await conn.scalar(select(cash.scopes.c.branch_id).where(scope.where(cash.scopes))) is not None
    async with maker.begin() as db:
        revoked = await db.get(UserSession, replica)
        revoked.is_active = False
    async with engine.begin() as conn:
        # A retired session is never admitted, and its revocation adds nothing.
        assert await link.read_plan(conn, scope, b) is None
        with pytest.raises(cash.CashAccessDenied):
            await link.prepared(conn, scope, b, plan=fresh["id"], digest=digest, account_id=account)


@pytest.mark.asyncio
@pytest.mark.parametrize("version", [2, 3])
async def test_relay_isolates_two_owner_sessions_employee_and_merchant_link(engine, monkeypatch, version):
    email = f"signup-{uuid4().hex[:24]}@example.test"
    monkeypatch.setattr(qa_directory, "INVITES", frozenset({email}))
    monkeypatch.setattr(qa_business_ledger, "INVITES", frozenset({email}))
    monkeypatch.setenv("FYONA_QA_ENROLL_NEW_LEDGER", "1")
    monkeypatch.setenv("FYONA_QA_CASH_RELAY", "1")
    org, owner, branch, sibling = await _seed(engine, email)
    await _directory_registered(engine, org, owner, branch)
    await qa_business_ledger.install(engine)

    workspace = cash.CashScope(org, branch)
    employee, customer, their_org, bank = (uuid4() for _ in range(4))
    a, b = (cash.CashReplica(owner, uuid4()) for _ in range(2))
    c = cash.CashReplica(employee, uuid4())
    external = cash.CashReplica(customer, uuid4())
    unadmitted = cash.CashReplica(owner, uuid4())
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker.begin() as db:
        section_entitlements.activate(await db.get(Organization, org), "business", days=2)
        await qa_business_ledger.bind_new_ledger_branch(
            db, SimpleNamespace(id=owner, email=email, role="owner", organization_id=org),
            SimpleNamespace(id=branch, organization_id=org, is_default=False,
                            is_active=True, is_archived=False),
        )
        db.add(Organization(id=their_org, name="Synthetic conference", slug=their_org.hex))
        await db.flush()
        db.add_all([
            User(id=employee, organization_id=their_org, role="owner", full_name="Employee",
                 email=f"{employee.hex}@example.test"),
            User(id=customer, organization_id=their_org, role="owner", full_name="Customer",
                 email=f"{customer.hex}@example.test"),
        ])
        await db.flush()
        member_id = uuid4()
        member = BranchMember(id=member_id, organization_id=org, user_id=employee,
                              branch_ids=json.dumps([str(branch)]),
                              permissions=json.dumps({"banks": True, "expenses": True}))
        db.add(member)
        db.add(MerchantLink(merchant_org_id=org, party_kind="customer", party_id=uuid4(),
                            external_user_id=customer, status="accepted"))
        db.add_all(UserSession(
            id=device.session_id, user_id=device.actor_id, refresh_token=f"fixture-{device.session_id}",
            expires_at=datetime.now(timezone.utc) + timedelta(days=1),
        ) for device in (a, b, c, external, unadmitted))
        await db.flush()
        c = cash.CashReplica(employee, c.session_id, relay._membership_revision(member))
    async with engine.begin() as conn:
        await conn.run_sync(cash.metadata.create_all)
        await conn.execute(insert(cash.scopes).values(**workspace.key()))
        if version == 3:
            await cash.enable_settlement_protocol(conn, workspace)
        await conn.execute(insert(cash.resources).values(
            **workspace.key(), account_id=bank, currency="YER_OLD",
            available_minor=10000, allow_negative=False,
        ))
        for actor in (owner, employee):
            await cash.replace_grant(conn, workspace, actor, version=1, can_read=True, can_withdraw=True)
        checkpoint = await cash.cash_checkpoint(conn, workspace)
        for device in (a, b, c):
            await cash.admit_replica(conn, workspace, device, sequence=checkpoint.sequence,
                                     digest=checkpoint.digest, grant_version=1)

    app = FastAPI()
    app.include_router(relay.router, prefix="/api/v1")

    async def fixture_session():
        async with maker() as db:
            yield db

    app.dependency_overrides[get_db] = fixture_session
    async with AsyncClient(transport=ASGITransport(app=app), base_url="https://fixture.test") as http:
        async def request(device, action, body=None, *, status=200, token=None,
                          claimed_session=None, jwt_sid=None, wire_version=version):
            actor = device.actor_id
            bearer = create_access_token(str(actor), str(org if actor == owner else their_org),
                                         "owner", str(jwt_sid or device.session_id))
            scope_token = token or issue_scope_token(
                actor, org, branch, False, qa_directory=actor == owner,
                qa_business_ledger=actor == owner,
            )
            payload = {"checkpoint": {"sequence": checkpoint.sequence, "digest": checkpoint.digest},
                       **(body or {})}
            response = await http.post(f"/api/v1/business/cash-relay/v{wire_version}/{action}", json=payload,
                                       headers={"Authorization": f"Bearer {bearer}",
                                                "X-Branch-Token": scope_token,
                                                "X-Business-Replica-Session":
                                                    str(claimed_session or device.session_id)})
            assert response.status_code == status, response.json()
            return response.json().get("data")

        await request(unadmitted, "poll", status=403)
        await request(external, "poll", status=403)  # Consent to debt ≠ branch membership.
        await request(a, "poll", status=403, claimed_session=b.session_id)
        await request(c, "poll", status=403, claimed_session=a.session_id, jwt_sid=a.session_id)
        await request(a, "poll", status=403, token=issue_scope_token(
            owner, org, sibling, False, qa_directory=True, qa_business_ledger=True))
        await request(a, "poll", status=403, token=issue_scope_token(
            owner, org, None, True, [branch, sibling]))
        await request(a, "poll", status=403, token=issue_scope_token(
            owner, org, branch, False, qa_directory=True))
        await request(a, "poll", {"session_id": str(a.session_id)}, status=422)
        with monkeypatch.context() as off:
            off.delenv("FYONA_QA_CASH_RELAY")
            await request(a, "poll", status=404)
        await request(a, "poll", status=403, wire_version=5 - version)

        async def page(device):
            data = (await request(device, "poll"))["data"]
            return data["deliveries"] if version == 3 else data

        if version == 3:
            line = {"account_id": str(bank), "currency": "YER_OLD",
                    "expected_minor": 10000, "actual_minor": 9750}
            command = {"command_id": str(uuid4()), "observed_through": checkpoint.sequence,
                       "grant_version": 1, "entries": [line]}
            denied = await request(c, "settle", command)
            assert denied["data"]["decision"] == "permission_changed"
            # Owner's last empty poll pins the next authority head.
            head = (await request(a, "poll"))["data"]["observed_through"]
            accepted = await request(a, "settle", {**command, "command_id": str(uuid4()),
                                                  "observed_through": head})
            assert accepted["data"]["decision"] == "accepted"
            for device in (a, b, c):
                entry, = await page(device)
                assert entry["kind"] == "settlement"
                assert entry["entries"] == [line]
                await request(device, "ack", {key: entry[key] for key in ("command_id", "delivery_key")})

        command = str(uuid4())
        withdrawal = {"command_id": command, "account_id": str(bank), "currency": "YER_OLD",
                      "amount_minor": 1500, "grant_version": 1}
        wrong = {"sequence": checkpoint.sequence, "digest": "0" * 64}
        await request(a, "withdraw", {**withdrawal, "checkpoint": wrong}, status=403)
        await request(a, "withdraw", {**withdrawal, "checkpoint": None}, status=422)
        assert await page(b) == []
        accepted = await request(a, "withdraw", withdrawal)
        assert accepted["version"] == version
        assert accepted["session_id"] == str(a.session_id)
        assert accepted["data"]["decision"] == "accepted"
        assert accepted == await request(a, "withdraw", withdrawal)
        await request(b, "withdraw", withdrawal, status=403)

        async def delivery(device):
            return (await page(device))[0]

        async def ack(device, row, status=200):
            await request(device, "ack", {key: row[key] for key in ("command_id", "delivery_key")},
                          status=status)

        a_row = await delivery(a)
        await request(a, "ack", {"command_id": command, "delivery_key": a_row["delivery_key"],
                                 "checkpoint": wrong}, status=403)
        assert await delivery(a) == a_row
        await ack(b, a_row, 403)
        await ack(a, a_row)
        await ack(a, a_row)
        assert (await delivery(b))["command_id"] == command
        assert (await delivery(c))["command_id"] == command
        await ack(b, await delivery(b))
        await ack(c, await delivery(c))

        # Revoking the authority's write grant alone still returns a terminal
        # receipt to a reader, so the device can reverse the provisional post.
        async with engine.begin() as conn:
            await cash.replace_grant(conn, workspace, employee, version=2,
                                     can_read=True, can_withdraw=False)
        denied = await request(c, "withdraw", {**withdrawal, "command_id": str(uuid4())})
        assert denied["data"]["decision"] == "permission_changed"
        assert await page(c) == []

        another = str(uuid4())
        await request(a, "withdraw", {**withdrawal, "command_id": another, "amount_minor": 500})
        assert (await delivery(b))["command_id"] == another
        assert (await delivery(c))["command_id"] == another
        await ack(a, await delivery(a))
        # Re-grant before any relay tick, keeping the same session. An old
        # admission must not disclose a backlog or submit a queued command.
        async with maker.begin() as db:
            (await db.get(BranchMember, member_id)).permissions = '{"banks": false, "expenses": false}'
        await request(c, "poll", status=403)
        async with maker.begin() as db:
            (await db.get(UserSession, b.session_id)).is_active = False
            (await db.get(BranchMember, member_id)).permissions = member.permissions
        await request(b, "poll", status=401)
        await request(c, "poll", status=403)
        await request(c, "withdraw", {**withdrawal, "command_id": str(uuid4())}, status=403)
        assert await page(a) == []
        async with engine.begin() as conn:
            assert await conn.scalar(select(cash.resources.c.available_minor).where(
                workspace.where(cash.resources))) == (7750 if version == 3 else 8000)
            retired = (await conn.scalars(select(cash.replicas.c.session_id).where(
                workspace.where(cash.replicas), cash.replicas.c.retired.is_(True),
            ))).all()
            assert set(retired) == {b.session_id, c.session_id}
            assert await conn.scalar(select(func.count()).select_from(cash.payloads).where(
                workspace.where(cash.payloads))) == 0
            for table in ("invoices", "bank_accounts"):
                assert await conn.scalar(text(f"SELECT COUNT(*) FROM {table} WHERE branch_id = :branch"),
                                         {"branch": branch}) == 0
