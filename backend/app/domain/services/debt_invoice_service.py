"""Debt-invoice adjustment & permanent deletion with full reversal.

Merchant-only operations on a CONFIRMED debt invoice:
- adjust: change quantity/unit_price of lines, recompute totals, adjust stock
  (and lots), update the receivable/payable, and record before→after changes.
- delete: restore stock/lots, reverse bank payments, remove the receivable,
  soft-delete the invoice, and record an audit trail.
Everything runs in the caller's transaction (the router commits).
"""

from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Dict, List, Optional
from uuid import UUID

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.business_entities import (
    InventoryMovement, Product,
)
from app.domain.entities.finance_entities import BankAccount, BankTransaction
from app.domain.entities.invoice_entities import (
    Invoice, InvoiceItem, InvoiceItemChange, Payment,
)
from app.domain.entities.sale_entities import (
    CustomerReceivable, InventoryLot, SupplierPayable,
)
from app.domain.services import inventory_lots as lots
from app.domain.services import branch_stock_service as bstock
from app.domain.services.sale_service import TAU, _q, calc_totals

ZERO = Decimal("0")


async def _invoice_for_party(
    db: AsyncSession, org_id: UUID, kind: str, party_id: UUID, invoice_id: UUID
) -> Invoice:
    col = (Invoice.customer_id if kind == "customer" else Invoice.supplier_id)
    inv = (
        await db.execute(
            select(Invoice).where(
                Invoice.id == invoice_id,
                Invoice.organization_id == org_id,
                col == party_id,
                Invoice.is_deleted.is_(False),
            ).with_for_update()
        )
    ).scalar_one_or_none()
    if inv is None:
        raise ValueError("الفاتورة غير موجودة")
    if inv.status in ("draft", "cancelled"):
        raise ValueError("لا يمكن تعديل أو حذف فاتورة مسودة أو ملغاة")
    return inv


async def _receivable(
    db: AsyncSession, org_id: UUID, kind: str, invoice_id: UUID
):
    model = CustomerReceivable if kind == "customer" else SupplierPayable
    return (
        await db.execute(
            select(model).where(
                model.organization_id == org_id,
                model.invoice_id == invoice_id,
            ).with_for_update()
        )
    ).scalar_one_or_none()


async def _product(db: AsyncSession, org_id: UUID, product_id: UUID):
    return (
        await db.execute(
            select(Product).where(
                Product.id == product_id,
                Product.organization_id == org_id,
            ).with_for_update()
        )
    ).scalar_one_or_none()


def _dec(v) -> Decimal:
    return Decimal(str(v if v is not None else 0))


