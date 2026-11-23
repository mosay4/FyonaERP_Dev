"""Reconciliation engine (قسم المطابقة) — Business scope only.

Design contract (mirrors the product spec, nothing invented):
- CHECK is a pure inspection: it snapshots system balances/quantities vs the
  user's real (physical) values and archives the comparison. It NEVER mutates
  anything.
- APPROVE ("مساواة الرصيد") re-locks and re-verifies every balance/quantity
  against the values the user confirmed. If anything moved in between, the
  whole approval is refused with 409 + fresh state (the client re-confirms).
- Every currency/account/product is settled INDEPENDENTLY — a matched line is
  never touched, differences are never merged or converted across currencies.
- Bank settlement = ONE documented BankTransaction per account
  (tx_type reconciliation_increase / reconciliation_decrease) moving the
  account balance to the confirmed actual. NOT a sale/purchase, NOT income/
  expense (kept out of the income/expense kind groups), creates no debt.
- Inventory settlement = product.stock set to the counted quantity + ONE
  InventoryMovement (adjust_set, reference_type="reconciliation") + the
  project's real FIFO/FEFO lot engine (shortage consumes lots; surplus creates
  a lot at the product's last cost, source="adjustment") — exactly like the
  existing manual adjustment, so COGS/history stay intact.
- The archive row is permanent: full lines, settlements, refs, executors,
  timestamps. Approved records are immutable (repeat approve is idempotent).
"""

import json
import secrets
import uuid as _uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Dict, List, Optional
from uuid import UUID

from sqlalchemy import select, func, or_
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.business_entities import (
    InventoryMovement,
    Product,
    ProductCategory,
)
from app.domain.services import branch_stock_service as bstock
from app.domain.entities.finance_entities import BankAccount, BankTransaction
from app.domain.entities.sale_entities import ProductUnit
from app.domain.entities.reconciliation_entities import Reconciliation
from app.domain.entities.sale_entities import InventoryLot

EPS = 1e-9
CASH_NAMES = ("كاش", "Cash", "CASH")


def _s_cash(bank_name: str) -> bool:
    return (bank_name or "").strip().upper() in tuple(n.upper() for n in CASH_NAMES)


class ReconciliationConflict(Exception):
    """System state changed between CHECK and APPROVE — nothing was applied."""

    def __init__(self, detail: str, fresh: Dict[str, Any]):
        super().__init__(detail)
        self.detail = detail
        self.fresh = fresh


class ReconciliationError(Exception):
    pass


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _f(v) -> float:
    if v is None:
        return 0.0
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(str(v))
    except Exception:
        return 0.0


def _d(v) -> Decimal:
    try:
        return Decimal(str(_f(v)))
    except Exception:
        return Decimal("0")


def _ref_code() -> str:
    return f"RCN-{_now().strftime('%Y%m%d')}-{secrets.token_hex(3).upper()}"


def _status_of(diff: float) -> str:
    if abs(diff) <= EPS:
        return "match"
    return "short" if diff < 0 else "surplus"


def _num(v) -> float:
    # Trim float noise (0.30000000000000004 -> 0.3) for clean diffs.
    r = round(_f(v), 6)
    return int(r) if r == int(r) else r


async def _get_recon(
    db: AsyncSession, org_id: UUID, recon_id: UUID, lock: bool = False
) -> Reconciliation:
    stmt = select(Reconciliation).where(
        Reconciliation.id == recon_id,
        Reconciliation.organization_id == org_id,
    )
    if lock:
        # Serialize concurrent approvals of the SAME record: the second one
        # blocks until the first commits, then sees status="approved" and
        # returns idempotently instead of applying the settlement twice.
        stmt = stmt.with_for_update()
    row = (await db.execute(stmt)).scalar_one_or_none()
    if not row:
        raise ReconciliationError("سجل المطابقة غير موجود")
    return row


