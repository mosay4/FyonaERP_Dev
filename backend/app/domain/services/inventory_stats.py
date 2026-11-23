"""Business inventory statistics (real numbers, computed in the backend).

Aggregates sales/purchases/COGS/profit per product (and per period) from the
actual invoice lines and the FIFO/FEFO lot consumption — never from an
approximate cost. The AI (Falcon) only *explains* these numbers.

Money is bucketed by each invoice's REAL currency and converted to the
requested DISPLAY currency (default: the product's first priced currency —
never USD-hardcoded) so totals are exact and never mix currencies.
"""
from datetime import date
from decimal import Decimal
from typing import Optional
from uuid import UUID

from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.auth_entities import User
from app.domain.entities.business_entities import InventoryMovement
from app.domain.entities.invoice_entities import Invoice, InvoiceItem
from app.domain.services.fx_snapshot import convert_invoice_amount


def _f(v) -> float:
    return float(v or 0)


async def _fx_rate(from_ccy: str, to_ccy: str) -> float:
    """Live conversion rate via the central FX engine (report-only; it never
    mutates stored data). Falls back to 1.0 when unavailable."""
    from_ccy = (from_ccy or "").strip().upper()
    to_ccy = (to_ccy or "").strip().upper()
    if not from_ccy or not to_ccy or from_ccy == to_ccy:
        return 1.0
    try:
        from app.domain.services.currency_service import CentralFXEngine

        res = await CentralFXEngine.get_instance().get_rate(from_ccy, to_ccy)
        r = (res or {}).get("rate")
        return float(r) if r and float(r) > 0 else 1.0
    except Exception:
        return 1.0


async def product_price_currencies(
    db: AsyncSession, org_id: UUID, product_id: UUID
) -> list:
    """The currencies the product is actually PRICED in (product_prices rows),
    ordered as the merchant set them — the authoritative display options."""
    from app.domain.entities.sale_entities import ProductPrice

    rows = (
        await db.execute(
            select(ProductPrice.currency)
            .where(
                ProductPrice.organization_id == org_id,
                ProductPrice.product_id == product_id,
            )
            .order_by(ProductPrice.created_at)
        )
    ).all()
    return [str(c).strip().upper() for (c,) in rows if c]


