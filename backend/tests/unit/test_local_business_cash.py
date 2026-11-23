"""Runs against a fresh, Unix-socket-only cluster; no application DB imports."""

import asyncio
import os
import re
from uuid import uuid4

import pytest
import pytest_asyncio
from sqlalchemy import func, insert, select
from sqlalchemy.ext.asyncio import create_async_engine

from app.domain.services import local_business_cash as cash
from app.domain.services.local_business_cash_wire import cash_message


@pytest_asyncio.fixture
async def test_db():
    socket = os.environ.get("FYONA_TEST_CASH_SOCKET")
    if socket is None:
        pytest.skip("A disposable Unix socket is required")
    if not re.fullmatch(r"/tmp/opencode/fyona-cash-[a-zA-Z0-9]+/socket", socket):
        pytest.fail("Refusing to connect to a non-fixture database")
    engine = create_async_engine("postgresql+asyncpg://root@/postgres",
                                 connect_args={"host": socket})
    try:
        async with engine.begin() as conn:
            await conn.run_sync(cash.metadata.create_all)
        yield engine
    finally:
        await engine.dispose()


async def _seed(engine, *, negative=False, settlement=False):
    scope = cash.CashScope(uuid4(), uuid4())
    account, first, second, observer = [uuid4() for _ in range(4)]
    devices = [cash.CashReplica(actor, uuid4()) for actor in (first, second, observer)]
    async with engine.begin() as conn:
        await conn.execute(insert(cash.scopes).values(**scope.key()))
        if settlement:
            await cash.enable_settlement_protocol(conn, scope)
        await conn.execute(insert(cash.resources).values(
            **scope.key(), account_id=account, currency="SAR",
            available_minor=10_000, allow_negative=negative,
        ))
        for actor in (first, second, observer):
            await cash.replace_grant(
                conn, scope, actor, version=1, can_read=True,
                can_withdraw=actor != observer,
            )
        checkpoint = await cash.cash_checkpoint(conn, scope)
        for device in devices:
            await cash.admit_replica(conn, scope, device, sequence=checkpoint.sequence,
                                     digest=checkpoint.digest, grant_version=1)
    return scope, account, *devices


async def _spend(engine, scope, account, replica, command, amount=10_000, version=1):
    async with engine.begin() as conn:
        return await cash.decide_withdrawal(
            conn, scope, replica=replica, grant_version=version, command_id=command,
            account_id=account, currency="SAR", amount_minor=amount,
        )


@pytest.mark.asyncio
async def test_first_valid_withdrawal_wins_and_receipt_outlives_payload(test_db):
    scope, account, first, second, observer = await _seed(test_db)
    commands = {first: uuid4(), second: uuid4()}
    a, b = await asyncio.gather(*(
        _spend(test_db, scope, account, actor, command)
        for actor, command in commands.items()
    ))
    assert {a.decision, b.decision} == {"accepted", "insufficient_balance"}
    win, lose = sorted([a, b], key=lambda r: r.sequence)
    assert win.decision == "accepted"
    assert lose.blocked_by == win.command_id
    winner = next(actor for actor, command in commands.items() if command == win.command_id)
    loser = next(actor for actor, command in commands.items() if command == lose.command_id)
    async with test_db.begin() as conn:
        expected = [{
            "command_id": win.command_id, "account_id": account,
            "currency": "SAR", "delta_minor": -10_000, "sequence": win.sequence,
        }]
        observer_rows = await cash.poll(conn, scope, observer)
        loser_rows = await cash.poll(conn, scope, loser)
        assert [{k: v for k, v in row.items() if k != "delivery_key"}
                for row in observer_rows] == expected
        assert [{k: v for k, v in row.items() if k != "delivery_key"}
                for row in loser_rows] == expected
        assert observer_rows[0]["delivery_key"] != loser_rows[0]["delivery_key"]
        # A fetch is not a receipt. Simulate losing the first response.
        assert await cash.poll(conn, scope, loser) == loser_rows
        with pytest.raises(cash.CashAccessDenied):
            await cash.acknowledge(conn, scope, loser, win.command_id, observer_rows[0]["delivery_key"])
        await cash.acknowledge(conn, scope, loser, win.command_id, loser_rows[0]["delivery_key"])
        await cash.acknowledge(conn, scope, loser, win.command_id, loser_rows[0]["delivery_key"])
        assert await cash.poll(conn, scope, loser) == []
        assert await cash.poll(conn, scope, observer) == observer_rows
        await cash.acknowledge(conn, scope, observer, win.command_id, observer_rows[0]["delivery_key"])
        winner_rows = await cash.poll(conn, scope, winner)
        assert winner_rows[0]["command_id"] == win.command_id
        await cash.acknowledge(conn, scope, winner, win.command_id, winner_rows[0]["delivery_key"])
        assert await conn.scalar(select(func.count()).select_from(cash.payloads)
                                 .where(scope.where(cash.payloads))) == 0
        assert await conn.scalar(select(cash.resources.c.available_minor)
                                 .where(scope.where(cash.resources))) == 0
        assert await conn.scalar(select(func.count()).select_from(cash.receipts)
                                 .where(scope.where(cash.receipts))) == 2
    assert await _spend(test_db, scope, account, winner, win.command_id) == win
    assert await _spend(test_db, scope, account, loser, lose.command_id) == lose
    with pytest.raises(cash.CashReplayConflict):
        await _spend(test_db, scope, account, winner, win.command_id, amount=1)
    with pytest.raises(cash.CashAccessDenied):
        await _spend(test_db, scope, account, observer, win.command_id)


