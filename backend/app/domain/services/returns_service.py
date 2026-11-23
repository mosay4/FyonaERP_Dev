"""Business returns — sale (customer) and purchase (supplier).

Every return is ALWAYS linked to its original invoice: sale returns use
`invoice_returns.invoice_id`; purchase returns now use
`purchase_returns.invoice_id` (added in migration 075). A return never
creates a parallel document — it adjusts the SAME invoice's balance,
stock, accounts and party debt, then writes a bank movement and an
inventory movement so «المعاملات» and the reports see it automatically.

The whole operation runs in ONE commit (atomic): money can never move
without stock, or vice-versa.

Sale return  → money OUT of the chosen account (cash refund of the part that
               exceeds the outstanding receivable) + stock goes back IN.
Purchase ret → money INTO the chosen account (cash refund of the part that
               exceeds the outstanding payable) + stock goes OUT.
"""
from __future__ import annotations

from datetime import date, datetime, timezone
from decimal import Decimal
from typing import Optional
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.services import branch_stock_service as bstock

from app.domain.entities.business_entities import (
    Customer,
    InventoryMovement,
    Product,
    Supplier,
)
from app.domain.entities.finance_entities import BankAccount, BankTransaction
from app.domain.entities.invoice_entities import Invoice, InvoiceItem
from app.domain.entities.purchase_entities import PurchaseReturn, PurchaseReturnItem
from app.domain.entities.sale_entities import (
    Branch,
    CustomerReceivable,
    InvoiceReturn,
    InvoiceReturnItem,
    ProductUnit,
    SupplierPayable,
)
from app.domain.models.invoice_models import SaleReturnRequest
from app.domain.services import sale_service

ZERO = Decimal("0")
TAU = Decimal("0.005")
_CAP = 2000


def _q(v: Decimal) -> Decimal:
    return v.quantize(Decimal("0.01"))


# ═══════════════════════════════════════════
# Create — dispatch by invoice type
# ═══════════════════════════════════════════


async def confirm_any_return(
    db: AsyncSession,
    org_id: UUID,
    user_id: UUID,
    invoice_id: UUID,
    data: SaleReturnRequest,
) -> dict:
    """Confirm a return against whatever the invoice is: a sale (customer
    return) or a purchase (supplier return). Keeps ONE client endpoint."""
    inv_type = (
        await db.execute(
            select(Invoice.invoice_type).where(
                Invoice.id == invoice_id,
                Invoice.organization_id == org_id,
            )
        )
    ).scalar_one_or_none()
    if inv_type == "purchase":
        return await confirm_purchase_return(db, org_id, user_id, invoice_id, data)
    return await sale_service.confirm_return(db, org_id, user_id, invoice_id, data)


