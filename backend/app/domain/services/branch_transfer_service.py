"""Atomic branch-to-branch financial and inventory transfers + reversals.

Internal transfers are not sales, income or operating expenses: they move value
between two branches of the SAME company. Every write is idempotent, recorded
on both sides, and reversible without deleting history.
"""

import json
import secrets
from datetime import date, datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from typing import Any, Dict, Iterable, List, Optional
from uuid import UUID

from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.qa_business_ledger import contains_registered_branch
from app.domain.entities.auth_entities import User
from app.domain.entities.business_entities import (
    InventoryMovement, Product, ProductCategory,
)
from app.domain.entities.finance_entities import BankAccount, BankTransaction
from app.domain.entities.branch_entities import (
    BranchTransfer, BranchTransferItem, BranchMember,
)
from app.domain.entities.notification_entities import AppNotification
from app.domain.entities.sale_entities import (
    Branch, BranchStock, ProductUnit,
)
from app.domain.services import branch_access_service as access
from app.domain.services import branch_stock_service as stock_service
from app.domain.services import inventory_lots


class TransferNeedsArbitration(ValueError):
    """The connected writer must never complete one side of a device transfer."""


async def require_connected_transfer_scope(db: AsyncSession, branch_ids) -> None:
    if await contains_registered_branch(db, branch_ids):
        raise TransferNeedsArbitration(
            "التحويل الذي يشمل دفتر جهاز يتطلب التحكيم على الفرعين؛ لم تُغيّر أي كمية أو رصيد."
        )


_AR_CURRENCY = {
    "SAR": "ريال سعودي", "USD": "دولار أمريكي", "EUR": "يورو",
    "YER_OLD": "ريال يمني قديم", "YER_NEW": "ريال يمني جديد",
    "YER": "ريال يمني جديد", "AED": "درهم إماراتي",
    "KWD": "دينار كويتي", "QAR": "ريال قطري", "BHD": "دينار بحريني",
    "OMR": "ريال عماني", "EGP": "جنيه مصري", "TRY": "ليرة تركية",
}


def format_money_ar(amount, currency: Optional[str]) -> str:
    d = _d(amount)
    if (d - d.to_integral_value()).copy_abs() < Decimal("0.0000001"):
        num = str(int(d))
    else:
        num = format(d.normalize(), "f").rstrip("0").rstrip(".")
    code = str(currency or "").strip().upper()
    name = _AR_CURRENCY.get(code, code)
    return f"{num} {name}".strip()


ZERO = Decimal("0")
Q4 = Decimal("0.0001")
Q6 = Decimal("0.000001")


def _d(v) -> Decimal:
    return Decimal(str(v or 0))


def _q(v, step: Decimal = Q4) -> Decimal:
    return _d(v).quantize(step, rounding=ROUND_HALF_UP)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _number(kind: str) -> str:
    prefix = "FTR" if kind == "financial" else "ITR"
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    code = "".join(secrets.choice(alphabet) for _ in range(7))
    return f"{prefix}-{code}"


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False)


async def _branch(db: AsyncSession, org_id: UUID, branch_id: UUID, *, lock=False) -> Branch:
    query = select(Branch).where(
        Branch.id == branch_id, Branch.organization_id == org_id,
    )
    if lock:
        query = query.with_for_update().execution_options(populate_existing=True)
    row = (await db.execute(query)).scalar_one_or_none()
    if row is None:
        raise ValueError("الفرع غير موجود")
    if row.is_archived or not row.is_active:
        raise ValueError("الفرع غير نشط أو مؤرشف")
    return row


async def _account(db: AsyncSession, org_id: UUID, branch_id: UUID,
                   account_id: UUID) -> BankAccount:
    row = (await db.execute(select(BankAccount).where(
        BankAccount.id == account_id,
        BankAccount.organization_id == org_id,
        BankAccount.branch_id == branch_id,
        BankAccount.is_active.is_(True),
        BankAccount.is_deleted.is_(False),
    ).with_for_update().execution_options(populate_existing=True))).scalar_one_or_none()
    if row is None:
        raise ValueError("الحساب البنكي لا يتبع الفرع المحدد")
    return row


async def _validate_transfer_access(db: AsyncSession, org_id: UUID,
                                    actor: User, from_branch_id: UUID,
                                    to_branch_id: UUID) -> User:
    # Bank/stock capture shares the authority's company head. Take it before
    # identity, branch, account or stock rows on original Online paths too.
    if from_branch_id == to_branch_id:
        raise ValueError("يجب اختيار فرعين مختلفين")
    if actor is None:
        raise ValueError('المستخدم غير موجود')
    actor = (await db.execute(select(User).where(User.id == actor.id)
        .with_for_update().execution_options(populate_existing=True))).scalar_one_or_none()
    if actor is None or actor.status != 'active':
        raise ValueError('المستخدم غير نشط')
    await db.execute(select(BranchMember).where(BranchMember.organization_id == org_id,
        BranchMember.user_id == actor.id).with_for_update().execution_options(populate_existing=True))
    for branch_id in sorted((from_branch_id, to_branch_id), key=str):
        await _branch(db, org_id, branch_id, lock=True)
    allowed = await access.can_transfer(
        db, org_id, actor.id, from_branch_id, to_branch_id)
    if not allowed:
        raise ValueError("لا تملك صلاحية التحويل بين هذين الفرعين")
    await require_connected_transfer_scope(db, (from_branch_id, to_branch_id))
    return actor


async def _check_negative_override(db, org_id, actor, allow_negative):
    if type(allow_negative) is not bool:
        raise ValueError('خيار الرصيد السالب يجب أن يكون منطقيًا')
    if not allow_negative or access.is_owner(actor, org_id):
        return
    from .employee_access_policy import full_access
    member = await access.get_member(db, org_id, actor.id)
    try:
        permissions = json.loads(member.permissions or '{}') if member else {}
    except (TypeError, ValueError):
        permissions = {}
    # Preserve the original employee policy's explicit full-access exception.
    if isinstance(permissions, dict) and full_access(permissions):
        return
    from app.domain.entities.business_settings_entities import BusinessProjectSettings
    settings_row = (await db.execute(select(BusinessProjectSettings).where(
        BusinessProjectSettings.organization_id == org_id).with_for_update())).scalar_one_or_none()
    try:
        settings = json.loads(settings_row.settings or '{}') if settings_row else {}
    except (TypeError, ValueError):
        settings = {}
    permitted = isinstance(settings, dict) and settings.get('allow_negative') is True
    if not permitted:
        raise ValueError('تجاوز الرصيد غير مصرح به؛ يحتاج المالك أو إعداد الشركة')