async def product_stats(
    db: AsyncSession,
    org_id: UUID,
    product_id: UUID,
    date_from: Optional[date] = None,
    date_to: Optional[date] = None,
    display_currency: Optional[str] = None,
) -> dict:
    # ── Display currency: the product's FIRST priced currency by default
    # (never USD-hardcoded). All money below is converted INTO it before
    # summing, bucketed by each invoice's real currency.
    priced = await product_price_currencies(db, org_id, product_id)
    display = (display_currency or "").strip().upper()
    if not display or (priced and display not in priced):
        display = priced[0] if priced else (display or "SAR")

    q = (
        select(
            InvoiceItem,
            Invoice.invoice_type,
            Invoice.currency,
        )
        .join(Invoice, Invoice.id == InvoiceItem.invoice_id)
        .where(
            Invoice.organization_id == org_id,
            InvoiceItem.product_id == product_id,
            Invoice.is_deleted.is_(False),
        )
    )
    if date_from:
        q = q.where(Invoice.invoice_date >= date_from)
    if date_to:
        q = q.where(Invoice.invoice_date <= date_to)
    rows = (await db.execute(q)).all()

    sales_total = Decimal("0")
    sales_qty = 0.0
    sales_orders = set()
    cogs = Decimal("0")
    profit = Decimal("0")
    purchases_total = Decimal("0")
    purchases_qty = 0.0
    purchase_orders = set()
    money_ccys: set = set()
    fx_incomplete = False
    for it, typ, inv_ccy in rows:
        typ = (typ or "").lower()
        ccy = (inv_ccy or display).strip().upper()
        if ccy:
            money_ccys.add(ccy)
        # Convert THIS line to the display currency using its FROZEN snapshot
        # (original price currency + saved rate) when available, so historical
        # statistics don't shift with today's live FX. An IMPOSSIBLE conversion
        # (different currencies, no rate) yields None — never a silent 1:1 — so
        # the amount is excluded and the result is flagged `fx_incomplete`.
        pcy = getattr(it, "price_currency", None)
        rused = getattr(it, "exchange_rate_used", None)
        total_conv = await convert_invoice_amount(it.total, ccy, display, pcy, rused)
        if typ == "sale":
            if total_conv is None:
                fx_incomplete = True
            else:
                sales_total += total_conv
            sales_qty += float(it.base_quantity or 0)
            sales_orders.add(str(it.invoice_id))
            cogs_conv = await convert_invoice_amount(
                it.cost_total, ccy, display, pcy, rused)
            if cogs_conv is None:
                fx_incomplete = True
            else:
                cogs += cogs_conv
            profit_conv = await convert_invoice_amount(
                it.profit, ccy, display, pcy, rused)
            if profit_conv is None:
                fx_incomplete = True
            else:
                profit += profit_conv
        elif typ == "purchase":
            if total_conv is None:
                fx_incomplete = True
            else:
                purchases_total += total_conv
            purchases_qty += float(it.base_quantity or 0)
            purchase_orders.add(str(it.invoice_id))

    # Movement timeline (with reference + who did it).
    mq = select(InventoryMovement).where(
        InventoryMovement.organization_id == org_id,
        InventoryMovement.product_id == product_id,
    )
    if date_from:
        mq = mq.where(func.date(InventoryMovement.created_at) >= date_from)
    if date_to:
        mq = mq.where(func.date(InventoryMovement.created_at) <= date_to)
    movements = (
        await db.execute(mq.order_by(InventoryMovement.created_at.desc()).limit(200))
    ).scalars().all()

    # Resolve the linked invoice TYPE so the client opens the right viewer.
    ref_ids = [
        m.reference_id
        for m in movements
        if m.reference_type == "invoice" and m.reference_id
    ]
    type_map: dict = {}
    if ref_ids:
        for iid, itype in (
            await db.execute(
                select(Invoice.id, Invoice.invoice_type).where(Invoice.id.in_(ref_ids))
            )
        ).all():
            type_map[str(iid)] = itype

    # Resolve who performed each movement (name + role) in one query so the
    # client can show «تم بواسطة المدير» for owner/manager actions.
    creator_ids = {m.created_by for m in movements if m.created_by}
    performers: dict = {}
    if creator_ids:
        for uid, name, role in (
            await db.execute(
                select(User.id, User.full_name, User.role).where(
                    User.id.in_(creator_ids)
                )
            )
        ).all():
            performers[str(uid)] = {"name": name, "role": role or ""}

    return {
        "display_currency": display,
        "priced_currencies": priced,
        "fx_incomplete": fx_incomplete,
        "sales_total": _f(sales_total),
        "sales_quantity": sales_qty,
        "sales_count": len(sales_orders),
        "purchases_total": _f(purchases_total),
        "purchases_quantity": purchases_qty,
        "purchases_count": len(purchase_orders),
        "cogs": _f(cogs),
        "profit": _f(profit),
        "movements": [
            {
                "id": str(m.id),
                "type": m.movement_type,
                "movement_type": m.movement_type,
                "quantity": _f(m.quantity),
                "unit_price": _f(m.unit_price),
                "total": _f(m.total),
                "currency": m.currency,
                "reason": m.reason,
                "old_quantity": (
                    float(m.old_quantity)
                    if m.old_quantity is not None
                    else None
                ),
                "new_quantity": (
                    float(m.new_quantity)
                    if m.new_quantity is not None
                    else None
                ),
                "difference": (
                    float(m.difference) if m.difference is not None else None
                ),
                "reference_type": m.reference_type,
                "reference_id": str(m.reference_id) if m.reference_id else None,
                "invoice_type": (
                    type_map.get(str(m.reference_id)) if m.reference_id else None
                ),
                "notes": m.notes,
                "created_at": m.created_at.isoformat() if m.created_at else None,
                "created_by": str(m.created_by) if m.created_by else None,
                "performer_name": (
                    performers.get(str(m.created_by), {}).get("name")
                    if m.created_by
                    else None
                ),
                "performer_role": (
                    performers.get(str(m.created_by), {}).get("role")
                    if m.created_by
                    else None
                ),
                "performed_by_manager": (
                    performers.get(str(m.created_by), {}).get("role")
                    in ("owner", "manager")
                    if m.created_by
                    else False
                ),
            }
            for m in movements
        ],
    }
