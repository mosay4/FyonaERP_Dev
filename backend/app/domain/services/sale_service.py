"""Atomic business sale-issue + returns + product units/barcodes.

One rule governs everything here: a sale is either fully applied (invoice +
stock + accounts + receivable, in ONE commit) or nothing happens at all.
There is deliberately no draft state on this path.
"""
from datetime import date, datetime, timezone, timedelta
from decimal import Decimal
from typing import Optional
from uuid import UUID

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.auth_entities import Organization
from app.domain.entities.business_entities import (
    Customer,
    InventoryMovement,
    Product,
    ProductCategory,
    Supplier,
)
from app.domain.entities.finance_entities import BankAccount, BankTransaction
from app.domain.entities.invoice_entities import (
    Invoice,
    InvoiceItem,
    InvoiceSequence,
    Payment,
)
from app.domain.entities.sale_entities import (
    Branch,
    CustomerReceivable,
    InvoiceReturn,
    InvoiceReturnItem,
    ProductBarcode,
    ProductPrice,
    ProductUnit,
    SupplierPayable,
)
from app.domain.models.invoice_models import (
    SaleIssueRequest,
    SaleReturnRequest,
    ProductUnitCreate,
    ProductUnitUpdate,
    PurchaseIssueRequest,
    PartyPaymentRequest,
    ProductBarcodeCreate,
)

from app.domain.services import inventory_lots as lots
from app.domain.services import branch_stock_service as bstock
ZERO = Decimal("0")
CENT = Decimal("0.01")
TAU = Decimal("0.005")

# ── Unit measurement families ────────────────────────────────────────────────
# The single source of truth for which units may live on the same product. A
# product's extra units must share the base unit's family (you cannot attach a
# «لتر» to a «قطعة»). Custom units carry their family in the request.
UNIT_GROUPS = {
    "قطعة": "count", "درزن": "count", "باكيت": "count", "علبة": "count",
    "كرتون": "count", "كرتونة": "count",
    "كيلو": "weight", "جرام": "weight", "طن": "weight",
    "لتر": "volume",
    "متر": "length",
    "متر مربع": "area",
    "ساعة": "time", "يوم": "time",
    "خدمة": "service", "خدمة إلكترونية": "service",
}
UNIT_INCOMPATIBLE_MSG = (
    "لا يمكن إضافة هذه الوحدة؛ اختر وحدة من نفس مجموعة القياس"
)


def unit_group_for(name: str, provided: Optional[str] = None) -> Optional[str]:
    """The measurement family of a unit — canonical name wins, else the
    caller-provided family (for merchant-defined units). None = unknown."""
    n = (name or "").strip()
    if n in UNIT_GROUPS:
        return UNIT_GROUPS[n]
    p = (provided or "").strip()
    return p or None


def assert_unit_compatible(
    base_unit_name: str, extra_name: str, extra_group: Optional[str] = None
) -> None:
    """Refuse an extra unit from a DIFFERENT family than the product's base
    unit. Unknown families are permissive (legacy/custom safety) — we never
    block a unit we cannot classify."""
    base = unit_group_for(base_unit_name)
    extra = unit_group_for(extra_name, extra_group)
    if base and extra and base != extra:
        raise ValueError(UNIT_INCOMPATIBLE_MSG)


def _q(v: Decimal) -> Decimal:
    return v.quantize(CENT)


# ═══════════════════════════════════════════
# Sequences (same pattern as the invoice repo)
# ═══════════════════════════════════════════


async def _next_sequence(db: AsyncSession, org_id: UUID, prefix: str) -> str:
    today = date.today()
    stmt = (
        select(InvoiceSequence)
        .where(
            InvoiceSequence.organization_id == org_id,
            InvoiceSequence.prefix == prefix,
            InvoiceSequence.date == today,
        )
        .with_for_update()
    )
    seq = (await db.execute(stmt)).unique().scalar_one_or_none()
    if seq:
        seq.last_sequence += 1
        await db.flush()
        n = seq.last_sequence
    else:
        db.add(
            InvoiceSequence(
                organization_id=org_id, prefix=prefix, last_sequence=1, date=today
            )
        )
        await db.flush()
        n = 1
    return f"{prefix}-{today.strftime('%Y%m%d')}-{n:04d}"


# ═══════════════════════════════════════════
# Branches (minimal: one default branch per org)
# ═══════════════════════════════════════════


def _branch_default_name(org_name: Optional[str]) -> str:
    """Business display name (never the raw «X's Organization» label)."""
    import re as _re
    clean = (org_name or "").strip()
    clean = _re.sub(r"\s*'s\s+organization\s*$", "", clean, flags=_re.I).strip()
    if not clean or clean.lower() == "organization":
        clean = "Business"
    return clean[:200]


async def get_or_create_default_branch(db: AsyncSession, org_id: UUID) -> Branch:
    row = (
        await db.execute(
            select(Branch)
            .where(Branch.organization_id == org_id, Branch.is_active.is_(True))
            .order_by(Branch.is_default.desc(), Branch.created_at.asc())
            .limit(1)
        )
    ).scalar_one_or_none()
    if row:
        return row
    from app.domain.entities.auth_entities import Organization
    org_name = (await db.execute(
        select(Organization.name).where(Organization.id == org_id)
    )).scalar_one_or_none()
    branch = Branch(organization_id=org_id,
                    name=_branch_default_name(org_name), is_default=True)
    db.add(branch)
    await db.flush()
    return branch


async def resolve_branch(
    db: AsyncSession, org_id: UUID, branch_id: Optional[UUID]
) -> Branch:
    if branch_id is None:
        return await get_or_create_default_branch(db, org_id)
    row = (
        await db.execute(
            select(Branch).where(Branch.id == branch_id, Branch.organization_id == org_id)
        )
    ).scalar_one_or_none()
    if not row or not row.is_active:
        raise ValueError("الفرع غير موجود")
    return row


# ═══════════════════════════════════════════
# Product units & barcodes
# ═══════════════════════════════════════════


async def ensure_base_unit(db: AsyncSession, org_id: UUID, product: Product) -> ProductUnit:
    """Every product always has exactly one base unit (factor 1). Created
    lazily so legacy products become unit-aware without a data migration."""
    row = (
        await db.execute(
            select(ProductUnit).where(
                ProductUnit.organization_id == org_id,
                ProductUnit.product_id == product.id,
                ProductUnit.is_base.is_(True),
            )
        )
    ).scalar_one_or_none()
    if row:
        return row
    unit = ProductUnit(
        organization_id=org_id,
        product_id=product.id,
        name=product.unit or "قطعة",
        factor=Decimal("1"),
        group=unit_group_for(product.unit or "قطعة"),
        barcode=product.barcode,
        sale_price=product.price,
        is_base=True,
    )
    db.add(unit)
    await db.flush()
    return unit


async def barcode_taken(
    db: AsyncSession, org_id: UUID, code: str, *, ignore_product_id=None, ignore_row_id=None
) -> bool:
    hit = (
        await db.execute(
            select(Product.id).where(
                Product.organization_id == org_id,
                Product.barcode == code,
                Product.is_deleted.is_(False),
                *([Product.id != ignore_product_id] if ignore_product_id else []),
            ).limit(1)
        )
    ).scalar_one_or_none()
    if hit:
        return True
    stmt = select(ProductBarcode.id).where(
        ProductBarcode.organization_id == org_id,
        ProductBarcode.barcode == code,
    )
    if ignore_row_id:
        stmt = stmt.where(ProductBarcode.id != ignore_row_id)
    return (await db.execute(stmt.limit(1))).scalar_one_or_none() is not None


async def resolve_barcode(db: AsyncSession, org_id: UUID, code: str,
                          branch_ids: Optional[list] = None) -> dict:
    """Barcode → product + unit + suggested qty/price. Unit barcodes win;
    the product's own barcode column is the fallback (base unit)."""
    code = (code or "").strip()
    if not code:
        raise ValueError("الباركود مطلوب")
    bc_conds = [
        ProductBarcode.organization_id == org_id,
        ProductBarcode.barcode == code,
        Product.is_deleted.is_(False),
    ]
    if branch_ids:
        bc_conds.append(Product.branch_id.in_(branch_ids))
    row = (
        await db.execute(
            select(ProductBarcode, Product)
            .join(Product, Product.id == ProductBarcode.product_id)
            .where(*bc_conds)
            .limit(1)
        )
    ).first()
    product = None
    unit = None
    if row:
        _, product = row
        if row[0].unit_id:
            unit = (
                await db.execute(
                    select(ProductUnit).where(
                        ProductUnit.id == row[0].unit_id,
                        ProductUnit.is_active.is_(True),
                    )
                )
            ).scalar_one_or_none()
    if product is None:
        p_conds = [
            Product.organization_id == org_id,
            Product.barcode == code,
            Product.is_deleted.is_(False),
        ]
        if branch_ids:
            p_conds.append(Product.branch_id.in_(branch_ids))
        product = (
            await db.execute(
                select(Product).where(*p_conds).order_by(Product.created_at.asc())
            )
        ).scalars().first()
    if product is None or not product.is_active:
        raise ValueError("لا يوجد منتج بهذا الباركود")
    if unit is None:
        unit = await ensure_base_unit(db, org_id, product)
    factor = float(unit.factor or 1)
    price = unit.sale_price if unit.sale_price is not None else product.price
    return {
        "product": {
            "id": str(product.id),
            "name": product.name,
            "price": float(product.price or 0),
            "stock": float(product.stock or 0),
            "unit": product.unit,
            "is_service": bool(product.is_service),
        },
        "unit": {
            "id": str(unit.id),
            "name": unit.name,
            "factor": factor,
            "is_base": bool(unit.is_base),
        },
        "suggested_quantity": 1,
        "suggested_price": float(price or 0),
    }