async def _unit(db: AsyncSession, product_id: UUID,
                unit_id: Optional[UUID]) -> tuple[Decimal, Optional[str]]:
    if unit_id is None:
        return Decimal("1"), None
    row = (await db.execute(select(ProductUnit).where(
        ProductUnit.id == unit_id,
        ProductUnit.product_id == product_id,
        ProductUnit.is_active.is_(True),
    ))).scalar_one_or_none()
    if row is None:
        raise ValueError("وحدة القياس غير موجودة لهذا المنتج")
    return _d(row.factor or 1), row.name


async def _source_product(db: AsyncSession, org_id: UUID,
                          branch_id: UUID, product_id: UUID) -> Product:
    product = (await db.execute(select(Product).where(
        Product.id == product_id, Product.organization_id == org_id,
        Product.is_deleted.is_(False),
    ))).scalar_one_or_none()
    if product is None:
        raise ValueError("المنتج غير موجود")
    qty, _ = await stock_service.get_stock(db, branch_id, product_id)
    if qty <= ZERO:
        raise ValueError(f"المنتج «{product.name}» غير متوفر في الفرع المُرسِل")
    return product


async def _target_product(db: AsyncSession, org_id: UUID, branch_id: UUID,
                          product_id: UUID) -> Product:
    product = (await db.execute(select(Product).where(
        Product.id == product_id, Product.organization_id == org_id,
        Product.is_deleted.is_(False),
    ))).scalar_one_or_none()
    if product is None:
        raise ValueError("المنتج المقابل في الفرع المستلم غير موجود")
    row = (await db.execute(select(BranchStock).where(
        BranchStock.branch_id == branch_id,
        BranchStock.product_id == product_id,
    ))).scalar_one_or_none()
    if row is None and product.branch_id != branch_id:
        raise ValueError("المنتج المختار لا يتبع الفرع المستلم")
    return product


class UnitConversionRequired(ValueError):
    """The two independent products have no provable unit relationship."""

    def __init__(self, info: Dict[str, Any]):
        self.info = info
        super().__init__("معامل تحويل الوحدات مطلوب")


def _norm_unit(value: Optional[str]) -> str:
    return " ".join(str(value or "").strip().lower().split())


async def _product(db: AsyncSession, org_id: UUID, product_id: UUID) -> Product:
    row = (await db.execute(select(Product).where(
        Product.id == product_id, Product.organization_id == org_id,
        Product.is_deleted.is_(False)))).scalar_one_or_none()
    if row is None:
        raise ValueError("المنتج غير موجود")
    return row


async def _matching_unit(db: AsyncSession, product_id: UUID,
                         name: str):
    wanted = _norm_unit(name)
    if not wanted:
        return None
    rows = (await db.execute(select(ProductUnit).where(
        ProductUnit.product_id == product_id,
        ProductUnit.is_active.is_(True),
    ))).scalars().all()
    for row in rows:
        if _norm_unit(row.name) == wanted:
            return row
    return None


async def _resolve_conversion(db: AsyncSession, src: Product, dst: Product,
                              from_unit_name: Optional[str],
                              from_factor: Decimal,
                              explicit) -> tuple[Decimal, Optional[ProductUnit]]:
    name = from_unit_name or src.unit or "قطعة"
    if explicit is not None:
        value = _d(explicit)
        if value <= ZERO:
            raise ValueError("معامل التحويل يجب أن يكون أكبر من صفر")
        matched = await _matching_unit(db, dst.id, name)
        if matched is not None and _d(matched.factor) != value:
            matched.factor = value
        elif matched is None and src.id != dst.id:
            line_desc = f"تحويل من {src.name}"
            db.add(ProductUnit(
                organization_id=src.organization_id, product_id=dst.id,
                name=name, factor=value, group="تحويل بين الفروع",
                sale_price=ZERO, purchase_price=ZERO, is_base=False,
                is_active=True,
            ))
            await db.flush()
        return value, matched
    if src.id == dst.id:
        return from_factor, await _matching_unit(db, dst.id, name)
    matched = await _matching_unit(db, dst.id, name)
    if matched is not None and abs(_d(matched.factor) - from_factor) < Q6:
        return _d(matched.factor), matched
    if (_norm_unit(name) == _norm_unit(dst.unit) and
            abs(from_factor - Decimal("1")) < Q6):
        return Decimal("1"), None
    info = {
        "source_product_id": str(src.id), "source_product_name": src.name,
        "target_product_id": str(dst.id), "target_product_name": dst.name,
        "source_unit_name": name,
        "source_unit_factor": float(from_factor),
        "target_base_unit": dst.unit or "قطعة",
        "suggested_factor": (float(matched.factor) if matched is not None
                             else float(from_factor) if from_factor > ZERO
                             else 1.0),
        "conflicting_saved_factor": (float(matched.factor)
                                     if matched is not None else None),
    }
    raise UnitConversionRequired(info)


async def unit_conversion_info(db: AsyncSession, org_id: UUID,
                               from_product_id: UUID, to_product_id: UUID,
                               from_unit_id: Optional[UUID]) -> Dict[str, Any]:
    src = await _product(db, org_id, from_product_id)
    dst = await _product(db, org_id, to_product_id)
    await require_connected_transfer_scope(db, (src.branch_id, dst.branch_id))
    from_factor, from_name = await _unit(db, src.id, from_unit_id)
    name = from_name or src.unit or "قطعة"
    matched = await _matching_unit(db, dst.id, name)
    required = False
    factor = from_factor
    if src.id == dst.id:
        factor = from_factor
    elif matched is not None and abs(_d(matched.factor) - from_factor) < Q6:
        factor = _d(matched.factor)
    elif (_norm_unit(name) == _norm_unit(dst.unit) and
          abs(from_factor - Decimal("1")) < Q6):
        factor = Decimal("1")
    else:
        required = True
        if matched is not None:
            factor = _d(matched.factor)
    return {
        "required": required,
        "source_unit_name": name,
        "source_unit_factor": float(from_factor),
        "source_unit_id": str(from_unit_id) if from_unit_id else None,
        "target_base_unit": dst.unit or "قطعة",
        "target_product_id": str(dst.id),
        "target_product_name": dst.name,
        "matched_unit_id": str(matched.id) if matched else None,
        "suggested_factor": float(matched.factor) if matched else
        float(from_factor) if from_factor > ZERO else 1.0,
        "conflicting_saved_factor": float(matched.factor) if matched else None,
        "conversion_factor": float(factor),
    }


