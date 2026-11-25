"""Merchant ↔ linked party: carried to the other side's devices, then deleted."""

from uuid import uuid4

import pytest
from sqlalchemy import text

from app.domain.services import business_peer_relay as peer
from tests.unit.test_qa_business_ledger import engine, _seed  # noqa: F401


@pytest.mark.asyncio
async def test_debt_updates_and_chat_reach_the_other_side_then_leave_the_server(engine):
    from sqlalchemy.ext.asyncio import async_sessionmaker
    from app.domain.entities.merchant_entities import MerchantLink

    org, merchant, branch, _ = await _seed(engine, f"m-{uuid4().hex[:20]}@example.test")
    _, customer, _, _ = await _seed(engine, f"c-{uuid4().hex[:20]}@example.test")
    link = uuid4()
    async with async_sessionmaker(engine, expire_on_commit=False).begin() as db:
        db.add(MerchantLink(id=link, merchant_org_id=org, party_kind="customer",
                            party_id=uuid4(), external_user_id=customer, status="accepted"))
    shop, phone, phone2 = uuid4(), uuid4(), uuid4()
    async with engine.begin() as conn:
        await peer.install(conn)
        await peer.register(conn, user=merchant, device=shop)
        await peer.register(conn, user=customer, device=phone)
        await peer.register(conn, user=customer, device=phone2)
        snap = uuid4()
        sent = await peer.push(conn, user=merchant, device=shop, link_id=link,
                               kind="debt_snapshot", op_id=snap, payload={"debts": []})
        assert sent["recipients"] == [str(customer)]
        # The customer may chat, but never publishes the merchant's debts.
        with pytest.raises(peer.PeerDenied):
            await peer.push(conn, user=customer, device=phone, link_id=link,
                            kind="debt_snapshot", op_id=uuid4(), payload={})
        for device in (phone, phone2):
            items = await peer.pull(conn, user=customer, device=device)
            assert [i["id"] for i in items] == [str(snap)]
        assert await peer.pull(conn, user=merchant, device=shop) == []
        await peer.ack(conn, user=customer, device=phone, ids=[snap])
        assert await conn.scalar(text("SELECT COUNT(*) FROM business_peer_transit WHERE id = :i"), {"i": snap}) == 1
        await peer.ack(conn, user=customer, device=phone2, ids=[snap])
        assert await conn.scalar(text("SELECT COUNT(*) FROM business_peer_transit WHERE id = :i"), {"i": snap}) == 0
        # A stranger cannot use the link.
        _, stranger, _, _ = await _seed(engine, f"s-{uuid4().hex[:20]}@example.test")
        with pytest.raises(peer.PeerDenied):
            await peer.push(conn, user=stranger, device=uuid4(), link_id=link,
                            kind="chat", op_id=uuid4(), payload={"text": "x"})


@pytest.mark.asyncio
async def test_own_devices_state_reaches_other_devices_then_leaves_the_server(engine):
    _, user, _, _ = await _seed(engine, f"o-{uuid4().hex[:20]}@example.test")
    _, other, _, _ = await _seed(engine, f"x-{uuid4().hex[:20]}@example.test")
    a, b, c, foreign = uuid4(), uuid4(), uuid4(), uuid4()
    async with engine.begin() as conn:
        await peer.install(conn)
        for d in (a, b, c):
            await peer.register(conn, user=user, device=d)
        await peer.register(conn, user=other, device=foreign)
        op = uuid4()
        sent = await peer.push_self(conn, user=user, device=a, kind="account_types",
                                    op_id=op, payload={"types": {"x": {"t": "savings", "at": 1}}})
        assert sent["destinations"] == 2
        # Only the same user's other devices receive it.
        assert await peer.pull(conn, user=other, device=foreign) == []
        assert await peer.pull(conn, user=user, device=a) == []
        for d in (b, c):
            assert [i["kind"] for i in await peer.pull(conn, user=user, device=d)] == ["account_types"]
            await peer.ack(conn, user=user, device=d, ids=[op])
        assert await conn.scalar(text("SELECT COUNT(*) FROM business_peer_transit WHERE id = :i"), {"i": op}) == 0
        # A device of another user can't post on this user's behalf; unknown kinds refused.
        with pytest.raises(peer.PeerDenied):
            await peer.push_self(conn, user=user, device=foreign, kind="account_types",
                                 op_id=uuid4(), payload={})
        with pytest.raises(ValueError):
            await peer.push_self(conn, user=user, device=a, kind="debt_snapshot",
                                 op_id=uuid4(), payload={})
        # Single device: nothing is stored at all.
        _, solo, _, _ = await _seed(engine, f"z-{uuid4().hex[:20]}@example.test")
        only = uuid4()
        await peer.register(conn, user=solo, device=only)
        r = await peer.push_self(conn, user=solo, device=only, kind="account_types_request",
                                 op_id=uuid4(), payload={})
        assert r["destinations"] == 0