@pytest.mark.asyncio
async def test_revoked_grant_cannot_read_pending_data_or_approve_spends(test_db):
    scope, account, first, second, observer = await _seed(test_db)
    accepted = await _spend(test_db, scope, account, first, uuid4(), amount=1000)
    async with test_db.begin() as conn:
        await cash.replace_grant(
            conn, scope, second.actor_id, version=2, can_read=False, can_withdraw=False,
        )
        with pytest.raises(cash.CashAccessDenied):
            await cash.poll(conn, scope, second)
        with pytest.raises(cash.CashAccessDenied):
            await cash.acknowledge(conn, scope, second, accepted.command_id, uuid4())
        with pytest.raises(cash.CashAccessDenied):
            await cash.poll(conn, cash.CashScope(scope.workspace_id, uuid4()), first)
        assert (await cash.poll(conn, scope, observer))[0]["delta_minor"] == -1000
        for actor in (first, observer):
            row = (await cash.poll(conn, scope, actor))[0]
            await cash.acknowledge(conn, scope, actor, accepted.command_id, row["delivery_key"])
        assert await conn.scalar(select(func.count()).select_from(cash.payloads)
                                 .where(scope.where(cash.payloads))) == 0
    with pytest.raises(cash.CashAccessDenied):
        await _spend(test_db, scope, account, second, uuid4(), amount=100)
    async with test_db.begin() as conn:
        assert await conn.scalar(select(cash.resources.c.available_minor)
                                 .where(scope.where(cash.resources))) == 9000
        # Read grant can return, but no old unreceived transit is recreated.
        await cash.replace_grant(
            conn, scope, second.actor_id, version=3, can_read=True, can_withdraw=True,
        )
        with pytest.raises(cash.CashAccessDenied):
            await cash.poll(conn, scope, second)
        replacement = cash.CashReplica(second.actor_id, uuid4())
        checkpoint = await cash.cash_checkpoint(conn, scope)
        await cash.admit_replica(conn, scope, replacement, sequence=checkpoint.sequence,
                                 digest=checkpoint.digest, grant_version=3)
        assert await cash.poll(conn, scope, replacement) == []
    assert (await _spend(test_db, scope, account, replacement, uuid4(), amount=1,
                          version=2)).decision == "permission_changed"


@pytest.mark.asyncio
async def test_negative_policy_is_authoritative_and_rollback_publishes_nothing(test_db):
    scope, account, first, second, _ = await _seed(test_db, negative=True)
    command = uuid4()
    async with test_db.connect() as conn:
        transaction = await conn.begin()
        tentative = await cash.decide_withdrawal(
            conn, scope, replica=first, grant_version=1, command_id=command,
            account_id=account, currency="SAR", amount_minor=11_000,
        )
        assert tentative.decision == "accepted"
        await transaction.rollback()
    async with test_db.begin() as conn:
        assert await cash.poll(conn, scope, second) == []
        assert await conn.scalar(select(cash.resources.c.available_minor)
                                 .where(scope.where(cash.resources))) == 10000
    accepted = await _spend(test_db, scope, account, first, command, amount=11_000)
    assert accepted == tentative
    async with test_db.begin() as conn:
        assert await conn.scalar(select(cash.resources.c.available_minor)
                                 .where(scope.where(cash.resources))) == -1000
        assert (await cash.poll(conn, scope, second))[0]["delta_minor"] == -11_000