async def _lock_idempotency(db: AsyncSession, org_id: UUID,
                            key: Optional[str], kind: str) -> None:
    """Serialize concurrent retries of the SAME operation on PostgreSQL."""
    if not key:
        return
    try:
        from sqlalchemy import text
        await db.execute(text(
            "SELECT pg_advisory_xact_lock(hashtext(:k))"),
            {"k": f"branch-transfer:{kind}:{org_id}:{key}"})
    except Exception:
        # SQLite/other engines: the unique constraint remains the final guard.
        pass


async def create_financial(
    db: AsyncSession, org_id: UUID, actor: User, *,
    from_branch_id: UUID, to_branch_id: UUID,
    from_account_id: UUID, to_account_id: UUID,
    amount, exchange_rate=None, allow_negative: bool = False,
    idempotency_key: Optional[str] = None, notes: Optional[str] = None,
    commit: bool = True,
) -> Dict[str, Any]:
    actor = await _validate_transfer_access(
        db, org_id, actor, from_branch_id, to_branch_id)
    await _check_negative_override(db, org_id, actor, allow_negative)
    amount = _q(amount)
    if amount <= ZERO:
        raise ValueError("مبلغ التحويل يجب أن يكون أكبر من صفر")
    if idempotency_key:
        await _lock_idempotency(db, org_id, idempotency_key, "financial")
        existing = (await db.execute(select(BranchTransfer).where(
            BranchTransfer.organization_id == org_id,
            BranchTransfer.idempotency_key == idempotency_key,
        ))).scalar_one_or_none()
        if existing is not None:
            return await detail(db, org_id, existing.id)
    src = await _account(db, org_id, from_branch_id, from_account_id)
    dst = await _account(db, org_id, to_branch_id, to_account_id)
    src_cur = (src.currency or "SAR").strip().upper()
    dst_cur = (dst.currency or "SAR").strip().upper()
    if src_cur == dst_cur:
        rate = Decimal("1")
        received = amount
    else:
        if exchange_rate is None or _d(exchange_rate) <= ZERO:
            raise ValueError("سعر الصرف مطلوب للتحويل بين عملتين مختلفتين")
        rate = _d(exchange_rate)
        received = _q(amount * rate)
    if received <= ZERO:
        raise ValueError("المبلغ المستلم غير صالح")
    if not allow_negative and _d(src.balance) + Q4 < amount:
        raise ValueError("رصيد الحساب المُرسِل غير كافٍ")

    src.balance = _q(_d(src.balance) - amount)
    dst.balance = _q(_d(dst.balance) + received)
    number = _number("financial")
    now = _now()
    transfer = BranchTransfer(
        organization_id=org_id, transfer_number=number, kind="financial",
        from_branch_id=from_branch_id, to_branch_id=to_branch_id,
        actor_user_id=actor.id, actor_role=(actor.role or "employee"),
        status="completed", from_account_id=src.id, to_account_id=dst.id,
        amount=amount, currency=src_cur, to_currency=dst_cur,
        exchange_rate=rate, received_amount=received, total_cost=amount,
        idempotency_key=idempotency_key, notes=notes,
        created_at=now, completed_at=now,
    )
    db.add(transfer)
    await db.flush()
    db.add(BankTransaction(
        organization_id=org_id, bank_account_id=src.id, date=now,
        description=f"تحويل بين الفروع {number} إلى {dst.account_name}",
        tx_type="transfer_out", amount=amount, currency=src_cur,
        running_balance=src.balance, reference=number,
    ))
    db.add(BankTransaction(
        organization_id=org_id, bank_account_id=dst.id, date=now,
        description=f"تحويل بين الفروع {number} من {src.account_name}",
        tx_type="transfer_in", amount=received, currency=dst_cur,
        running_balance=dst.balance, reference=number,
    ))
    await _emit_transfer_notifications(
        db, org_id, transfer, "financial", amount, src_cur, received, dst_cur,
        from_name=(await _branch(db, org_id, from_branch_id)).name,
        to_name=(await _branch(db, org_id, to_branch_id)).name,
        actor_name=actor.full_name or "")
    if commit:
        await db.commit()
    return await detail(db, org_id, transfer.id)


def _norm_name(value: Optional[str]) -> str:
    return " ".join(str(value or "").strip().lower().split())


async def _find_target_by_name(db: AsyncSession, org_id: UUID,
                               branch_id: UUID, name: str) -> Optional[Product]:
    wanted = _norm_name(name)
    if not wanted:
        return None
    stmt = select(Product, BranchStock).outerjoin(
        BranchStock, (BranchStock.product_id == Product.id) &
        (BranchStock.branch_id == branch_id)
    ).where(
        Product.organization_id == org_id,
        Product.is_deleted.is_(False),
        Product.is_active.is_(True),
        Product.is_service.is_(False),
        or_(
            Product.branch_id == branch_id,
            BranchStock.id.is_not(None),
        ),
    )
    rows = (await db.execute(stmt.order_by(Product.name.asc(), Product.id.asc()))).all()
    for product, stock in rows:
        if _norm_name(product.name) != wanted:
            continue
        if product.branch_id == branch_id or stock is not None:
            return product
    return None


