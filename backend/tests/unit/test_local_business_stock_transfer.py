"""Runs only in the disposable Unix-socket cash/stock fixture database."""

import asyncio
from dataclasses import replace
from datetime import date
from uuid import uuid4, uuid5

import pytest
from sqlalchemy import delete, insert, select, update
from sqlalchemy.exc import IntegrityError

from app.domain.services import local_business_stock_transfer as stock
from tests.unit.test_local_business_cash import test_db  # noqa: F401


async def _seed(engine):
    org, sender, receiver = uuid4(), uuid4(), uuid4()
    first, second, observer = (
        stock.StockSession(org, uuid4(), uuid4(), branch)
        for branch in (sender, sender, receiver)
    )
    async with engine.begin() as conn:
        await conn.run_sync(stock.metadata.create_all)
        await conn.execute(insert(stock.heads).values(organization_id=org))
        await conn.execute(insert(stock.branches), [
            {"organization_id": org, "branch_id": branch} for branch in (sender, receiver)
        ])
        await conn.execute(insert(stock.grants), [
            dict(organization_id=org, branch_id=branch, actor_id=session.actor_id,
                 session_id=session.session_id, version=1, can_read=True, can_transfer=session != observer)
            for session in (first, second, observer)
            for branch in ((sender, receiver) if session != observer else (receiver,))
        ])
        src, dst, src2, dst2 = [uuid4() for _ in range(4)]
        a, b, c, d, item, item2, measure = [uuid4() for _ in range(7)]
        await conn.execute(insert(stock.products), [
            dict(organization_id=org, branch_id=branch, product_id=product, item_key=key,
                 quantity_milli=qty, revision=1)
            for branch, product, key, qty in (
                (sender, src, item, 5000), (receiver, dst, item, 0),
                (sender, src2, item2, 1000), (receiver, dst2, item2, 0),
            )
        ])
        await conn.execute(insert(stock.units), [
            dict(organization_id=org, branch_id=branch, product_id=product, unit_id=unit, measure_key=measure,
                 factor_micro=factor)
            for branch, product, unit, factor in (
                (sender, src, a, 2_000_000), (receiver, dst, b, 1_000_000),
                (sender, src2, c, 1_000_000), (receiver, dst2, d, 1_000_000),
            )
        ])
        late, early, unknown = uuid4(), uuid4(), uuid4()
        await conn.execute(insert(stock.lots), [
            dict(organization_id=org, branch_id=sender, product_id=product, lot_id=lot, origin_lot_id=lot,
                 received_milli=qty, remaining_milli=qty, cost_4=cost, currency=currency,
                 received_on=date(2026, 1, 1), expiry_on=date(2026, month, 1), lot_number=number)
            for product, lot, qty, cost, currency, month, number in (
                (src, late, 3000, 10000, "SAR", 10, "late"),
                (src, early, 2000, 30000, "USD", 9, "early"),
                (src2, unknown, 1000, None, None, 9, "no-cost"),
            )
        ])
    return first, second, observer, stock.TransferLine(src, dst, a, b, 2000, 1, 1), \
        stock.TransferLine(src2, dst2, c, d, 1000, 1, 1), early, late


async def _post(engine, who, sender, receiver, command, *lines, reverse_of=None):
    async with engine.begin() as conn:
        return await stock.decide(conn, who, command=command, sender=sender, receiver=receiver,
                                  grant_versions=(1, 1), lines=lines, reverse_of=reverse_of)


async def _balances(conn, org, line):
    return dict((await conn.execute(select(stock.products.c.product_id, stock.products.c.quantity_milli).where(
        stock.products.c.organization_id == org,
        stock.products.c.product_id.in_((line.from_product, line.to_product)),
    ))).all())