async def confirm_purchase_return(
    db: AsyncSession,
    org_id: UUID,
    user_id: UUID,
    invoice_id: UUID,
    data: SaleReturnRequest,
) -> dict:
    invoice = (
        await db.execute(
            select(Invoice)
            .where(
                Invoice.id == invoice_id,
                Invoice.organization_id == org_id,
                Invoice.is_deleted.is_(False),
            )
            .with_for_update()
        )
    ).scalar_one_or_none()
    if not invoice or invoice.invoice_type != "purchase":
        raise ValueError("الفاتورة غير موجودة")
    if invoice.status in ("draft", "cancelled"):
        raise ValueError("لا يمكن إرجاع فاتورة مسودة أو ملغية")
    if not data.lines:
        raise ValueError("حدد صنفاً واحداً على الأقل للإرجاع")

    items = (
        await db.execute(select(InvoiceItem).where(InvoiceItem.invoice_id == invoice.id))
    ).scalars().all()
    by_id = {it.id: it for it in items}

    returned: dict = {}
    prior = (
        await db.execute(
            select(PurchaseReturnItem)
            .join(PurchaseReturn, PurchaseReturn.id == PurchaseReturnItem.purchase_return_id)
            .where(
                PurchaseReturn.organization_id == org_id,
                PurchaseReturn.invoice_id == invoice.id,
                PurchaseReturn.status == "confirmed",
            )
        )
    ).scalars().all()
    for pr in prior:
        if pr.invoice_item_id:
            returned[pr.invoice_item_id] = returned.get(pr.invoice_item_id, 0.0) + float(
                pr.quantity or 0
            )

    ret_lines = []
    ret_total = ZERO
    for rl in data.lines:
        src = by_id.get(rl.invoice_item_id)
        if not src:
            raise ValueError("بند غير موجود في الفاتورة الأصلية")
        sold_qty = float(src.quantity or 0)
        already = returned.get(src.id, 0.0)
        if float(rl.quantity) + already - sold_qty > 1e-9:
            raise ValueError(f"الكمية المرتجعة تتجاوز المشترى للبند {src.description}")
        ratio = Decimal(str(rl.quantity)) / Decimal(str(sold_qty)) if sold_qty else ZERO
        prorated_discount = (src.discount or ZERO) * ratio
        line_total = _q(Decimal(str(rl.quantity)) * src.unit_price - prorated_discount)
        # Prefer the conversion-factor SNAPSHOT frozen on the invoice line so a
        # later edit of the unit's factor can never change a historical return.
        # Legacy lines (no snapshot) fall back to the unit's current factor.
        snapshot = getattr(src, "factor", None)
        if snapshot is not None and float(snapshot) > 0:
            factor = float(snapshot)
        else:
            factor = 1.0
            if src.unit_id:
                unit = (
                    await db.execute(select(ProductUnit).where(ProductUnit.id == src.unit_id))
                ).scalar_one_or_none()
                if unit and unit.factor:
                    factor = float(unit.factor)
        ret_total += line_total
        ret_lines.append(
            {
                "src": src,
                "quantity": float(rl.quantity),
                "base_quantity": float(rl.quantity) * factor,
                "unit_price": src.unit_price,
                "total": line_total,
                "restock": bool(getattr(rl, "restock", True)),
            }
        )
    ret_total = _q(ret_total)

    # ── Money: shrink the outstanding payable first, receive the rest ──
    balance = Decimal(str(invoice.balance or 0))
    paid = Decimal(str(invoice.paid_amount or 0))
    apply = min(ret_total, balance)
    remainder = ret_total - apply
    inv_cur = (invoice.currency or "SAR").strip().upper()
    refund_account = None
    move_amount = ZERO  # what actually enters the account (its own currency)
    refund_cur = inv_cur
    if remainder > TAU:
        if not data.refund_account_id:
            raise ValueError("المبلغ المسترد نقداً يحتاج حساب الاسترداد")
        refund_account = (
            await db.execute(
                select(BankAccount).where(
                    BankAccount.id == data.refund_account_id,
                    BankAccount.organization_id == org_id,
                    BankAccount.is_deleted.is_(False),
                )
            )
        ).scalar_one_or_none()
        if not refund_account or not refund_account.is_active:
            raise ValueError("حساب الاسترداد غير موجود")
        refund_cur = (refund_account.currency or "SAR").strip().upper()
        if refund_cur == inv_cur:
            move_amount = remainder
        else:
            if data.refund_amount is None or data.refund_amount <= ZERO:
                raise ValueError("المبلغ المسترد بعملة الحساب مطلوب")
            move_amount = _q(data.refund_amount)

    ret = PurchaseReturn(
        organization_id=org_id,
        invoice_id=invoice.id,
        supplier_id=invoice.supplier_id,
        return_number=await sale_service._next_sequence(db, org_id, "PRT"),
        return_date=date.today(),
        status="confirmed",
        reason=data.reason,
        total=ret_total,
        created_by=user_id,
    )
    db.add(ret)
    await db.flush()

    for rl in ret_lines:
        src = rl["src"]
        db.add(
            PurchaseReturnItem(
                purchase_return_id=ret.id,
                invoice_item_id=src.id,
                product_id=src.product_id,
                description=src.description,
                quantity=rl["quantity"],
                unit_price=src.unit_price,
                total=rl["total"],
            )
        )
        # Stock OUT (goods go back to the supplier). A damaged line marked
        # restock=false is left untouched on purpose.
        if rl["restock"] and src.product_id and not src.is_service:
            product = (
                await db.execute(
                    select(Product)
                    .where(
                        Product.id == src.product_id,
                        Product.organization_id == org_id,
                    )
                    .with_for_update()
                )
            ).scalar_one_or_none()
            if not product:
                raise ValueError("منتج البند غير موجود لسحب المخزون")
            await bstock.apply_delta(db, org_id, invoice.branch_id, product,
                                     -rl["base_quantity"])
            db.add(
                InventoryMovement(
                    organization_id=org_id,
                    product_id=product.id,
                    movement_type="purchase_return",
                    quantity=-rl["base_quantity"],
                    unit_price=src.unit_price,
                    total=rl["total"],
                    currency=invoice.currency,
                    reference_type="purchase_return",
                    reference_id=ret.id,
                    notes=f"مرتجع شراء {ret.return_number} من {invoice.invoice_number}",
                    created_by=user_id,
                )
            )
        elif (not rl["restock"]) and src.product_id and not src.is_service:
            # Damaged/not-restocked purchase return: informational movement
            # («مرجوع إلى خارج المخزون») WITHOUT touching the stock.
            db.add(
                InventoryMovement(
                    organization_id=org_id,
                    product_id=src.product_id,
                    movement_type="purchase_return_no_stock",
                    quantity=-rl["base_quantity"],
                    unit_price=src.unit_price,
                    total=rl["total"],
                    currency=invoice.currency,
                    reference_type="purchase_return",
                    reference_id=ret.id,
                    notes=f"مرتجع شراء غير مرجع للمخزون {ret.return_number}",
                    created_by=user_id,
                )
            )
    await db.flush()

    invoice.balance = _q(balance - apply)
    net_paid = paid - remainder
    invoice.paid_amount = _q(net_paid if net_paid > ZERO else ZERO)
    if remainder > TAU:
        refund_account.balance = Decimal(str(refund_account.balance or 0)) + move_amount
        cross_note = (
            "" if refund_cur == inv_cur
            else f" ({move_amount} {refund_cur} ≈ {remainder} {inv_cur})"
        )
        db.add(
            BankTransaction(
                organization_id=org_id,
                bank_account_id=refund_account.id,
                date=datetime.now(timezone.utc),
                description=f"استرداد مرتجع شراء {ret.return_number}{cross_note}",
                tx_type="deposit",
                amount=move_amount,
                currency=refund_cur,
                running_balance=refund_account.balance,
                reference=ret.return_number,
            )
        )
    if invoice.balance <= TAU:
        invoice.status = "paid"
    elif invoice.paid_amount > TAU:
        invoice.status = "partially_paid"
    else:
        invoice.status = "confirmed"

    payable = (
        await db.execute(
            select(SupplierPayable).where(SupplierPayable.invoice_id == invoice.id)
        )
    ).scalar_one_or_none()
    if payable and payable.status != "cancelled":
        payable.amount = _q(max(ZERO, Decimal(str(payable.amount or 0)) - apply))
        if payable.amount <= TAU:
            payable.amount = ZERO
            payable.status = "paid"
        elif payable.paid > ZERO:
            payable.status = "partial"
    await db.flush()

    pushes = await sale_service._linked_return(db, org_id, user_id, invoice, ret.id, ret_total)
    await db.commit()

    branch_name = None
    if invoice.branch_id:
        branch_name = (
            await db.execute(select(Branch.name).where(Branch.id == invoice.branch_id))
        ).scalar_one_or_none()
    out = await sale_service._serialize_invoice(db, invoice, branch_name, None, False)
    out['_notification_pushes'] = pushes
    out["payable"] = sale_service._payable_dict(payable)
    out["return"] = {
        "id": str(ret.id),
        "return_number": ret.return_number,
        "total": float(ret_total),
        "kind": "purchase_return",
    }
    return out