async def product_match(db: AsyncSession, org_id: UUID, actor: User,
                        from_product_id: UUID, to_branch_id: UUID) -> Dict[str, Any]:
    allowed = set(await access.effective_branch_ids(db, org_id, actor.id))
    if to_branch_id not in allowed:
        raise ValueError("لا تملك صلاحية الوصول إلى هذا الفرع")
    src = await _product(db, org_id, from_product_id)
    await require_connected_transfer_scope(db, (src.branch_id, to_branch_id))
    await _branch(db, org_id, to_branch_id)
    match = await _find_target_by_name(db, org_id, to_branch_id, src.name)
    available = ZERO
    if match is None:
        return {"exists": False, "source_name": src.name}
    qty = await stock_service.available_locked(
        db, org_id, to_branch_id, match)
    units = (await db.execute(select(ProductUnit).where(
        ProductUnit.product_id == match.id,
        ProductUnit.is_active.is_(True),
    ).order_by(ProductUnit.is_base.desc(), ProductUnit.name.asc()))).scalars().all()
    return {
        "exists": True, "source_name": src.name,
        "product": {
            "id": str(match.id), "name": match.name,
            "image": match.image, "unit": match.unit,
            "sale_price": float(match.price or 0),
            "cost_price": float(match.cost_price or 0), "available": float(qty),
            "units": [{
                "id": str(u.id), "name": u.name,
                "factor": float(u.factor or 1), "is_base": bool(u.is_base),
            } for u in units],
        },
    }


async def create_inventory(
    db: AsyncSession, org_id: UUID, actor: User, *,
    from_branch_id: UUID, to_branch_id: UUID,
    items: List[Dict[str, Any]],
    idempotency_key: Optional[str] = None, notes: Optional[str] = None,
    commit: bool = True,
) -> Dict[str, Any]:
    actor = await _validate_transfer_access(
        db, org_id, actor, from_branch_id, to_branch_id)
    if not items:
        raise ValueError("أضف منتجًا واحدًا على الأقل")
    if idempotency_key:
        await _lock_idempotency(db, org_id, idempotency_key, "inventory")
        existing = (await db.execute(select(BranchTransfer).where(
            BranchTransfer.organization_id == org_id,
            BranchTransfer.idempotency_key == idempotency_key,
        ))).scalar_one_or_none()
        if existing is not None:
            return await detail(db, org_id, existing.id)
    number = _number("inventory")
    now = _now()
    transfer = BranchTransfer(
        organization_id=org_id, transfer_number=number, kind="inventory",
        from_branch_id=from_branch_id, to_branch_id=to_branch_id,
        actor_user_id=actor.id, actor_role=(actor.role or "employee"),
        status="completed", idempotency_key=idempotency_key, notes=notes,
        created_at=now, completed_at=now, total_cost=ZERO,
    )
    db.add(transfer)
    await db.flush()
    total_value = ZERO
    cost_currencies: set = set()
    for raw in items:
        src_product = await _source_product(
            db, org_id, from_branch_id, UUID(str(raw["from_product_id"])))
        from_qty = _q(raw.get("quantity"))
        if from_qty <= ZERO:
            raise ValueError("الكمية يجب أن تكون أكبر من صفر")
        from_factor, from_unit_name = await _unit(
            db, src_product.id,
            UUID(str(raw["from_unit_id"])) if raw.get("from_unit_id") else None)
        source_base_qty = _q(from_qty * from_factor)
        src_qty = await stock_service.available_locked(
            db, org_id, from_branch_id, src_product)
        _, src_avg = await stock_service.get_stock(
            db, from_branch_id, src_product.id)
        if src_qty + Q4 < source_base_qty:
            raise ValueError(
                f"الكمية المتاحة من «{src_product.name}» هي "
                f"{float(src_qty):g} فقط")
        unit_cost = _d(raw.get("unit_cost")) if raw.get("unit_cost") is not None \
            else src_avg
        if unit_cost < ZERO:
            raise ValueError("تكلفة الوحدة غير صالحة")

        target_raw = raw.get("to_product_id")
        if target_raw:
            dst_product = await _target_product(
                db, org_id, to_branch_id, UUID(str(target_raw)))
        else:
            # Exact same product name in the receiver branch is the SAME
            # product; only create an independent clone when it is absent.
            dst_product = await _find_target_by_name(
                db, org_id, to_branch_id, src_product.name)
            if dst_product is None:
                dst_product = await _clone_product(
                    db, org_id, to_branch_id, src_product, unit_cost)
        conversion, _matched = await _resolve_conversion(
            db, src_product, dst_product, from_unit_name, from_factor,
            raw.get("conversion_factor"))
        target_base_qty = _q(from_qty * conversion)
        if target_base_qty <= ZERO:
            raise ValueError("الكمية المحوّلة يجب أن تكون أكبر من صفر")
        to_factor, to_unit_name = await _unit(
            db, dst_product.id,
            UUID(str(raw["to_unit_id"])) if raw.get("to_unit_id") else None)
        to_qty = _q(target_base_qty / (to_factor or Decimal("1")))
        line_cost = _q(source_base_qty * unit_cost)
        target_unit_cost = _q(line_cost / target_base_qty, Q6)
        if src_product.cost_currency:
            cost_currencies.add(str(src_product.cost_currency).upper())

        item = BranchTransferItem(
            transfer_id=transfer.id, from_product_id=src_product.id, to_product_id=dst_product.id,
            from_unit_id=UUID(str(raw['from_unit_id'])) if raw.get('from_unit_id') else None,
            to_unit_id=UUID(str(raw['to_unit_id'])) if raw.get('to_unit_id') else None,
            unit_name=from_unit_name or src_product.unit, from_quantity=from_qty, to_quantity=to_qty,
            base_quantity=source_base_qty, target_base_quantity=target_base_qty,
            conversion_factor=conversion, factor=from_factor, unit_cost=unit_cost,
            total_cost=line_cost, currency=src_product.cost_currency)
        db.add(item)
        await db.flush()
        valuations = await inventory_lots.move_branch_transfer_lots(db, org_id, src_product, dst_product,
            from_branch_id, to_branch_id, source_base_qty, target_base_qty, item.id)
        if raw.get('unit_cost') is None and len(valuations) == 1:
            lot_currency, fifo_cost = next(iter(valuations.items()))
            if lot_currency == src_product.cost_currency:
                line_cost = _q(fifo_cost)
                unit_cost = _q(fifo_cost / source_base_qty, Q6)
                target_unit_cost = _q(fifo_cost / target_base_qty, Q6)
                item.unit_cost = unit_cost
                item.total_cost = line_cost
        await stock_service.apply_delta(
            db, org_id, from_branch_id, src_product, -source_base_qty)
        await stock_service.apply_delta(
            db, org_id, to_branch_id, dst_product, target_base_qty,
            target_unit_cost)
        total_value += line_cost
        db.add(InventoryMovement(
            organization_id=org_id, product_id=src_product.id,
            movement_type="transfer_out", quantity=-float(source_base_qty),
            unit_price=unit_cost, total=-float(line_cost),
            currency=src_product.cost_currency, branch_id=from_branch_id,
            reference_type="branch_transfer", reference_id=transfer.id,
            notes=f"تحويل إلى فرع آخر {number}", created_by=actor.id,
        ))
        db.add(InventoryMovement(
            organization_id=org_id, product_id=dst_product.id,
            movement_type="transfer_in", quantity=float(target_base_qty),
            unit_price=target_unit_cost, total=float(line_cost),
            currency=dst_product.cost_currency, branch_id=to_branch_id,
            reference_type="branch_transfer", reference_id=transfer.id,
            notes=f"تحويل من فرع آخر {number}", created_by=actor.id,
        ))
    transfer.total_cost = _q(total_value)
    transfer.currency = (next(iter(cost_currencies))
                         if len(cost_currencies) == 1 else
                         ("MIXED" if cost_currencies else None))
    await db.flush()
    await _emit_transfer_notifications(
        db, org_id, transfer, "inventory", None, None, None, None,
        from_name=(await _branch(db, org_id, from_branch_id)).name,
        to_name=(await _branch(db, org_id, to_branch_id)).name,
        actor_name=actor.full_name or "",
        items_summary=f"{len(items)} منتج/منتجات")
    if commit:
        await db.commit()
    return await detail(db, org_id, transfer.id)


