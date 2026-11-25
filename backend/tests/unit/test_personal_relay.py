"""The Personal relay carries one user's changes between that user's devices,
then forgets them: nothing Personal stays on the server."""

import base64
from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.domain.services import personal_relay as relay
from tests.unit.test_qa_business_ledger import engine, _seed  # noqa: F401


async def _user(engine):
    _org, owner, _b, _o = await _seed(engine, f"prelay-{uuid4().hex[:20]}@example.test")
    async with engine.begin() as conn:
        await relay.install(conn)
    return owner


def _op(body="x"):
    blob = base64.b64encode(f"ciphertext-{body}".encode()).decode()
    return {"id": str(uuid4()), "kind": "ops", "payload": blob}


async def _ops(conn, user):
    return (await conn.execute(text(
        "SELECT COUNT(*) FROM personal_relay_ops WHERE user_id = :u"
    ), {"u": user})).scalar()


async def _inbox(conn, user):
    return (await conn.execute(text(
        "SELECT COUNT(*) FROM personal_relay_inbox i JOIN personal_relay_replicas r "
        "ON r.id = i.replica_id WHERE r.user_id = :u"
    ), {"u": user})).scalar()


async def _devices(conn, user, *ids):
    for rid in ids:
        await relay.register(conn, user=user, session=None, replica_id=rid)
    for rid in ids[1:]:
        await relay.snapshot_applied(conn, user=user, replica_id=rid)


@pytest.mark.asyncio
async def test_push_is_sequenced_idempotent_fanned_out_then_deleted(engine):
    user = await _user(engine)
    a, b, c = uuid4(), uuid4(), uuid4()
    async with engine.begin() as conn:
        first = await relay.register(conn, user=user, session=None, replica_id=a)
        assert first["resync_required"] is False and first["head"] == 0
        second = await relay.register(conn, user=user, session=None, replica_id=b)
        assert second["resync_required"] is True
        await relay.register(conn, user=user, session=None, replica_id=c)

        x, y, z = _op("x"), _op("y"), _op("z")
        pushed = await relay.push(conn, user=user, replica_id=a, items=[x, y])
        pushed += await relay.push(conn, user=user, replica_id=b, items=[z])
        assert [p["seq"] for p in pushed] == [1, 2, 3]
        assert await relay.push(conn, user=user, replica_id=a, items=[x]) == [pushed[0]]

        for_c = await relay.pull(conn, user=user, replica_id=c)
        assert [i["seq"] for i in for_c["items"]] == [1, 2, 3]
        assert for_c["drained"] and for_c["head"] == 3
        assert base64.b64decode(for_c["items"][0]["payload"]) == b"ciphertext-x"
        # The author never receives its own operation back.
        assert [i["seq"] for i in (await relay.pull(conn, user=user, replica_id=a))["items"]] == [3]
        assert [i["seq"] for i in (await relay.pull(conn, user=user, replica_id=b))["items"]] == [1, 2]
        # Paged pull keeps the order.
        page = await relay.pull(conn, user=user, replica_id=c, limit=2)
        assert [i["seq"] for i in page["items"]] == [1, 2] and not page["drained"]

        ids = [UUID(o["id"]) for o in (x, y, z)]
        await relay.ack(conn, user=user, replica_id=c, op_ids=ids)
        assert await _ops(conn, user) == 3
        await relay.ack(conn, user=user, replica_id=b, op_ids=ids[:2])
        assert await _ops(conn, user) == 1
        assert await relay.ack(conn, user=user, replica_id=a, op_ids=[ids[2]]) == 1
        # Every destination stored them: no payload is left.
        assert await _ops(conn, user) == 0
        assert await _inbox(conn, user) == 0
        tomb = (await conn.execute(text(
            "SELECT COUNT(*) FROM personal_relay_delivered WHERE user_id = :u"
        ), {"u": user})).scalar()
        assert tomb == 3
        # A late retry of a delivered push is still not re-sequenced.
        assert await relay.push(conn, user=user, replica_id=a, items=[x]) == [pushed[0]]
        assert (await relay.push(conn, user=user, replica_id=a, items=[_op()]))[0]["seq"] == 4


@pytest.mark.asyncio
async def test_a_lone_device_keeps_nothing_on_the_server(engine):
    user = await _user(engine)
    a = uuid4()
    async with engine.begin() as conn:
        await relay.register(conn, user=user, session=None, replica_id=a)
        out = await relay.push(conn, user=user, replica_id=a, items=[_op()])
        assert out[0]["seq"] == 1
        assert await _ops(conn, user) == 0


