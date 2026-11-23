"""Inventory lot engine: FIFO/FEFO consumption, lot creation, real COGS.

Every purchase line becomes an independent lot row. Sales consume lots FIFO
(oldest first) or FEFO (nearest expiry first) and record exactly which lots
left the warehouse, so cost of goods sold and profit come from the real
batches — never from a blended average.

Currency: a lot keeps its original cost + currency. At consumption, cost is
converted to the sale-invoice currency using a rate frozen at that moment
(so a later rate change never alters an old sale's profit). When no rate can
be resolved, cost is returned as ``None`` instead of a wrong number.
"""
from datetime import date, datetime, timezone
from decimal import Decimal
from typing import List, Optional
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.sale_entities import InventoryLot, InventoryLotConsumption
from app.domain.entities.business_entities import Product

ZERO = Decimal("0")
TAU = Decimal("0.00001")


def _q(v) -> Decimal:
    return Decimal(str(v)).quantize(Decimal("0.01"))


async def _rate(from_ccy: str, to_ccy: str) -> Optional[float]:
    from_ccy = (from_ccy or "").strip().upper()
    to_ccy = (to_ccy or "").strip().upper()
    if not from_ccy or not to_ccy:
        return None
    if from_ccy == to_ccy:
        return 1.0
    try:
        from app.domain.services.currency_service import CentralFXEngine

        res = await CentralFXEngine.get_instance().get_rate(from_ccy, to_ccy)
        r = (res or {}).get("rate")
        if r is None or float(r) <= 0:
            return None
        return float(r)
    except Exception:
        return None


async def create_lot(
    db: AsyncSession,
    org_id: UUID,
    product: Product,
    base_qty: float,
    unit_cost,
    currency: str,
    *,
    branch_id: Optional[UUID] = None,
    supplier_id: Optional[UUID] = None,
    purchase_invoice_id: Optional[UUID] = None,
    invoice_item_id: Optional[UUID] = None,
    unit_id: Optional[UUID] = None,
    purchase_date: Optional[date] = None,
    expiry_date: Optional[date] = None,
    lot_number: Optional[str] = None,
    source: str = "purchase",
) -> InventoryLot:
    lot = InventoryLot(
        organization_id=org_id,
        product_id=product.id,
        branch_id=branch_id,
        supplier_id=supplier_id,
        purchase_invoice_id=purchase_invoice_id,
        invoice_item_id=invoice_item_id,
        unit_id=unit_id,
        received_quantity=float(base_qty),
        remaining_quantity=float(base_qty),
        unit_cost=Decimal(str(unit_cost or 0)),
        currency=(currency or "").strip().upper() or None,
        purchase_date=purchase_date or date.today(),
        expiry_date=expiry_date,
        lot_number=lot_number,
        source=source,
    )
    db.add(lot)
    await db.flush()
    return lot


def _lot_order(lots: List[InventoryLot]):
    has_expiry = any(l.expiry_date is not None for l in lots)
    if has_expiry:  # FEFO — nearest expiry first, no-expiry last
        return sorted(
            lots,
            key=lambda l: (
                l.expiry_date is None,
                l.expiry_date or date.max,
                l.created_at or datetime.min,
            ),
        )
    # FIFO — oldest receipt first
    return sorted(
        lots,
        key=lambda l: (l.purchase_date or date.min, l.created_at or datetime.min),
    )