async def _clone_product(db: AsyncSession, org_id: UUID, branch_id: UUID,
                         src: Product, unit_cost: Decimal) -> Product:
    clone = Product(
        organization_id=org_id, branch_id=branch_id, category_id=src.category_id,
        name=src.name, name_ar=src.name_ar, sku=None, barcode=None,
        description=src.description, unit=src.unit, price=src.price,
        cost_price=(src.cost_price if _d(src.cost_price) > ZERO
                    else unit_cost),
        cost_currency=src.cost_currency,
        stock=0, min_stock=src.min_stock, is_service=src.is_service,
        is_active=src.is_active, expiry_date=src.expiry_date, image=src.image,
        notes=src.notes,
    )
    db.add(clone)
    await db.flush()
    await stock_service.adjust_stock(
        db, org_id, branch_id, clone.id, ZERO, unit_cost)
    # Copy the unit definitions so the new independent product keeps the same
    # measurement behaviour. Barcodes are intentionally NOT copied (org-wide
    # uniqueness).
    units = (await db.execute(select(ProductUnit).where(
        ProductUnit.product_id == src.id,
        ProductUnit.is_active.is_(True),
    ))).scalars().all()
    for u in units:
        db.add(ProductUnit(
            organization_id=org_id, product_id=clone.id, name=u.name,
            factor=u.factor, group=u.group, sale_price=u.sale_price,
            purchase_price=u.purchase_price, is_base=u.is_base,
            is_active=u.is_active,
        ))
    await db.flush()
    return clone


async def _emit_transfer_notifications(
    db: AsyncSession, org_id: UUID, transfer: BranchTransfer, kind: str,
    amount, currency, received, to_currency, *, from_name: str, to_name: str,
    actor_name: str, items_summary: str = "",
) -> None:
    recipients = await access.branch_recipients(
        db, org_id, transfer.to_branch_id)
    # The actor already knows; only the receiving branch is notified.
    recipients = [u for u in recipients if u != transfer.actor_user_id]
    if kind == "financial":
        body = (f"استلمت الفرع: تحويل {format_money_ar(amount, currency)} "
                f"من {from_name} إلى {to_name} بواسطة {actor_name}")
    else:
        body = (f"تحويل مخزوني ({items_summary}) من {from_name} إلى {to_name} "
                f"بواسطة {actor_name}")
    title = "تحويل مالي بين الفروع" if kind == "financial" else \
        "تحويل مخزوني بين الفروع"
    route = f"/branches/transfers/{transfer.id}"
    for uid in recipients:
        db.add(AppNotification(
            organization_id=org_id, user_id=uid, type="info", title=title,
            message=body, action="open_screen",
            action_payload=_json({"transfer_id": str(transfer.id)}),
            route=route, event_id=f"branch_transfer:{transfer.id}",
            domain="main", is_read=False,
        ))


async def detail(db: AsyncSession, org_id: UUID,
                 transfer_id: UUID) -> Dict[str, Any]:
    transfer = (await db.execute(select(BranchTransfer).where(
        BranchTransfer.id == transfer_id,
        BranchTransfer.organization_id == org_id,
    ))).scalar_one_or_none()
    if transfer is None:
        raise ValueError("التحويل غير موجود")
    await require_connected_transfer_scope(db, (transfer.from_branch_id, transfer.to_branch_id))
    from_branch = (await db.execute(select(Branch).where(
        Branch.id == transfer.from_branch_id))).scalar_one_or_none()
    to_branch = (await db.execute(select(Branch).where(
        Branch.id == transfer.to_branch_id))).scalar_one_or_none()
    actor = (await db.execute(select(User).where(
        User.id == transfer.actor_user_id))).scalar_one_or_none() \
        if transfer.actor_user_id else None
    items = (await db.execute(select(BranchTransferItem).where(
        BranchTransferItem.transfer_id == transfer.id))).scalars().all()
    out_items = []
    for it in items:
        src = (await db.execute(select(Product).where(
            Product.id == it.from_product_id))).scalar_one_or_none()
        dst = (await db.execute(select(Product).where(
            Product.id == it.to_product_id))).scalar_one_or_none()
        out_items.append({
            "id": str(it.id),
            "from_product_id": str(it.from_product_id) if it.from_product_id else None,
            "from_product_name": src.name if src else None,
            "from_product_image": (src.image if src else None) or
            (dst.image if dst else None),
            "sale_price": float(src.price or 0) if src else 0,
            "to_product_id": str(it.to_product_id) if it.to_product_id else None,
            "to_product_name": dst.name if dst else None,
            "from_quantity": float(it.from_quantity or 0),
            "to_quantity": float(it.to_quantity or 0),
            "base_quantity": float(it.base_quantity or 0),
            "target_base_quantity": float(it.target_base_quantity or 0),
            "conversion_factor": float(it.conversion_factor or 1),
            "reversed_quantity": float(it.reversed_quantity or 0),
            "remaining_quantity": float(
                (_d(it.target_base_quantity) or _d(it.base_quantity)) -
                _d(it.reversed_quantity)),
            "unit_name": it.unit_name,
            "unit_cost": float(it.unit_cost or 0),
            "total_cost": float(it.total_cost or 0),
            "currency": it.currency,
        })
    return {
        "id": str(transfer.id), "number": transfer.transfer_number,
        "kind": transfer.kind, "status": transfer.status,
        "from_branch_id": str(transfer.from_branch_id),
        "from_branch_name": from_branch.name if from_branch else None,
        "to_branch_id": str(transfer.to_branch_id),
        "to_branch_name": to_branch.name if to_branch else None,
        "actor_user_id": str(transfer.actor_user_id) if transfer.actor_user_id else None,
        "actor_name": actor.full_name if actor else None,
        "actor_role": transfer.actor_role,
        "amount": float(transfer.amount) if transfer.amount is not None else None,
        "currency": transfer.currency,
        "to_currency": transfer.to_currency,
        "exchange_rate": float(transfer.exchange_rate)
        if transfer.exchange_rate is not None else None,
        "received_amount": float(transfer.received_amount)
        if transfer.received_amount is not None else None,
        "total_cost": float(transfer.total_cost)
        if transfer.total_cost is not None else None,
        "reversed_amount": float(transfer.reversed_amount or 0),
        "reversal_of_id": str(transfer.reversal_of_id)
        if transfer.reversal_of_id else None,
        "from_account_id": str(transfer.from_account_id)
        if transfer.from_account_id else None,
        "to_account_id": str(transfer.to_account_id)
        if transfer.to_account_id else None,
        "notes": transfer.notes,
        "created_at": transfer.created_at.isoformat()
        if transfer.created_at else None,
        "completed_at": transfer.completed_at.isoformat()
        if transfer.completed_at else None,
        "reversed_at": transfer.reversed_at.isoformat()
        if transfer.reversed_at else None,
        "items": out_items,
        "can_reverse": transfer.status in ("completed", "partially_reversed")
        and not transfer.reversal_of_id,
    }