def _record_dict(r: Reconciliation) -> Dict[str, Any]:
    return {
        "id": str(r.id),
        "ref_code": r.ref_code,
        "rtype": r.rtype,
        "scope": r.scope,
        "scope_json": json.loads(r.scope_json or "{}"),
        "status": r.status,
        "period_start": r.period_start.isoformat() if r.period_start else None,
        "period_end": r.period_end.isoformat() if r.period_end else None,
        "measured_at": r.measured_at.isoformat() if r.measured_at else None,
        "notes": r.notes,
        "lines": json.loads(r.lines_json or "[]"),
        "settlements": json.loads(r.settlements_json or "[]"),
        "result": json.loads(r.result_json or "{}"),
        "created_by": str(r.created_by) if r.created_by else None,
        "approved_by": str(r.approved_by) if r.approved_by else None,
        "created_at": r.created_at.isoformat() if r.created_at else None,
        "approved_at": r.approved_at.isoformat() if r.approved_at else None,
    }


# ══════════════════════════════════════════════════════════════
#  BANK / CASH
# ══════════════════════════════════════════════════════════════


async def list_bank_accounts(db: AsyncSession, org_id: UUID,
                             branch_ids: Optional[list] = None) -> List[Dict]:
    stmt = select(BankAccount).where(
        BankAccount.organization_id == org_id,
        ~BankAccount.is_deleted,
        BankAccount.is_active.is_(True),
    )
    if branch_ids is not None:
        stmt = stmt.where(BankAccount.branch_id.in_(branch_ids))
    rows = (await db.execute(
        stmt.order_by(BankAccount.bank_name.asc(), BankAccount.created_at.asc())
    )).scalars().all()
    return [
        {
            "id": str(a.id),
            "branch_id": str(a.branch_id) if a.branch_id else None,
            "bank_name": a.bank_name,
            "account_name": a.account_name,
            "account_number": a.account_number,
            "currency": (a.currency or "SAR").strip().upper(),
            "balance": _num(a.balance),
            "account_type": (getattr(a, "account_type", None) or "checking"),
            "is_cash": (a.bank_name or "").strip().upper()
            in tuple(n.upper() for n in CASH_NAMES),
        }
        for a in rows
    ]


async def _lock_account(
    db: AsyncSession, org_id: UUID, account_id: UUID
) -> BankAccount:
    acc = (
        await db.execute(
            select(BankAccount)
            .where(
                BankAccount.id == account_id,
                BankAccount.organization_id == org_id,
                ~BankAccount.is_deleted,
            )
            .with_for_update()
        )
    ).scalar_one_or_none()
    if not acc:
        raise ReconciliationError("الحساب البنكي غير موجود")
    return acc


async def bank_check(
    db: AsyncSession,
    org_id: UUID,
    user_id: UUID,
    entries: List[Dict[str, Any]],
    measured_at: Optional[datetime] = None,
    period_start: Optional[datetime] = None,
    period_end: Optional[datetime] = None,
    notes: Optional[str] = None,
    idempotency_key: Optional[str] = None,
    branch_id: Optional[UUID] = None,
) -> Dict[str, Any]:
    """Pure inspection: archive system vs actual per account (currency).
    Locks each account row so the snapshot is consistent, changes nothing."""
    if not entries:
        raise ReconciliationError("حدد الحسابات الفعلية للمطابقة")
    if idempotency_key:
        existing = (
            await db.execute(
                select(Reconciliation).where(
                    Reconciliation.organization_id == org_id,
                    Reconciliation.idempotency_key == idempotency_key,
                )
            )
        ).scalar_one_or_none()
        if existing:
            return _record_dict(existing)

    lines = []
    seen = set()
    all_cash = True
    for e in entries:
        acc_id = UUID(str(e.get("account_id")))
        if acc_id in seen:
            raise ReconciliationError("حساب مكرر في المطابقة")
        seen.add(acc_id)
        acc = await _lock_account(db, org_id, acc_id)
        if _s_cash(acc.bank_name) is False:
            all_cash = False
        system = _f(acc.balance)
        actual = _f(e.get("actual"))
        diff = actual - system
        lines.append({
            "account_id": str(acc.id),
            "name": acc.account_name or acc.bank_name,
            "bank_name": acc.bank_name,
            "currency": (acc.currency or "SAR").strip().upper(),
            "account_type": (getattr(acc, "account_type", None) or "checking"),
            "system": _num(system),
            "actual": _num(actual),
            "diff": _num(diff),
            "status": _status_of(diff),
        })

    rec = Reconciliation(
        organization_id=org_id,
        branch_id=branch_id,
        ref_code=_ref_code(),
        rtype="bank",
        scope="accounts",
        scope_json=json.dumps(
            {
                "account_ids": [l["account_id"] for l in lines],
                # The REAL equalization kind, recorded at check time — the
                # success scene never guesses it from account names.
                "kind": "cash" if all_cash else "bank",
            },
            ensure_ascii=False,
        ),
        status="checked",
        period_start=period_start,
        period_end=period_end,
        measured_at=measured_at or _now(),
        notes=notes,
        lines_json=json.dumps(lines, ensure_ascii=False),
        created_by=user_id,
        idempotency_key=idempotency_key,
    )
    db.add(rec)
    await db.flush()
    return _record_dict(rec)