# ═══════════════════════════════════════════
# Read — unified list + detail
# ═══════════════════════════════════════════


async def _party_names(
    db: AsyncSession, cust_ids: set, sup_ids: set
) -> tuple[dict, dict]:
    customers = {}
    suppliers = {}
    if cust_ids:
        rows = (
            await db.execute(select(Customer.id, Customer.name).where(Customer.id.in_(cust_ids)))
        ).all()
        customers = {r[0]: r[1] for r in rows}
    if sup_ids:
        rows = (
            await db.execute(select(Supplier.id, Supplier.name).where(Supplier.id.in_(sup_ids)))
        ).all()
        suppliers = {r[0]: r[1] for r in rows}
    return customers, suppliers


async def _serialize_sale_return(
    db: AsyncSession, ret: InvoiceReturn, invoice: Optional[Invoice], party: Optional[str]
) -> dict:
    items = (
        await db.execute(
            select(InvoiceReturnItem)
            .where(InvoiceReturnItem.return_id == ret.id)
            .order_by(InvoiceReturnItem.id.asc())
        )
    ).scalars().all()
    return {
        "id": str(ret.id),
        "kind": "sale_return",
        "return_number": ret.return_number,
        "date": ret.return_date.isoformat() if ret.return_date else None,
        "created_at": ret.created_at.isoformat() if ret.created_at else None,
        "status": ret.status,
        "reason": ret.reason,
        "party": party,
        "total": float(ret.total or 0),
        "currency": (invoice.currency if invoice else None),
        "invoice_id": str(ret.invoice_id) if ret.invoice_id else None,
        "invoice_number": invoice.invoice_number if invoice else None,
        "items": [
            {
                "invoice_item_id": str(it.invoice_item_id) if it.invoice_item_id else None,
                "product_id": str(it.product_id) if it.product_id else None,
                "description": it.description,
                "quantity": float(it.quantity or 0),
                "unit_price": float(it.unit_price or 0),
                "total": float(it.total or 0),
            }
            for it in items
        ],
    }