async def list_transfers(db: AsyncSession, org_id: UUID, actor: User,
                         branch_id: Optional[UUID] = None,
                         kind: Optional[str] = None,
                         page: int = 1, per_page: int = 20,
                         ) -> tuple[List[Dict[str, Any]], int]:
    allowed = set(await access.effective_branch_ids(db, org_id, actor.id))
    stmt = select(BranchTransfer).where(
        BranchTransfer.organization_id == org_id,
    )
    if not access.is_owner(actor, org_id):
        stmt = stmt.where(BranchTransfer.from_branch_id.in_(allowed),
                          BranchTransfer.to_branch_id.in_(allowed))
    if branch_id is not None:
        if branch_id not in allowed:
            raise ValueError("لا تملك صلاحية الوصول إلى هذا الفرع")
        await require_connected_transfer_scope(db, (branch_id,))
        stmt = stmt.where((BranchTransfer.from_branch_id == branch_id) |
                          (BranchTransfer.to_branch_id == branch_id))
    elif allowed:
        await require_connected_transfer_scope(db, sorted(allowed))
        stmt = stmt.where((BranchTransfer.from_branch_id.in_(allowed)) |
                          (BranchTransfer.to_branch_id.in_(allowed)))
    else:
        return [], 0
    if kind in ("financial", "inventory"):
        stmt = stmt.where(BranchTransfer.kind == kind)
    total = (await db.execute(select(func.count()).select_from(
        stmt.subquery()))).scalar_one()
    rows = (await db.execute(stmt.order_by(
        BranchTransfer.created_at.desc()).offset((page - 1) * per_page)
        .limit(per_page))).scalars().all()
    return [await detail(db, org_id, r.id) for r in rows], int(total)


async def reverse_financial(
    db: AsyncSession, org_id: UUID, actor: User, transfer_id: UUID,
    allow_negative: bool = False, notes: Optional[str] = None,
    commit: bool = True,
) -> Dict[str, Any]:
    original = (await db.execute(select(BranchTransfer).where(
        BranchTransfer.id == transfer_id,
        BranchTransfer.organization_id == org_id,
        BranchTransfer.kind == "financial",
    ).with_for_update().execution_options(populate_existing=True))).scalar_one_or_none()
    if original is None:
        raise ValueError("التحويل المالي غير موجود")
    if original.reversal_of_id is not None:
        raise ValueError("لا يمكن عكس عملية عكس")
    if original.status == "reversed":
        raise ValueError("تم عكس هذا التحويل مسبقًا")
    actor = await _validate_transfer_access(
        db, org_id, actor, original.from_branch_id, original.to_branch_id)
    await _check_negative_override(db, org_id, actor, allow_negative)
    src = await _account(db, org_id, original.from_branch_id,
                         original.from_account_id)
    dst = await _account(db, org_id, original.to_branch_id,
                         original.to_account_id)
    amount = _d(original.amount)
    received = _d(original.received_amount)
    if not allow_negative and _d(dst.balance) + Q4 < received:
        raise ValueError("رصيد الفرع المستلم غير كافٍ لعكس التحويل")
    src.balance = _q(_d(src.balance) + amount)
    dst.balance = _q(_d(dst.balance) - received)
    now = _now()
    number = _number("financial")
    reversal = BranchTransfer(
        organization_id=org_id, transfer_number=number, kind="financial",
        from_branch_id=original.to_branch_id,
        to_branch_id=original.from_branch_id,
        actor_user_id=actor.id, actor_role=(actor.role or "employee"),
        status="completed", from_account_id=dst.id, to_account_id=src.id,
        amount=received, currency=(dst.currency or original.to_currency),
        to_currency=(src.currency or original.currency),
        exchange_rate=(amount / received) if received > ZERO else Decimal("1"),
        received_amount=amount, total_cost=amount,
        reversal_of_id=original.id, notes=notes or "عكس تحويل مالي",
        created_at=now, completed_at=now,
    )
    db.add(reversal)
    await db.flush()
    db.add(BankTransaction(
        organization_id=org_id, bank_account_id=dst.id, date=now,
        description=f"عكس تحويل بين الفروع {number}",
        tx_type="transfer_reversal_out", amount=received,
        currency=(dst.currency or "SAR"), running_balance=dst.balance,
        reference=number,
    ))
    db.add(BankTransaction(
        organization_id=org_id, bank_account_id=src.id, date=now,
        description=f"عكس تحويل بين الفروع {number}",
        tx_type="transfer_reversal_in", amount=amount,
        currency=(src.currency or "SAR"), running_balance=src.balance,
        reference=number,
    ))
    original.status = "reversed"
    original.reversed_amount = amount
    original.reversed_at = now
    from_name = (await _branch(db, org_id, reversal.from_branch_id)).name
    to_name = (await _branch(db, org_id, reversal.to_branch_id)).name
    await _emit_transfer_notifications(
        db, org_id, reversal, "financial", received, reversal.currency,
        amount, reversal.to_currency, from_name=from_name, to_name=to_name,
        actor_name=actor.full_name or "")
    if commit:
        await db.commit()
    return await detail(db, org_id, reversal.id)