async def bank_approve(
    db: AsyncSession,
    org_id: UUID,
    user_id: UUID,
    recon_id: UUID,
    entries: List[Dict[str, Any]],
    notes: Optional[str] = None,
) -> Dict[str, Any]:
    """مساواة الرصيد: for every account the user asks to settle, re-verify the
    system balance (optimistic lock) then write ONE documented adjustment
    transaction. Matched accounts are NEVER touched."""
    rec = await _get_recon(db, org_id, recon_id, lock=True)
    if rec.rtype != "bank":
        raise ReconciliationError("نوع السجل ليس مطابقة حسابات")
    if rec.status == "approved":
        # Idempotent re-approve (double tap / retry after disconnect).
        return _record_dict(rec)
    if rec.status != "checked":
        raise ReconciliationError("يجب فحص المطابقة قبل المساواة")
    if not entries:
        raise ReconciliationError("لا توجد عملات تحتاج تسوية")

    # Conflict detection pass — lock and compare every account first.
    settled_lines = {}
    for e in entries:
        acc = await _lock_account(db, org_id, UUID(str(e.get("account_id"))))
        expected = e.get("expected_system")
        if expected is None or abs(_f(acc.balance) - _f(expected)) > EPS:
            raise ReconciliationConflict(
                "تغير رصيد الحساب بين الفحص والاعتماد — أعد التأكيد",
                {
                    "account_id": str(acc.id),
                    "name": acc.account_name or acc.bank_name,
                    "currency": (acc.currency or "SAR").strip().upper(),
                    "system": _num(acc.balance),
                },
            )
        settled_lines[str(acc.id)] = (acc, _f(e.get("actual")))

    settlements = []
    for acc_id_s, (acc, actual) in settled_lines.items():
        before = _f(acc.balance)
        diff = actual - before
        tx_id = None
        if abs(diff) > EPS:
            acc.balance = _d(actual)
            tx = BankTransaction(
                organization_id=org_id,
                bank_account_id=acc.id,
                date=_now(),
                description=f"تسوية مطابقة {rec.ref_code}",
                tx_type=("reconciliation_increase" if diff > 0
                         else "reconciliation_decrease"),
                amount=Decimal(str(abs(round(diff, 2)))),
                currency=(acc.currency or "SAR").strip().upper(),
                running_balance=acc.balance,
                reference=rec.ref_code,
            )
            db.add(tx)
            await db.flush()
            tx_id = str(tx.id)
        settlements.append({
            "account_id": acc_id_s,
            "name": acc.account_name or acc.bank_name,
            "currency": (acc.currency or "SAR").strip().upper(),
            "before": _num(before),
            "after": _num(actual),
            "diff": _num(diff),
            "bank_tx_id": tx_id,
            "applied": abs(diff) > EPS,
        })

    lines = json.loads(rec.lines_json or "[]")
    result = {
        "settled": len([s for s in settlements if s["applied"]]),
        "untouched": len([s for s in settlements if not s["applied"]]),
        "ref_code": rec.ref_code,
    }
    rec.settlements_json = json.dumps(settlements, ensure_ascii=False)
    rec.result_json = json.dumps(result, ensure_ascii=False)
    rec.status = "approved"
    rec.approved_by = user_id
    rec.approved_at = _now()
    if notes:
        rec.notes = notes
    await db.flush()
    out = _record_dict(rec)
    return out