async def adjust_debt_invoice(
    db: AsyncSession, org_id: UUID, actor: UUID, kind: str, party_id: UUID,
    invoice_id: UUID, changes: List[Dict[str, Any]],
) -> Dict[str, Any]:
    inv = await _invoice_for_party(db, org_id, kind, party_id, invoice_id)
    is_sale = inv.invoice_type == "sale"
    items = (
        await db.execute(
            select(InvoiceItem).where(InvoiceItem.invoice_id == inv.id)
        )
    ).scalars().all()
    by_id = {str(it.id): it for it in items}
    changed = 0
    applied_changes = []
    for ch in changes:
        it = by_id.get(str(ch.get("item_id") or ""))
        if it is None:
            continue
        new_qty = float(ch.get("quantity") or 0)
        new_price = _dec(ch.get("unit_price"))
        if new_qty <= 0 or new_price < ZERO:
            raise ValueError("الكمية أو السعر غير صالح")
        old_qty = float(it.quantity or 0)
        old_price = _dec(it.unit_price)
        if abs(new_qty - old_qty) < 1e-9 and new_price == old_price:
            continue
        factor = float(it.factor or 1) or 1.0
        old_base = float(it.base_quantity or 0) or old_qty * factor
        new_base = new_qty * factor
        delta = new_base - old_base
        if it.product_id and not it.is_service and abs(delta) > 1e-9:
            product = await _product(db, org_id, it.product_id)
            if product is not None:
                if is_sale:
                    if delta > 0:
                        if float(await bstock.available(
                                db, org_id, inv.branch_id, product)) + 1e-9 < delta:
                            raise ValueError("الكمية أكبر من المخزون المتاح")
                        await bstock.apply_delta(db, org_id, inv.branch_id,
                                                 product, -delta)
                        await lots.consume_fifo_fefo(
                            db, org_id, product, delta,
                            inv.currency or "", invoice_item_id=it.id)
                    else:
                        await bstock.apply_delta(db, org_id, inv.branch_id,
                                                 product, -delta)
                        await lots.restore_to_lots(
                            db, org_id, product, it.id, -delta)
                else:
                    if delta > 0:
                        await bstock.apply_delta(db, org_id, inv.branch_id,
                                                 product, delta)
                        await lots.create_lot(
                            db, org_id, product, delta, new_price,
                            inv.currency or "",
                            purchase_invoice_id=inv.id,
                            invoice_item_id=it.id)
                    else:
                        if float(await bstock.available(
                                db, org_id, inv.branch_id, product)) + 1e-9 < (-delta):
                            raise ValueError("لا يمكن خفض المخزون أكثر من المتاح")
                        await bstock.apply_delta(db, org_id, inv.branch_id,
                                                 product, delta)
                        await lots.adjust_lots(
                            db, org_id, product, delta, inv.currency or "")
                db.add(InventoryMovement(
                    organization_id=org_id, product_id=product.id,
                    movement_type=("sale_adjust" if is_sale
                                   else "purchase_adjust"),
                    quantity=delta, unit_price=new_price,
                    total=_q(new_price * _dec(delta)),
                    currency=inv.currency,
                    reference_type="invoice", reference_id=inv.id,
                    notes=f"تعديل {inv.invoice_number}", created_by=actor,
                ))
        it.quantity = new_qty
        it.unit_price = new_price
        it.total = _q(new_price * _dec(new_qty) - _dec(it.discount))
        it.base_quantity = new_base
        qty_changed = abs(new_qty - old_qty) > 1e-9
        price_changed = new_price != old_price
        db.add(InvoiceItemChange(
            organization_id=org_id, invoice_id=inv.id, item_id=it.id,
            description=it.description,
            old_quantity=old_qty if qty_changed else None,
            new_quantity=new_qty if qty_changed else None,
            old_unit_price=old_price if price_changed else None,
            new_unit_price=new_price if price_changed else None,
            changed_by=actor,
        ))
        applied_changes.append({
            "description": it.description,
            "old_quantity": old_qty if qty_changed else None,
            "new_quantity": new_qty if qty_changed else None,
            "old_unit_price": str(old_price) if price_changed else None,
            "new_unit_price": str(new_price) if price_changed else None,
        })
        changed += 1
    if changed == 0:
        raise ValueError("لا توجد تعديلات")
    lines = [
        {"quantity": it.quantity, "unit_price": _dec(it.unit_price),
         "discount": _dec(it.discount)}
        for it in items
    ]
    totals = calc_totals(
        lines, inv.discount_type, _dec(inv.discount_value),
        inv.tax_type, _dec(inv.tax_rate))
    inv.subtotal = totals["subtotal"]
    inv.discount_amount = totals["discount_amount"]
    inv.tax_amount = totals["tax_amount"]
    inv.total = totals["total"]
    paid = _dec(inv.paid_amount)
    new_balance = totals["total"] - paid
    if new_balance < ZERO:
        new_balance = ZERO
    inv.balance = _q(new_balance)
    inv.status = ("paid" if new_balance <= TAU
                  else ("partially_paid" if paid > ZERO else "confirmed"))
    rec = await _receivable(db, org_id, kind, inv.id)
    if rec is not None:
        rec.amount = _q(new_balance + _dec(rec.paid))
        rem = _dec(rec.amount) - _dec(rec.paid)
        rec.status = ("paid" if rem <= TAU
                      else ("partial" if _dec(rec.paid) > ZERO else "open"))
    await db.flush()
    return {
        "invoice_id": str(inv.id), "number": inv.invoice_number,
        "total": float(inv.total), "balance": float(inv.balance),
        "status": inv.status, "paid": float(inv.paid_amount or 0),
        "party_kind": kind, "party_id": str(party_id),
        "changes": applied_changes,
    }