@pytest.mark.asyncio
async def test_users_are_isolated(engine):
    me, other = await _user(engine), await _user(engine)
    mine, theirs, theirs2 = uuid4(), uuid4(), uuid4()
    async with engine.begin() as conn:
        await _devices(conn, other, theirs, theirs2)
        await relay.register(conn, user=me, session=None, replica_id=mine)
        x = _op()
        assert (await relay.push(conn, user=other, replica_id=theirs, items=[x]))[0]["seq"] == 1
        # Sequences are per user.
        assert (await relay.push(conn, user=me, replica_id=mine, items=[_op()]))[0]["seq"] == 1
        for call in (relay.pull, relay.retire, relay.snapshot_applied):
            with pytest.raises(relay.RelayAccessDenied):
                await call(conn, user=me, replica_id=theirs)
        with pytest.raises(relay.RelayAccessDenied):
            await relay.register(conn, user=me, session=None, replica_id=theirs)
        with pytest.raises(relay.RelayAccessDenied):
            await relay.push(conn, user=me, replica_id=theirs, items=[_op()])
        with pytest.raises(relay.RelayAccessDenied):
            await relay.ack(conn, user=me, replica_id=theirs, op_ids=[UUID(x["id"])])
        # Reusing another user's operation id is refused, not answered.
        with pytest.raises(relay.RelayAccessDenied):
            await relay.push(conn, user=me, replica_id=mine, items=[x])
        # Serving to another user's waiting device does nothing.
        await relay.register(conn, user=other, session=None, replica_id=uuid4())
        waiting = (await relay.my_replicas(conn, user=other))[-1]["replica_id"]
        assert not await relay.serve_snapshot(conn, user=me, replica_id=mine,
                                              target=UUID(waiting), payload={"a": 1})
        assert [r["replica_id"] for r in await relay.my_replicas(conn, user=me)] == [str(mine)]
        assert (await relay.pull(conn, user=other, replica_id=theirs2))["items"][0]["id"] == x["id"]


@pytest.mark.asyncio
async def test_expired_operations_are_dropped_and_the_absent_device_resyncs(engine):
    user = await _user(engine)
    a, b = uuid4(), uuid4()
    old = datetime.now(timezone.utc) - timedelta(days=91)
    async with engine.begin() as conn:
        await _devices(conn, user, a, b)
        assert (await relay.pull(conn, user=user, replica_id=b))["resync_required"] is False
        await relay.push(conn, user=user, replica_id=a, items=[_op()], now=old)
        fresh = _op()
        await relay.push(conn, user=user, replica_id=a, items=[fresh])
        assert await relay.purge_expired(conn) >= 1
        assert await _ops(conn, user) == 1
        away = await relay.pull(conn, user=user, replica_id=b)
        assert away["resync_required"] is True
        assert [i["id"] for i in away["items"]] == [fresh["id"]]
        # Old tombstones go too.
        await conn.execute(text(
            "UPDATE personal_relay_delivered SET created_us = 0 WHERE user_id = :u"
        ), {"u": user})
        await relay.purge_expired(conn)
        assert (await conn.execute(text(
            "SELECT COUNT(*) FROM personal_relay_delivered WHERE user_id = :u"
        ), {"u": user})).scalar() == 0


@pytest.mark.asyncio
async def test_snapshot_hand_over_is_delivered_once_then_deleted(engine):
    user = await _user(engine)
    live, fresh = uuid4(), uuid4()
    async with engine.begin() as conn:
        await relay.register(conn, user=user, session=None, replica_id=live)
        assert (await relay.register(conn, user=user, session=None,
                                     replica_id=fresh))["resync_required"]
        asked = await relay.request_snapshot(conn, user=user, replica_id=fresh)
        assert asked == {"requested": True, "resync_required": True}
        got = (await relay.pull(conn, user=user, replica_id=live))["items"]
        assert [i["kind"] for i in got] == ["snapshot_request"]
        # Only a waiting device can be served, never oneself.
        assert not await relay.serve_snapshot(conn, user=user, replica_id=live,
                                              target=live, payload={"rows": []})
        blob = base64.b64encode(b"encrypted-full-copy").decode()
        assert await relay.serve_snapshot(conn, user=user, replica_id=live,
                                          target=fresh, payload=blob)
        assert not await relay.serve_snapshot(conn, user=user, replica_id=live,
                                              target=fresh, payload=blob)
        # The answered request no longer waits at the serving device.
        assert (await relay.pull(conn, user=user, replica_id=live))["items"] == []
        item = (await relay.pull(conn, user=user, replica_id=fresh))["items"]
        assert [i["kind"] for i in item] == ["snapshot"] and item[0]["seq"] is None
        assert base64.b64decode(item[0]["payload"]) == b"encrypted-full-copy"
        await relay.snapshot_applied(conn, user=user, replica_id=fresh)
        assert await _ops(conn, user) == 0 and await _inbox(conn, user) == 0
        back = await relay.pull(conn, user=user, replica_id=fresh)
        assert back["items"] == [] and back["resync_required"] is False
        # No longer waiting: a new serve is refused.
        assert not await relay.serve_snapshot(conn, user=user, replica_id=live,
                                              target=fresh, payload=blob)
        # Snapshots and requests leave no tombstone.
        assert (await conn.execute(text(
            "SELECT COUNT(*) FROM personal_relay_delivered WHERE user_id = :u"
        ), {"u": user})).scalar() == 0