# ═══════════════════════════════════════════
# Totals (same formula as the invoice engine)
# ═══════════════════════════════════════════


def calc_totals(lines: list, discount_type, discount_value, tax_type, tax_rate) -> dict:
    subtotal = ZERO
    for ln in lines:
        subtotal += Decimal(str(ln["quantity"])) * ln["unit_price"] - ln["discount"]
    discount_amount = ZERO
    if discount_type == "percentage":
        discount_amount = subtotal * discount_value / Decimal("100")
    elif discount_type == "fixed":
        discount_amount = discount_value
    if discount_amount > subtotal:
        raise ValueError("الخصم يتجاوز إجمالي الفاتورة")
    after_discount = subtotal - discount_amount
    tax_amount = ZERO
    if tax_type == "percentage":
        tax_amount = after_discount * tax_rate / Decimal("100")
    elif tax_type == "fixed":
        tax_amount = tax_rate
    total = after_discount + tax_amount
    if total < ZERO:
        raise ValueError("إجمالي الفاتورة غير صالح")
    return {
        "subtotal": _q(subtotal),
        "discount_amount": _q(discount_amount),
        "tax_amount": _q(tax_amount),
        "total": _q(total),
    }


# ═══════════════════════════════════════════
# Product units & barcodes (Inventory-owned)
# ═══════════════════════════════════════════


def _unit_to_dict(unit: ProductUnit) -> dict:
    return {
        "id": str(unit.id),
        "product_id": str(unit.product_id),
        "name": unit.name,
        "factor": float(unit.factor or 1),
        "group": unit.group,
        "barcode": unit.barcode,
        "sale_price": float(unit.sale_price) if unit.sale_price is not None else None,
        "purchase_price": float(unit.purchase_price) if unit.purchase_price is not None else None,
        "is_base": bool(unit.is_base),
        "is_active": bool(unit.is_active),
    }


async def _get_product_or_raise(db: AsyncSession, org_id: UUID, product_id: UUID) -> Product:
    product = (
        await db.execute(
            select(Product).where(
                Product.id == product_id,
                Product.organization_id == org_id,
                Product.is_deleted.is_(False),
            )
        )
    ).scalar_one_or_none()
    if not product:
        raise ValueError("المنتج غير موجود")
    return product


async def list_units(db: AsyncSession, org_id: UUID, product_id: UUID) -> dict:
    product = await _get_product_or_raise(db, org_id, product_id)
    await ensure_base_unit(db, org_id, product)
    units = (
        await db.execute(
            select(ProductUnit)
            .where(ProductUnit.organization_id == org_id, ProductUnit.product_id == product_id)
            .order_by(ProductUnit.is_base.desc(), ProductUnit.name.asc())
        )
    ).scalars().all()
    extras = (
        await db.execute(
            select(ProductBarcode).where(
                ProductBarcode.organization_id == org_id,
                ProductBarcode.product_id == product_id,
            )
        )
    ).scalars().all()
    return {
        "units": [_unit_to_dict(u) for u in units],
        "barcodes": [
            {
                "id": str(b.id),
                "product_id": str(b.product_id),
                "unit_id": str(b.unit_id) if b.unit_id else None,
                "barcode": b.barcode,
            }
            for b in extras
        ],
    }


async def create_unit(db: AsyncSession, org_id: UUID, product_id: UUID, data: ProductUnitCreate) -> dict:
    product = await _get_product_or_raise(db, org_id, product_id)
    dup = (
        await db.execute(
            select(ProductUnit.id).where(
                ProductUnit.organization_id == org_id,
                ProductUnit.product_id == product_id,
                ProductUnit.name == data.name,
            ).limit(1)
        )
    ).scalar_one_or_none()
    if dup:
        raise ValueError("هذه الوحدة موجودة مسبقاً لهذا المنتج")
    # Enforce the measurement-family rule with the product's base unit.
    assert_unit_compatible(
        getattr(product, "unit", "") or "",
        data.name,
        getattr(data, "group", None),
    )
    if data.barcode and await barcode_taken(db, org_id, data.barcode.strip()):
        raise ValueError("الباركود مستخدم لمنتج آخر")
    for field in ("sale_price", "purchase_price"):
        val = getattr(data, field)
        if val is not None and val < ZERO:
            raise ValueError("السعر لا يمكن أن يكون سالباً")
    unit = ProductUnit(
        organization_id=org_id,
        product_id=product_id,
        name=data.name,
        factor=data.factor,
        group=unit_group_for(data.name, getattr(data, "group", None)),
        barcode=data.barcode.strip() if data.barcode else None,
        sale_price=data.sale_price,
        purchase_price=data.purchase_price,
        is_base=False,
    )
    db.add(unit)
    await db.flush()
    # Index the unit barcode for lookup + global uniqueness. The column stays
    # the display value; product_barcodes is the single resolution source.
    if unit.barcode:
        db.add(
            ProductBarcode(
                organization_id=org_id,
                product_id=product_id,
                unit_id=unit.id,
                barcode=unit.barcode,
            )
        )
        await db.flush()
    await db.commit()
    await db.refresh(unit)
    return _unit_to_dict(unit)


async def update_unit(
    db: AsyncSession, org_id: UUID, unit_id: UUID, data: ProductUnitUpdate
) -> dict:
    unit = (
        await db.execute(
            select(ProductUnit).where(
                ProductUnit.id == unit_id, ProductUnit.organization_id == org_id
            )
        )
    ).scalar_one_or_none()
    if not unit:
        raise ValueError("الوحدة غير موجودة")
    if data.name and data.name != unit.name:
        dup = (
            await db.execute(
                select(ProductUnit.id).where(
                    ProductUnit.organization_id == org_id,
                    ProductUnit.product_id == unit.product_id,
                    ProductUnit.name == data.name,
                ).limit(1)
            )
        ).scalar_one_or_none()
        if dup:
            raise ValueError("هذه الوحدة موجودة مسبقاً لهذا المنتج")
        unit.name = data.name
        if not unit.is_base:
            product = await _get_product_or_raise(db, org_id, unit.product_id)
            assert_unit_compatible(
                getattr(product, "unit", "") or "",
                data.name,
                getattr(data, "group", None),
            )
    if data.factor is not None:
        if data.factor <= ZERO:
            raise ValueError("معامل الوحدة يجب أن يكون أكبر من صفر")
        if unit.is_base and data.factor != Decimal("1"):
            raise ValueError("لا يمكن تغيير معامل الوحدة الأساسية")
        unit.factor = data.factor
    if data.barcode is not None:
        code = data.barcode.strip() or None
        if code and await barcode_taken(db, org_id, code):
            raise ValueError("الباركود مستخدم لمنتج آخر")
        unit.barcode = code
        # Keep the resolution index in sync with the display column.
        existing_rows = (
            await db.execute(
                select(ProductBarcode).where(
                    ProductBarcode.organization_id == org_id,
                    ProductBarcode.unit_id == unit.id,
                )
            )
        ).scalars().all()
        for row in existing_rows:
            await db.delete(row)
        if code:
            db.add(
                ProductBarcode(
                    organization_id=org_id,
                    product_id=unit.product_id,
                    unit_id=unit.id,
                    barcode=code,
                )
            )
    for field in ("sale_price", "purchase_price"):
        val = getattr(data, field)
        if val is not None:
            if val < ZERO:
                raise ValueError("السعر لا يمكن أن يكون سالباً")
            setattr(unit, field, val)
    if getattr(data, "group", None) is not None:
        unit.group = unit_group_for(unit.name, data.group)
    if data.is_active is not None:
        if unit.is_base and not data.is_active:
            raise ValueError("لا يمكن تعطيل الوحدة الأساسية")
        unit.is_active = data.is_active
    await db.commit()
    await db.refresh(unit)
    return _unit_to_dict(unit)


async def delete_unit(db: AsyncSession, org_id: UUID, unit_id: UUID) -> None:
    unit = (
        await db.execute(
            select(ProductUnit).where(
                ProductUnit.id == unit_id, ProductUnit.organization_id == org_id
            )
        )
    ).scalar_one_or_none()
    if not unit:
        raise ValueError("الوحدة غير موجودة")
    if unit.is_base:
        raise ValueError("لا يمكن حذف الوحدة الأساسية")
    used = (
        await db.execute(
            select(InvoiceItem.id).where(InvoiceItem.unit_id == unit_id).limit(1)
        )
    ).scalar_one_or_none()
    if used:
        raise ValueError("هذه الوحدة مستخدمة في فواتير — عطّلها بدل حذفها")
    await db.execute(
        ProductBarcode.__table__.delete().where(ProductBarcode.unit_id == unit_id)
    )
    await db.delete(unit)
    await db.commit()


async def add_barcode(
    db: AsyncSession, org_id: UUID, product_id: UUID, data: ProductBarcodeCreate
) -> dict:
    await _get_product_or_raise(db, org_id, product_id)
    unit_id = None
    if data.unit_id:
        unit = (
            await db.execute(
                select(ProductUnit).where(
                    ProductUnit.id == data.unit_id,
                    ProductUnit.product_id == product_id,
                    ProductUnit.organization_id == org_id,
                )
            )
        ).scalar_one_or_none()
        if not unit:
            raise ValueError("الوحدة غير موجودة لهذا المنتج")
        unit_id = unit.id
    if await barcode_taken(db, org_id, data.barcode):
        raise ValueError("الباركود مستخدم لمنتج آخر")
    row = ProductBarcode(
        organization_id=org_id, product_id=product_id, unit_id=unit_id, barcode=data.barcode
    )
    db.add(row)
    await db.commit()
    await db.refresh(row)
    return {
        "id": str(row.id),
        "product_id": str(row.product_id),
        "unit_id": str(row.unit_id) if row.unit_id else None,
        "barcode": row.barcode,
    }