async def reverse_inventory(
    db: AsyncSession, org_id: UUID, actor: User, transfer_id: UUID,
    items: Optional[List[Dict[str, Any]]] = None,
    notes: Optional[str] = None, commit: bool = True,
) -> Dict[str, Any]:
    original = (await db.execute(select(BranchTransfer).where(
        BranchTransfer.id == transfer_id,
        BranchTransfer.organization_id == org_id,
        BranchTransfer.kind == "inventory",
    ).with_for_update().execution_options(populate_existing=True))).scalar_one_or_none()
    if original is None:
        raise ValueError("التحويل المخزوني غير موجود")
    if original.reversal_of_id is not None:
        raise ValueError("لا يمكن عكس عملية عكس")
    if original.status == "reversed":
        raise ValueError("تم عكس هذا التحويل بالكامل مسبقًا")
    actor = await _validate_transfer_access(
        db, org_id, actor, original.from_branch_id, original.to_branch_id)
    rows = (await db.execute(select(BranchTransferItem).where(
        BranchTransferItem.transfer_id == original.id,
    ).with_for_update())).scalars().all()
    requested = {}
    for raw in items or []:
        identity = UUID(str(raw["transfer_item_id"]))
        quantity = _q(raw.get("quantity"))
        if identity in requested or quantity <= ZERO:
            raise ValueError("كمية العكس أو بند التحويل غير صالح")
        requested[identity] = quantity
    if set(requested) - {it.id for it in rows}:
        raise ValueError("بند العكس لا يتبع التحويل")
    # Validate the whole request before creating a reversal or changing any row.
    # Never silently clamp a full/requested reversal to the unconsumed stock.
    required = {}
    for it in rows:
        remaining = (_d(it.target_base_quantity) or _d(it.base_quantity)) - _d(it.reversed_quantity)
        if items and it.id not in requested:
            continue
        take = requested.get(it.id, remaining)
        if take > remaining:
            raise ValueError("كمية العكس تتجاوز الكمية المتبقية")
        if take <= ZERO:
            continue
        dst = await _product(db, org_id, it.to_product_id)
        required[dst.id] = required.get(dst.id, ZERO) + take
        if await stock_service.available_locked(db, org_id, original.to_branch_id, dst) + Q4 < required[dst.id]:
            raise ValueError("الكمية في الفرع المستلم غير كافية لعكس التحويل")
        if not await inventory_lots.reverse_branch_transfer_lots(db, org_id, it.id, take):
            raise ValueError('التحويل القديم يحتاج مطابقة الدفعات قبل العكس')
    now = _now()
    number = _number("inventory")
    reversal = BranchTransfer(
        organization_id=org_id, transfer_number=number, kind="inventory",
        from_branch_id=original.to_branch_id,
        to_branch_id=original.from_branch_id,
        actor_user_id=actor.id, actor_role=(actor.role or "employee"),
        status="completed", reversal_of_id=original.id,
        notes=notes or "عكس تحويل مخزوني", created_at=now,
        completed_at=now, total_cost=ZERO,
    )
    db.add(reversal)
    await db.flush()
    reversed_any = False
    total_value = ZERO
    for it in rows:
        target_base = _d(it.target_base_quantity)
        if target_base <= ZERO:
            target_base = _d(it.base_quantity)  # legacy rows
        remaining = target_base - _d(it.reversed_quantity)
        if remaining <= ZERO:
            continue
        if items and it.id not in requested:
            continue
        src = (await db.execute(select(Product).where(
            Product.id == it.from_product_id))).scalar_one_or_none()
        dst = (await db.execute(select(Product).where(
            Product.id == it.to_product_id))).scalar_one_or_none()
        if src is None or dst is None:
            continue
        dst_qty = await stock_service.available_locked(
            db, org_id, original.to_branch_id, dst)
        take = requested.get(it.id, remaining) if items else remaining
        if take > remaining or take > dst_qty + Q4:
            raise ValueError("الكمية في الفرع المستلم غير كافية لعكس التحويل")
        take = _q(take)
        if take <= ZERO:
            continue
        conversion = _d(it.conversion_factor) or Decimal("1")
        source_take = _q(take * (_d(it.factor) or Decimal("1")) / conversion)
        target_unit_cost = (_d(it.total_cost) / target_base
                            if target_base > ZERO else _d(it.unit_cost))
        line_cost = _q(source_take * _d(it.unit_cost))
        total_value += line_cost
        if not await inventory_lots.reverse_branch_transfer_lots(db, org_id, it.id, take, apply=True):
            raise ValueError('التحويل القديم يحتاج مطابقة الدفعات قبل العكس')
        await stock_service.apply_delta(
            db, org_id, original.to_branch_id, dst, -take)
        await stock_service.apply_delta(
            db, org_id, original.from_branch_id, src, source_take,
            _d(it.unit_cost))
        it.reversed_quantity = _q(_d(it.reversed_quantity) + take)
        db.add(InventoryMovement(
            organization_id=org_id, product_id=dst.id,
            movement_type="transfer_reversal_out", quantity=-float(take),
            unit_price=target_unit_cost, total=-float(line_cost),
            currency=dst.cost_currency, branch_id=original.to_branch_id,
            reference_type="branch_transfer", reference_id=reversal.id,
            notes=f"عكس تحويل مخزوني {number}", created_by=actor.id,
        ))
        db.add(InventoryMovement(
            organization_id=org_id, product_id=src.id,
            movement_type="transfer_reversal_in", quantity=float(source_take),
            unit_price=_d(it.unit_cost), total=float(line_cost),
            currency=src.cost_currency, branch_id=original.from_branch_id,
            reference_type="branch_transfer", reference_id=reversal.id,
            notes=f"عكس تحويل مخزوني {number}", created_by=actor.id,
        ))
        db.add(BranchTransferItem(
            transfer_id=reversal.id, from_product_id=dst.id,
            to_product_id=src.id, unit_name=it.unit_name,
            from_quantity=_q(take),
            to_quantity=_q(source_take / (_d(it.factor) or Decimal("1"))),
            base_quantity=source_take, target_base_quantity=take,
            conversion_factor=conversion, factor=it.factor,
            unit_cost=_d(it.unit_cost), total_cost=line_cost,
            currency=it.currency,
        ))
        reversed_any = True
    if not reversed_any:
        raise ValueError("لا توجد كمية متاحة لعكسها في الفرع المستلم")
    reversal.total_cost = _q(total_value)
    all_done = all(
        _d(it.reversed_quantity) + Q4 >= (
            _d(it.target_base_quantity) or _d(it.base_quantity))
        for it in rows)
    original.status = "reversed" if all_done else "partially_reversed"
    original.reversed_amount = _q(_d(original.reversed_amount) + total_value)
    if all_done:
        original.reversed_at = now
    from_name = (await _branch(db, org_id, reversal.from_branch_id)).name
    to_name = (await _branch(db, org_id, reversal.to_branch_id)).name
    await _emit_transfer_notifications(
        db, org_id, reversal, "inventory", None, None, None, None,
        from_name=from_name, to_name=to_name,
        actor_name=actor.full_name or "", items_summary="عكس تحويل مخزوني")
    if commit:
        await db.commit()
    return await detail(db, org_id, reversal.id)


