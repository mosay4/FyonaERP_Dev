"""Share debt from a device-owned branch without a legacy writer."""
from datetime import date, datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock
from uuid import UUID, uuid4

import pytest
from fastapi import FastAPI, HTTPException
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.api.v1 import merchant_links as legacy
from app.api.v1 import qa_business_party_sharing as api
from app.core import qa_business_ledger, qa_directory
from app.core.database import get_db
from app.core.security import create_access_token
from app.domain.entities.auth_entities import Organization, User, UserSession
from app.domain.entities.merchant_entities import MerchantLink
from app.domain.entities.notification_entities import AppNotification
from app.domain.services import merchant_link_service as links
from app.domain.services import qa_business_party_sharing as share
from app.domain.services import section_entitlements
from app.domain.services.branch_service import issue_scope_token
from tests.unit.test_qa_business_ledger import engine, _directory_registered, _seed  # noqa: F401


@pytest.mark.asyncio
async def test_missing_optional_share_schema_fails_closed_without_affecting_legacy(engine, monkeypatch):
    monkeypatch.setattr(qa_directory, "INVITES", frozenset({"synthetic@example.test"}))
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker() as db:
        # Test multiple rollout orders without destroying the fixture table.
        if await share.available(db):
            await db.execute(text(
                "ALTER TABLE public.fyona_qa_business_party_shares "
                "RENAME TO fixture_hidden_party_shares"
            ))
        try:
            org, owner, branch = uuid4(), uuid4(), uuid4()
            conventional = MerchantLink(merchant_org_id=org, party_kind="customer", party_id=uuid4())
            assert not await share.is_share(db, conventional)
            token = issue_scope_token(owner, org, branch, False,
                                      qa_directory=True, qa_business_ledger=True)
            with pytest.raises(HTTPException) as denied:
                await api.writer(str(org), owner,
                                 SimpleNamespace(branch_id=branch, all_mode=False), token, db)
            assert denied.value.status_code == 404
        finally:
            await db.rollback()


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", ["customer", "supplier"])
async def test_invite_consent_publish_update_and_revoke(engine, monkeypatch, kind):
    email = f"signup-{uuid4().hex[:24]}@example.test"
    monkeypatch.setattr(qa_directory, "INVITES", frozenset({email}))
    monkeypatch.setattr(qa_business_ledger, "INVITES", frozenset({email}))
    monkeypatch.setenv("FYONA_QA_ENROLL_NEW_LEDGER", "1")
    # No external notifications, SMTP, billing or cloud.
    push = AsyncMock()
    monkeypatch.setattr(api, "_push_after_commit", push)
    from app.domain.services import invitation_response_service
    monkeypatch.setattr(invitation_response_service, "deliver", AsyncMock())
    from app.domain.services import debt_notification_service
    monkeypatch.setattr(debt_notification_service, "push_event", AsyncMock())

    org, owner, branch, other_branch = await _seed(engine, email)
    await _directory_registered(engine, org, owner, branch)
    await qa_business_ledger.install(engine)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    code = str(uuid4().int)[-6:]
    phone = "2025550123" if kind == "supplier" else "2025550124"
    target, outsider, personal_org = uuid4(), uuid4(), uuid4()
    sessions = {user: uuid4() for user in (owner, target, outsider)}
    other_owner_session, other_partner_session = uuid4(), uuid4()
    async with maker.begin() as db:
        section_entitlements.activate(await db.get(Organization, org), "business", days=2)
        await qa_business_ledger.bind_new_ledger_branch(
            db,
            SimpleNamespace(id=owner, email=email, role="owner", organization_id=org),
            SimpleNamespace(id=branch, organization_id=org, is_default=False,
                            is_active=True, is_archived=False),
        )
        db.add(Organization(id=personal_org, name="Synthetic recipient org", slug=personal_org.hex))
        await db.flush()
        db.add_all([
            User(id=target, organization_id=personal_org, email=f"{target.hex}@example.test",
                 role="owner", status="active", full_name="Synthetic partner", public_code=code,
                 phone=f"+1{phone}", phone_lookup_digits=f"1{phone}", phone_national_digits=phone),
            User(id=outsider, organization_id=personal_org, email=f"{outsider.hex}@example.test",
                 role="employee", status="active", full_name="Unrelated partner"),
        ])
        await db.flush()
        db.add_all(UserSession(
            id=sid, user_id=uid, refresh_token=f"fixture-{sid}",
            expires_at=datetime.now(timezone.utc) + timedelta(days=1), is_active=True,
        ) for uid, sid in [*sessions.items(), (owner, other_owner_session),
                            (target, other_partner_session)])

    def headers(user, organization, role, branch_token=None, *, sid=None):
        token = create_access_token(str(user), str(organization), role, str(sid or sessions[user]))
        result = {"Authorization": f"Bearer {token}"}
        if branch_token:
            result["X-Branch-Token"] = branch_token
        return result

    # Exercise the real route, JWT and dependencies in-process (no listener).
    app = FastAPI()
    app.include_router(api.router, prefix="/api/v1")
    app.include_router(legacy.router, prefix="/api/v1")

    async def fixture_session():
        async with maker() as db:
            yield db

    app.dependency_overrides[get_db] = fixture_session
    good_token = issue_scope_token(owner, org, branch, False,
                                   qa_directory=True, qa_business_ledger=True)
    merchant = headers(owner, org, "owner", good_token)
    other_merchant = headers(owner, org, "owner", good_token, sid=other_owner_session)
    partner = headers(target, personal_org, "owner")
    other_partner = headers(target, personal_org, "owner", sid=other_partner_session)
    unrelated = headers(outsider, personal_org, "employee")
    base = "/api/v1/business/party-sharing"
    inbox = "/api/v1/me/merchant-invites"
    contact = {"phone": phone, "country": "US"} if kind == "supplier" else {"code": code}
    key, op_id = uuid4(), uuid4()
    party = f"{base}/{kind}/{key}"

    async with AsyncClient(transport=ASGITransport(app=app), base_url="https://fixture.test") as http:
        async def request(method, path, actor, expected=200, **kwargs):
            response = await http.request(method, path, headers=actor, **kwargs)
            assert response.status_code == expected, response.json()
            return response.json().get("data")

        for denial in (
            headers(owner, org, "owner", issue_scope_token(owner, org, branch, False, qa_directory=True)),
            headers(outsider, personal_org, "employee", good_token),
            headers(owner, org, "owner", issue_scope_token(owner, org, other_branch, False)),
            headers(owner, org, "owner", issue_scope_token(owner, org, None, True, [branch, other_branch])),
            headers(owner, org, "owner", good_token, sid=other_partner_session),
        ):
            await request("GET", party, denial, 403)
        match = await request("POST", f"{base}/lookup", merchant,
                              json={"kind": kind, **contact})
        assert match["found"] is True
        assert match["contact"] == ({"via": "phone", "value": phone}
                                    if kind == "supplier" else {"via": "code", "value": code})
        first = await request("POST", f"{party}/invite", merchant, json=contact)
        repeat = await request("POST", f"{party}/invite", merchant, json=contact)
        assert repeat == first
        await request("POST", f"{party}/invite", other_merchant, 409, json=contact)
        assert first["status"] == "pending"
        assert first["revision"] > 0
        link = first["id"]
        overview = f"/api/v1/me/merchant-links/{link}/debt-overview?currency=YER_OLD"
        async with maker() as db:
            notice = (await db.scalars(select(AppNotification).where(
                AppNotification.event_id.like(f"merchant_invite:{link}:%")
            ))).one()
            assert notice.user_id == target
        assert sum(call.args[-1] is not None for call in push.await_args_list) == 1
        assert (await request("GET", inbox, partner))[0]["link_id"] == link
        assert await request("GET", inbox, unrelated) == []
        assert (await request("GET", f"{base}/{kind}/{uuid4()}", merchant))["status"] == "none"

        def snapshot(info, remaining=2600):
            debt = {"currency": "YER_OLD", "remaining_minor": remaining,
                    "paid_minor": 4000 - remaining}
            return {"revision": info["revision"], "link_id": info["id"], "generation": info["generation"],
                    "debts": [debt], "operations": [{**debt, "id": str(op_id), "total_minor": 4000,
                    "number": "APP-SHARE-1", "date": date.today().isoformat()}]}

        path = f"{party}/snapshot"
        await request("PUT", path, merchant, 409, json=snapshot(first))
        await request("GET", overview, partner, 400)
        await request("GET", overview, other_partner, 400)
        await request("POST", f"{inbox}/{link}/accept", unrelated, 400)
        assert (await request("POST", f"{inbox}/{link}/reject", partner))["status"] == "rejected"
        assert (await request("GET", party, merchant))["status"] == "rejected"
        await request("PUT", path, merchant, 409, json=snapshot(first))
        await request("GET", overview, partner, 400)
        assert (await request("POST", f"{inbox}/{link}/accept", partner))["status"] == "rejected"
        second = await request("POST", f"{party}/invite", merchant, json=contact)
        assert second["status"] == "pending"
        assert second["generation"] != first["generation"]
        assert second["id"] != link
        await request("POST", f"{inbox}/{link}/accept", partner, 400)
        link = second["id"]
        overview = f"/api/v1/me/merchant-links/{link}/debt-overview?currency=YER_OLD"
        await request("GET", overview, partner, 400)
        assert (await request("POST", f"{inbox}/{link}/accept", partner))["status"] == "accepted"
        assert (await request("GET", overview, partner))["published_at"] is None
        await request("PUT", path, other_merchant, 409, json=snapshot(second))
        await request("PUT", path, merchant, 409, json=snapshot(first))
        published = await request("PUT", path, merchant, json=snapshot(second))
        assert published["revision"] == second["revision"] + 1
        assert await request("PUT", path, merchant, json=snapshot(second)) == published
        result = await request("GET", overview, partner)
        assert result["remaining_total"] == "26.00"
        assert result["published_at"] is not None
        assert result["operations"][0]["id"] == str(op_id)
        assert await request("GET", overview, other_partner) == result
        await request("GET", overview, unrelated, 400)
        await request("PUT", path, merchant, 409, json=snapshot(second, 2000))
        await request("PUT", path, merchant, json=snapshot(published, 1700))
        latest = await request("GET", party, other_merchant)
        await request("PUT", path, other_merchant, 409, json=snapshot(latest))
        assert (await request("GET", overview, partner))["remaining_total"] == "17.00"
        async with maker.begin() as db:
            (await db.get(User, target)).status = "inactive"
        await request("GET", overview, partner, 400)
        await request("GET", overview, other_partner, 400)
        async with maker.begin() as db:
            (await db.get(User, target)).status = "active"

        async with maker() as db:
            row = await db.get(MerchantLink, UUID(link))
            assert row.party_id != key
            entity = "customers" if kind == "customer" else "suppliers"
            assert not await db.scalar(text(f"SELECT 1 FROM {entity} WHERE id = :id"),
                                       {"id": row.party_id})
            assert await db.scalar(text("SELECT COUNT(*) FROM invoices WHERE branch_id = :id"),
                                   {"id": branch}) == 0
            with pytest.raises(ValueError, match="لمتابعة الدين فقط"):
                await links.create_settlement_request(
                    db, target, UUID(link), 10, "YER_OLD", None, None, None, None, None)

        # Losing the allowlist (or switching it off completely) does not
        # disclose past snapshots or turn an accepted share into a legacy link.
        for invited in (frozenset({"other@example.test"}), frozenset()):
            with monkeypatch.context() as revoked:
                revoked.setattr(qa_directory, "INVITES", invited)
                await request("GET", overview, partner, 400)
                async with maker() as db:
                    with pytest.raises(ValueError, match="لمتابعة الدين فقط"):
                        await links.create_settlement_request(
                            db, target, UUID(link), 10, "YER_OLD", None, None, None, None, None)

        unknown = f"{base}/{kind}/{uuid4()}"
        assert (await request("DELETE", unknown, merchant))["status"] == "revoked"
        assert (await request("GET", unknown, merchant))["status"] == "none"
        if kind == "supplier":
            unlink = f"/api/v1/me/merchant-links/{link}/unlink"
            await request("POST", unlink, unrelated, 400)
            assert (await request("POST", unlink, other_partner))["status"] == "revoked"
        else:
            # Revoking consent may be done from the owner's other live device;
            # publishing from a second device is not enabled by that right.
            assert (await request("DELETE", party, other_merchant))["status"] == "revoked"
        assert (await request("DELETE", party, merchant))["status"] == "revoked"
        await request("GET", overview, partner, 400)
        await request("GET", overview, other_partner, 400)
        assert (await request("GET", party, merchant))["status"] == "revoked"
        await request("PUT", path, merchant, 409, json=snapshot(latest))
        async with maker() as db:
            row = await db.get(MerchantLink, UUID(link))
            assert not await db.scalar(text(
                "SELECT snapshot IS NOT NULL OR published_at IS NOT NULL "
                "FROM public.fyona_qa_business_party_shares WHERE id = :id"
            ), {"id": row.party_id})