async def consume_fifo_fefo(
    db: AsyncSession,
    org_id: UUID,
    product: Product,
    base_qty: float,
    invoice_ccy: str,
    *,
    invoice_item_id: Optional[UUID] = None,
) -> Optional[Decimal]:
    """Consume [base_qty] base units from the product's lots. Returns the COGS
    in the invoice currency, or None when a cross-currency rate is unknown."""
    need = float(base_qty)
    invoice_ccy = (invoice_ccy or "").strip().upper()
    if need <= 1e-9:
        return ZERO

    lots = (
        await db.execute(
            select(InventoryLot)
            .where(
                InventoryLot.organization_id == org_id,
                InventoryLot.product_id == product.id,
                InventoryLot.remaining_quantity > 0,
            )
            .with_for_update()
        )
    ).scalars().all()

    cost = ZERO
    unknown = False
    for lot in _lot_order(list(lots)):
        if need <= 1e-9:
            break
        avail = float(lot.remaining_quantity or 0)
        if avail <= 1e-9:
            continue
        take = min(avail, need)
        lot.remaining_quantity = avail - take
        lot_ccy = (lot.currency or invoice_ccy).strip().upper()
        unit_cost = Decimal(str(lot.unit_cost or 0))
        if lot_ccy == invoice_ccy:
            rate = 1.0
        else:
            rate = await _rate(lot_ccy, invoice_ccy)
            if rate is None:
                unknown = True
                rate = 1.0
        cost += unit_cost * Decimal(str(take)) * Decimal(str(rate))
        db.add(
            InventoryLotConsumption(
                organization_id=org_id,
                lot_id=lot.id,
                invoice_item_id=invoice_item_id,
                quantity=take,
                unit_cost=unit_cost,
                currency=lot_ccy,
            )
        )
        need -= take

    # Legacy stock with no lots: cover the shortfall with an opening lot valued
    # at the product's last known cost so costing is never silently lost.
    if need > 1e-9:
        oc = (product.cost_currency or invoice_ccy).strip().upper()
        uc = Decimal(str(product.cost_price or 0))
        lot = await create_lot(
            db, org_id, product, need, uc, oc,
            source="opening", invoice_item_id=invoice_item_id,
        )
        lot.remaining_quantity = 0.0
        if oc == invoice_ccy:
            rate = 1.0
        else:
            rate = await _rate(oc, invoice_ccy)
            if rate is None:
                unknown = True
                rate = 1.0
        cost += uc * Decimal(str(need)) * Decimal(str(rate))
        db.add(
            InventoryLotConsumption(
                organization_id=org_id,
                lot_id=lot.id,
                invoice_item_id=invoice_item_id,
                quantity=need,
                unit_cost=uc,
                currency=oc or None,
            )
        )

    await db.flush()
    return None if unknown else _q(cost)


async def restore_to_lots(
    db: AsyncSession,
    org_id: UUID,
    product: Product,
    invoice_item_id: UUID,
    base_qty: float,
) -> None:
    """Sale return: put base units back into the SAME lots they came from
    (reverse order). Any overflow becomes an opening lot."""
    pending = float(base_qty)
    cons = (
        await db.execute(
            select(InventoryLotConsumption)
            .where(
                InventoryLotConsumption.organization_id == org_id,
                InventoryLotConsumption.invoice_item_id == invoice_item_id,
            )
            .order_by(InventoryLotConsumption.created_at.desc())
        )
    ).scalars().all()
    for c in cons:
        if pending <= 1e-9:
            break
        lot = (
            await db.execute(
                select(InventoryLot)
                .where(InventoryLot.id == c.lot_id)
                .with_for_update()
            )
        ).scalar_one_or_none()
        if not lot:
            continue
        back = min(float(c.quantity or 0), pending)
        lot.remaining_quantity = float(lot.remaining_quantity or 0) + back
        pending -= back
    if pending > 1e-9:
        await create_lot(
            db, org_id, product, pending,
            Decimal(str(product.cost_price or 0)),
            (product.cost_currency or ""), source="return",
        )
    await db.flush()


async def adjust_lots(
    db: AsyncSession,
    org_id: UUID,
    product: Product,
    diff: float,
    invoice_ccy: str,
) -> None:
    """Stock adjustment: removing stock consumes lots FIFO/FEFO; adding stock
    creates a lot valued at the product's last cost."""
    if diff < -1e-9:
        await consume_fifo_fefo(db, org_id, product, -diff, invoice_ccy)
    elif diff > 1e-9:
        await create_lot(
            db, org_id, product, diff,
            Decimal(str(product.cost_price or 0)),
            (product.cost_currency or invoice_ccy), source="adjustment",
        )


async def transfer_lots(
    db: AsyncSession,
    org_id: UUID,
    product: Product,
    qty: float,
    from_branch_id: Optional[UUID],
    to_branch_id: Optional[UUID],
    user_id: Optional[UUID] = None,
) -> None:
    """Move [qty] base units between branches as a stock move (not a sale or
    purchase): lots leave the source (FIFO/FEFO) and mirrored lots appear at
    the target with the SAME cost/currency/expiry — total stock is unchanged."""
    need = float(qty)
    if need <= 1e-9:
        return
    conds = [
        InventoryLot.organization_id == org_id,
        InventoryLot.product_id == product.id,
        InventoryLot.remaining_quantity > 0,
    ]
    if from_branch_id is not None:
        conds.append(InventoryLot.branch_id == from_branch_id)
    lots = (
        await db.execute(select(InventoryLot).where(*conds).with_for_update())
    ).scalars().all()
    for lot in _lot_order(list(lots)):
        if need <= 1e-9:
            break
        avail = float(lot.remaining_quantity or 0)
        take = min(avail, need)
        if take <= 1e-9:
            continue
        lot.remaining_quantity = avail - take
        db.add(
            InventoryLot(
                organization_id=org_id,
                product_id=product.id,
                branch_id=to_branch_id,
                unit_id=lot.unit_id,
                received_quantity=take,
                remaining_quantity=take,
                unit_cost=lot.unit_cost,
                currency=lot.currency,
                purchase_date=lot.purchase_date,
                expiry_date=lot.expiry_date,
                lot_number=lot.lot_number,
                source="transfer",
            )
        )
        need -= take
    if need > 1e-9:
        raise ValueError("الكمية غير كافية للتحويل في هذا الفرع")
    await db.flush()