# ══════════════════════════════════════════════════════════════
#  INVENTORY
# ══════════════════════════════════════════════════════════════


async def _products_for_scope(
    db: AsyncSession,
    org_id: UUID,
    scope: str,
    product_id: Optional[UUID],
    category_id: Optional[UUID],
    branch_id: Optional[UUID] = None,
) -> List[Product]:
    conds = [
        Product.organization_id == org_id,
        ~Product.is_deleted,
        Product.is_active.is_(True),
        ~Product.is_service,  # services carry no stock
    ]
    if branch_id is not None:
        conds.append(Product.branch_id == branch_id)
    if scope == "product":
        if not product_id:
            raise ReconciliationError("حدد المنتج المطلوب جردُه")
        conds.append(Product.id == product_id)
    elif scope == "category":
        if not category_id:
            raise ReconciliationError("حدد التصنيف المطلوب جردُه")
        conds.append(Product.category_id == category_id)
    rows = (
        await db.execute(
            select(Product).where(*conds).order_by(Product.name.asc()).limit(2000)
        )
    ).scalars().all()
    if scope == "product" and not rows:
        raise ReconciliationError("لا توجد منتجات في هذا النطاق")
    return list(rows)


async def inventory_start(
    db: AsyncSession,
    org_id: UUID,
    user_id: UUID,
    scope: str,
    product_id: Optional[UUID] = None,
    category_id: Optional[UUID] = None,
    branch_id: Optional[UUID] = None,
    notes: Optional[str] = None,
    idempotency_key: Optional[str] = None,
) -> Dict[str, Any]:
    """Open a counting session: snapshot system quantities NOW (the reference
    the later movement check is measured against)."""
    if scope not in ("product", "category", "full"):
        raise ReconciliationError("نطاق الجرد غير معروف")
    if idempotency_key:
        existing = (
            await db.execute(
                select(Reconciliation).where(
                    Reconciliation.organization_id == org_id,
                    Reconciliation.idempotency_key == idempotency_key,
                )
            )
        ).scalar_one_or_none()
        if existing:
            return _record_dict(existing)

    products = await _products_for_scope(db, org_id, scope, product_id, category_id, branch_id)
    pids = [p.id for p in products]
    units_rows = []
    if pids:
        units_rows = (
            await db.execute(
                select(ProductUnit).where(
                    ProductUnit.organization_id == org_id,
                    ProductUnit.product_id.in_(pids),
                    ProductUnit.is_active.is_(True),
                )
            )
        ).scalars().all()
    units_by_product: Dict[UUID, List[Dict]] = {}
    for u in units_rows:
        units_by_product.setdefault(u.product_id, []).append({
            "unit_id": str(u.id),
            "name": u.name,
            "factor": _f(u.factor) or 1.0,
        })

    cat_name = None
    if scope == "category" and category_id:
        cat = (
            await db.execute(
                select(ProductCategory).where(
                    ProductCategory.id == category_id,
                    ProductCategory.organization_id == org_id,
                )
            )
        ).scalar_one_or_none()
        cat_name = cat.name if cat else None

    measured = _now()
    lines = [
        {
            "product_id": str(p.id),
            "name": p.name,
            "image": p.image,
            "unit": p.unit or "قطعة",
            "system_qty": _num(p.stock),
            "counted_qty": None,   # never treated as zero until counted
            "unit_id": None,       # chosen extra unit (qty entered in it)
            "base_qty": None,      # qty converted to the base unit
            "barcode": p.barcode,
        }
        for p in products
    ]
    rec = Reconciliation(
        organization_id=org_id,
        branch_id=branch_id,
        ref_code=_ref_code(),
        rtype="inventory",
        scope=scope,
        scope_json=json.dumps(
            {
                "product_id": str(product_id) if product_id else None,
                "category_id": str(category_id) if category_id else None,
                "category_name": cat_name,
            },
            ensure_ascii=False,
        ),
        status="draft",
        measured_at=measured,
        notes=notes,
        lines_json=json.dumps(lines, ensure_ascii=False),
        created_by=user_id,
        idempotency_key=idempotency_key,
    )
    db.add(rec)
    await db.flush()
    out = _record_dict(rec)
    out["units"] = {str(k): v for k, v in units_by_product.items()}
    return out