async def _serialize_purchase_return(
    db: AsyncSession, ret: PurchaseReturn, invoice: Optional[Invoice], party: Optional[str]
) -> dict:
    items = (
        await db.execute(
            select(PurchaseReturnItem)
            .where(PurchaseReturnItem.purchase_return_id == ret.id)
            .order_by(PurchaseReturnItem.id.asc())
        )
    ).scalars().all()
    return {
        "id": str(ret.id),
        "kind": "purchase_return",
        "return_number": ret.return_number,
        "date": ret.return_date.isoformat() if ret.return_date else None,
        "created_at": ret.created_at.isoformat() if ret.created_at else None,
        "status": ret.status,
        "reason": ret.reason,
        "party": party,
        "total": float(ret.total or 0),
        "currency": (invoice.currency if invoice else None),
        "invoice_id": str(ret.invoice_id) if ret.invoice_id else None,
        "invoice_number": invoice.invoice_number if invoice else None,
        "items": [
            {
                "invoice_item_id": str(it.invoice_item_id) if it.invoice_item_id else None,
                "product_id": str(it.product_id) if it.product_id else None,
                "description": it.description,
                "quantity": float(it.quantity or 0),
                "unit_price": float(it.unit_price or 0),
                "total": float(it.total or 0),
            }
            for it in items
        ],
    }