async def delete_barcode(db: AsyncSession, org_id: UUID, barcode_id: UUID) -> None:
    row = (
        await db.execute(
            select(ProductBarcode).where(
                ProductBarcode.id == barcode_id,
                ProductBarcode.organization_id == org_id,
            )
        )
    ).scalar_one_or_none()
    if not row:
        raise ValueError("الباركود غير موجود")
    await db.delete(row)
    await db.commit()


async def _serialize_invoice(db: AsyncSession, invoice: Invoice, branch_name, receivable, already_issued: bool) -> dict:
    items = (
        await db.execute(
            select(InvoiceItem)
            .where(InvoiceItem.invoice_id == invoice.id)
            .order_by(InvoiceItem.id.asc())
        )
    ).scalars().all()
    payments = (
        await db.execute(
            select(Payment)
            .where(Payment.invoice_id == invoice.id)
            .order_by(Payment.created_at.asc())
        )
    ).scalars().all()
    customer_name = None
    if invoice.customer_id:
        customer_name = (
            await db.execute(select(Customer.name).where(Customer.id == invoice.customer_id))
        ).scalar_one_or_none()
    supplier_name = None
    if invoice.supplier_id:
        supplier_name = (
            await db.execute(select(Supplier.name).where(Supplier.id == invoice.supplier_id))
        ).scalar_one_or_none()
    out_items = []
    for it in items:
        pname = (
            await db.execute(select(Product.name).where(Product.id == it.product_id))
        ).scalar_one_or_none() if it.product_id else None
        out_items.append(
            {
                "id": str(it.id),
                "product_id": str(it.product_id) if it.product_id else None,
                "product_name": pname,
                "description": it.description,
                "unit_id": str(it.unit_id) if it.unit_id else None,
                "unit_name": it.unit_name,
                "quantity": float(it.quantity or 0),
                "base_quantity": float(it.base_quantity or 0),
                "unit_price": float(it.unit_price or 0),
                "discount": float(it.discount or 0),
                "total": float(it.total or 0),
                "is_service": bool(it.is_service),
                "image": it.image,
                "cost_total": float(it.cost_total) if it.cost_total is not None else None,
                "profit": float(it.profit) if it.profit is not None else None,
                "original_unit_price": float(it.original_unit_price) if it.original_unit_price is not None else None,
                "price_currency": it.price_currency,
                "exchange_rate_used": float(it.exchange_rate_used) if it.exchange_rate_used is not None else None,
            }
        )
    out_payments = []
    for p in payments:
        aname = None
        if p.bank_account_id:
            aname = (
                await db.execute(
                    select(BankAccount.bank_name).where(BankAccount.id == p.bank_account_id)
                )
            ).scalar_one_or_none()
        out_payments.append(
            {
                "id": str(p.id),
                "amount": float(p.amount or 0),
                "payment_method": p.payment_method,
                "bank_account_id": str(p.bank_account_id) if p.bank_account_id else None,
                "bank_account_name": aname,
                "reference": p.reference,
                "payment_currency": p.payment_currency,
                "invoice_currency": p.invoice_currency,
                "original_amount": float(p.original_amount) if p.original_amount is not None else float(p.amount or 0),
                "exchange_rate": float(p.exchange_rate) if p.exchange_rate is not None else 1.0,
                "equivalent_amount": float(p.equivalent_amount) if p.equivalent_amount is not None else float(p.amount or 0),
                "exchange_rate_source": p.exchange_rate_source,
                "exchange_rate_timestamp": p.exchange_rate_timestamp.isoformat() if p.exchange_rate_timestamp else None,
            }
        )
    return {
        "id": str(invoice.id),
        "invoice_number": invoice.invoice_number,
        "status": invoice.status,
        "currency": invoice.currency,
        "branch_id": str(invoice.branch_id) if invoice.branch_id else None,
        "branch_name": branch_name,
        "customer_id": str(invoice.customer_id) if invoice.customer_id else None,
        "customer_name": customer_name,
        "supplier_id": str(invoice.supplier_id) if invoice.supplier_id else None,
        "supplier_name": supplier_name,
        "invoice_date": invoice.invoice_date.isoformat() if invoice.invoice_date else None,
        "due_date": invoice.due_date.isoformat() if invoice.due_date else None,
        "subtotal": float(invoice.subtotal or 0),
        "discount_type": invoice.discount_type,
        "discount_value": float(invoice.discount_value or 0),
        "discount_amount": float(invoice.discount_amount or 0),
        "tax_type": invoice.tax_type,
        "tax_rate": float(invoice.tax_rate or 0),
        "tax_amount": float(invoice.tax_amount or 0),
        "total": float(invoice.total or 0),
        "paid_amount": float(invoice.paid_amount or 0),
        "balance": float(invoice.balance or 0),
        "notes": invoice.notes,
        "already_issued": already_issued,
        "items": out_items,
        "payments": out_payments,
        "receivable": (
            {
                "id": str(receivable.id),
                "amount": float(receivable.amount or 0),
                "paid": float(receivable.paid or 0),
                "status": receivable.status,
            }
            if receivable else None
        ),
    }


