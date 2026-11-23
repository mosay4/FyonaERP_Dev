"""Isolated QA authority for a fully reconciled pair of inventory ledgers.

Not an API, cutover, enrollment, or writer for the connected ledger. All
resources, unit equivalences and session grants are supplied by the fixture.
Callers must commit before exposing a decision or acknowledging a delivery.
"""

import json
import re
from dataclasses import asdict, dataclass
from hashlib import sha256
from uuid import UUID, uuid4, uuid5

from sqlalchemy import (
    JSON, BigInteger, Boolean, CheckConstraint, Column, Date, ForeignKey,
    ForeignKeyConstraint, MetaData, String, Table, Uuid, and_, delete, insert,
    select, update,
)
from sqlalchemy.ext.asyncio import AsyncConnection


metadata = MetaData()
MAX_QUANTITY = 99_999_999_999_999  # integer milli-units
MAX_COST = 999_999_999_999_999_999  # integer ten-thousandths per base unit
UNIT_SCALE = 1_000_000
_CURRENCY = re.compile(r"[A-Z]{3}(?:_[A-Z]{3})?")


def _org_column(*, foreign=False):
    refs = (ForeignKey("lab_stock_heads.organization_id"),) if foreign else ()
    return Column("organization_id", Uuid, *refs, primary_key=True)


def _branch_columns():
    return _org_column(), Column("branch_id", Uuid, primary_key=True)


def _branch_fk():
    return ForeignKeyConstraint(
        ("organization_id", "branch_id"),
        ("lab_stock_branches.organization_id", "lab_stock_branches.branch_id"),
    )


def _product_fk():
    return ForeignKeyConstraint(
        ("organization_id", "branch_id", "product_id"),
        ("lab_stock_products.organization_id", "lab_stock_products.branch_id",
         "lab_stock_products.product_id"),
    )


heads = Table("lab_stock_heads", metadata, _org_column(),
              Column("sequence", BigInteger, nullable=False, server_default="0"))
branches = Table("lab_stock_branches", metadata, _org_column(foreign=True),
                 Column("branch_id", Uuid, primary_key=True))
grants = Table(
    "lab_stock_grants", metadata, *_branch_columns(),
    Column("session_id", Uuid, primary_key=True),
    Column("actor_id", Uuid, nullable=False),
    Column("version", BigInteger, nullable=False),
    Column("can_read", Boolean, nullable=False),
    Column("can_transfer", Boolean, nullable=False), _branch_fk(),
)
products = Table(
    "lab_stock_products", metadata, *_branch_columns(),
    Column("product_id", Uuid, primary_key=True),
    # Explicit identity mapping, not a match on name, SKU or a client hint.
    Column("item_key", Uuid, nullable=False),
    Column("quantity_milli", BigInteger, nullable=False),
    Column("revision", BigInteger, nullable=False),
    CheckConstraint(f"quantity_milli BETWEEN 0 AND {MAX_QUANTITY}"),
    _branch_fk(),
)
units = Table(
    "lab_stock_units", metadata, *_branch_columns(),
    Column("product_id", Uuid, primary_key=True),
    Column("unit_id", Uuid, primary_key=True),
    Column("measure_key", Uuid, nullable=False),
    Column("factor_micro", BigInteger, nullable=False),
    CheckConstraint("factor_micro BETWEEN 1 AND 1000000000000"),
    _product_fk(),
)
lots = Table(
    "lab_stock_lots", metadata, *_branch_columns(),
    Column("lot_id", Uuid, primary_key=True),
    Column("product_id", Uuid, nullable=False),
    Column("received_milli", BigInteger, nullable=False),
    Column("remaining_milli", BigInteger, nullable=False),
    Column("cost_4", BigInteger),
    Column("currency", String(10)),
    Column("received_on", Date, nullable=False),
    Column("expiry_on", Date),
    Column("lot_number", String(100)),
    Column("origin_lot_id", Uuid, nullable=False),
    CheckConstraint(f"received_milli BETWEEN 1 AND {MAX_QUANTITY}"),
    CheckConstraint("remaining_milli BETWEEN 0 AND received_milli"),
    CheckConstraint(f"cost_4 BETWEEN 0 AND {MAX_COST}"),
    _product_fk(),
)
receipts = Table(
    "lab_stock_receipts", metadata, _org_column(foreign=True),
    Column("command_id", Uuid, primary_key=True),
    Column("from_branch", Uuid, nullable=False),
    Column("to_branch", Uuid, nullable=False),
    Column("actor_id", Uuid, nullable=False),
    Column("session_id", Uuid, nullable=False),
    Column("sequence", BigInteger, nullable=False),
    Column("fingerprint", String(64), nullable=False),
    Column("decision", String(32), nullable=False),
    Column("reversal_of", Uuid),
)