async def list_returns(
    db: AsyncSession,
    org_id: UUID,
    kind: Optional[str] = None,
    search: Optional[str] = None,
    invoice_id: Optional[str] = None,
    page: int = 1,
    per_page: int = 20,
    branch_ids: Optional[list] = None,
) -> dict:
    want_sale = kind in (None, "", "sale", "sale_return", "customer")
    want_purchase = kind in (None, "", "purchase", "purchase_return", "supplier")
    inv_filter = UUID(str(invoice_id)) if invoice_id else None

    records: list = []
    if want_sale:
        q = select(InvoiceReturn).where(
            InvoiceReturn.organization_id == org_id,
            InvoiceReturn.status == "confirmed",
        )
        if inv_filter:
            q = q.where(InvoiceReturn.invoice_id == inv_filter)
        if branch_ids is not None:
            q = q.where(InvoiceReturn.invoice_id.in_(
                select(Invoice.id).where(Invoice.branch_id.in_(branch_ids))))
        for ret in (
            await db.execute(q.order_by(InvoiceReturn.created_at.desc()).limit(_CAP))
        ).scalars().all():
            records.append(("sale", ret))
    if want_purchase:
        q = select(PurchaseReturn).where(
            PurchaseReturn.organization_id == org_id,
            PurchaseReturn.status == "confirmed",
        )
        if inv_filter:
            q = q.where(PurchaseReturn.invoice_id == inv_filter)
        if branch_ids is not None:
            q = q.where(PurchaseReturn.invoice_id.in_(
                select(Invoice.id).where(Invoice.branch_id.in_(branch_ids))))
        for ret in (
            await db.execute(q.order_by(PurchaseReturn.created_at.desc()).limit(_CAP))
        ).scalars().all():
            records.append(("purchase", ret))

    inv_ids = {r[1].invoice_id for r in records if r[1].invoice_id}
    invoices: dict = {}
    if inv_ids:
        rows = (
            await db.execute(select(Invoice).where(Invoice.id.in_(inv_ids)))
        ).scalars().all()
        invoices = {i.id: i for i in rows}
    cust_ids = {
        invoices[r[1].invoice_id].customer_id
        for r in records
        if r[1].invoice_id in invoices and invoices[r[1].invoice_id].customer_id
    }
    sup_ids = {
        invoices[r[1].invoice_id].supplier_id
        for r in records
        if r[1].invoice_id in invoices and invoices[r[1].invoice_id].supplier_id
    }
    customers, suppliers = await _party_names(db, cust_ids, sup_ids)

    out = []
    for kind_, ret in records:
        invoice = invoices.get(ret.invoice_id) if ret.invoice_id else None
        if kind_ == "sale":
            party = customers.get(invoice.customer_id) if invoice else None
            out.append(await _serialize_sale_return(db, ret, invoice, party))
        else:
            party = suppliers.get(invoice.supplier_id) if invoice else (
                suppliers.get(ret.supplier_id) if ret.supplier_id else None
            )
            out.append(await _serialize_purchase_return(db, ret, invoice, party))

    if search:
        term = search.strip().lower()
        if term:
            def _hit(r: dict) -> bool:
                hay = " ".join(
                    str(r.get(k) or "")
                    for k in ("return_number", "invoice_number", "party", "total")
                ).lower()
                return term in hay
            out = [r for r in out if _hit(r)]

    out.sort(key=lambda r: r["date"] or "", reverse=True)
    total = len(out)
    page = max(1, page)
    per_page = max(1, min(per_page, 100))
    start = (page - 1) * per_page
    return {"items": out[start:start + per_page], "total": total, "page": page,
            "per_page": per_page}


async def get_return_detail(
    db: AsyncSession, org_id: UUID, kind: str, return_id: UUID
) -> Optional[dict]:
    if kind in ("purchase", "purchase_return"):
        ret = (
            await db.execute(
                select(PurchaseReturn).where(
                    PurchaseReturn.id == return_id,
                    PurchaseReturn.organization_id == org_id,
                )
            )
        ).scalar_one_or_none()
        if not ret:
            return None
        invoice = None
        if ret.invoice_id:
            invoice = (
                await db.execute(select(Invoice).where(Invoice.id == ret.invoice_id))
            ).scalar_one_or_none()
        party = None
        sup_id = invoice.supplier_id if invoice else ret.supplier_id
        if sup_id:
            party = (
                await db.execute(select(Supplier.name).where(Supplier.id == sup_id))
            ).scalar_one_or_none()
        return await _serialize_purchase_return(db, ret, invoice, party)

    ret = (
        await db.execute(
            select(InvoiceReturn).where(
                InvoiceReturn.id == return_id,
                InvoiceReturn.organization_id == org_id,
            )
        )
    ).scalar_one_or_none()
    if not ret:
        return None
    invoice = None
    if ret.invoice_id:
        invoice = (
            await db.execute(select(Invoice).where(Invoice.id == ret.invoice_id))
        ).scalar_one_or_none()
    party = None
    if invoice and invoice.customer_id:
        party = (
            await db.execute(select(Customer.name).where(Customer.id == invoice.customer_id))
        ).scalar_one_or_none()
    return await _serialize_sale_return(db, ret, invoice, party)