async def delete_debt_invoice(
    db: AsyncSession, org_id: UUID, actor: UUID, kind: str, party_id: UUID,
    invoice_id: UUID,
) -> Dict[str, Any]:
    inv = await _invoice_for_party(db, org_id, kind, party_id, invoice_id)
    is_sale = inv.invoice_type == "sale"
    items = (
        await db.execute(
            select(InvoiceItem).where(InvoiceItem.invoice_id == inv.id)
        )
    ).scalars().all()
    for it in items:
        if not it.product_id or it.is_service:
            continue
        product = await _product(db, org_id, it.product_id)
        if product is None:
            continue
        base = float(it.base_quantity or 0)
        if base <= 0:
            continue
        if is_sale:
            await bstock.apply_delta(db, org_id, inv.branch_id, product, base)
            await lots.restore_to_lots(db, org_id, product, it.id, base)
        else:
            lot_rows = (
                await db.execute(
                    select(InventoryLot).where(
                        InventoryLot.organization_id == org_id,
                        InventoryLot.purchase_invoice_id == inv.id,
                        InventoryLot.invoice_item_id == it.id,
                    ).with_for_update()
                )
            ).scalars().all()
            for lot in lot_rows:
                if (float(lot.remaining_quantity or 0) + 1e-6
                        < float(lot.received_quantity or 0)):
                    raise ValueError(
                        "لا يمكن حذف فاتورة شراء استُهلك جزء من مخزونها")
            for lot in lot_rows:
                await db.delete(lot)
            if float(product.stock or 0) + 1e-9 < base:
                raise ValueError("المخزون غير كافٍ للتراجع عن الفاتورة")
            await bstock.apply_delta(db, org_id, inv.branch_id, product, -base)
    await db.execute(delete(InventoryMovement).where(
        InventoryMovement.organization_id == org_id,
        InventoryMovement.reference_type == "invoice",
        InventoryMovement.reference_id == inv.id,
    ))
    pays = (
        await db.execute(select(Payment).where(Payment.invoice_id == inv.id))
    ).scalars().all()
    for p in pays:
        if p.bank_account_id:
            acct = (
                await db.execute(
                    select(BankAccount).where(
                        BankAccount.id == p.bank_account_id
                    ).with_for_update()
                )
            ).scalar_one_or_none()
            if acct is not None:
                amt = _dec(p.original_amount if p.original_amount is not None
                           else p.amount)
                if is_sale:
                    acct.balance = _dec(acct.balance) - amt
                    tx_type = "withdrawal"
                else:
                    acct.balance = _dec(acct.balance) + amt
                    tx_type = "deposit"
                db.add(BankTransaction(
                    organization_id=org_id, bank_account_id=acct.id,
                    date=datetime.now(timezone.utc),
                    description=f"إلغاء فاتورة {inv.invoice_number}",
                    tx_type=tx_type, amount=amt,
                    currency=p.payment_currency or inv.currency,
                    running_balance=acct.balance,
                    reference=f"cancel:{inv.id}",
                ))
        await db.delete(p)
    rec = await _receivable(db, org_id, kind, inv.id)
    if rec is not None:
        await db.delete(rec)
    inv.is_deleted = True
    inv.status = "cancelled"
    inv.cancelled_at = datetime.now(timezone.utc)
    await db.flush()
    return {
        "invoice_id": str(inv.id), "number": inv.invoice_number,
        "total": float(inv.total or 0),
        "paid": float(inv.paid_amount or 0),
        "party_kind": kind, "party_id": str(party_id),
    }