def _receipt_fk():
    return ForeignKeyConstraint(
        ("organization_id", "command_id"),
        ("lab_stock_receipts.organization_id", "lab_stock_receipts.command_id"),
    )


effects = Table(
    "lab_stock_effects", metadata, *_branch_columns(),
    Column("command_id", Uuid, primary_key=True),
    Column("lines", JSON, nullable=False), _receipt_fk(), _branch_fk(),
)
deliveries = Table(
    "lab_stock_deliveries", metadata, *_branch_columns(),
    Column("command_id", Uuid, primary_key=True),
    Column("session_id", Uuid, primary_key=True),
    Column("delivery_key", Uuid, nullable=False),
    ForeignKeyConstraint(
        ("organization_id", "branch_id", "command_id"),
        ("lab_stock_effects.organization_id", "lab_stock_effects.branch_id",
         "lab_stock_effects.command_id"),
    ),
    ForeignKeyConstraint(
        ("organization_id", "branch_id", "session_id"),
        ("lab_stock_grants.organization_id", "lab_stock_grants.branch_id",
         "lab_stock_grants.session_id"),
    ),
)


@dataclass(frozen=True)
class StockSession:
    organization_id: UUID
    actor_id: UUID
    session_id: UUID
    branch_id: UUID


@dataclass(frozen=True)
class TransferLine:
    from_product: UUID
    to_product: UUID
    from_unit: UUID
    to_unit: UUID
    quantity_milli: int  # Number of the selected, equivalent physical units.
    from_revision: int
    to_revision: int


@dataclass(frozen=True)
class StockDecision:
    command_id: UUID
    sequence: int
    decision: str


class StockAccessDenied(Exception):
    pass


class StockReplayConflict(Exception):
    pass


class _Reject(Exception):
    """A terminal decision after successful identity and scope checks."""


def _where(table, **match):
    return and_(*(table.c[key] == value for key, value in match.items()))


async def _row(conn, table, **key):
    return (await conn.execute(select(table).where(_where(table, **key)))).mappings().one_or_none()


async def _lock(conn: AsyncConnection, organization: UUID) -> int:
    if conn.dialect.name != "postgresql" or not conn.in_transaction():
        raise RuntimeError("Stock authority requires a PostgreSQL transaction")
    sequence = await conn.scalar(select(heads.c.sequence).where(
        heads.c.organization_id == organization,
    ).with_for_update())
    if sequence is None:
        raise StockAccessDenied
    return sequence


async def _read_grant(conn, session, branch):
    row = await _row(conn, grants, organization_id=session.organization_id,
                     branch_id=branch, session_id=session.session_id)
    if row is None or row["actor_id"] != session.actor_id or not row["can_read"]:
        raise StockAccessDenied
    return row


async def revoke(conn: AsyncConnection, session: StockSession, *, read: bool) -> None:
    """Internal fixture operation. A retired grant is never reissued in-place."""
    await _lock(conn, session.organization_id)
    row = await _read_grant(conn, session, session.branch_id)
    match = dict(organization_id=session.organization_id, branch_id=session.branch_id,
                 session_id=session.session_id)
    await conn.execute(update(grants).where(_where(grants, **match)).values(
        version=row["version"] + 1, can_transfer=False, can_read=not read,
    ))
    if read:
        await conn.execute(delete(deliveries).where(_where(deliveries, **match)))