@pytest.mark.asyncio
async def test_two_sides_commit_one_decision_with_exact_lots_and_scoped_delivery(test_db):
    first, second, observer, line, _, early, late = await _seed(test_db)
    sender, receiver, org = first.branch_id, observer.branch_id, first.organization_id
    commands = {first: uuid4(), second: uuid4()}
    got = await asyncio.gather(*(
        _post(test_db, who, sender, receiver, command, line)
        for who, command in commands.items()
    ))
    accepted, rejected = sorted(got, key=lambda decision: decision.sequence)
    assert (accepted.decision, rejected.decision) == ("accepted", "stock_changed")
    winner = next(who for who, command in commands.items() if command == accepted.command_id)
    assert await _post(test_db, winner, sender, receiver, accepted.command_id, line) == accepted
    with pytest.raises(stock.StockReplayConflict):
        await _post(test_db, winner, sender, receiver, accepted.command_id, replace(line, quantity_milli=1000))
    with pytest.raises(stock.StockAccessDenied):
        await _post(test_db, observer, sender, receiver, accepted.command_id, line)
    with pytest.raises(stock.StockAccessDenied):
        await _post(test_db, replace(winner, organization_id=uuid4()),
                    sender, receiver, uuid4(), line)

    async with test_db.begin() as conn:
        assert await _balances(conn, org, line) == {line.from_product: 1000, line.to_product: 2000}
        src, = await stock.poll(conn, winner)
        dst, = await stock.poll(conn, observer)
        source, = src["lines"]
        target, = dst["lines"]
        assert (source["product_id"], source["delta_milli"]) == (str(line.from_product), -4000)
        assert (target["product_id"], target["delta_milli"]) == (str(line.to_product), 2000)
        assert [(lot["lot_id"], lot["lot_number"], lot["value_7"], lot["currency"])
                for lot in source["lots"]] == [
            (str(early), "early", "60000000", "USD"), (str(late), "late", "20000000", "SAR"),
        ]
        assert [(lot["origin_lot_id"], lot["quantity_milli"], lot["cost_4"], lot["value_7"], lot["expiry_on"])
                for lot in target["lots"]] == [
            (str(early), 1000, 60000, "60000000", "2026-09-01"),
            (str(late), 1000, 20000, "20000000", "2026-10-01"),
        ]
        with pytest.raises(stock.StockAccessDenied):
            await stock.acknowledge(conn, observer, accepted.command_id, src["delivery_key"])
        await stock.acknowledge(conn, winner, accepted.command_id, src["delivery_key"])
    # Reopen a transaction after losing the response to ACK; no other side was cleared.
    async with test_db.begin() as conn:
        await stock.acknowledge(conn, winner, accepted.command_id, src["delivery_key"])
        assert await stock.poll(conn, winner) == []
        assert await stock.poll(conn, observer) == [dst]
        await stock.revoke(conn, observer, read=True)
        with pytest.raises(stock.StockAccessDenied):
            await stock.poll(conn, observer)
        with pytest.raises(stock.StockAccessDenied):
            await stock.acknowledge(conn, observer, accepted.command_id, dst["delivery_key"])

    reverse = uuid4()
    undone = await _post(test_db, winner, sender, receiver, reverse, reverse_of=accepted.command_id)
    assert undone.decision == "accepted"
    assert await _post(test_db, winner, sender, receiver, reverse, reverse_of=accepted.command_id) == undone
    assert (await _post(test_db, winner, sender, receiver, uuid4(),
                        reverse_of=accepted.command_id)).decision == "already_reversed"
    assert (await _post(test_db, winner, sender, receiver, uuid4(), line)).decision == "stock_changed"
    async with test_db.begin() as conn:
        assert await _balances(conn, org, line) == {line.from_product: 5000, line.to_product: 0}
        assert dict((await conn.execute(select(stock.lots.c.lot_id, stock.lots.c.remaining_milli).where(
            stock.lots.c.organization_id == org, stock.lots.c.lot_id.in_((early, late)),
        ))).all()) == {early: 2000, late: 3000}
        await stock.revoke(conn, replace(winner, branch_id=receiver), read=False)
    assert (await _post(test_db, winner, sender, receiver, uuid4(),
                        replace(line, from_revision=3, to_revision=3))).decision == "permission_changed"


@pytest.mark.asyncio
async def test_unproven_lines_and_failed_destination_write_do_not_debit_anything(test_db):
    first, _, observer, line, unpriced, early, _ = await _seed(test_db)
    org, sender, receiver = first.organization_id, first.branch_id, observer.branch_id
    for submitted, reason in (
        ((line, unpriced), "unproven_cost"),
        ((replace(line, to_unit=unpriced.to_unit),), "unit_not_proven"),
        ((replace(line, quantity_milli=3000),), "insufficient_stock"),
    ):
        assert (await _post(test_db, first, sender, receiver, uuid4(), *submitted)).decision == reason
    command = uuid4()
    collision = uuid5(command, f"{line.to_product}:{early}")
    async with test_db.begin() as conn:
        await conn.execute(insert(stock.lots).values(
            organization_id=org, branch_id=receiver, lot_id=collision, product_id=line.to_product,
            received_milli=1, remaining_milli=0, received_on=date(2026, 1, 1), origin_lot_id=uuid4(),
        ))
    with pytest.raises(IntegrityError):
        await _post(test_db, first, sender, receiver, command, line)
    async with test_db.begin() as conn:
        assert await _balances(conn, org, line) == {line.from_product: 5000, line.to_product: 0}
        assert await stock.poll(conn, observer) == []
        assert await conn.scalar(select(stock.lots.c.remaining_milli).where(
            stock.lots.c.organization_id == org, stock.lots.c.lot_id == early,
        )) == 2000
        assert await conn.scalar(select(stock.receipts.c.command_id).where(
            stock.receipts.c.organization_id == org, stock.receipts.c.command_id == command,
        )) is None
        await conn.execute(delete(stock.lots).where(
            stock.lots.c.organization_id == org, stock.lots.c.lot_id == collision,
        ))
    assert (await _post(test_db, first, sender, receiver, command, line)).decision == "accepted"
    async with test_db.begin() as conn:
        # The receiver used an incoming slice. Buying the same amount from
        # elsewhere does not make the original lots reversible.
        await conn.execute(update(stock.lots).where(
            stock.lots.c.organization_id == org, stock.lots.c.lot_id == collision,
        ).values(remaining_milli=0))
        replacement = uuid4()
        await conn.execute(insert(stock.lots).values(
            organization_id=org, branch_id=receiver, lot_id=replacement, product_id=line.to_product,
            received_milli=1000, remaining_milli=1000, received_on=date(2026, 1, 1),
            origin_lot_id=replacement, cost_4=60000, currency="USD",
        ))
    assert (await _post(test_db, first, sender, receiver, uuid4(),
                        reverse_of=command)).decision == "unavailable_reversal"
    async with test_db.begin() as conn:
        assert await _balances(conn, org, line) == {line.from_product: 1000, line.to_product: 2000}
