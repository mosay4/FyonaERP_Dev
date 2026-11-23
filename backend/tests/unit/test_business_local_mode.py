"""Every active branch of an invited owner's organization is a device branch."""

from types import SimpleNamespace
from uuid import uuid4

import pytest

from app.core import business_local_mode, qa_directory
from tests.unit.test_qa_business_ledger import engine, _seed  # noqa: F401


@pytest.mark.asyncio
async def test_main_and_other_branches_are_all_device_branches(engine, monkeypatch):
    from sqlalchemy.ext.asyncio import async_sessionmaker
    from app.domain.entities.auth_entities import User
    from app.domain.entities.sale_entities import Branch

    email = f"local-{uuid4().hex[:20]}@example.test"
    org, owner, branch, main = await _seed(engine, email)
    monkeypatch.setattr(qa_directory, "INVITES", frozenset({email}))
    async with async_sessionmaker(engine, expire_on_commit=False)() as db:
        user = await db.get(User, owner)
        for branch_id in (branch, main):
            row = await db.get(Branch, branch_id)
            assert await business_local_mode.whole_organization(db, user, row)
        names = await business_local_mode.branch_names(db, org)
        assert set(names) == {str(branch), str(main)}
        stranger = SimpleNamespace(email="other@example.test", role="owner",
                                   status="active", organization_id=org)
        assert not await business_local_mode.whole_organization(
            db, stranger, await db.get(Branch, main))


def test_the_managed_pinned_account_is_included(monkeypatch):
    org, account = uuid4(), uuid4()
    monkeypatch.setattr(qa_directory, "INVITES", frozenset({"signup-" + "a" * 24 + "@example.test"}))
    monkeypatch.setenv("FYONA_QA_REMOTE", "1")
    import json
    monkeypatch.setenv("FYONA_QA_EXISTING_LEDGER_GRANTS", json.dumps(
        {str(uuid4()): {"account": str(account), "organization": str(org)}}))
    pinned = SimpleNamespace(id=account, organization_id=org, email="directory-owner@example.test",
                             role="owner", status="active")
    other = SimpleNamespace(id=uuid4(), organization_id=org, email="x@example.test",
                            role="owner", status="active")
    assert business_local_mode.enabled_for(pinned)
    assert not business_local_mode.enabled_for(other)


@pytest.mark.asyncio
async def test_an_employee_works_only_in_their_branches(engine, monkeypatch):
    import json
    from sqlalchemy import text
    from sqlalchemy.ext.asyncio import async_sessionmaker
    from app.domain.entities.auth_entities import User
    from app.domain.entities.branch_entities import BranchMember
    from app.domain.entities.sale_entities import Branch
    from app.domain.services import business_relay as relay

    boss = f"local-{uuid4().hex[:20]}@example.test"
    org, owner, branch, main = await _seed(engine, boss)
    _, staff, _, _ = await _seed(engine, f"staff-{uuid4().hex[:20]}@example.test")
    monkeypatch.setattr(qa_directory, "INVITES", frozenset({boss}))
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker.begin() as db:
        db.add(BranchMember(organization_id=org, user_id=staff,
                            branch_ids=json.dumps([str(branch)]), permissions="{}",
                            status="active"))
    async with maker() as db:
        employee = await db.get(User, staff)
        allowed = await business_local_mode.member_scope(db, employee, await db.get(Branch, branch))
        assert set(allowed) == {str(branch)}
        assert await business_local_mode.member_scope(db, employee, await db.get(Branch, main)) is None
    async with engine.begin() as conn:
        await relay.install(conn)
        boss_phone, staff_phone = uuid4(), uuid4()
        await relay.register(conn, org=org, user=owner, session=None, replica_id=boss_phone)
        await relay.register(conn, org=org, user=staff, session=None, replica_id=staff_phone)
        await relay.request_snapshot(conn, org=org, user=staff, replica_id=staff_phone)
        asked = (await relay.pull(conn, org=org, user=owner, replica_id=boss_phone))["items"]
        import base64
        body = json.loads(base64.b64decode(asked[0]["payload"]))
        assert body["branch_ids"] == [str(branch)]
        # Once removed, what the employee did offline is not carried.
        await conn.execute(text("UPDATE branch_members SET status = 'removed' WHERE user_id = :u"), {"u": staff})
        with pytest.raises(relay.RelayRevoked):
            await relay.push(conn, org=org, user=staff, replica_id=staff_phone, items=[
                {"id": str(uuid4()), "branch_id": str(branch), "kind": "ops", "payload": {"changes": []}}])


@pytest.mark.asyncio
async def test_chat_invoice_message_for_a_device_ledger_business(engine, monkeypatch):
    from sqlalchemy.ext.asyncio import async_sessionmaker
    from app.domain.entities.merchant_entities import MerchantLink
    from app.domain.services import chat_service

    boss = f"local-{uuid4().hex[:20]}@example.test"
    org, owner, _branch, _ = await _seed(engine, boss)
    _, customer, _, _ = await _seed(engine, f"c-{uuid4().hex[:20]}@example.test")
    link, invoice = uuid4(), uuid4()
    from app.domain.entities import chat_entities
    async with engine.begin() as conn:
        for table in (chat_entities.ChatMessage.__table__, chat_entities.ChatPresence.__table__):
            await conn.run_sync(table.create, checkfirst=True)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker.begin() as db:
        db.add(MerchantLink(id=link, merchant_org_id=org, party_kind="customer",
                            party_id=uuid4(), external_user_id=customer,
                            invited_by=owner, status="accepted"))
    # Not a device-ledger business: an unknown invoice is refused as before.
    async with maker() as db:
        with pytest.raises(ValueError):
            await chat_service.send_message(db, owner, link, side="merchant", kind="invoice",
                                            invoice_id=invoice, file_name="INV-1")
    monkeypatch.setattr(qa_directory, "INVITES", frozenset({boss}))
    async with maker() as db:
        sent = await chat_service.send_message(db, owner, link, side="merchant", kind="invoice",
                                               invoice_id=invoice, file_name="INV-1")
        await db.commit()
    message = sent.get("message", sent)
    assert message["invoice_number"] == "INV-1"