@pytest.mark.asyncio
async def test_second_session_of_same_account_has_its_own_ack_and_snapshot(test_db):
    scope, account, first, unrelated, observer = await _seed(test_db)
    second = cash.CashReplica(first.actor_id, uuid4())
    unadmitted = cash.CashReplica(first.actor_id, uuid4())
    async with test_db.begin() as conn:
        opening = await cash.cash_checkpoint(conn, scope)
        with pytest.raises(cash.CashCheckpointChanged):
            await cash.admit_replica(conn, scope, second, sequence=opening.sequence,
                                     digest="0" * 64, grant_version=1)
        await cash.admit_replica(conn, scope, second, sequence=opening.sequence,
                                 digest=opening.digest, grant_version=1)
        with pytest.raises(cash.CashAccessDenied):
            await cash.poll(conn, scope, unadmitted)
    command = uuid4()
    accepted = await _spend(test_db, scope, account, first, command, amount=2500)
    assert accepted.decision == "accepted"
    with pytest.raises(cash.CashAccessDenied):
        await _spend(test_db, scope, account, second, command, amount=2500)
    async with test_db.begin() as conn:
        # A lost admission response can be retried, but a new session cannot
        # join on a stale checkpoint and silently miss an accepted withdrawal.
        await cash.admit_replica(conn, scope, second, sequence=opening.sequence,
                                 digest=opening.digest, grant_version=1)
        with pytest.raises(cash.CashCheckpointChanged):
            await cash.admit_replica(conn, scope, unadmitted, sequence=opening.sequence,
                                     digest=opening.digest, grant_version=1)
        for replica in (first, unrelated, observer):
            entry = (await cash.poll(conn, scope, replica))[0]
            await cash.acknowledge(conn, scope, replica, command, entry["delivery_key"])
        assert (await cash.poll(conn, scope, second))[0]["delta_minor"] == -2500
        await cash.retire_replica(conn, scope, second)
        with pytest.raises(cash.CashAccessDenied):
            await cash.poll(conn, scope, second)
        assert await cash.poll(conn, scope, first) == []
        assert await conn.scalar(select(func.count()).select_from(cash.payloads)
                                 .where(scope.where(cash.payloads))) == 0


@pytest.mark.asyncio
async def test_settlement_uses_cash_order_and_pin_even_when_the_amount_returns(test_db):
    scope, account, first, second, observer = await _seed(test_db, settlement=True)
    async with test_db.begin() as conn:
        sequence, digest = await cash.replica_checkpoint(conn, scope, first)
    checkpoint = {"sequence": sequence, "digest": digest}

    async def send(device, action, *, version=3, allowed=True, **body):
        frame = await cash_message(
            test_db, scope, device, action, {"checkpoint": checkpoint, **body},
            version=version, live_can_equalize=allowed,
        )
        return frame["data"]

    async def settle(who, before, after, head, *, command=None, **kwargs):
        return await send(who, "settle", command_id=str(command or uuid4()), observed_through=head,
                          grant_version=1, entries=[{
                              "account_id": str(account), "currency": "SAR",
                              "expected_minor": before, "actual_minor": after,
                          }], **kwargs)

    async def drain(who):
        page = await send(who, "poll")
        for row in page["deliveries"]:
            await send(who, "ack", command_id=row["command_id"], delivery_key=row["delivery_key"])
        return (await send(who, "poll"))["observed_through"]

    with pytest.raises(cash.CashAccessDenied):
        await send(first, "poll", version=2)
    assert await drain(second) == 0
    down = await _spend(test_db, scope, account, first, uuid4(), amount=1000)
    assert down.sequence == 1
    assert (await settle(first, 9000, 10000, 1))["decision"] == "stale_measurement"
    assert await drain(first) == 2  # A rejected command also advances the order.
    fixed = uuid4()
    accepted = await settle(first, 9000, 10000, 2, command=fixed)
    assert accepted["decision"] == "accepted"
    assert await settle(first, 9000, 10000, 2, command=fixed) == accepted
    with pytest.raises(cash.CashReplayConflict):
        await settle(first, 9000, 9999, 2, command=fixed)
    assert await drain(second) == 3
    assert (await settle(second, 10000, 11000, 0))["decision"] == "stale_measurement"
    assert await drain(observer) == 4
    assert (await settle(observer, 10000, 11000, 4, allowed=False))["decision"] == "permission_changed"
    async with test_db.begin() as conn:
        assert (await cash.cash_checkpoint(conn, scope)).accounts == ((str(account), "SAR", 10000, False),)