def _exact(numerator, denominator, maximum, *, zero=False):
    value, remainder = divmod(numerator, denominator)
    if remainder or not (0 if zero else 1) <= value <= maximum:
        raise _Reject("precision_not_proven")
    return value


async def _product_lots(conn, organization, branch, product):
    key = dict(organization_id=organization, branch_id=branch, product_id=product)
    stock = await _row(conn, products, **key)
    if stock is None:
        raise _Reject("unavailable_resource")
    rows = (await conn.execute(select(lots).where(
        _where(lots, **key), lots.c.remaining_milli > 0,
    ).order_by(lots.c.expiry_on.asc().nulls_last(), lots.c.received_on, lots.c.lot_id))).mappings().all()
    if sum(row["remaining_milli"] for row in rows) != stock["quantity_milli"]:
        raise _Reject("unproven_stock")
    return stock, rows


async def _plan(conn, org, sender, receiver, command, lines):
    debit, credit, updates = [], [], []
    for line in lines:
        src, source_lots = await _product_lots(conn, org, sender, line.from_product)
        dst, _ = await _product_lots(conn, org, receiver, line.to_product)
        if (src["revision"], dst["revision"]) != (line.from_revision, line.to_revision):
            raise _Reject("stock_changed")
        a = await _row(conn, units, organization_id=org, branch_id=sender,
                       product_id=line.from_product, unit_id=line.from_unit)
        b = await _row(conn, units, organization_id=org, branch_id=receiver,
                       product_id=line.to_product, unit_id=line.to_unit)
        if src["item_key"] != dst["item_key"] or a is None or b is None or a["measure_key"] != b["measure_key"]:
            raise _Reject("unit_not_proven")
        from_factor, to_factor = a["factor_micro"], b["factor_micro"]
        from_qty = _exact(line.quantity_milli * from_factor, UNIT_SCALE, MAX_QUANTITY)
        to_qty = _exact(line.quantity_milli * to_factor, UNIT_SCALE, MAX_QUANTITY)
        if src["quantity_milli"] < from_qty:
            raise _Reject("insufficient_stock")
        if dst["quantity_milli"] + to_qty > MAX_QUANTITY:
            raise _Reject("quantity_out_of_range")
        src_slices, dst_slices = [], []
        pending = from_qty
        for lot in source_lots:
            if not pending:
                break
            cut = min(pending, lot["remaining_milli"])
            if lot["cost_4"] is None or not _CURRENCY.fullmatch(lot["currency"] or ""):
                raise _Reject("unproven_cost")
            target_qty = _exact(cut * to_factor, from_factor, MAX_QUANTITY)
            value = cut * lot["cost_4"]
            target_cost = _exact(value, target_qty, MAX_COST, zero=True)
            arrival_id = uuid5(command, f"{line.to_product}:{lot['lot_id']}")
            shared = {
                "origin_lot_id": str(lot["origin_lot_id"]),
                "currency": lot["currency"], "value_7": str(value),
                "received_on": lot["received_on"].isoformat(),
                "expiry_on": lot["expiry_on"].isoformat() if lot["expiry_on"] else None,
                "lot_number": lot["lot_number"],
            }
            src_slices.append({**shared, "lot_id": str(lot["lot_id"]), "quantity_milli": cut,
                               "cost_4": lot["cost_4"]})
            dst_slices.append({**shared, "lot_id": str(arrival_id), "quantity_milli": target_qty,
                               "cost_4": target_cost})
            updates.append((lot, -cut, None))
            updates.append((lot, target_qty, (receiver, line.to_product, arrival_id, target_cost)))
            pending -= cut
        debit.append(_effect_line(src, line.from_unit, from_factor, -from_qty, src_slices))
        credit.append(_effect_line(dst, line.to_unit, to_factor, to_qty, dst_slices))
    return debit, credit, updates


