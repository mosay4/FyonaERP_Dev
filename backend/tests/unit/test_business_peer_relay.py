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