async def remove_outbox_for_reversal(db: AsyncSession, transfer_id) -> None:
    """Marker notifications read when a transfer is reversed (best effort)."""
    try:
        rows = (await db.execute(select(AppNotification).where(
            AppNotification.event_id == f"branch_transfer:{transfer_id}"))).scalars().all()
        for r in rows:
            r.is_read = True
    except Exception:
        pass


async def options(db: AsyncSession, org_id: UUID, actor: User,
                  branch_id: UUID, search: Optional[str] = None,
                  include_zero: bool = False) -> Dict[str, Any]:
    """Accounts + stock/products of ONE branch for the transfer pickers."""
    allowed = set(await access.effective_branch_ids(db, org_id, actor.id))
    if branch_id not in allowed:
        raise ValueError("لا تملك صلاحية الوصول إلى هذا الفرع")
    await require_connected_transfer_scope(db, (branch_id,))
    branch = await _branch(db, org_id, branch_id)
    accounts = (await db.execute(select(BankAccount).where(
        BankAccount.organization_id == org_id,
        BankAccount.branch_id == branch_id,
        BankAccount.is_active.is_(True),
        BankAccount.is_deleted.is_(False),
    ).order_by(BankAccount.created_at.asc()))).scalars().all()
    stmt = select(Product, BranchStock).outerjoin(
        BranchStock, (BranchStock.product_id == Product.id) &
        (BranchStock.branch_id == branch_id)
    ).where(
        Product.organization_id == org_id,
        Product.is_deleted.is_(False),
        Product.is_active.is_(True),
        Product.is_service.is_(False),
        # Scope BEFORE loading, including zero-stock products. A 500-row
        # organization-wide query used to omit/mix sender warehouse rows.
        or_(
            Product.branch_id == branch_id,
            BranchStock.id.is_not(None),
            Product.branch_id.is_(None) if branch.is_default else False,
        ),
    )
    if search and search.strip():
        term = f"%{search.strip()}%"
        stmt = stmt.where((Product.name.ilike(term)) |
                          (Product.name_ar.ilike(term)) |
                          (Product.barcode.ilike(term)) |
                          (Product.sku.ilike(term)))
    rows = (await db.execute(stmt.order_by(Product.name.asc(), Product.id.asc()))).all()
    category_ids = {p.category_id for p, _ in rows if p.category_id}
    categories = {}
    if category_ids:
        cats = (await db.execute(select(ProductCategory).where(
            ProductCategory.id.in_(category_ids)))).scalars().all()
        categories = {c.id: c for c in cats}
    products = []
    for product, stock in rows:
        qty = _d(stock.quantity) if stock is not None else (
            _d(product.stock) if branch.is_default else ZERO)
        if qty <= ZERO and not include_zero:
            continue
        cat = categories.get(product.category_id)
        units = (await db.execute(select(ProductUnit).where(
            ProductUnit.product_id == product.id,
            ProductUnit.is_active.is_(True),
        ).order_by(ProductUnit.is_base.desc(), ProductUnit.name.asc()))).scalars().all()
        products.append({
            "id": str(product.id), "name": product.name,
            "name_ar": product.name_ar, "barcode": product.barcode,
            "sku": product.sku, "image": product.image, "unit": product.unit,
            "cost_price": float(product.cost_price or 0),
            "sale_price": float(product.price or 0),
            "cost_currency": product.cost_currency,
            "category_id": str(product.category_id) if product.category_id else None,
            "category_name": cat.name if cat is not None else None,
            "category_name_ar": cat.name_ar if cat is not None else None,
            "available": float(qty),
            "units": [{
                "id": str(u.id), "name": u.name, "factor": float(u.factor or 1),
                "is_base": bool(u.is_base),
            } for u in units],
        })
    all_categories = (await db.execute(select(ProductCategory).where(
        ProductCategory.organization_id == org_id,
        ProductCategory.is_deleted.is_(False),
        ProductCategory.is_active.is_(True),
    ).order_by(ProductCategory.name.asc()))).scalars().all()
    return {
        "branch": {"id": str(branch.id), "name": branch.name},
        "categories": [{
            "id": str(c.id), "name": c.name, "name_ar": c.name_ar,
            "image": c.image,
        } for c in all_categories],
        "accounts": [{
            "id": str(a.id), "bank_name": a.bank_name,
            "account_name": a.account_name, "account_number": a.account_number,
            "currency": (a.currency or "SAR").strip().upper(),
            "balance": float(a.balance or 0),
        } for a in accounts],
        "products": products,
    }