def _effect_line(stock, unit, factor, delta, slices):
    return {
        "product_id": str(stock["product_id"]), "unit_id": str(unit), "factor_micro": factor,
        "before_revision": stock["revision"], "after_revision": stock["revision"] + 1,
        "delta_milli": delta, "balance_milli": stock["quantity_milli"] + delta, "lots": slices,
    }


async def _plan_reversal(conn, org, sender, receiver, original):
    # Reverse the exact original slices, not a new allocation of equal stock.
    async def side(branch, sign):
        row = await _row(conn, effects, organization_id=org, branch_id=branch, command_id=original)
        lines, changes = [], []
        for line in row["lines"]:
            product = UUID(line["product_id"])
            stock, _ = await _product_lots(conn, org, branch, product)
            delta = -line["delta_milli"]
            if not 0 <= stock["quantity_milli"] + delta <= MAX_QUANTITY:
                raise _Reject("unavailable_reversal")
            for allocation in line["lots"]:
                lot = await _row(conn, lots, organization_id=org, branch_id=branch,
                                 lot_id=UUID(allocation["lot_id"]))
                quantity = allocation["quantity_milli"]
                if (lot is None or lot["product_id"] != product
                        or lot["cost_4"] != allocation["cost_4"] or lot["currency"] != allocation["currency"]
                        or str(lot["origin_lot_id"]) != allocation["origin_lot_id"]
                        or (sign < 0 and lot["remaining_milli"] != quantity)
                        or (sign > 0 and lot["remaining_milli"] + quantity > lot["received_milli"])):
                    raise _Reject("unavailable_reversal")
                changes.append((lot, sign * quantity, None))
            lines.append(_effect_line(stock, UUID(line["unit_id"]), line["factor_micro"], delta, line["lots"]))
        return lines, changes

    credit, adds = await side(sender, 1)
    debit, removes = await side(receiver, -1)
    return debit, credit, removes + adds


