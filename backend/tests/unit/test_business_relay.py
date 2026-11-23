"""The relay sequences and carries device operations, then forgets them."""

from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

import pytest
from sqlalchemy import text

from app.domain.services import business_relay as relay
from tests.unit.test_qa_business_ledger import engine, _seed  # noqa: F401


async def _ready(engine):
    async with engine.begin() as conn:
        await relay.install(conn)


def _op(branch, body="x"):
    return {"id": str(uuid4()), "branch_id": str(branch), "kind": "ops",
            "payload": {"changes": body}}


async def _org_ops(conn, org):
    return (await conn.execute(text(
        "SELECT COUNT(*) FROM business_relay_ops WHERE organization_id = :o"
    ), {"o": org})).scalar()


async def _count(conn, table):
    return (await conn.execute(text(f"SELECT COUNT(*) FROM {table}"))).scalar()


@pytest.mark.asyncio
async def test_operations_are_sequenced_carried_and_then_deleted(engine):
    org, owner, branch, _ = await _seed(engine, f"relay-{uuid4().hex[:20]}@example.test")
    await _ready(engine)
    a, b, c = uuid4(), uuid4(), uuid4()
    async with engine.begin() as conn:
        first = await relay.register(conn, org=org, user=owner, session=None, replica_id=a)
        # The first replica of the organization holds the only copy.
        assert first["resync_required"] is False
        second = await relay.register(conn, org=org, user=owner, session=None, replica_id=b)
        third = await relay.register(conn, org=org, user=owner, session=None, replica_id=c)
        # Later replicas need a copy from a live device: the server has none.
        assert second["resync_required"] and third["resync_required"]

        x, y = _op(branch, "x"), _op(branch, "y")
        pushed = await relay.push(conn, org=org, user=owner, replica_id=a, items=[x])
        pushed += await relay.push(conn, org=org, user=owner, replica_id=b, items=[y])
        assert [p["seq"] for p in pushed] == [1, 2]
        # A retry keeps the original arrival order.
        again = await relay.push(conn, org=org, user=owner, replica_id=a, items=[x])
        assert again == [pushed[0]]

        for_c = await relay.pull(conn, org=org, user=owner, replica_id=c)
        assert [i["seq"] for i in for_c["items"]] == [1, 2] and for_c["drained"]
        for_a = await relay.pull(conn, org=org, user=owner, replica_id=a)
        # The author never receives its own operation back.
        assert [i["seq"] for i in for_a["items"]] == [2]

        await relay.ack(conn, org=org, user=owner, replica_id=c,
                        op_ids=[UUID(x["id"]), UUID(y["id"])])
        assert await _count(conn, "business_relay_ops") == 2
        await relay.ack(conn, org=org, user=owner, replica_id=b, op_ids=[UUID(x["id"])])
        await relay.ack(conn, org=org, user=owner, replica_id=a, op_ids=[UUID(y["id"])])
        # Every destination stored them: nothing Business is left.
        assert await _count(conn, "business_relay_ops") == 0
        assert await _count(conn, "business_relay_inbox") == 0
        # A very late retry of a delivered push is still not re-sequenced.
        late = await relay.push(conn, org=org, user=owner, replica_id=a, items=[x])
        assert late == [pushed[0]]


@pytest.mark.asyncio
async def test_expired_operations_are_dropped_and_the_absent_device_resyncs(engine):
    org, owner, branch, _ = await _seed(engine, f"relay-{uuid4().hex[:20]}@example.test")
    await _ready(engine)
    a, b = uuid4(), uuid4()
    old = datetime.now(timezone.utc) - timedelta(days=91)
    async with engine.begin() as conn:
        await relay.register(conn, org=org, user=owner, session=None, replica_id=a)
        await relay.register(conn, org=org, user=owner, session=None, replica_id=b)
        await relay.snapshot_applied(conn, org=org, user=owner, replica_id=b)
        await relay.push(conn, org=org, user=owner, replica_id=a,
                         items=[_op(branch)], now=old)
        assert await relay.purge_expired(conn) == 1
        assert await _count(conn, "business_relay_ops") == 0
        away = await relay.pull(conn, org=org, user=owner, replica_id=b)
        assert away["items"] == [] and away["resync_required"] is True


