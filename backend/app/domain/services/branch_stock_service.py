"""Per-branch stock and weighted-average cost (Option A)."""
from decimal import Decimal
from typing import Optional, Tuple
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.sale_entities import Branch, BranchStock


async def get_stock(db: AsyncSession, branch_id: UUID,
                    product_id: UUID) -> Tuple[Decimal, Decimal]:
    row = (await db.execute(select(BranchStock).where(
        BranchStock.branch_id == branch_id,
        BranchStock.product_id == product_id,
    ))).scalar_one_or_none()
    if row is None:
        return Decimal("0"), Decimal("0")
    return Decimal(str(row.quantity or 0)), Decimal(str(row.avg_cost or 0))


async def adjust_stock(
    db: AsyncSession, organization_id: UUID, branch_id: UUID,
    product_id: UUID, delta: Decimal,
    unit_cost: Optional[Decimal] = None,
) -> BranchStock:
    """Atomic per-branch change. Positive receipts move the weighted average;
    negative issues keep the existing average cost."""
    row = (await db.execute(select(BranchStock).where(
        BranchStock.branch_id == branch_id,
        BranchStock.product_id == product_id,
    ).with_for_update())).scalar_one_or_none()
    if row is None:
        row = BranchStock(organization_id=organization_id, branch_id=branch_id,
                          product_id=product_id, quantity=Decimal("0"),
                          avg_cost=Decimal(str(unit_cost or 0)))
        db.add(row)
        await db.flush()
    qty = Decimal(str(row.quantity or 0))
    avg = Decimal(str(row.avg_cost or 0))
    d = Decimal(str(delta))
    if d > 0 and unit_cost is not None:
        new_qty = qty + d
        if new_qty > 0:
            avg = ((qty * avg) + (d * Decimal(str(unit_cost)))) / new_qty
    row.quantity = qty + d
    row.avg_cost = avg
    await db.flush()
    return row


async def aggregate_all(db: AsyncSession, organization_id: UUID,
                        product_id: UUID) -> Tuple[Decimal, Decimal]:
    """Unified «all branches» view: summed quantity + total value (no row
    duplication; each branch row is counted once)."""
    qty, value = (await db.execute(select(
        func.coalesce(func.sum(BranchStock.quantity), 0),
        func.coalesce(func.sum(BranchStock.quantity * BranchStock.avg_cost), 0),
    ).where(BranchStock.organization_id == organization_id,
            BranchStock.product_id == product_id))).one()
    return Decimal(str(qty or 0)), Decimal(str(value or 0))


async def available_locked(db: AsyncSession, org_id: UUID, branch_id: Optional[UUID],
                           product) -> Decimal:
    """Lock the branch stock row and return its exact quantity.

    The lock is held until the transaction commits, so two concurrent
    transfers/consumptions cannot both pass the availability check.
    """
    bid = await resolve_branch_id(db, org_id, branch_id)
    is_main = (await db.execute(select(Branch.is_default).where(
        Branch.id == bid))).scalar_one_or_none()
    row = (await db.execute(select(BranchStock).where(
        BranchStock.branch_id == bid,
        BranchStock.product_id == product.id,
    ).with_for_update())).scalar_one_or_none()
    if row is None and is_main:
        seed_qty = Decimal(str(getattr(product, "stock", 0) or 0))
        seed_cost = Decimal(str(getattr(product, "cost_price", 0) or 0))
        row = BranchStock(organization_id=org_id, branch_id=bid,
                          product_id=product.id, quantity=seed_qty,
                          avg_cost=seed_cost)
        db.add(row)
        await db.flush()
    return Decimal(str(row.quantity or 0)) if row is not None else Decimal("0")


async def list_branch_stock(db: AsyncSession, branch_id: UUID):
    return list((await db.execute(select(BranchStock).where(
        BranchStock.branch_id == branch_id))).scalars().all())

async def resolve_branch_id(db: AsyncSession, org_id: UUID,
                            branch_id: Optional[UUID]) -> UUID:
    if branch_id is not None:
        return branch_id
    from app.domain.services.sale_service import get_or_create_default_branch
    return (await get_or_create_default_branch(db, org_id)).id


async def available(db: AsyncSession, org_id: UUID, branch_id: Optional[UUID],
                    product) -> Decimal:
    """Quantity the CURRENT branch may consume/sell (never another branch's)."""
    bid = await resolve_branch_id(db, org_id, branch_id)
    row = (await db.execute(select(BranchStock).where(
        BranchStock.branch_id == bid,
        BranchStock.product_id == product.id,
    ))).scalar_one_or_none()
    if row is not None:
        return Decimal(str(row.quantity or 0))
    is_main = (await db.execute(select(Branch.is_default).where(
        Branch.id == bid))).scalar_one_or_none()
    return Decimal(str(getattr(product, "stock", 0) or 0)) if is_main else Decimal("0")


async def apply_delta(
    db: AsyncSession, org_id: UUID, branch_id: Optional[UUID], product,
    delta, unit_cost=None,
) -> BranchStock:
    """Atomic branch change + Product.stock mirror for the MAIN branch only.

    Every stock mutation path must call this instead of writing
    `Product.stock` directly, so no double deduction ever happens.
    """
    bid = await resolve_branch_id(db, org_id, branch_id)
    is_main = (await db.execute(select(Branch.is_default).where(
        Branch.id == bid))).scalar_one_or_none()
    # Legacy products keep their pre-branch balance in Product.stock. The
    # FIRST per-branch mutation must seed the main branch row from that real
    # balance instead of silently starting at zero (which used to make the
    # second sale see a negative/insufficient branch quantity).
    existing = (await db.execute(select(BranchStock).where(
        BranchStock.branch_id == bid,
        BranchStock.product_id == product.id,
    ))).scalar_one_or_none()
    if existing is None and is_main:
        seed_qty = Decimal(str(getattr(product, "stock", 0) or 0))
        seed_cost = Decimal(str(getattr(product, "cost_price", 0) or 0))
        db.add(BranchStock(
            organization_id=org_id, branch_id=bid, product_id=product.id,
            quantity=seed_qty, avg_cost=seed_cost,
        ))
        await db.flush()
    row = await adjust_stock(db, org_id, bid, product.id,
                             Decimal(str(delta)),
                             Decimal(str(unit_cost)) if unit_cost is not None else None)
    if is_main:
        product.stock = float(product.stock or 0) + float(delta)
    return row


async def set_quantity(db: AsyncSession, org_id: UUID, branch_id: Optional[UUID],
                       product, new_qty) -> BranchStock:
    current = await available(db, org_id, branch_id, product)
    return await apply_delta(db, org_id, branch_id, product,
                             Decimal(str(new_qty)) - current)