async def decide(
    conn: AsyncConnection, session: StockSession, *, command: UUID, sender: UUID, receiver: UUID,
    grant_versions: tuple[int, int], lines: tuple[TransferLine, ...] = (), reverse_of: UUID | None = None,
) -> StockDecision:
    """CAS on both stock revisions. Whole reversals use the frozen receipt."""
    if (sender == receiver or session.branch_id not in (sender, receiver)
            or len(grant_versions) != 2 or any(type(v) is not int or v < 1 for v in grant_versions)):
        raise StockAccessDenied
    if reverse_of is None:
        if (not 1 <= len(lines) <= 50
                or len({line.from_product for line in lines}) != len(lines)
                or len({line.to_product for line in lines}) != len(lines)
                or any(type(line.quantity_milli) is not int or not 0 < line.quantity_milli <= MAX_QUANTITY
                       or any(type(r) is not int or r < 1 for r in (line.from_revision, line.to_revision))
                       for line in lines)):
            raise ValueError("Invalid stock transfer")
    elif lines or reverse_of == command:
        raise ValueError("Invalid stock reversal")
    lines = tuple(sorted(lines, key=lambda line: line.from_product))
    digest = sha256(json.dumps(
        ["lab-stock-transfer/v1", sender, receiver, grant_versions, reverse_of, [asdict(line) for line in lines]],
        default=str, sort_keys=True, separators=(",", ":"),
    ).encode()).hexdigest()
    org = session.organization_id
    sequence = await _lock(conn, org)
    a, b = [await _read_grant(conn, session, branch) for branch in (sender, receiver)]
    old = await _row(conn, receipts, organization_id=org, command_id=command)
    if old is not None:
        if (old["actor_id"], old["session_id"]) != (session.actor_id, session.session_id):
            raise StockAccessDenied
        if old["fingerprint"] != digest:
            raise StockReplayConflict
        return StockDecision(command, old["sequence"], old["decision"])
    try:
        if not (a["can_transfer"] and b["can_transfer"]) or (a["version"], b["version"]) != grant_versions:
            raise _Reject("permission_changed")
        if reverse_of is None:
            debit, credit, updates = await _plan(conn, org, sender, receiver, command, lines)
            out_branch, in_branch = sender, receiver
        else:
            original = await _row(conn, receipts, organization_id=org, command_id=reverse_of)
            if (original is None or original["decision"] != "accepted" or original["reversal_of"] is not None
                    or (original["from_branch"], original["to_branch"]) != (sender, receiver)):
                raise _Reject("unavailable_reversal")
            if await conn.scalar(select(receipts.c.command_id).where(
                receipts.c.organization_id == org, receipts.c.reversal_of == reverse_of,
                receipts.c.decision == "accepted",
            ).limit(1)) is not None:
                raise _Reject("already_reversed")
            debit, credit, updates = await _plan_reversal(conn, org, sender, receiver, reverse_of)
            out_branch, in_branch = receiver, sender
    except _Reject as error:
        decision = str(error)
    else:
        decision = "accepted"
    sequence += 1
    await conn.execute(update(heads).where(heads.c.organization_id == org).values(sequence=sequence))
    await conn.execute(insert(receipts).values(
        organization_id=org, command_id=command, from_branch=sender, to_branch=receiver,
        actor_id=session.actor_id, session_id=session.session_id, sequence=sequence,
        fingerprint=digest, decision=decision, reversal_of=reverse_of,
    ))
    if decision == "accepted":
        for lot, delta, new in updates:
            if new is None:
                await conn.execute(update(lots).where(_where(
                    lots, organization_id=org, branch_id=lot["branch_id"], lot_id=lot["lot_id"],
                )).values(remaining_milli=lot["remaining_milli"] + delta))
            else:
                branch, product, lot_id, cost = new
                await conn.execute(insert(lots).values(
                    organization_id=org, branch_id=branch, product_id=product, lot_id=lot_id,
                    remaining_milli=delta, received_milli=delta, cost_4=cost,
                    **{field: lot[field] for field in (
                        "origin_lot_id", "currency", "received_on", "expiry_on", "lot_number",
                    )},
                ))
        for branch, side in ((out_branch, debit), (in_branch, credit)):
            for line in side:
                await conn.execute(update(products).where(_where(
                    products, organization_id=org, branch_id=branch, product_id=UUID(line["product_id"]),
                )).values(quantity_milli=line["balance_milli"], revision=line["after_revision"]))
            key = dict(organization_id=org, branch_id=branch, command_id=command)
            await conn.execute(insert(effects).values(**key, lines=side))
            readers = (await conn.scalars(select(grants.c.session_id).where(
                _where(grants, organization_id=org, branch_id=branch), grants.c.can_read.is_(True),
            ))).all()
            if readers:
                await conn.execute(insert(deliveries), [
                    {**key, "session_id": reader, "delivery_key": uuid4()} for reader in readers
                ])
    return StockDecision(command, sequence, decision)


async def poll(conn: AsyncConnection, session: StockSession):
    await _lock(conn, session.organization_id)
    await _read_grant(conn, session, session.branch_id)
    rows = (await conn.execute(select(
        deliveries.c.command_id, deliveries.c.delivery_key, receipts.c.sequence,
        receipts.c.reversal_of, effects.c.lines,
    ).select_from(deliveries.join(effects).join(receipts)).where(_where(
        deliveries, organization_id=session.organization_id, branch_id=session.branch_id,
        session_id=session.session_id,
    )).order_by(receipts.c.sequence).limit(50))).mappings().all()
    return [dict(row) for row in rows]


async def acknowledge(conn: AsyncConnection, session: StockSession, command: UUID, key: UUID) -> None:
    await _lock(conn, session.organization_id)
    await _read_grant(conn, session, session.branch_id)
    match = dict(organization_id=session.organization_id, branch_id=session.branch_id,
                 command_id=command, session_id=session.session_id)
    row = await _row(conn, deliveries, **match)
    if row is None:
        return  # Retry after a committed acknowledgment.
    if row["delivery_key"] != key:
        raise StockAccessDenied
    await conn.execute(delete(deliveries).where(_where(deliveries, **match)))