async def _load_units_map(
    db: AsyncSession, org_id: UUID
) -> Dict[UUID, Dict[UUID, float]]:
    rows = (
        await db.execute(
            select(ProductUnit).where(ProductUnit.organization_id == org_id)
        )
    ).scalars().all()
    m: Dict[UUID, Dict[UUID, float]] = {}
    for u in rows:
        m.setdefault(u.product_id, {})[u.id] = _f(u.factor) or 1.0
    return m


async def inventory_save(
    db: AsyncSession,
    org_id: UUID,
    user_id: UUID,
    recon_id: UUID,
    counts: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """Partial save: upsert counted quantities. Products not counted keep
    counted_qty=None (never zero). Draft can be resumed later."""
    rec = await _get_recon(db, org_id, recon_id)
    if rec.rtype != "inventory":
        raise ReconciliationError("نوع السجل ليس جرد مخزون")
    if rec.status == "approved":
        raise ReconciliationError("الجرد معتمد بالفعل ولا يمكن تعديله")
    if not counts:
        raise ReconciliationError("لا توجد كميات مدخلة")

    lines = json.loads(rec.lines_json or "[]")
    idx = {l["product_id"]: l for l in lines}
    units_map = await _load_units_map(db, org_id)
    for c in counts:
        pid = str(c.get("product_id"))
        line = idx.get(pid)
        if not line:
            raise ReconciliationError("منتج خارج نطاق هذا الجرد")
        parts = c.get("parts")
        # drop all-empty parts lists (Pydantic dumps defaults)
        if parts and any(_f(p.get("qty")) > 0 for p in parts):
            parts = [p for p in parts if _f(p.get("qty")) > 0]
            # Multi-unit entry: one box per unit (e.g. 3 cartons + 2 pieces).
            # The REAL total is the sum converted to base units; the entered
            # breakdown is kept on the line for display.
            base = 0.0
            stored_parts = []
            for p in parts:
                q = _f(p.get("qty"))
                if q < 0:
                    raise ReconciliationError("الكمية لا يمكن أن تكون سالبة")
                uid_raw = p.get("unit_id")
                factor = 1.0
                if uid_raw:
                    factor = units_map.get(
                        _uuid.UUID(pid), {}
                    ).get(_uuid.UUID(str(uid_raw)), 1.0)
                base += q * factor
                stored_parts.append({
                    "unit_id": str(uid_raw) if uid_raw else None,
                    "unit_name": p.get("unit_name"),
                    "qty": _num(q),
                    "factor": factor,
                })
            line["parts"] = stored_parts
            line["counted_qty"] = _num(base)
            line["unit_id"] = None
            line["base_qty"] = _num(base)
            continue
        qty = _f(c.get("qty"))
        if qty < 0:
            raise ReconciliationError("الكمية لا يمكن أن تكون سالبة")
        unit_id_raw = c.get("unit_id")
        factor = 1.0
        if unit_id_raw:
            unit_id = _uuid.UUID(str(unit_id_raw))
            factor = units_map.get(
                _uuid.UUID(pid), {}
            ).get(unit_id, 1.0)
        base = qty * factor
        line["parts"] = [{
            "unit_id": str(unit_id_raw) if unit_id_raw else None,
            "unit_name": None,
            "qty": _num(qty),
            "factor": factor,
        }]
        line["counted_qty"] = _num(qty)
        line["unit_id"] = str(unit_id_raw) if unit_id_raw else None
        line["base_qty"] = _num(base)
    rec.lines_json = json.dumps(lines, ensure_ascii=False)
    rec.status = "draft"
    await db.flush()
    return _record_dict(rec)


async def inventory_check(
    db: AsyncSession, org_id: UUID, user_id: UUID, recon_id: UUID
) -> Dict[str, Any]:
    """Compute the real comparison: counted (base units) vs the CURRENT system
    quantity. Products that moved AFTER the count started are flagged stale —
    the client must re-count or re-confirm them; nothing is applied here."""
    rec = await _get_recon(db, org_id, recon_id)
    if rec.rtype != "inventory":
        raise ReconciliationError("نوع السجل ليس جرد مخزون")
    if rec.status == "approved":
        raise ReconciliationError("الجرد معتمد بالفعل")
    lines = json.loads(rec.lines_json or "[]")
    counted = [l for l in lines if l.get("base_qty") is not None]
    if not counted:
        raise ReconciliationError("لم تُجرَد أي كمية بعد")

    pids = [_uuid.UUID(l["product_id"]) for l in counted]
    products = {
        str(p.id): p
        for p in (
            await db.execute(select(Product).where(Product.id.in_(pids)))
        ).scalars().all()
    }
    mov_counts: Dict[str, int] = {}
    if rec.measured_at:
        rows = await db.execute(
            select(
                InventoryMovement.product_id,
                func.count(InventoryMovement.id),
            )
            .where(
                InventoryMovement.organization_id == org_id,
                InventoryMovement.product_id.in_(pids),
                InventoryMovement.created_at > rec.measured_at,
            )
            .group_by(InventoryMovement.product_id)
        )
        mov_counts = {str(k): int(v) for k, v in rows.all()}

    # All ACTIVE units per counted product — used to render ONE consistent
    # per-unit table from the SINGLE base total (never independent entries).
    units_by_pid: Dict[str, list] = {}
    if pids:
        for u in (
            await db.execute(
                select(ProductUnit).where(
                    ProductUnit.organization_id == org_id,
                    ProductUnit.product_id.in_(pids),
                    ProductUnit.is_active.is_(True),
                )
            )
        ).scalars().all():
            units_by_pid.setdefault(str(u.product_id), []).append(u)

    short = surplus = matched = stale_n = 0
    for l in lines:
        if l.get("base_qty") is None:
            continue
        p = products.get(l["product_id"])
        if not p:
            continue
        current = _f(p.stock)
        l["system_qty"] = _num(current)
        diff = _f(l["base_qty"]) - current
        l["diff"] = _num(diff)
        # Consistent equivalents: every unit derived from the SAME base/system.
        grows = []
        for u in units_by_pid.get(l["product_id"], []):
            f = float(u.factor or 1)
            if f <= 0:
                continue
            grows.append(
                {
                    "unit_name": u.name,
                    "factor": f,
                    "system": _num(current / f),
                    "actual": _num(_f(l["base_qty"]) / f),
                    "diff": _num((_f(l["base_qty"]) - current) / f),
                }
            )
        l["unit_rows"] = grows
        l["status"] = _status_of(diff)
        l["movements_since"] = mov_counts.get(l["product_id"], 0)
        l["stale"] = l["movements_since"] > 0
        if l["stale"]:
            stale_n += 1
        if l["status"] == "match":
            matched += 1
        elif l["status"] == "short":
            short += 1
        else:
            surplus += 1

    rec.lines_json = json.dumps(lines, ensure_ascii=False)
    rec.status = "checked"
    rec.result_json = json.dumps(
        {
            "counted": len(counted),
            "matched": matched,
            "short": short,
            "surplus": surplus,
            "stale": stale_n,
            "uncounted": len(lines) - len(counted),
        },
        ensure_ascii=False,
    )
    await db.flush()
    return _record_dict(rec)


async def inventory_approve(
    db: AsyncSession,
    org_id: UUID,
    user_id: UUID,
    recon_id: UUID,
    settlements: List[Dict[str, Any]],
    branch_id: Optional[UUID] = None,
    notes: Optional[str] = None,
) -> Dict[str, Any]:
    """Apply the confirmed quantities: re-verify each product against the
    expected system quantity (optimistic lock), then adjust stock through the
    project's real FIFO/FEFO engine. Matched/uncounted products are untouched;
    history, invoices, and COGS are never rewritten."""
    rec = await _get_recon(db, org_id, recon_id, lock=True)
    if rec.rtype != "inventory":
        raise ReconciliationError("نوع السجل ليس جرد مخزون")
    if rec.status == "approved":
        return _record_dict(rec)  # idempotent re-approve
    if rec.status != "checked":
        raise ReconciliationError("يجب فحص الجرد قبل الاعتماد")
    if not settlements:
        raise ReconciliationError("لا توجد منتجات للاعتماد")

    lines = {l["product_id"]: l for l in json.loads(rec.lines_json or "[]")}

    # Conflict pass — lock every product and verify the expected quantity.
    locked: Dict[str, Product] = {}
    for s in settlements:
        pid = str(s.get("product_id"))
        if pid not in lines:
            raise ReconciliationError("منتج خارج نطاق هذا الجرد")
        p = (
            await db.execute(
                select(Product)
                .where(
                    Product.id == _uuid.UUID(pid),
                    Product.organization_id == org_id,
                )
                .with_for_update()
            )
        ).scalar_one_or_none()
        if not p:
            raise ReconciliationError("المنتج غير موجود")
        expected = s.get("expected_system")
        if expected is None or abs(_f(p.stock) - _f(expected)) > EPS:
            raise ReconciliationConflict(
                "تغيرت كمية أحد المنتجات بعد الفحص — أعد المراجعة",
                {
                    "product_id": pid,
                    "name": p.name,
                    "system_qty": _num(p.stock),
                },
            )
        if p.is_service:
            raise ReconciliationError("لا يمكن جرد منتج خدمي")
        locked[pid] = p

    settlements_out = []
    for s in settlements:
        pid = str(s.get("product_id"))
        p = locked[pid]
        new_qty = _f(s.get("new_qty"))
        if new_qty < 0:
            raise ReconciliationError("الكمية الجديدة لا يمكن أن تكون سالبة")
        before = float(await bstock.available(db, org_id, branch_id, p))
        diff = new_qty - before
        movement_id = None
        if abs(diff) > EPS:
            await bstock.set_quantity(db, org_id, branch_id, p, new_qty)
            mv = InventoryMovement(
                organization_id=org_id,
                product_id=p.id,
                movement_type="adjust_set",
                quantity=diff,
                unit_price=Decimal("0"),
                total=Decimal("0"),
                currency=p.cost_currency,
                reason="مطابقة المخزون",
                old_quantity=before,
                new_quantity=new_qty,
                difference=diff,
                branch_id=branch_id,
                reference_type="reconciliation",
                notes=f"تسوية جرد {rec.ref_code}",
                created_by=user_id,
            )
            db.add(mv)
            await db.flush()
            movement_id = str(mv.id)
            # FIFO/FEFO integrity: shortage consumes lots; surplus creates a
            # lot valued at the product's last cost (source="adjustment").
            from app.domain.services import inventory_lots as lots

            await lots.adjust_lots(
                db, org_id, p, diff, (p.cost_currency or "")
            )
        entry = {
            "product_id": pid,
            "name": p.name,
            "unit": p.unit or "قطعة",
            "before": _num(before),
            "after": _num(new_qty),
            "diff": _num(diff),
            "movement_id": movement_id,
            "applied": abs(diff) > EPS,
        }
        # multi-unit breakdown (what the user actually counted) travels with
        # the settlement so the details page and the PDF can show per-unit.
        try:
            _lines_now = json.loads(rec.lines_json or "[]")
            _line = next((x for x in _lines_now
                          if isinstance(x, dict) and str(x.get("product_id")) == pid),
                         None)
            entry["parts"] = (_line or {}).get("parts", [])
            # Consistent per-unit equivalents travel too (rendered from the
            # single base — never independent settlements).
            entry["unit_rows"] = (_line or {}).get("unit_rows", [])
        except Exception:
            entry["parts"] = []
            entry["unit_rows"] = []
        settlements_out.append(entry)

    applied = len([s for s in settlements_out if s["applied"]])
    result = {
        "settled": applied,
        "untouched": len(settlements_out) - applied,
        "ref_code": rec.ref_code,
    }
    rec.settlements_json = json.dumps(settlements_out, ensure_ascii=False)
    rec.result_json = json.dumps(result, ensure_ascii=False)
    rec.status = "approved"
    rec.approved_by = user_id
    rec.approved_at = _now()
    if branch_id and not rec.branch_id:
        rec.branch_id = branch_id
    if notes:
        rec.notes = notes
    await db.flush()
    return _record_dict(rec)


# ══════════════════════════════════════════════════════════════
#  ARCHIVE
# ══════════════════════════════════════════════════════════════


async def list_reconciliations(
    db: AsyncSession,
    org_id: UUID,
    rtype: Optional[str] = None,
    status: Optional[str] = None,
    date_from: Optional[datetime] = None,
    date_to: Optional[datetime] = None,
    search: Optional[str] = None,
    page: int = 1,
    per_page: int = 20,
    branch_ids: Optional[list] = None,
) -> Dict[str, Any]:
    conds = [Reconciliation.organization_id == org_id]
    if branch_ids is not None:
        conds.append(Reconciliation.branch_id.in_(branch_ids))
    if rtype:
        conds.append(Reconciliation.rtype == rtype)
    if status:
        conds.append(Reconciliation.status == status)
    if date_from:
        conds.append(Reconciliation.created_at >= date_from)
    if date_to:
        conds.append(Reconciliation.created_at <= date_to)
    if search and search.strip():
        term = f"%{search.strip()}%"
        conds.append(
            Reconciliation.ref_code.ilike(term)
            | Reconciliation.scope_json.ilike(term)
            | Reconciliation.notes.ilike(term)
        )
    total = (
        await db.execute(
            select(func.count()).select_from(Reconciliation).where(*conds)
        )
    ).scalar_one()
    rows = (
        await db.execute(
            select(Reconciliation)
            .where(*conds)
            .order_by(Reconciliation.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
    ).scalars().all()
    items = []
    for r in rows:
        result = json.loads(r.result_json or "{}")
        lines = json.loads(r.lines_json or "[]")
        # Exact «is there any difference?» flag for the archive chip
        # (اختلاف / سليم) — computed from the stored lines, not estimated.
        has_diff = any(
            abs(_f(l.get("diff"))) > 1e-9 for l in lines if isinstance(l, dict)
        )
        summary = {
            "has_diff": has_diff,
            "id": str(r.id),
            "ref_code": r.ref_code,
            "rtype": r.rtype,
            "scope": r.scope,
            "scope_json": json.loads(r.scope_json or "{}"),
            "status": r.status,
            "measured_at": r.measured_at.isoformat() if r.measured_at else None,
            "created_at": r.created_at.isoformat() if r.created_at else None,
            "approved_at": r.approved_at.isoformat() if r.approved_at else None,
            "lines_count": len(lines),
            "result": result,
        }
        items.append(summary)
    return {"items": items, "total": int(total), "page": page,
            "per_page": per_page}


async def get_reconciliation(
    db: AsyncSession, org_id: UUID, recon_id: UUID
) -> Dict[str, Any]:
    rec = await _get_recon(db, org_id, recon_id)
    return _record_dict(rec)


async def resolve_executor_names(
    db: AsyncSession, org_id: UUID, records: List[Dict[str, Any]]
) -> None:
    """Attach display names for created_by/approved_by (manager = «المدير»)."""
    ids: set = set()
    for r in records:
        for k in ("created_by", "approved_by"):
            if r.get(k):
                try:
                    ids.add(_uuid.UUID(str(r[k])))
                except Exception:
                    pass
    if not ids:
        return
    from app.domain.entities.auth_entities import User

    names = {
        row[0]: row[1]
        for row in (
            await db.execute(
                select(User.id, User.full_name).where(User.id.in_(ids))
            )
        ).all()
    }
    mgr = (
        await db.execute(
            select(User.id)
            .where(User.organization_id == org_id)
            .order_by(User.created_at.asc())
            .limit(1)
        )
    ).scalar_one_or_none()
    for r in records:
        for k, out in (("created_by", "created_by_name"),
                       ("approved_by", "approved_by_name")):
            raw = r.get(k)
            if raw:
                uid = _uuid.UUID(str(raw))
                r[out] = names.get(uid)
                if k.endswith("approved_by"):
                    r["approved_by_is_manager"] = bool(mgr and uid == mgr)
                else:
                    r["created_by_is_manager"] = bool(mgr and uid == mgr)