async def issue_sale(
    db: AsyncSession, org_id: UUID, user_id: UUID, data: SaleIssueRequest
) -> dict:
    # ── Idempotency: a retried/double-tapped issue returns the original ──
    if data.idempotency_key:
        dup = (
            await db.execute(
                select(Invoice).where(
                    Invoice.organization_id == org_id,
                    Invoice.idempotency_key == data.idempotency_key,
                )
            )
        ).scalar_one_or_none()
        if dup:
            branch_name = None
            if dup.branch_id:
                branch_name = (
                    await db.execute(select(Branch.name).where(Branch.id == dup.branch_id))
                ).scalar_one_or_none()
            receivable = (
                await db.execute(
                    select(CustomerReceivable).where(CustomerReceivable.invoice_id == dup.id)
                )
            ).scalar_one_or_none()
            return await _serialize_invoice(db, dup, branch_name, receivable, True)

    if not data.items:
        raise ValueError("يجب إضافة بند واحد على الأقل")

    # ── Customer ──
    customer = None
    if data.customer_id:
        customer = (
            await db.execute(
                select(Customer).where(
                    Customer.id == data.customer_id,
                    Customer.organization_id == org_id,
                    Customer.is_deleted.is_(False),
                )
            )
        ).scalar_one_or_none()
        if not customer or not customer.is_active:
            raise ValueError("العميل غير موجود")

    branch = await resolve_branch(db, org_id, data.branch_id)
    currency = (data.currency or "SAR").strip().upper()

    # ── Resolve lines (products locked for stock check) ──
    lines = []
    for ln in data.items:
        qty = float(ln.quantity)
        price = ln.unit_price
        disc = ln.discount
        if disc > Decimal(str(qty)) * price:
            raise ValueError("خصم البند يتجاوز قيمته")
        if ln.product_id is None:
            # Inline quick-add during a sale: create/reuse a real product
            # (identical rules to the purchase quick-add) so it never
            # "disappears" after the invoice.
            if getattr(ln, "new_product", None):
                lines.append(await _resolve_purchase_line(db, org_id, ln, branch.id))
                continue
            if not (ln.description or "").strip():
                raise ValueError("البند اليدوي يحتاج وصفاً")
            lines.append(
                {
                    "product": None, "unit": None, "factor": 1.0,
                    "description": ln.description.strip(),
                    "unit_name": "خدمة",
                    "quantity": qty, "base_quantity": qty,
                    "unit_price": price, "discount": disc,
                    "is_service": True,
                }
            )
            continue
        product = (
            await db.execute(
                select(Product)
                .where(
                    Product.id == ln.product_id,
                    Product.organization_id == org_id,
                    Product.is_deleted.is_(False),
                )
                .with_for_update()
            )
        ).scalar_one_or_none()
        if not product or not product.is_active:
            raise ValueError("منتج غير موجود في الفاتورة")
        if (getattr(product, "branch_id", None) is not None
                and product.branch_id != branch.id):
            raise ValueError("هذا المنتج تابع لفرع آخر ولا يمكن استخدامه هنا")
        unit = None
        factor = 1.0
        unit_name = product.unit or "قطعة"
        if ln.unit_id:
            unit = (
                await db.execute(
                    select(ProductUnit).where(
                        ProductUnit.id == ln.unit_id,
                        ProductUnit.product_id == product.id,
                        ProductUnit.organization_id == org_id,
                    )
                )
            ).scalar_one_or_none()
            if not unit or not unit.is_active:
                raise ValueError(f"وحدة غير صالحة للمنتج {product.name}")
            factor = float(unit.factor or 1)
            unit_name = unit.name
        base_qty = qty * factor
        is_service = bool(product.is_service)
        if not is_service and float(await bstock.available(
                db, org_id, branch.id, product)) + 1e-9 < base_qty:
            raise ValueError(f"المخزون غير كافٍ للمنتج {product.name}")
        lines.append(
            {
                "product": product, "unit": unit, "factor": factor,
                "description": (ln.description or "").strip() or product.name,
                "unit_name": unit_name,
                "quantity": qty, "base_quantity": base_qty,
                "unit_price": price, "discount": disc,
                "is_service": is_service,
                "original_price": ln.original_price,
                "price_currency": ln.price_currency,
                "exchange_rate": ln.exchange_rate,
            }
        )

    prepared = [
        {
            **ln,
            "unit_price": ln["unit_price"],
            "discount": ln["discount"],
            "quantity": ln["quantity"],
            "line_total": _q(Decimal(str(ln["quantity"])) * ln["unit_price"] - ln["discount"]),
        }
        for ln in lines
    ]
    totals = calc_totals(
        [
            {"quantity": ln["quantity"], "unit_price": ln["unit_price"], "discount": ln["discount"]}
            for ln in lines
        ],
        data.discount_type,
        data.discount_value,
        data.tax_type,
        data.tax_rate,
    )
    total = totals["total"]

    # ── Payments (multi-currency split; no overpay) ──
    # Each account receives money in ITS OWN currency. When that differs from
    # the invoice currency the payment carries a frozen exchange-rate snapshot
    # and its converted value is what counts toward the invoice.
    paid = ZERO
    resolved = []
    for pm in data.payments:
        acct = (
            await db.execute(
                select(BankAccount).where(
                    BankAccount.id == pm.bank_account_id,
                    BankAccount.organization_id == org_id,
                    BankAccount.is_deleted.is_(False),
                )
            )
        ).scalar_one_or_none()
        if not acct or not acct.is_active:
            raise ValueError("حساب بنكي غير موجود")
        acct_cur = (acct.currency or "SAR").strip().upper()
        pay_cur = (pm.currency or acct_cur).strip().upper()
        if pay_cur != acct_cur:
            raise ValueError(
                f"عملة الدفعة لا تطابق عملة الحساب {acct.bank_name}"
            )
        if pay_cur == currency:
            rate = Decimal("1")
            equivalent = pm.amount
        else:
            if pm.exchange_rate is None or pm.exchange_rate <= 0:
                raise ValueError(
                    f"سعر الصرف مطلوب للدفعة بعملة {pay_cur}"
                )
            rate = pm.exchange_rate
            equivalent = _q(pm.amount * rate)
        paid += equivalent
        resolved.append((pm, acct, pay_cur, rate, equivalent))
    if paid - total > TAU:
        raise ValueError("المبلغ المدفوع يتجاوز إجمالي الفاتورة")
    balance = total - paid
    if balance < ZERO:
        balance = ZERO

    # ── Debt requires a real customer — never on a cash customer ──
    if balance > TAU and customer is None:
        raise ValueError("المبلغ المتبقي يتطلب اختيار عميل — لا يمكن إنشاء دين على عميل نقدي")

    invoice_date = date.today()
    invoice = Invoice(
        organization_id=org_id,
        invoice_number=await _next_sequence(db, org_id, "INV"),
        invoice_type="sale",
        customer_id=customer.id if customer else None,
        debt_group_id=getattr(data, "debt_group_id", None),
        invoice_date=invoice_date,
        due_date=data.due_date or (invoice_date + timedelta(days=30) if balance > TAU else None),
        status="confirmed",
        subtotal=totals["subtotal"],
        discount_type=data.discount_type,
        discount_value=data.discount_value,
        discount_amount=totals["discount_amount"],
        tax_type=data.tax_type,
        tax_rate=data.tax_rate,
        tax_amount=totals["tax_amount"],
        total=total,
        paid_amount=_q(paid),
        balance=_q(balance),
        currency=currency,
        branch_id=branch.id,
        idempotency_key=data.idempotency_key,
        notes=data.notes,
        created_by=user_id,
    )
    db.add(invoice)
    await db.flush()

    item_objs = []
    for ln in prepared:
        item = InvoiceItem(
            invoice_id=invoice.id,
            product_id=ln["product"].id if ln["product"] else None,
            description=ln["description"],
            quantity=ln["quantity"],
            unit_price=ln["unit_price"],
            discount=ln["discount"],
            tax_rate=ZERO,
            total=ln["line_total"],
            unit_id=ln["unit"].id if ln["unit"] else None,
            unit_name=ln["unit_name"],
            base_quantity=ln["base_quantity"],
            factor=ln.get("factor"),
            is_service=ln["is_service"],
            image=ln["product"].image if ln["product"] else None,
            original_unit_price=ln.get("original_price"),
            price_currency=ln.get("price_currency"),
            exchange_rate_used=ln.get("exchange_rate"),
        )
        db.add(item)
        item_objs.append(item)
    await db.flush()

    # ── Stock (base units only; services untouched) + real FIFO/FEFO cost ──
    for idx, ln in enumerate(prepared):
        product = ln["product"]
        if product is None or ln["is_service"]:
            continue
        await bstock.apply_delta(db, org_id, invoice.branch_id, product,
                                 -ln["base_quantity"])
        base_price = ln["unit_price"] / Decimal(str(ln["factor"])) if ln["factor"] else ln["unit_price"]
        db.add(
            InventoryMovement(
                organization_id=org_id,
                product_id=product.id,
                movement_type="sale",
                quantity=-ln["base_quantity"],
                unit_price=_q(base_price),
                total=-ln["line_total"],
                reference_type="invoice",
                reference_id=invoice.id,
                notes=f"بيع {invoice.invoice_number}",
                created_by=user_id,
            )
        )
        # Consume the exact lots (FEFO when the product has expiry, else FIFO)
        # and freeze this line's cost + profit in the invoice currency.
        item = item_objs[idx]
        cogs = await lots.consume_fifo_fefo(
            db,
            org_id,
            product,
            ln["base_quantity"],
            currency,
            invoice_item_id=item.id,
        )
        if cogs is None:
            item.cost_total = None
            item.profit = None
        else:
            item.cost_total = _q(cogs)
            item.profit = _q(ln["line_total"] - cogs)
    await db.flush()

    # ── Money into the chosen accounts (each in its own currency) ──
    for pm, acct, pay_cur, rate, equivalent in resolved:
        acct.balance = Decimal(str(acct.balance or 0)) + pm.amount
        db.add(
            BankTransaction(
                organization_id=org_id,
                bank_account_id=acct.id,
                date=datetime.now(timezone.utc),
                description=f"تحصيل فاتورة {invoice.invoice_number}",
                tx_type="deposit",
                amount=pm.amount,
                currency=pay_cur,
                running_balance=acct.balance,
                reference=invoice.invoice_number,
            )
        )
        db.add(
            Payment(
                organization_id=org_id,
                branch_id=invoice.branch_id,
                invoice_id=invoice.id,
                # Invoice-currency value (backward compatible) + frozen
                # snapshot of the money as actually received.
                amount=_q(equivalent),
                payment_date=invoice_date,
                payment_method=pm.payment_method,
                reference=pm.reference,
                bank_account_id=acct.id,
                payment_currency=pay_cur,
                invoice_currency=currency,
                original_amount=_q(pm.amount),
                exchange_rate=rate,
                equivalent_amount=_q(equivalent),
                exchange_rate_source=(pm.exchange_rate_source or ("same" if pay_cur == currency else "manual")),
                exchange_rate_timestamp=pm.exchange_rate_timestamp,
                created_by=user_id,
            )
        )
    await db.flush()

    # ── Receivable for the remainder ──
    receivable = None
    if balance > TAU:
        receivable = CustomerReceivable(
            organization_id=org_id,
            customer_id=customer.id,
            invoice_id=invoice.id,
            amount=_q(balance),
            paid=ZERO,
            status="open",
        )
        db.add(receivable)
        await db.flush()

    if balance <= TAU:
        invoice.status = "paid"
    elif paid > ZERO:
        invoice.status = "partially_paid"
    await db.flush()

    pushes = await _linked_debt_created(db, org_id, user_id, invoice)
    await db.commit()
    out = await _serialize_invoice(db, invoice, branch.name, receivable, False)
    out['_notification_pushes'] = pushes
    return out


# ═══════════════════════════════════════════
# Customer debt snapshot
# ═══════════════════════════════════════════


async def customer_balance(db: AsyncSession, org_id: UUID, customer_id: UUID) -> dict:
    customer = (
        await db.execute(
            select(Customer).where(
                Customer.id == customer_id,
                Customer.organization_id == org_id,
                Customer.is_deleted.is_(False),
            )
        )
    ).scalar_one_or_none()
    if not customer:
        raise ValueError("العميل غير موجود")
    rows = (
        await db.execute(
            select(CustomerReceivable, Invoice.currency)
            .join(Invoice, Invoice.id == CustomerReceivable.invoice_id)
            .where(
                CustomerReceivable.organization_id == org_id,
                CustomerReceivable.customer_id == customer_id,
                CustomerReceivable.status.in_(["open", "partial"]),
            )
        )
    ).all()
    by_currency: dict = {}
    items: list = []
    for rec, cur in rows:
        cur = (cur or "SAR").upper()
        remaining = rec.amount - rec.paid
        by_currency[cur] = by_currency.get(cur, ZERO) + remaining
        items.append({
            "currency": cur,
            "debt": float(_q(remaining)),
            "date": rec.created_at.isoformat() if rec.created_at else None,
            "invoice_id": str(rec.invoice_id) if rec.invoice_id else None,
        })
    return {
        "customer_id": str(customer_id),
        "customer_name": customer.name,
        "open_count": len(rows),
        "debts": [
            {"currency": cur, "debt": float(_q(amt))}
            for cur, amt in sorted(by_currency.items())
        ],
        "items": items,
    }


# ═══════════════════════════════════════════
# Returns (linked to the original invoice, always)
# ═══════════════════════════════════════════