@pytest.mark.asyncio
async def test_alone_device_needs_no_snapshot(engine):
    user = await _user(engine)
    a = uuid4()
    async with engine.begin() as conn:
        await relay.register(conn, user=user, session=None, replica_id=a)
        assert await relay.request_snapshot(conn, user=user, replica_id=a) == {
            "requested": False, "resync_required": False}


@pytest.mark.asyncio
async def test_retire_releases_what_waited_and_return_requires_a_copy(engine):
    user = await _user(engine)
    a, gone = uuid4(), uuid4()
    async with engine.begin() as conn:
        await _devices(conn, user, a, gone)
        await relay.push(conn, user=user, replica_id=a, items=[_op()])
        assert await _ops(conn, user) == 1
        listed = {r["replica_id"]: r for r in await relay.my_replicas(conn, user=user)}
        assert listed[str(gone)]["pending"] == 1 and "payload" not in listed[str(gone)]
        await relay.retire(conn, user=user, replica_id=gone)
        assert await _ops(conn, user) == 0
        with pytest.raises(relay.RelayAccessDenied):
            await relay.pull(conn, user=user, replica_id=gone)
        assert [r["replica_id"] for r in await relay.my_replicas(conn, user=user)] == [str(a)]
        again = await relay.register(conn, user=user, session=None, replica_id=gone)
        assert again["resync_required"] is True and again["head"] == 1


@pytest.mark.asyncio
async def test_payload_limits(engine, monkeypatch):
    user = await _user(engine)
    a, b = uuid4(), uuid4()
    async with engine.begin() as conn:
        await _devices(conn, user, a, b)
        for bad in ("", "not base64!", None, 12):
            with pytest.raises(relay.RelayInvalid):
                await relay.push(conn, user=user, replica_id=a,
                                 items=[{"id": str(uuid4()), "payload": bad}])
        with pytest.raises(relay.RelayInvalid):
            await relay.push(conn, user=user, replica_id=a,
                             items=[{**_op(), "kind": "snapshot"}])
        with pytest.raises(relay.RelayInvalid):
            await relay.push(conn, user=user, replica_id=a,
                             items=[_op() for _ in range(relay.MAX_BATCH + 1)])
        monkeypatch.setattr(relay, "MAX_PAYLOAD", 8)
        with pytest.raises(relay.RelayInvalid):
            await relay.push(conn, user=user, replica_id=a,
                             items=[{"id": str(uuid4()),
                                     "payload": base64.b64encode(b"123456789").decode()}])
        ok = await relay.push(conn, user=user, replica_id=a,
                              items=[{"id": str(uuid4()),
                                      "payload": base64.b64encode(b"12345678").decode()}])
        assert ok[0]["seq"] == 1


@pytest.mark.asyncio
async def test_kicked_session_retires_personal_replica(engine):
    from app.api.v1.auth import _retire_relay_devices
    from app.domain.entities.auth_entities import UserSession

    user = await _user(engine)
    kicked, kept = uuid4(), uuid4()
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker.begin() as db:
        for sid in (kicked, kept):
            db.add(UserSession(id=sid, user_id=user, refresh_token=sid.hex,
                               expires_at=datetime.now(timezone.utc) + timedelta(days=1),
                               is_active=True))
    ra, rb = uuid4(), uuid4()
    async with engine.begin() as conn:
        await relay.register(conn, user=user, session=kicked, replica_id=ra)
        await relay.register(conn, user=user, session=kept, replica_id=rb)
    async with maker.begin() as db:
        await _retire_relay_devices(db, [kicked])
    async with engine.begin() as conn:
        rows = dict((await conn.execute(text(
            "SELECT id, retired FROM personal_relay_replicas WHERE user_id = :u"
        ), {"u": user})).all())
    assert rows[ra] is True and rows[rb] is False