async def move_branch_transfer_lots(db, org_id, source, target, from_branch, to_branch,
                                    source_qty, target_qty, item_id):
    """Original FIFO/FEFO order, exact mapped base units and immutable lot metadata.

    Opening coverage is limited to real legacy branch stock, not an invented
    quantity or a product-wide balance from another branch.
    """
    from .branch_stock_service import available_locked
    from ..entities.branch_entities import BranchTransferLotMove
    source_qty, target_qty = Decimal(str(source_qty)), Decimal(str(target_qty))
    rows = list((await db.scalars(select(InventoryLot).where(
        InventoryLot.organization_id == org_id, InventoryLot.product_id == source.id,
        InventoryLot.branch_id == from_branch, InventoryLot.remaining_quantity > 0)
        .with_for_update().execution_options(populate_existing=True))).all())
    available = await available_locked(db, org_id, from_branch, source)
    covered = sum((Decimal(str(l.remaining_quantity)) for l in rows), ZERO)
    if available + TAU < source_qty:
        raise ValueError('الكمية غير كافية للتحويل في هذا الفرع')
    if covered + TAU < available:
        rows.append(await create_lot(db, org_id, source, float(available - covered),
            source.cost_price, source.cost_currency, branch_id=from_branch, source='opening'))
    need, remaining_target, valuations = source_qty, target_qty, {}
    for lot in _lot_order(rows):
        if need <= ZERO:
            break
        take = min(Decimal(str(lot.remaining_quantity)), need)
        if take <= ZERO:
            continue
        mapped = remaining_target if take == need else (take * target_qty / source_qty).quantize(Decimal('0.00000001'))
        cost = Decimal(str(lot.unit_cost or 0))
        received = await create_lot(db, org_id, target, float(mapped),
            cost * take / mapped, lot.currency, branch_id=to_branch,
            purchase_date=lot.purchase_date, expiry_date=lot.expiry_date,
            lot_number=lot.lot_number, source='branch_transfer')
        lot.remaining_quantity = float(Decimal(str(lot.remaining_quantity)) - take)
        db.add(BranchTransferLotMove(transfer_item_id=item_id, source_lot_id=lot.id,
            target_lot_id=received.id, source_quantity=take, target_quantity=mapped))
        valuations[lot.currency] = valuations.get(lot.currency, ZERO) + cost * take
        need -= take
        remaining_target -= mapped
    if need > TAU:
        raise ValueError('الكمية غير كافية للتحويل في هذا الفرع')
    await db.flush()
    return valuations


async def reverse_branch_transfer_lots(db, org_id, item_id, quantity, *, apply=False):
    """Preflight or restore only this transfer's exact received batches."""
    from ..entities.branch_entities import BranchTransferLotMove
    moves = (await db.scalars(select(BranchTransferLotMove).where(
        BranchTransferLotMove.transfer_item_id == item_id).order_by(BranchTransferLotMove.id)
        .with_for_update().execution_options(populate_existing=True))).all()
    if not moves:
        return False  # Pre-118 history requires an explicit legacy reconciliation.
    need = Decimal(str(quantity))
    for move in moves:
        if need <= ZERO:
            break
        remaining = move.target_quantity - move.returned_quantity
        take = min(remaining, need)
        if take <= ZERO:
            continue
        target = (await db.scalars(select(InventoryLot).where(
            InventoryLot.id == move.target_lot_id, InventoryLot.organization_id == org_id)
            .with_for_update().execution_options(populate_existing=True))).one()
        if Decimal(str(target.remaining_quantity)) + TAU < take:
            raise ValueError('دفعات التحويل في الفرع المستلم غير كافية للعكس')
        if apply:
            source = (await db.scalars(select(InventoryLot).where(
                InventoryLot.id == move.source_lot_id, InventoryLot.organization_id == org_id)
                .with_for_update().execution_options(populate_existing=True))).one()
            back = take * move.source_quantity / move.target_quantity
            target.remaining_quantity = float(Decimal(str(target.remaining_quantity)) - take)
            source.remaining_quantity = float(Decimal(str(source.remaining_quantity)) + back)
            move.returned_quantity += take
        need -= take
    if need > TAU:
        raise ValueError('دفعات التحويل غير كافية للعكس')
    if apply:
        await db.flush()
    return True