@pytest.mark.asyncio
async def test_snapshot_hand_over_reaches_only_the_waiting_device(engine):
    org, owner, branch, _ = await _seed(engine, f"relay-{uuid4().hex[:20]}@example.test")
    await _ready(engine)
    live, fresh = uuid4(), uuid4()
    async with engine.begin() as conn:
        await relay.register(conn, org=org, user=owner, session=None, replica_id=live)
        await relay.register(conn, org=org, user=owner, session=None, replica_id=fresh)
        asked = await relay.request_snapshot(conn, org=org, user=owner, replica_id=fresh)
        assert asked["requested"]
        request = (await relay.pull(conn, org=org, user=owner, replica_id=live))["items"]
        assert [i["kind"] for i in request] == ["snapshot_request"]
        assert await relay.serve_snapshot(conn, org=org, user=owner, replica_id=live,
                                          target=fresh, payload={"rows": []})
        # A second answer is not needed.
        assert not await relay.serve_snapshot(conn, org=org, user=owner, replica_id=live,
                                              target=fresh, payload={"rows": []})
        got = (await relay.pull(conn, org=org, user=owner, replica_id=fresh))["items"]
        assert [i["kind"] for i in got] == ["snapshot"]


@pytest.mark.asyncio
async def test_strangers_cannot_use_another_organization_replica(engine):
    org, owner, branch, _ = await _seed(engine, f"relay-{uuid4().hex[:20]}@example.test")
    other_org, stranger, _, _ = await _seed(engine, f"relay-{uuid4().hex[:20]}@example.test")
    await _ready(engine)
    mine = uuid4()
    async with engine.begin() as conn:
        await relay.register(conn, org=org, user=owner, session=None, replica_id=mine)
        with pytest.raises(relay.RelayAccessDenied):
            await relay.pull(conn, org=other_org, user=stranger, replica_id=mine)
        with pytest.raises(relay.RelayAccessDenied):
            await relay.register(conn, org=other_org, user=stranger, session=None,
                                 replica_id=mine)


@pytest.mark.asyncio
async def test_a_retired_device_no_longer_holds_anything_back(engine):
    org, owner, branch, _ = await _seed(engine, f"relay-{uuid4().hex[:20]}@example.test")
    await _ready(engine)
    a, gone = uuid4(), uuid4()
    async with engine.begin() as conn:
        await relay.register(conn, org=org, user=owner, session=None, replica_id=a)
        await relay.register(conn, org=org, user=owner, session=None, replica_id=gone)
        await relay.push(conn, org=org, user=owner, replica_id=a, items=[_op(branch)])
        assert await _org_ops(conn, org) == 1
        await relay.retire(conn, org=org, user=owner, replica_id=gone)
        # It only waited for the retired device: deleted.
        assert await _org_ops(conn, org) == 0
        # A device that is alone again holds the only copy: no resync.
        fresh = await relay.request_snapshot(conn, org=org, user=owner, replica_id=a)
        assert fresh["requested"] is False
        with pytest.raises(relay.RelayAccessDenied):
            await relay.pull(conn, org=org, user=owner, replica_id=gone)
        mine = await relay.my_replicas(conn, org=org, user=owner)
        assert [r["replica_id"] for r in mine] == [str(a)]


@pytest.mark.asyncio
async def test_a_retired_device_that_returns_rejoins_with_a_full_copy(engine):
    org, owner, branch, _ = await _seed(engine, f"relay-{uuid4().hex[:20]}@example.test")
    await _ready(engine)
    a, back = uuid4(), uuid4()
    async with engine.begin() as conn:
        await relay.register(conn, org=org, user=owner, session=None, replica_id=a)
        await relay.register(conn, org=org, user=owner, session=None, replica_id=back)
        await relay.snapshot_applied(conn, org=org, user=owner, replica_id=back)
        await relay.retire(conn, org=org, user=owner, replica_id=back)
        again = await relay.register(conn, org=org, user=owner, session=None, replica_id=back)
        assert again["resync_required"] is True
        assert (await relay.pull(conn, org=org, user=owner, replica_id=back))["resync_required"]