async def confirm_return(
    db: AsyncSession, org_id: UUID, user_id: UUID, invoice_id: UUID, data: SaleReturnRequest
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
    if not invoice or invoice.invoice_type != "sale":
        raise ValueError("الفاتورة غير موجودة")
    if invoice.status in ("draft", "cancelled"):
        raise ValueError("لا يمكن إرجاع فاتورة مسودة أو ملغية")
    if not data.lines:
        raise ValueError("حدد صنفاً واحداً على الأقل للإرجاع")

    items = (
        await db.execute(select(InvoiceItem).where(InvoiceItem.invoice_id == invoice.id))
    ).scalars().all()
    by_id = {it.id: it for it in items}
    # already-returned base qty per line (confirmed returns only)
    returned: dict = {}
    prior = (
        await db.execute(
            select(InvoiceReturnItem)
            .join(InvoiceReturn, InvoiceReturn.id == InvoiceReturnItem.return_id)
            .where(
                InvoiceReturn.organization_id == org_id,
                InvoiceReturn.invoice_id == invoice.id,
                InvoiceReturn.status == "confirmed",
            )
        )
    ).scalars().all()
    for pr in prior:
        if pr.invoice_item_id:
            returned[pr.invoice_item_id] = returned.get(pr.invoice_item_id, 0.0) + float(
                pr.quantity or 0
            ) * 1.0  # stored in SOLD units (see below)

    ret_lines = []
    ret_total = ZERO
    for rl in data.lines:
        src = by_id.get(rl.invoice_item_id)
        if not src:
            raise ValueError("بند غير موجود في الفاتورة الأصلية")
        sold_qty = float(src.quantity or 0)
        already = returned.get(src.id, 0.0)
        if float(rl.quantity) + already - sold_qty > 1e-9:
            raise ValueError(f"الكمية المرتجعة تتجاوز المباع للبند {src.description}")
        ratio = Decimal(str(rl.quantity)) / Decimal(str(sold_qty)) if sold_qty else ZERO
        prorated_discount = (src.discount or ZERO) * ratio
        line_total = _q(Decimal(str(rl.quantity)) * src.unit_price - prorated_discount)
        # Prefer the factor SNAPSHOT frozen on the invoice line (historical
        # correctness); legacy lines fall back to the unit's current factor.
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
                "src": src, "quantity": float(rl.quantity),
                "base_quantity": float(rl.quantity) * factor,
                "unit_price": src.unit_price, "total": line_total,
                "restock": bool(getattr(rl, "restock", True)),
            }
        )
    ret_total = _q(ret_total)

    # ── Money: shrink balance/receivable first, refund the rest ──
    balance = Decimal(str(invoice.balance or 0))
    paid = Decimal(str(invoice.paid_amount or 0))
    apply = min(ret_total, balance)
    remainder = ret_total - apply
    inv_cur = (invoice.currency or "SAR").strip().upper()
    refund_account = None
    move_amount = ZERO  # what actually leaves the account (its own currency)
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
            # Any account / any currency: base value stays in the invoice
            # currency, the account moves the client-converted amount.
            if data.refund_amount is None or data.refund_amount <= ZERO:
                raise ValueError("المبلغ المسترد بعملة الحساب مطلوب")
            move_amount = _q(data.refund_amount)
        if not data.allow_negative:
            if Decimal(str(refund_account.balance or 0)) + TAU < move_amount:
                raise ValueError("رصيد حساب الاسترداد غير كافٍ")

    ret = InvoiceReturn(
        organization_id=org_id,
        invoice_id=invoice.id,
        return_number=await _next_sequence(db, org_id, "RTN"),
        return_date=date.today(),
        status="confirmed",
        reason=data.reason,
        total=ret_total,
        created_by=user_id,
    )
    db.add(ret)
    await db.flush()

    from app.domain.entities.business_entities import InventoryMovement

    for rl in ret_lines:
        src = rl["src"]
        db.add(
            InvoiceReturnItem(
                return_id=ret.id,
                invoice_item_id=src.id,
                product_id=src.product_id,
                description=src.description,
                quantity=rl["quantity"],
                unit_price=src.unit_price,
                total=rl["total"],
            )
        )
        # Restock (services never touched stock, so nothing to give back).
        # A line marked restock=false (damaged goods) is skipped on purpose.
        if rl["restock"] and src.product_id and not src.is_service:
            product = (
                await db.execute(
                    select(Product)
                    .where(Product.id == src.product_id, Product.organization_id == org_id)
                    .with_for_update()
                )
            ).scalar_one_or_none()
            if not product:
                raise ValueError("منتج البند غير موجود لإعادة المخزون")
            await bstock.apply_delta(db, org_id, invoice.branch_id, product,
                                     rl["base_quantity"])
            # Put the units back into the SAME lots the sale consumed.
            await lots.restore_to_lots(
                db, org_id, product, src.id, rl["base_quantity"]
            )
            db.add(
                InventoryMovement(
                    organization_id=org_id,
                    product_id=product.id,
                    movement_type="sale_return",
                    quantity=rl["base_quantity"],
                    unit_price=src.unit_price,
                    total=rl["total"],
                    reference_type="invoice_return",
                    reference_id=ret.id,
                    notes=f"مرتجع {ret.return_number} من {invoice.invoice_number}",
                    created_by=user_id,
                )
            )
        elif (not rl["restock"]) and src.product_id and not src.is_service:
            # Damaged/not-restocked return: record an informational movement
            # («مرجوع إلى خارج المخزون») WITHOUT touching the product stock.
            db.add(
                InventoryMovement(
                    organization_id=org_id,
                    product_id=src.product_id,
                    movement_type="sale_return_no_stock",
                    quantity=rl["base_quantity"],
                    unit_price=src.unit_price,
                    total=rl["total"],
                    reference_type="invoice_return",
                    reference_id=ret.id,
                    notes=f"مرتجع غير مرجع للمخزون {ret.return_number} من {invoice.invoice_number}",
                    created_by=user_id,
                )
            )
    await db.flush()

    invoice.balance = _q(balance - apply)
    invoice.paid_amount = _q(paid - remainder)
    if remainder > TAU:
        refund_account.balance = Decimal(str(refund_account.balance or 0)) - move_amount
        cross_note = (
            "" if refund_cur == inv_cur
            else f" ({move_amount} {refund_cur} ≈ {remainder} {inv_cur})"
        )
        db.add(
            BankTransaction(
                organization_id=org_id,
                bank_account_id=refund_account.id,
                date=datetime.now(timezone.utc),
                description=f"استرداد مرتجع {ret.return_number}{cross_note}",
                tx_type="withdrawal",
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

    receivable = (
        await db.execute(
            select(CustomerReceivable).where(CustomerReceivable.invoice_id == invoice.id)
        )
    ).scalar_one_or_none()
    if receivable and receivable.status != "cancelled":
        receivable.amount = _q(max(ZERO, Decimal(str(receivable.amount or 0)) - apply))
        if receivable.amount <= TAU:
            receivable.amount = ZERO
            receivable.status = "paid"
        elif receivable.paid > ZERO:
            receivable.status = "partial"
    await db.flush()

    pushes = await _linked_return(db, org_id, user_id, invoice, ret.id, ret_total)
    await db.commit()
    branch_name = None
    if invoice.branch_id:
        branch_name = (
            await db.execute(select(Branch.name).where(Branch.id == invoice.branch_id))
        ).scalar_one_or_none()
    out = await _serialize_invoice(db, invoice, branch_name, receivable, False)
    out['_notification_pushes'] = pushes
    out["return"] = {
        "id": str(ret.id),
        "return_number": ret.return_number,
        "total": float(ret_total),
        "kind": "sale_return",
    }
    return out


# ═══════════════════════════════════════════
# Purchase invoices (money out, stock in, supplier payable)
# ═══════════════════════════════════════════


def _payable_dict(payable: Optional[SupplierPayable]) -> Optional[dict]:
    if payable is None:
        return None
    return {
        "id": str(payable.id),
        "amount": float(payable.amount or 0),
        "paid": float(payable.paid or 0),
        "status": payable.status,
    }


async def _find_or_create_unit(
    db: AsyncSession, org_id: UUID, product: Product, unit_name: str
) -> ProductUnit:
    """Return the product's unit named [unit_name], creating it when missing.

    Used by inline purchase quick-add so a new barcode can be attached to the
    exact unit it belongs to (piece / pack / carton …), supporting several
    barcodes per product across units."""
    base = await ensure_base_unit(db, org_id, product)
    name = (unit_name or "").strip()
    if not name or name == base.name:
        return base
    unit = (
        await db.execute(
            select(ProductUnit).where(
                ProductUnit.organization_id == org_id,
                ProductUnit.product_id == product.id,
                ProductUnit.name == name,
            )
        )
    ).scalar_one_or_none()
    if unit is None:
        unit = ProductUnit(
            organization_id=org_id,
            product_id=product.id,
            name=name,
            factor=Decimal("1"),
            is_base=False,
        )
        db.add(unit)
        await db.flush()
    return unit


async def _resolve_purchase_line(
    db: AsyncSession, org_id: UUID, ln, branch_id: UUID
) -> dict:
    """Resolve one purchase line into a normalized dict, creating a real
    inventory product inline when the client sent a quick-add definition."""
    product = None
    unit = None
    factor = 1.0
    unit_name = "قطعة"
    is_service = False
    description = (ln.description or "").strip()

    if ln.product_id:
        product = (
            await db.execute(
                select(Product)
                .where(
                    Product.id == ln.product_id,
                    Product.organization_id == org_id,
                    Product.is_deleted.is_(False),
                )
                .with_for_update()
            )
        ).scalar_one_or_none()
        if not product or not product.is_active:
            raise ValueError("منتج غير موجود في الفاتورة")
        if (getattr(product, "branch_id", None) is not None
                and product.branch_id != branch_id):
            raise ValueError("هذا المنتج تابع لفرع آخر ولا يمكن استخدامه هنا")
        unit_name = product.unit or "قطعة"
        is_service = bool(product.is_service)
        if ln.unit_id:
            unit = (
                await db.execute(
                    select(ProductUnit).where(
                        ProductUnit.id == ln.unit_id,
                        ProductUnit.product_id == product.id,
                        ProductUnit.organization_id == org_id,
                    )
                )
            ).scalar_one_or_none()
            if not unit or not unit.is_active:
                raise ValueError(f"وحدة غير صالحة للمنتج {product.name}")
            factor = float(unit.factor or 1)
            unit_name = unit.name
        if not description:
            description = product.name

    elif ln.new_product:
        np = ln.new_product or {}
        name = (np.get("name") or "").strip()
        if not name:
            raise ValueError("اسم المنتج السريع مطلوب")
        save = bool(np.get("save_to_inventory", True))
        is_service = bool(np.get("is_service", False)) or not save
        barcode = (np.get("barcode") or "").strip() or None
        want_unit = (np.get("unit") or "").strip()

        existing = None
        brow = None
        # A barcode that already exists belongs to a product (and maybe a
        # specific unit): reuse it and NEVER create a duplicate product.
        if barcode:
            brow = (
                await db.execute(
                    select(ProductBarcode).where(
                        ProductBarcode.organization_id == org_id,
                        ProductBarcode.barcode == barcode,
                    )
                )
            ).scalar_one_or_none()
            if brow is not None:
                existing = (
                    await db.execute(
                        select(Product).where(
                            Product.id == brow.product_id,
                            Product.organization_id == org_id,
                            Product.is_deleted.is_(False),
                        )
                    )
                ).scalar_one_or_none()
                if existing is not None and brow.unit_id:
                    unit = (
                        await db.execute(
                            select(ProductUnit).where(
                                ProductUnit.id == brow.unit_id,
                                ProductUnit.organization_id == org_id,
                            )
                        )
                    ).scalar_one_or_none()
            if existing is None:
                existing = (
                    await db.execute(
                        select(Product).where(
                            Product.organization_id == org_id,
                            Product.barcode == barcode,
                            Product.is_deleted.is_(False),
                        )
                    )
                ).scalar_one_or_none()
        if existing is None:
            existing = (
                await db.execute(
                    select(Product).where(
                        Product.organization_id == org_id,
                        func.lower(Product.name) == name.lower(),
                        Product.is_deleted.is_(False),
                    )
                )
            ).scalar_one_or_none()
        if existing is not None:
            product = existing
            if unit is None:
                unit = (
                    await _find_or_create_unit(db, org_id, product, want_unit)
                    if want_unit
                    else await ensure_base_unit(db, org_id, product)
                )
            unit_name = unit.name
            factor = float(unit.factor or 1)
            is_service = bool(product.is_service)
            # New barcode for an existing product/unit: index it so future
            # scans resolve here (still one product, multiple barcodes).
            if barcode and brow is None:
                db.add(
                    ProductBarcode(
                        organization_id=org_id,
                        product_id=product.id,
                        unit_id=unit.id if unit is not None else None,
                        barcode=barcode,
                    )
                )
        elif save and not is_service:
            _expiry = None
            _ex = np.get("expiry_date")
            if _ex:
                try:
                    from datetime import date as _date

                    _expiry = _date.fromisoformat(str(_ex)[:10])
                except Exception:
                    _expiry = None
            product = Product(
                organization_id=org_id,
                branch_id=branch_id,
                category_id=np.get("category_id") or None,
                name=name,
                unit=(np.get("unit") or "قطعة"),
                price=Decimal(str(np.get("sell_price") or 0)),
                cost_price=ln.unit_price,
                min_stock=Decimal(str(np.get("min_stock") or 0)),
                expiry_date=_expiry,
                stock=0,
                is_service=False,
                barcode=barcode,
                is_active=True,
            )
            db.add(product)
            await db.flush()
            # Sell price in the merchant's chosen currency (if any), kept as an
            # independent per-currency price so it shows in the warehouse.
            _sell_ccy = (np.get("sell_currency") or "").strip().upper()
            if _sell_ccy:
                db.add(
                    ProductPrice(
                        organization_id=org_id,
                        product_id=product.id,
                        currency=_sell_ccy,
                        price=Decimal(str(np.get("sell_price") or 0)),
                    )
                )
            _buy_ccy = (np.get("buy_currency") or "").strip().upper()
            if _buy_ccy:
                product.cost_currency = _buy_ccy
            base = await ensure_base_unit(db, org_id, product)
            unit = (
                await _find_or_create_unit(db, org_id, product, want_unit)
                if want_unit
                else base
            )
            unit_name = unit.name
            factor = float(unit.factor or 1)
            if barcode:
                db.add(
                    ProductBarcode(
                        organization_id=org_id,
                        product_id=product.id,
                        unit_id=unit.id if unit is not None else None,
                        barcode=barcode,
                    )
                )
        else:
            product = None
            is_service = True
            unit_name = (want_unit or "خدمة")
        if not description:
            description = name

    else:
        if not description:
            raise ValueError("البند اليدوي يحتاج وصفاً")
        is_service = True
        unit_name = "خدمة"

    qty = float(ln.quantity)
    price = ln.unit_price
    disc = ln.discount
    if disc > Decimal(str(qty)) * price:
        raise ValueError("خصم البند يتجاوز قيمته")
    base_qty = qty * factor
    return {
        "product": product,
        "unit": unit,
        "factor": factor,
        "description": description,
        "unit_name": unit_name,
        "quantity": qty,
        "base_quantity": base_qty,
        "unit_price": price,
        "discount": disc,
        "is_service": is_service,
        # Frozen FX snapshot sent by the client (product original price +
        # currency + the rate actually applied to reach the invoice currency).
        "original_price": getattr(ln, "original_price", None),
        "price_currency": getattr(ln, "price_currency", None),
        "exchange_rate": getattr(ln, "exchange_rate", None),
    }


async def issue_purchase(
    db: AsyncSession, org_id: UUID, user_id: UUID, data: PurchaseIssueRequest
) -> dict:
    # ── Idempotency: a retried/double-tapped issue returns the original ──
    if data.idempotency_key:
        dup = (
            await db.execute(
                select(Invoice).where(
                    Invoice.organization_id == org_id,
                    Invoice.idempotency_key == data.idempotency_key,
                )
            )
        ).scalar_one_or_none()
        if dup:
            branch_name = None
            if dup.branch_id:
                branch_name = (
                    await db.execute(select(Branch.name).where(Branch.id == dup.branch_id))
                ).scalar_one_or_none()
            payable = (
                await db.execute(
                    select(SupplierPayable).where(SupplierPayable.invoice_id == dup.id)
                )
            ).scalar_one_or_none()
            out = await _serialize_invoice(db, dup, branch_name, None, True)
            out["payable"] = _payable_dict(payable)
            return out

    if not data.items:
        raise ValueError("يجب إضافة بند واحد على الأقل")

    supplier = None
    if data.supplier_id:
        supplier = (
            await db.execute(
                select(Supplier).where(
                    Supplier.id == data.supplier_id,
                    Supplier.organization_id == org_id,
                    Supplier.is_deleted.is_(False),
                )
            )
        ).scalar_one_or_none()
        if not supplier or not supplier.is_active:
            raise ValueError("المورد غير موجود")

    branch = await resolve_branch(db, org_id, data.branch_id)
    currency = (data.currency or "SAR").strip().upper()

    prepared = []
    for ln in data.items:
        resolved_line = await _resolve_purchase_line(db, org_id, ln, branch.id)
        resolved_line["expiry_date"] = getattr(ln, "expiry_date", None)
        resolved_line["lot_number"] = getattr(ln, "lot_number", None)
        resolved_line["line_total"] = _q(
            Decimal(str(resolved_line["quantity"])) * resolved_line["unit_price"]
            - resolved_line["discount"]
        )
        prepared.append(resolved_line)

    totals = calc_totals(
        [
            {
                "quantity": ln["quantity"],
                "unit_price": ln["unit_price"],
                "discount": ln["discount"],
            }
            for ln in prepared
        ],
        data.discount_type,
        data.discount_value,
        data.tax_type,
        data.tax_rate,
    )
    total = totals["total"]

    # ── Payments: money leaves each account in its own currency ──
    paid = ZERO
    resolved = []
    for pm in data.payments:
        acct = (
            await db.execute(
                select(BankAccount).where(
                    BankAccount.id == pm.bank_account_id,
                    BankAccount.organization_id == org_id,
                    BankAccount.is_deleted.is_(False),
                )
            )
        ).scalar_one_or_none()
        if not acct or not acct.is_active:
            raise ValueError("حساب بنكي غير موجود")
        acct_cur = (acct.currency or "SAR").strip().upper()
        pay_cur = (pm.currency or acct_cur).strip().upper()
        if pay_cur != acct_cur:
            raise ValueError(f"عملة الدفعة لا تطابق عملة الحساب {acct.bank_name}")
        if pay_cur == currency:
            rate = Decimal("1")
            equivalent = pm.amount
        else:
            if pm.exchange_rate is None or pm.exchange_rate <= 0:
                raise ValueError(f"سعر الصرف مطلوب للدفعة بعملة {pay_cur}")
            rate = pm.exchange_rate
            equivalent = _q(pm.amount * rate)
        paid += equivalent
        resolved.append((pm, acct, pay_cur, rate, equivalent))

    if paid - total > TAU:
        raise ValueError("المبلغ المدفوع يتجاوز إجمالي الفاتورة")
    balance = total - paid
    if balance < ZERO:
        balance = ZERO
    if balance > TAU and supplier is None:
        raise ValueError("المبلغ المتبقي يتطلب اختيار مورد — لا يمكن إنشاء دين على مورد نقدي")

    invoice = Invoice(
        organization_id=org_id,
        invoice_number=await _next_sequence(db, org_id, "PUR"),
        invoice_type="purchase",
        supplier_id=supplier.id if supplier else None,
        debt_group_id=getattr(data, "debt_group_id", None),
        invoice_date=date.today(),
        due_date=data.due_date or (date.today() + timedelta(days=30) if balance > TAU else None),
        status="confirmed",
        subtotal=totals["subtotal"],
        discount_type=data.discount_type,
        discount_value=data.discount_value,
        discount_amount=totals["discount_amount"],
        tax_type=data.tax_type,
        tax_rate=data.tax_rate,
        tax_amount=totals["tax_amount"],
        total=total,
        paid_amount=_q(paid),
        balance=_q(balance),
        currency=currency,
        branch_id=branch.id,
        idempotency_key=data.idempotency_key,
        notes=data.notes,
        created_by=user_id,
    )
    db.add(invoice)
    await db.flush()

    item_objs = []
    for ln in prepared:
        item = InvoiceItem(
            invoice_id=invoice.id,
            product_id=ln["product"].id if ln["product"] else None,
            description=ln["description"],
            quantity=ln["quantity"],
            unit_price=ln["unit_price"],
            discount=ln["discount"],
            tax_rate=ZERO,
            total=ln["line_total"],
            unit_id=ln["unit"].id if ln["unit"] else None,
            unit_name=ln["unit_name"],
            base_quantity=ln["base_quantity"],
            factor=ln.get("factor"),
            is_service=ln["is_service"],
            image=ln["product"].image if ln["product"] else None,
            original_unit_price=ln.get("original_price"),
            price_currency=ln.get("price_currency"),
            exchange_rate_used=ln.get("exchange_rate"),
        )
        db.add(item)
        item_objs.append(item)
    await db.flush()

    # ── Stock IN (base units only; services untouched) ──
    for idx, ln in enumerate(prepared):
        product = ln["product"]
        if product is None or ln["is_service"]:
            continue
        await bstock.apply_delta(db, org_id, invoice.branch_id, product,
                                 ln["base_quantity"],
                                 unit_cost=ln["unit_price"])
        product.cost_price = ln["unit_price"]
        product.cost_currency = currency
        base_price = ln["unit_price"] / Decimal(str(ln["factor"])) if ln["factor"] else ln["unit_price"]
        db.add(
            InventoryMovement(
                organization_id=org_id,
                product_id=product.id,
                movement_type="purchase",
                quantity=ln["base_quantity"],
                unit_price=_q(base_price),
                total=ln["line_total"],
                currency=currency,
                reference_type="invoice",
                reference_id=invoice.id,
                notes=f"شراء {invoice.invoice_number}",
                created_by=user_id,
            )
        )
        # Keep each purchase as an INDEPENDENT lot (cost + currency + expiry).
        await lots.create_lot(
            db,
            org_id,
            product,
            ln["base_quantity"],
            _q(base_price),
            currency,
            branch_id=branch.id,
            supplier_id=supplier.id if supplier else None,
            purchase_invoice_id=invoice.id,
            invoice_item_id=item_objs[idx].id,
            unit_id=ln["unit"].id if ln["unit"] else None,
            purchase_date=invoice.invoice_date,
            expiry_date=ln.get("expiry_date"),
            lot_number=ln.get("lot_number"),
            source="purchase",
        )
    await db.flush()

    # ── Money OUT of the chosen accounts (each in its own currency) ──
    for pm, acct, pay_cur, rate, equivalent in resolved:
        acct.balance = Decimal(str(acct.balance or 0)) - pm.amount
        db.add(
            BankTransaction(
                organization_id=org_id,
                bank_account_id=acct.id,
                date=datetime.now(timezone.utc),
                description=f"سداد فاتورة شراء {invoice.invoice_number}",
                tx_type="withdrawal",
                amount=pm.amount,
                currency=pay_cur,
                running_balance=acct.balance,
                reference=invoice.invoice_number,
            )
        )
        db.add(
            Payment(
                organization_id=org_id,
                branch_id=invoice.branch_id,
                invoice_id=invoice.id,
                amount=_q(equivalent),
                payment_date=date.today(),
                payment_method=pm.payment_method,
                reference=pm.reference,
                bank_account_id=acct.id,
                payment_currency=pay_cur,
                invoice_currency=currency,
                original_amount=_q(pm.amount),
                exchange_rate=rate,
                equivalent_amount=_q(equivalent),
                exchange_rate_source=(pm.exchange_rate_source or ("same" if pay_cur == currency else "manual")),
                exchange_rate_timestamp=pm.exchange_rate_timestamp,
                created_by=user_id,
            )
        )
    await db.flush()

    # ── Payable for the remainder ──
    payable = None
    if balance > TAU:
        payable = SupplierPayable(
            organization_id=org_id,
            supplier_id=supplier.id,
            invoice_id=invoice.id,
            amount=_q(balance),
            paid=ZERO,
            status="open",
        )
        db.add(payable)
        await db.flush()

    if balance <= TAU:
        invoice.status = "paid"
    elif paid > ZERO:
        invoice.status = "partially_paid"
    await db.flush()

    pushes = await _linked_debt_created(db, org_id, user_id, invoice)
    await db.commit()
    out = await _serialize_invoice(db, invoice, branch.name, None, False)
    out['_notification_pushes'] = pushes
    out["payable"] = _payable_dict(payable)
    return out


async def party_operations(
    db: AsyncSession, org_id: UUID, party_id: UUID, is_supplier: bool
) -> list:
    """Every invoice operation for a party with its own outstanding balance
    (instead of a single aggregated total), so each can be opened separately."""
    if is_supplier:
        model = SupplierPayable
        flt = SupplierPayable.supplier_id == party_id
    else:
        model = CustomerReceivable
        flt = CustomerReceivable.customer_id == party_id
    rows = (
        await db.execute(
            select(Invoice, model)
            .join(model, model.invoice_id == Invoice.id)
            .where(
                Invoice.organization_id == org_id,
                Invoice.is_deleted.is_(False),
                flt,
            )
            .order_by(Invoice.invoice_date.desc())
        )
    ).all()
    out = []
    for inv, ent in rows:
        amt = float(ent.amount or 0)
        paid = float(ent.paid or 0)
        out.append({
            "invoice_id": str(inv.id),
            "invoice_number": inv.invoice_number,
            "invoice_type": inv.invoice_type,
            "date": inv.invoice_date.isoformat() if inv.invoice_date else None,
            "total": float(inv.total or 0),
            "paid": paid,
            "balance": max(amt - paid, 0.0),
            "currency": inv.currency,
            "status": ent.status,
        })
    return out


async def supplier_balance(db: AsyncSession, org_id: UUID, supplier_id: UUID) -> dict:
    supplier = (
        await db.execute(
            select(Supplier).where(
                Supplier.id == supplier_id,
                Supplier.organization_id == org_id,
                Supplier.is_deleted.is_(False),
            )
        )
    ).scalar_one_or_none()
    if not supplier:
        raise ValueError("المورد غير موجود")
    rows = (
        await db.execute(
            select(SupplierPayable, Invoice.currency)
            .join(Invoice, Invoice.id == SupplierPayable.invoice_id)
            .where(
                SupplierPayable.organization_id == org_id,
                SupplierPayable.supplier_id == supplier_id,
                SupplierPayable.status.in_(["open", "partial"]),
            )
        )
    ).all()
    by_currency: dict = {}
    for pay, cur in rows:
        cur = (cur or "SAR").upper()
        by_currency[cur] = by_currency.get(cur, ZERO) + (pay.amount - pay.paid)
    return {
        "supplier_id": str(supplier_id),
        "supplier_name": supplier.name,
        "open_count": len(rows),
        "debts": [
            {"currency": cur, "debt": float(_q(amt))}
            for cur, amt in sorted(by_currency.items())
        ],
    }


async def _settle_party(
    db: AsyncSession,
    org_id: UUID,
    user_id: UUID,
    *,
    is_supplier: bool,
    party_id: UUID,
    data: PartyPaymentRequest,
    branch_id: Optional[UUID] = None,
    notify_linked: bool = True,
) -> dict:
    """Shared supplier-payment / customer-collection engine. Applies one
    account+currency+amount to the open debts of that same currency (oldest
    first), updates each invoice, and posts ONE account movement."""
    is_main = False
    if branch_id is not None:
        branch = (await db.execute(select(Branch).where(
            Branch.id == branch_id, Branch.organization_id == org_id,
            Branch.is_active.is_(True)))).scalar_one_or_none()
        if branch is None:
            raise ValueError("الفرع غير متاح")
        is_main = bool(branch.is_default)

    def in_branch(value):
        return branch_id is None or value == branch_id or (value is None and is_main)
    acct = (
        await db.execute(
            select(BankAccount).where(
                BankAccount.id == data.bank_account_id,
                BankAccount.organization_id == org_id,
                BankAccount.is_deleted.is_(False),
            ).with_for_update().execution_options(populate_existing=True)
        )
    ).scalar_one_or_none()
    if not acct or not acct.is_active:
        raise ValueError("حساب بنكي غير موجود")
    if not in_branch(acct.branch_id):
        raise ValueError("الحساب يخص فرعًا آخر")
    acct_cur = (acct.currency or "SAR").strip().upper()
    currency = (data.currency or acct_cur).strip().upper()
    if currency != acct_cur:
        raise ValueError(f"عملة الدفعة لا تطابق عملة الحساب {acct.bank_name}")

    if is_supplier:
        entity_model = SupplierPayable
        entity_filter = SupplierPayable.supplier_id == party_id
        party = (
            await db.execute(
                select(Supplier).where(
                    Supplier.id == party_id, Supplier.organization_id == org_id
                ).with_for_update().execution_options(populate_existing=True)
            )
        ).scalar_one_or_none()
        if not party:
            raise ValueError("المورد غير موجود")
    else:
        entity_model = CustomerReceivable
        entity_filter = CustomerReceivable.customer_id == party_id
        party = (
            await db.execute(
                select(Customer).where(
                    Customer.id == party_id, Customer.organization_id == org_id
                ).with_for_update().execution_options(populate_existing=True)
            )
        ).scalar_one_or_none()
        if not party:
            raise ValueError("العميل غير موجود")

    if party.is_deleted or not in_branch(party.branch_id):
        raise ValueError("الطرف غير متاح في هذا الفرع")
    invoice_filters = [
        Invoice.organization_id == org_id,
        Invoice.invoice_type == ('purchase' if is_supplier else 'sale'),
        (Invoice.supplier_id if is_supplier else Invoice.customer_id) == party_id,
        Invoice.is_deleted.is_(False),
    ]
    if branch_id is not None:
        from sqlalchemy import or_
        invoice_filters.append(or_(Invoice.branch_id == branch_id,
            Invoice.branch_id.is_(None) if is_main else False))
    if data.invoice_id is not None:
        valid = await db.scalar(select(Invoice.id).where(
            Invoice.id == data.invoice_id, *invoice_filters,
            *([Invoice.debt_group_id == data.debt_group_id] if data.debt_group_id else [])))
        if valid is None:
            raise ValueError("الفاتورة غير متاحة لهذا الطرف والفرع")

    rows = (
        await db.execute(
            select(entity_model, Invoice)
            .join(Invoice, Invoice.id == entity_model.invoice_id)
            .where(
                entity_model.organization_id == org_id,
                entity_filter,
                *invoice_filters,
                entity_model.status.in_(["open", "partial"]),
                func.upper(Invoice.currency) == currency,
                *([Invoice.debt_group_id == data.debt_group_id]
                  if getattr(data, "debt_group_id", None) else []),
                *([Invoice.id == data.invoice_id]
                  if getattr(data, "invoice_id", None) else []),
            )
            .order_by(Invoice.invoice_date.asc(), entity_model.created_at.asc())
            .with_for_update(of=(entity_model, Invoice))
        )
    ).all()

    settle_currency = currency
    apply_amount = data.amount
    # Cross-currency: no debts in the payment currency -> settle an existing
    # debt currency using the provided (frozen) exchange rate.
    if not rows:
        any_rows = (
            await db.execute(
                select(entity_model, Invoice)
                .join(Invoice, Invoice.id == entity_model.invoice_id)
                .where(
                    entity_model.organization_id == org_id,
                    entity_filter,
                    *invoice_filters,
                    entity_model.status.in_(["open", "partial"]),
                    *([Invoice.debt_group_id == data.debt_group_id]
                      if getattr(data, "debt_group_id", None) else []),
                    *([Invoice.id == data.invoice_id]
                      if getattr(data, "invoice_id", None) else []),
                )
                .order_by(Invoice.invoice_date.asc(), entity_model.created_at.asc())
                .with_for_update(of=(entity_model, Invoice))
            )
        ).all()
        if any_rows and data.exchange_rate and data.exchange_rate > 0:
            settle_currency = (any_rows[0][1].currency or currency).upper()
            apply_amount = _q(data.amount * data.exchange_rate)
            rows = [
                r
                for r in any_rows
                if (r[1].currency or "").upper() == settle_currency
            ]

    remaining = apply_amount
    applied = ZERO
    touched = []
    for debt, invoice in rows:
        if remaining <= TAU:
            break
        owed = Decimal(str(debt.amount or 0)) - Decimal(str(debt.paid or 0))
        if owed <= TAU:
            continue
        take = owed if owed < remaining else remaining
        debt.paid = Decimal(str(debt.paid or 0)) + take
        debt.status = "paid" if (Decimal(str(debt.amount)) - debt.paid) <= TAU else "partial"
        # Invoice mirror
        inv_paid = Decimal(str(invoice.paid_amount or 0)) + take
        invoice.paid_amount = _q(inv_paid)
        new_balance = Decimal(str(invoice.total or 0)) - inv_paid
        if new_balance < ZERO:
            new_balance = ZERO
        invoice.balance = _q(new_balance)
        invoice.status = "paid" if new_balance <= TAU else "partially_paid"
        db.add(
            Payment(
                organization_id=org_id,
                branch_id=invoice.branch_id,
                invoice_id=invoice.id,
                amount=_q(take),
                payment_date=date.today(),
                payment_method=data.payment_method,
                reference=data.reference,
                bank_account_id=acct.id,
                payment_currency=currency,
                invoice_currency=settle_currency,
                original_amount=_q(
                    take if currency == settle_currency
                    else Decimal(str(take)) / data.exchange_rate
                ),
                exchange_rate=(
                    Decimal("1") if currency == settle_currency
                    else data.exchange_rate
                ),
                equivalent_amount=_q(take),
                exchange_rate_source=(
                    "same" if currency == settle_currency else "manual"
                ),
                notes=data.notes,
                created_by=user_id,
            )
        )
        applied += take
        remaining -= take
        touched.append(str(invoice.id))

    if applied <= ZERO:
        raise ValueError("لا يوجد مستحق بهذه العملة")
    # Over-payment is ALLOWED: the debt is cleared with its exact remainder and
    # the extra money still moves through the bank as an advance. This lets a
    # customer pay a little more (or the merchant round a supplier payment up)
    # without forcing the amount to match the debt to the cent.
    surplus = remaining if remaining > TAU else ZERO
    surplus_pay = (surplus / data.exchange_rate
                   if surplus > TAU and data.exchange_rate
                   else surplus)

    # Money movement: supplier payment leaves the account; collection enters it.
    if is_supplier:
        acct.balance = Decimal(str(acct.balance or 0)) - data.amount
        tx_type = "withdrawal"
        desc = f"سداد للمورد {party.name}"
    else:
        acct.balance = Decimal(str(acct.balance or 0)) + data.amount
        tx_type = "deposit"
        desc = f"تحصيل من العميل {party.name}"
    if surplus > TAU:
        desc = f"{desc} (+زيادة {_q(surplus_pay)} {currency})"
    transaction = BankTransaction(
            organization_id=org_id,
            bank_account_id=acct.id,
            date=datetime.now(timezone.utc),
            description=desc,
            tx_type=tx_type,
            amount=data.amount,
            currency=currency,
            running_balance=acct.balance,
            reference=data.reference,
        )
    db.add(transaction)
    await db.flush()
    from . import merchant_link_service as links
    pushes = await links.notify_party(
        db, org_id, 'supplier' if is_supplier else 'customer', party_id,
        event_id=f'payment:{transaction.id}', title='تحديث السداد',
        message=f'دفعة {data.amount} {currency}',
        route_for=lambda link: f'/personal/merchant-partner?link={link.id}',
        actor_user_id=user_id) if notify_linked else []
    await db.commit()
    return {
        '_notification_pushes': pushes,
        "party_id": str(party_id),
        "party_name": party.name,
        "applied": float(_q(applied)),
        "surplus": float(_q(surplus_pay)),
        "surplus_currency": currency,
        "currency": currency,
        "invoices": touched,
    }


async def add_supplier_payment(
    db: AsyncSession, org_id: UUID, user_id: UUID, supplier_id: UUID, data: PartyPaymentRequest,
    *, branch_id: Optional[UUID] = None, notify_linked: bool = True,
) -> dict:
    return await _settle_party(
        db, org_id, user_id, is_supplier=True, party_id=supplier_id, data=data, branch_id=branch_id,
        notify_linked=notify_linked
    )


async def add_customer_payment(
    db: AsyncSession, org_id: UUID, user_id: UUID, customer_id: UUID, data: PartyPaymentRequest,
    *, branch_id: Optional[UUID] = None, notify_linked: bool = True,
) -> dict:
    return await _settle_party(
        db, org_id, user_id, is_supplier=False, party_id=customer_id, data=data, branch_id=branch_id,
        notify_linked=notify_linked
    )


async def _linked_debt_created(db, org_id, user_id, invoice):
    """Outbox belongs to the original writer, including offline approval.

    Online routers consume the private push payload after this service commits;
    the sync authority retains the row in its operation/receipt transaction.
    """
    if Decimal(str(invoice.balance or 0)) <= TAU:
        return []
    from . import merchant_link_service as links
    supplier = invoice.invoice_type == 'purchase'
    return await links.notify_party(
        db, org_id, 'supplier' if supplier else 'customer',
        invoice.supplier_id if supplier else invoice.customer_id,
        event_id=f'debt_created:{invoice.id}', title='دين جديد',
        message=f'سُجّل دين جديد بقيمة {invoice.balance} {invoice.currency}',
        route_for=lambda link: f'/personal/merchant-partner?link={link.id}&op={invoice.id}',
        actor_user_id=user_id)


async def _linked_return(db, org_id, user_id, invoice, return_id, total):
    from . import merchant_link_service as links
    supplier = invoice.invoice_type == 'purchase'
    return await links.notify_party(
        db, org_id, 'supplier' if supplier else 'customer',
        invoice.supplier_id if supplier else invoice.customer_id,
        event_id=f'debt_return:{return_id}', title='تحديث الدين — مرتجع',
        message=f'مرتجع بقيمة {total} {invoice.currency} — المتبقي {invoice.balance}',
        route_for=lambda link: f'/personal/merchant-partner?link={link.id}&op={invoice.id}',
        actor_user_id=user_id)
