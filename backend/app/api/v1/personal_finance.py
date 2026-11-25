"""Self-service personal finance endpoints for regular (personal-mode) users.

Mirrors the admin/personal surface but scoped to the authenticated user, and
adds the create operations the admin surface lacks. All personal entities are
keyed by `user_id` and soft-deleted via `is_deleted`.
"""
from datetime import datetime, timezone
from decimal import Decimal
from typing import Optional
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select, func, or_, delete
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ...api.deps import get_current_user_uuid, require_permission
from ...api.responses import ok, created, no_content, ok_paginated
from ...core.database import get_db
from ...domain.entities.personal_entities import (
    PersonalBankAccount,
    PersonalTransaction,
    PersonalSavingsGoal,
    PersonalDebt,
    PersonalDebtPayment,
    PersonalBudget,
    PersonalBudgetCategory,
    PersonalRecurringTransaction,
    effective_account_type,
    normalize_account_type,
)
from ...domain.entities.auth_entities import User
from ...domain.entities.sync_entities import EntityVersion, ConflictLog, SyncLog
from ...domain.services.personal_sync import PERSONAL_MODELS, record_entity_version

async def _check_personal_maintenance(
    request: Request,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    """مركز فحص الصيانة — يمنع أي عملية داخل قسم متوقف حتى لو كانت الصفحة مفتوحة مسبقاً.
    يطبق الهرمية APP > PERSONAL > FEATURE ويحترم الأدمن.
    """
    try:
        # الأدمن لا يُحجب
        try:
            urow = await db.execute(select(User.is_platform_admin).where(User.id == user_id))
            is_admin = urow.scalar_one_or_none()
            if is_admin:
                return
        except Exception:
            pass
        from app.domain.services.admin_settings_service import AdminSettingsService
        ctrl = await AdminSettingsService(db).get_controls()
        maint = ctrl.get("maintenance") or {}
        if maint.get("all") is True:
            msg = (maint.get("message") or "").strip() or "التطبيق تحت الصيانة حالياً"
            raise HTTPException(status_code=503, detail={"code": "maintenance_all", "message": msg})
        if maint.get("personal") is True:
            msg = (maint.get("message") or "").strip() or "القسم الشخصي تحت الصيانة"
            raise HTTPException(status_code=503, detail={"code": "maintenance_personal", "message": msg})
        # ميزة محددة — مطابقة بادئة المسار
        path = request.url.path or ""
        # خريطة المسار -> مفتاح الميزة
        feature_map = {
            "/personal/finance/accounts": "personal/banks",
            "/personal/banks": "personal/banks",
            "/personal/finance/banks": "personal/banks",
            "/personal/finance/transactions": "personal/transactions",
            "/personal/transactions": "personal/transactions",
            "/personal/finance/budgets": "personal/budget",
            "/personal/budget": "personal/budget",
            "/personal/finance/goals": "personal/savings",
            "/personal/finance/savings": "personal/savings",
            "/personal/savings": "personal/savings",
            "/personal/finance/debts": "personal/debts",
            "/personal/debts": "personal/debts",
            "/personal/ai": "personal/ai",
            "/personal/finance/ai": "personal/ai",
            "/personal/finance/recurring": "personal/transactions",
            "/personal/finance/categories": "personal/transactions",
        }
        feature_key = None
        for prefix, key in feature_map.items():
            if path.startswith(prefix):
                feature_key = key
                break
        # سحب مصروف / إضافة دخل تُمرر كـ tx_type في الـ body — نتعامل معها كـ transactions عامة
        # لكن لو كان disabled_buttons يحتوي المفتاح الدقيق، نمنعه
        disabled = ctrl.get("disabled_buttons") or {}
        personal_disabled = disabled.get("personal") or []
        all_disabled = disabled.get("all") or []
        method = (request.method or "GET").upper()
        # تحقق دقيق: للمعاملات نميز بين القراءة والكتابة
        blocked = False
        blocked_key = feature_key
        if feature_key:
            if feature_key == "personal/transactions" and method in ("POST", "PUT", "PATCH", "DELETE"):
                # سحب مصروف / إضافة دخل كحالتين خاصتين ضمن المعاملات
                for k in ("personal/transactions", "personal/transactions/add-expense", "personal/transactions/add-income"):
                    if k in personal_disabled or k in all_disabled:
                        blocked = True
                        blocked_key = k
                        break
            else:
                if feature_key in personal_disabled or feature_key in all_disabled:
                    blocked = True
        if blocked:
            msg = (maint.get("message") or "").strip() or "هذا القسم تحت الصيانة"
            raise HTTPException(status_code=503, detail={"code": "maintenance_feature", "feature": blocked_key, "message": msg})
    except HTTPException:
        raise
    except Exception:
        # لا نكسر الطلب في حال فشل قراءة الإعدادات — نسمح بالمرور
        return


router = APIRouter(tags=["Personal Finance"], dependencies=[Depends(_check_personal_maintenance)])


async def _user_org_id(db: AsyncSession, user_id: UUID):
    """Return the user's organization_id (best-effort; None if unknown)."""
    try:
        row = await db.execute(select(User.organization_id).where(User.id == user_id))
        return row.scalar_one_or_none()
    except Exception:  # noqa: BLE001
        return None


def _is_replay(request: Request) -> bool:
    """True when the request comes from the offline sync engine replaying a
    locally-committed operation.

    Replay semantics (safe, money-preserving):
      * parent rows may be soft-deleted (the operation already happened on the
        device; deleting the parent elsewhere must not erase this movement),
      * the balance-sufficiency check is skipped because the device validated
        the intent against its synchronised snapshot — a concurrent device may
        have moved money since, and replaying must never wedge forever.
    """
    try:
        return (request.headers.get("X-Sync-Replay") or "").strip() == "1"
    except Exception:  # noqa: BLE001
        return False


async def _client_uuid_existing(db: AsyncSession, model, entity_id, user_id):
    """Idempotent-create lookup for a client-generated UUID.

    Offline creates carry the UUID they were born with; a retried replay must
    return the SAME row instead of inserting a second one.
    """
    if entity_id is None:
        return None
    row = (await db.execute(select(model).where(model.id == entity_id))).scalar_one_or_none()
    if row is None:
        return None
    if getattr(row, "user_id", None) != user_id:
        raise HTTPException(status_code=409, detail="المعرف مستخدم من حساب آخر")
    return row


async def _commit_or_dedupe(db: AsyncSession, model, entity_id, user_id):
    """Commit a create; on a concurrent duplicate UUID return the existing row
    instead of failing (exactly-once semantics for replay)."""
    try:
        await db.commit()
        return None
    except IntegrityError:
        await db.rollback()
        existing = await _client_uuid_existing(db, model, entity_id, user_id)
        if existing is not None:
            return existing
        raise

VALID_TX_TYPES = ("income", "expense", "transfer_in", "transfer_out")
# Semantic movement for balance: a transfer out is an expense for the source
# account, a transfer in is an income for the target account.
SEMANTIC_TX_TYPE = {
    "income": "income",
    "expense": "expense",
    "transfer_in": "income",
    "transfer_out": "expense",
}
VALID_FREQUENCIES = ("daily", "weekly", "monthly", "yearly")
VALID_DEBT_TYPES = ("payable", "receivable")


# ── Serializers ──


def _account_to_dict(a: PersonalBankAccount) -> dict:
    return {
        "id": str(a.id),
        "bank_name": a.bank_name,
        "currency": a.currency,
        "balance": float(a.balance) if a.balance else 0,
        "notes": a.notes,
        "account_type": effective_account_type(a),
        # False only for legacy rows whose type was never stated (reads as
        # 'current'); lets a device migrate its local-only type up once.
        "account_type_set": getattr(a, "account_type", None) is not None,
        "is_active": a.is_active,
        "sort_order": a.sort_order if a.sort_order is not None else 0,
        "created_at": a.created_at.isoformat() if a.created_at else None,
        "updated_at": a.updated_at.isoformat() if a.updated_at else None,
    }


def _tx_to_dict(t: PersonalTransaction) -> dict:
    return {
        "id": str(t.id),
        "tx_type": t.tx_type,
        "amount": float(t.amount) if t.amount else 0,
        "currency": t.currency or "SAR",
        "category": t.category,
        "description": t.description or "",
        "date": t.date.isoformat() if t.date else None,
        "bank_account_id": str(t.bank_account_id) if t.bank_account_id else None,
        "budget_id": str(t.budget_id) if getattr(t, "budget_id", None) else None,
        "budget_category_id": str(t.budget_category_id) if getattr(t, "budget_category_id", None) else None,
        "goal_id": str(t.goal_id) if getattr(t, "goal_id", None) else None,
        "debt_id": str(t.debt_id) if getattr(t, "debt_id", None) else None,
        "goal_amount": float(t.goal_amount) if getattr(t, "goal_amount", None) is not None else None,
        "debt_amount": float(t.debt_amount) if getattr(t, "debt_amount", None) is not None else None,
        "payment_method": t.payment_method,
        "exchange_rate": float(t.exchange_rate) if getattr(t, "exchange_rate", None) is not None else None,
        "exchange_rate_currency": getattr(t, "exchange_rate_currency", None),
        "fx_source": getattr(t, "fx_source", None),
        "client_operation_id": getattr(t, "client_operation_id", None),
        "created_at": t.created_at.isoformat() if t.created_at else None,
        "updated_at": t.updated_at.isoformat() if getattr(t, "updated_at", None) else None,
    }


def _goal_to_dict(g: PersonalSavingsGoal) -> dict:
    return {
        "id": str(g.id),
        "name": g.name,
        "target_amount": float(g.target_amount) if g.target_amount else 0,
        "current_amount": float(g.current_amount) if g.current_amount else 0,
        "currency": g.currency,
        "deadline": g.deadline.isoformat() if g.deadline else None,
        "icon": g.icon or "SAVINGS",
        "notes": g.notes or "",
        "budget_id": str(g.budget_id) if getattr(g, "budget_id", None) else None,
        "is_completed": g.is_completed,
        "created_at": g.created_at.isoformat() if g.created_at else None,
        "updated_at": g.updated_at.isoformat() if getattr(g, "updated_at", None) else None,
        "progress_pct": round(float(g.current_amount or 0) / float(g.target_amount or 1) * 100, 1) if g.target_amount and g.target_amount > 0 else 0,
    }


async def _debt_to_dict(d: PersonalDebt, db: AsyncSession = None, _paid_total: float | None = None) -> dict:
    if _paid_total is not None:
        paid_total = _paid_total
    elif db is not None:
        rows = (await db.execute(
            select(PersonalDebtPayment.amount).where(
                PersonalDebtPayment.debt_id == d.id,
                PersonalDebtPayment.is_deleted == False,
            )
        )).scalars().all()
        paid_total = sum(float(r or 0) for r in rows)
    else:
        paid_total = 0.0
    amt = float(d.amount or 0)
    return {
        "id": str(d.id),
        "debt_type": d.debt_type,
        "person_name": d.person_name,
        "amount": amt,
        "currency": d.currency,
        "description": d.description or "",
        "due_date": d.due_date.isoformat() if d.due_date else None,
        "is_paid": d.is_paid,
        "paid": paid_total,
        "remaining": max(amt - paid_total, 0),
        "status": "paid" if d.is_paid else ("overdue" if d.due_date and d.due_date < datetime.now(timezone.utc).date() else "active"),
        "paid_date": d.paid_date.isoformat() if d.paid_date else None,
        "reminder": bool(d.reminder) if hasattr(d, "reminder") and d.reminder is not None else False,
        "budget_id": str(d.budget_id) if getattr(d, "budget_id", None) else None,
        "created_at": d.created_at.isoformat() if d.created_at else None,
        "updated_at": d.updated_at.isoformat() if getattr(d, "updated_at", None) else None,
    }


def _payment_to_dict(p: PersonalDebtPayment) -> dict:
    return {
        "id": str(p.id),
        "debt_id": str(p.debt_id),
        "budget_id": str(p.budget_id) if getattr(p, "budget_id", None) else None,
        "amount": float(p.amount) if p.amount else 0,
        "currency": getattr(p, "currency", None) or "SAR",
        "payment_date": p.payment_date.isoformat() if p.payment_date else None,
        "notes": p.notes or "",
        "created_at": p.created_at.isoformat() if p.created_at else None,
    }


def _budget_to_dict(b: PersonalBudget) -> dict:
    from app.domain.entities.personal_entities import PersonalBudgetCategory
    from sqlalchemy import select
    from app.core.database import async_session_factory

    def _cat_to_dict(c) -> dict:
        if isinstance(c, dict):
            return {
                "id": str(c.get("id")) if c.get("id") else None,
                "budget_id": str(c.get("budget_id") or b.id),
                "name": c.get("name", ""),
                "type": c.get("type", "expense"),
                "allocated_amount": float(c.get("allocated_amount", 0) or 0),
                "spent_amount": float(c.get("spent_amount", 0) or 0),
                "currency": c.get("currency") or b.currency or "SAR",
                "goal_id": str(c.get("goal_id")) if c.get("goal_id") else None,
                "debt_id": str(c.get("debt_id")) if c.get("debt_id") else None,
                "created_at": c.get("created_at"),
                "updated_at": c.get("updated_at"),
            }
        return {
            "id": str(c.id),
            "budget_id": str(c.budget_id) if getattr(c, "budget_id", None) else str(b.id),
            "name": c.name,
            "type": c.type,
            "allocated_amount": float(c.allocated_amount) if c.allocated_amount else 0,
            "spent_amount": float(c.spent_amount) if c.spent_amount else 0,
            "currency": c.currency or b.currency or "SAR",
            "goal_id": str(c.goal_id) if getattr(c, "goal_id", None) else None,
            "debt_id": str(c.debt_id) if getattr(c, "debt_id", None) else None,
            "created_at": c.created_at.isoformat() if getattr(c, "created_at", None) else None,
            "updated_at": c.updated_at.isoformat() if getattr(c, "updated_at", None) else None,
        }

    cats = []
    if hasattr(b, '_categories_loaded'):
        cats = [_cat_to_dict(c) for c in (b._categories_loaded or [])]
    elif hasattr(b, 'budget_categories'):
        cats = [_cat_to_dict(c) for c in b.budget_categories] if hasattr(b, 'budget_categories') and b.budget_categories else []

    total_spent = sum(c.get("spent_amount", 0) for c in cats) if cats else (float(b.spent) if b.spent else 0)

    return {
        "id": str(b.id),
        "name": b.name or b.category or "",
        "period_type": b.period_type or "monthly",
        "start_date": b.start_date.isoformat() if b.start_date else None,
        "end_date": b.end_date.isoformat() if b.end_date else None,
        "custom_days": b.custom_days,
        "total_amount": float(b.total_amount or b.amount or 0),
        "amount": float(b.total_amount or b.amount or 0),
        "currency": b.currency,
        "bank_account_ids": b.bank_account_ids or [],
        "budget_types": b.budget_types or ["expenses"],
        "total_spent": total_spent,
        "spent": total_spent,
        "categories": cats,
        "category": b.category,
        "month": b.month,
        "year": b.year,
        "created_at": b.created_at.isoformat() if b.created_at else None,
        "updated_at": b.updated_at.isoformat() if getattr(b, "updated_at", None) else None,
        "remaining": round(float((b.total_amount or b.amount or 0)) - total_spent, 2),
    }


async def _budget_categories_payload(db: AsyncSession, budget_id) -> list:
    """Category rows for one budget, in the shape `_budget_to_dict` expects."""
    fresh_cats = (await db.execute(
        select(PersonalBudgetCategory).where(PersonalBudgetCategory.budget_id == budget_id)
    )).scalars().all()
    return [
        {"id": str(c.id), "budget_id": str(c.budget_id), "name": c.name, "type": c.type,
         "allocated_amount": float(c.allocated_amount) if c.allocated_amount else 0,
         "spent_amount": float(c.spent_amount) if c.spent_amount else 0,
         "currency": c.currency,
         "goal_id": str(c.goal_id) if getattr(c, "goal_id", None) else None,
         "debt_id": str(c.debt_id) if getattr(c, "debt_id", None) else None,
         "created_at": c.created_at.isoformat() if getattr(c, "created_at", None) else None,
         "updated_at": c.updated_at.isoformat() if getattr(c, "updated_at", None) else None}
        for c in fresh_cats
    ]


def _recurring_to_dict(r: PersonalRecurringTransaction) -> dict:
    return {
        "id": str(r.id),
        "name": r.name or "",
        "tx_type": r.tx_type,
        "amount": float(r.amount) if r.amount else 0,
        "currency": r.currency or "SAR",
        "category": r.category,
        "description": r.description or "",
        "frequency": r.frequency,
        "interval_value": r.interval_value,
        "next_run_date": r.next_run_date.isoformat() if r.next_run_date else None,
        "account_type": r.account_type or "fixed",
        "bank_account_id": str(r.bank_account_id) if r.bank_account_id else None,
        "execution_type": r.execution_type or "auto",
        "reminder_time": r.reminder_time,
        "approximate_start_day": r.approximate_start_day,
        "approximate_end_day": r.approximate_end_day,
        "last_executed_at": r.last_executed_at.isoformat() if r.last_executed_at else None,
        "is_active": r.is_active,
        "created_at": r.created_at.isoformat() if r.created_at else None,
        "updated_at": r.updated_at.isoformat() if getattr(r, "updated_at", None) else None,
    }


# ── Schemas ──


class PersonalAccountCreate(BaseModel):
    # Client-generated UUID (offline-first identity + replay idempotency).
    id: Optional[UUID] = None
    bank_name: str = Field(min_length=1)
    currency: str = "SAR"
    balance: float = 0
    notes: Optional[str] = None
    is_active: bool = True
    # 'current' (جاري) / 'savings' (توفير); omitted → 'current'.
    account_type: Optional[str] = None

    @field_validator("account_type", mode="before")
    @classmethod
    def _valid_account_type(cls, v):
        return normalize_account_type(v)


class PersonalAccountUpdate(BaseModel):
    bank_name: Optional[str] = None
    currency: Optional[str] = None
    balance: Optional[float] = None
    notes: Optional[str] = None
    is_active: Optional[bool] = None
    account_type: Optional[str] = None

    @field_validator("account_type", mode="before")
    @classmethod
    def _valid_account_type(cls, v):
        return normalize_account_type(v)


class PersonalTransactionCreate(BaseModel):
    # Client-generated UUID (offline-first identity + replay idempotency).
    id: Optional[UUID] = None
    tx_type: str
    amount: float = Field(gt=0)
    currency: str = "SAR"
    category: str = Field(min_length=1)
    description: Optional[str] = None
    date: Optional[str] = None
    bank_account_id: Optional[str] = None
    payment_method: Optional[str] = None
    budget_id: Optional[str] = None
    budget_category_id: Optional[str] = None
    goal_id: Optional[str] = None
    debt_id: Optional[str] = None
    # Amount credited to the linked goal in the goal's currency (may differ
    # from `amount` for cross-currency contributions).
    goal_amount: Optional[float] = None
    # Optional exchange-rate snapshot recorded at execution time (offline-first):
    # the client may send the rate it used so history keeps it, never recomputed.
    exchange_rate: Optional[float] = None
    exchange_rate_currency: Optional[str] = None
    fx_source: Optional[str] = None
    # Client-generated idempotency key (one per user intent, e.g. one form
    # submission): repeats with the same key return the original transaction.
    client_operation_id: Optional[str] = None


class PersonalTransactionUpdate(BaseModel):
    tx_type: Optional[str] = None
    amount: Optional[float] = None
    category: Optional[str] = None
    description: Optional[str] = None
    date: Optional[str] = None
    currency: Optional[str] = None
    bank_account_id: Optional[str] = None
    payment_method: Optional[str] = None
    budget_id: Optional[str] = None
    budget_category_id: Optional[str] = None
    goal_id: Optional[str] = None
    debt_id: Optional[str] = None
    exchange_rate: Optional[float] = None
    exchange_rate_currency: Optional[str] = None
    fx_source: Optional[str] = None


class PersonalGoalCreate(BaseModel):
    id: Optional[UUID] = None
    name: str = Field(min_length=1)
    target_amount: float = Field(gt=0)
    current_amount: float = 0
    currency: str = "SAR"
    deadline: Optional[str] = None
    icon: Optional[str] = None
    notes: Optional[str] = None
    budget_id: Optional[str] = None


class PersonalGoalUpdate(BaseModel):
    name: Optional[str] = None
    target_amount: Optional[float] = None
    current_amount: Optional[float] = None
    deadline: Optional[str] = None
    icon: Optional[str] = None
    notes: Optional[str] = None
    is_completed: Optional[bool] = None
    budget_id: Optional[str] = None


class PersonalGoalContribute(BaseModel):
    amount: float = Field(gt=0)
    # Optional client UUID for the created contribution transaction, so the
    # offline row keeps the identity it was born with after replay.
    tx_id: Optional[UUID] = None
    # Optional overrides so ONE call moves money AND links the tx by IDs.
    # amount/currency/bank_account_id describe the money movement;
    # goal_amount (default = amount) is credited to the goal in goal currency.
    currency: Optional[str] = None
    bank_account_id: Optional[str] = None
    payment_method: Optional[str] = None
    goal_amount: Optional[float] = None
    category: Optional[str] = None
    description: Optional[str] = None
    # Idempotency key for the created contribution transaction.
    client_operation_id: Optional[str] = None


class PersonalDebtCreate(BaseModel):
    id: Optional[UUID] = None
    debt_type: str
    person_name: str = Field(min_length=1)
    amount: float = Field(gt=0)
    currency: str = "SAR"
    description: Optional[str] = None
    due_date: Optional[str] = None
    reminder: bool = False
    budget_id: Optional[str] = None


class PersonalDebtUpdate(BaseModel):
    debt_type: Optional[str] = None
    person_name: Optional[str] = None
    amount: Optional[float] = None
    currency: Optional[str] = None
    description: Optional[str] = None
    due_date: Optional[str] = None
    is_paid: Optional[bool] = None
    reminder: Optional[bool] = None
    budget_id: Optional[str] = None


class PersonalDebtPaymentCreate(BaseModel):
    amount: float = Field(gt=0)
    # Optional client UUID for the created payment transaction.
    tx_id: Optional[UUID] = None
    payment_date: Optional[str] = None
    notes: Optional[str] = None
    bank_account_id: Optional[str] = None
    payment_method: Optional[str] = None
    # amount/currency describe the money movement in the account currency;
    # debt_amount (default = amount) is credited to the debt in debt
    # currency (goals-style cross-currency support).
    currency: Optional[str] = None
    debt_amount: Optional[float] = None
    # Idempotency key for the created payment transaction.
    client_operation_id: Optional[str] = None


class PersonalBudgetCreate(BaseModel):
    id: Optional[UUID] = None
    name: str = Field(min_length=1, max_length=200)
    amount: float = Field(gt=0)
    period_type: str = "monthly"
    start_date: Optional[str] = None
    end_date: Optional[str] = None
    custom_days: Optional[int] = None
    currency: str = "SAR"
    bank_account_ids: Optional[list] = None
    budget_types: Optional[list] = None
    categories: Optional[list] = None  # [{name, type, amount, currency}]


class PersonalBudgetUpdate(BaseModel):
    name: Optional[str] = None
    amount: Optional[float] = None
    period_type: Optional[str] = None
    start_date: Optional[str] = None
    end_date: Optional[str] = None
    custom_days: Optional[int] = None
    currency: Optional[str] = None
    bank_account_ids: Optional[list] = None
    budget_types: Optional[list] = None
    categories: Optional[list] = None


class PersonalRecurringCreate(BaseModel):
    id: Optional[UUID] = None
    name: Optional[str] = None
    tx_type: str
    amount: float = Field(gt=0)
    currency: str = "SAR"
    category: str = Field(min_length=1)
    description: Optional[str] = None
    frequency: str = "monthly"
    interval_value: int = 1
    next_run_date: Optional[str] = None
    account_type: str = "fixed"
    bank_account_id: Optional[str] = None
    execution_type: str = "auto"
    reminder_time: Optional[str] = None
    approximate_start_day: Optional[int] = None
    approximate_end_day: Optional[int] = None
    is_active: bool = True


class PersonalRecurringUpdate(BaseModel):
    name: Optional[str] = None
    tx_type: Optional[str] = None
    amount: Optional[float] = None
    currency: Optional[str] = None
    category: Optional[str] = None
    description: Optional[str] = None
    frequency: Optional[str] = None
    interval_value: Optional[int] = None
    next_run_date: Optional[str] = None
    account_type: Optional[str] = None
    bank_account_id: Optional[str] = None
    execution_type: Optional[str] = None
    reminder_time: Optional[str] = None
    approximate_start_day: Optional[int] = None
    approximate_end_day: Optional[int] = None
    is_active: Optional[bool] = None


# ── Stats ──


@router.get("/personal/finance/stats", summary="Personal finance dashboard stats")
async def get_personal_finance_stats(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "read")),
):
    accounts = (await db.execute(
        select(PersonalBankAccount).where(
            PersonalBankAccount.user_id == user_id,
            PersonalBankAccount.is_deleted == False,
        )
    )).scalars().all()

    transactions = (await db.execute(
        select(PersonalTransaction).where(
            PersonalTransaction.user_id == user_id,
            PersonalTransaction.is_deleted == False,
        )
    )).scalars().all()

    goals = (await db.execute(
        select(PersonalSavingsGoal).where(
            PersonalSavingsGoal.user_id == user_id,
            PersonalSavingsGoal.is_deleted == False,
        )
    )).scalars().all()

    debts = (await db.execute(
        select(PersonalDebt).where(
            PersonalDebt.user_id == user_id,
            PersonalDebt.is_deleted == False,
        )
    )).scalars().all()

    total_income = sum(float(t.amount or 0) for t in transactions if t.tx_type == "income")
    total_expense = sum(float(t.amount or 0) for t in transactions if t.tx_type == "expense")

    return ok(data={
        "total_balance": sum(float(a.balance or 0) for a in accounts),
        "accounts_count": len(accounts),
        "total_income": total_income,
        "total_expense": total_expense,
        "net_savings": round(total_income - total_expense, 2),
        "goals_count": len(goals),
        "goals_completed": sum(1 for g in goals if g.is_completed),
        "debts_count": len(debts),
        "active_debts_count": sum(1 for d in debts if not d.is_paid),
        "active_debts_amount": sum(float(d.amount or 0) for d in debts if not d.is_paid),
        "transactions_count": len(transactions),
    })


# ── Accounts ──

CASH_ACCOUNT_NAMES = ("كاش", "Cash")


#: Default cash-account currency per phone country ISO code. Used ONLY when
#: lazily creating a user's first cash account; existing rows are never
#: touched. Unknown/missing countries keep the historical SAR default.
CASH_CURRENCY_BY_COUNTRY = {
    "YE": "YER", "SA": "SAR", "AE": "AED", "KW": "KWD", "QA": "QAR",
    "BH": "BHD", "OM": "OMR", "JO": "JOD", "LB": "LBP", "IQ": "IQD",
    "SY": "SYP", "PS": "ILS", "EG": "EGP", "TR": "TRY", "MA": "MAD",
    "TN": "TND", "DZ": "DZD", "LY": "LYD", "SD": "SDG", "DJ": "DJF",
    "SO": "SOS", "KM": "KMF", "MR": "MRU", "CM": "XAF", "NG": "NGN",
    "GH": "GHS", "KE": "KES", "ET": "ETB", "TZ": "TZS", "ZA": "ZAR",
    "IN": "INR", "PK": "PKR", "BD": "BDT", "LK": "LKR", "NP": "NPR",
    "AF": "AFN", "IR": "IRR", "TH": "THB", "ID": "IDR", "MY": "MYR",
    "PH": "PHP", "VN": "VND", "KR": "KRW", "JP": "JPY", "CN": "CNY",
    "SG": "SGD", "HK": "HKD", "TW": "TWD", "AU": "AUD", "NZ": "NZD",
    "US": "USD", "CA": "CAD", "GB": "GBP", "FR": "EUR", "DE": "EUR",
    "IT": "EUR", "ES": "EUR", "NL": "EUR", "BE": "EUR", "CH": "CHF",
    "AT": "EUR", "SE": "SEK", "NO": "NOK", "DK": "DKK", "FI": "EUR",
    "PL": "PLN", "CZ": "CZK", "RO": "RON", "GR": "EUR", "PT": "EUR",
    "IE": "EUR", "RU": "RUB", "UA": "UAH", "BR": "BRL", "MX": "MXN",
    "AR": "ARS", "CO": "COP", "CL": "CLP", "PE": "PEN",
}


async def _ensure_cash_account(
    db: AsyncSession, user_id: UUID, currency: Optional[str] = None
) -> Optional[PersonalBankAccount]:
    """Lazily create the user's 'كاش' (cash) account so it always exists as soon
    as the banks section is used. It is intentionally NOT a default account: it
    is just an ordinary row (sort_order=0, no default flag). Soft-deleted rows
    still count, so a user can delete it once and it will not come back.
    Returns the cash account row so callers can operate on its balance.

    When [currency] is given, the row of that currency bucket is preferred
    (multi-currency users must not land on the oldest row regardless of
    currency); a missing bucket is created in that currency instead of the
    phone-country default.
    """
    wanted = (currency or "").strip().upper() or None
    wanted_bucket = ("YER" if wanted == "YER_NEW" else wanted) if wanted else None
    result = await db.execute(
        select(PersonalBankAccount).where(
            PersonalBankAccount.user_id == user_id,
            PersonalBankAccount.bank_name.in_(CASH_ACCOUNT_NAMES),
        ).order_by(PersonalBankAccount.created_at)
    )
    rows = result.scalars().all()
    if rows:
        if wanted_bucket:
            for cash in rows:
                bucket = ("YER" if (cash.currency or "SAR").strip().upper() == "YER_NEW"
                          else (cash.currency or "SAR").strip().upper())
                if bucket == wanted_bucket:
                    return cash
        else:
            return rows[0]
    # New cash accounts inherit the user's phone country currency so the
    # default cash matches the country picked at signup (SAR fallback) —
    # unless the caller already told us which currency it operates in.
    cash_currency = wanted or "SAR"
    try:
        owner = (await db.execute(
            select(User).where(User.id == user_id)
        )).scalar_one_or_none()
        if owner is not None:
            cc = (getattr(owner, "phone_country", None) or "").strip().upper()
            if cc:
                cash_currency = CASH_CURRENCY_BY_COUNTRY.get(cc, "SAR")
    except Exception:
        cash_currency = "SAR"
    cash = PersonalBankAccount(
        user_id=user_id,
        bank_name="كاش",
        currency=cash_currency,
        balance=0,
        notes=None,
        is_active=True,
        sort_order=0,
    )
    db.add(cash)
    await db.commit()
    # The implicit cash row must also be visible to other devices' pulls.
    try:
        await record_entity_version(
            db, await _user_org_id(db, user_id), user_id,
            "personal_bank_account", cash.id, _account_to_dict(cash),
            operation_id=f"crud_cash_{cash.id}",
        )
        await db.commit()
    except Exception:  # noqa: BLE001 - best-effort, never break the caller
        pass
    return cash


@router.get("/personal/finance/accounts", summary="List my bank accounts")
async def list_my_accounts(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "read")),
):
    await _ensure_cash_account(db, user_id)
    result = await db.execute(
        select(PersonalBankAccount).where(
            PersonalBankAccount.user_id == user_id,
            PersonalBankAccount.is_deleted == False,
        ).order_by(PersonalBankAccount.sort_order)
    )
    return ok(data=[_account_to_dict(a) for a in result.scalars().all()])


@router.post("/personal/finance/accounts", status_code=status.HTTP_201_CREATED, summary="Create bank account")
async def create_my_account(
    data: PersonalAccountCreate,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "create")),
):
    # Idempotent replay: the client may already have created this UUID.
    existing = await _client_uuid_existing(db, PersonalBankAccount, data.id, user_id)
    if existing is not None:
        return created(data=_account_to_dict(existing), message="تم إنشاء الحساب")
    account = PersonalBankAccount(
        id=data.id,
        user_id=user_id,
        bank_name=data.bank_name.strip(),
        currency=data.currency or "SAR",
        balance=Decimal(str(data.balance)) if data.balance else Decimal("0"),
        notes=data.notes,
        # Omitted (older clients) stays NULL = "not stated" (reads as
        # 'current'), so that device can still migrate its local type up.
        account_type=data.account_type,
        is_active=data.is_active,
    )
    db.add(account)
    duplicate = await _commit_or_dedupe(db, PersonalBankAccount, data.id, user_id)
    if duplicate is not None:
        return created(data=_account_to_dict(duplicate), message="تم إنشاء الحساب")
    await db.refresh(account)
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_bank_account", account.id,
        _account_to_dict(account), operation_id=f"crud_{account.id}",
    )
    await db.commit()
    return created(data=_account_to_dict(account), message="تم إنشاء الحساب")


@router.get("/personal/finance/accounts/{account_id}", summary="Get bank account")
async def get_my_account(
    account_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "read")),
):
    result = await db.execute(
        select(PersonalBankAccount).where(
            PersonalBankAccount.id == account_id,
            PersonalBankAccount.user_id == user_id,
            PersonalBankAccount.is_deleted == False,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="الحساب غير موجود")
    return ok(data=_account_to_dict(row))


@router.patch("/personal/finance/accounts/{account_id}", summary="Update bank account")
async def update_my_account(
    account_id: UUID,
    data: PersonalAccountUpdate,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "update")),
):
    result = await db.execute(
        select(PersonalBankAccount).where(
            PersonalBankAccount.id == account_id,
            PersonalBankAccount.user_id == user_id,
            PersonalBankAccount.is_deleted == False,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="الحساب غير موجود")
    if data.bank_name is not None: row.bank_name = data.bank_name.strip()
    if data.currency is not None: row.currency = data.currency
    if data.balance is not None: row.balance = Decimal(str(data.balance))
    if data.notes is not None: row.notes = data.notes
    if data.is_active is not None: row.is_active = data.is_active
    if data.account_type is not None: row.account_type = data.account_type
    await db.commit()
    await db.refresh(row)
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_bank_account", row.id,
        _account_to_dict(row), operation_id=f"crud_upd_{row.id}",
    )
    await db.commit()
    return ok(data=_account_to_dict(row))


@router.delete("/personal/finance/accounts/{account_id}", summary="Delete bank account")
async def delete_my_account(
    account_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "delete")),
):
    result = await db.execute(
        select(PersonalBankAccount).where(
            PersonalBankAccount.id == account_id,
            PersonalBankAccount.user_id == user_id,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="الحساب غير موجود")
    # Prevent deleting the cash account
    if row.bank_name in CASH_ACCOUNT_NAMES:
        raise HTTPException(status_code=400, detail="لا يمكن حذف حساب الكاش — هذا الحساب أساسي ولا يمكن حذفه")
    row.is_deleted = True
    row.deleted_at = datetime.now(timezone.utc)
    await db.commit()
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_bank_account", row.id,
        {"id": str(row.id), "deleted_at": row.deleted_at.isoformat()},
        deleted=True, operation_id=f"crud_del_{row.id}",
    )
    await db.commit()
    return no_content(message="تم حذف الحساب")


# ── Transactions ──


@router.get("/personal/finance/transactions", summary="List my transactions")
async def list_my_transactions(
    tx_type: Optional[str] = Query(None),
    category: Optional[str] = Query(None),
    month: Optional[int] = Query(None, ge=1, le=12),
    year: Optional[int] = Query(None, ge=2000),
    account_id: Optional[str] = Query(None),
    page: int = Query(1, ge=1),
    per_page: int = Query(50, ge=1, le=200),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "read")),
):
    query = select(PersonalTransaction).where(
        PersonalTransaction.user_id == user_id,
        PersonalTransaction.is_deleted == False,
    )
    if tx_type:
        query = query.where(PersonalTransaction.tx_type == tx_type)
    if category:
        query = query.where(PersonalTransaction.category == category)
    if month:
        query = query.where(func.extract("month", PersonalTransaction.date) == month)
    if year:
        query = query.where(func.extract("year", PersonalTransaction.date) == year)
    if account_id:
        try:
            account_uuid = UUID(account_id)
        except ValueError:
            account_uuid = None
        if account_uuid:
            query = query.where(PersonalTransaction.bank_account_id == account_uuid)

    count_q = select(func.count()).select_from(query.subquery())
    total = (await db.execute(count_q)).scalar() or 0

    result = await db.execute(
        query.order_by(PersonalTransaction.date.desc())
        .offset((page - 1) * per_page)
        .limit(per_page)
    )
    items = result.scalars().all()
    return ok_paginated([_tx_to_dict(t) for t in items], total, page, per_page)


@router.post("/personal/finance/transactions", status_code=status.HTTP_201_CREATED, summary="Create transaction")
async def create_my_transaction(
    data: PersonalTransactionCreate,
    request: Request,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "create")),
):
    if data.tx_type not in VALID_TX_TYPES:
        raise HTTPException(status_code=422, detail="نوع المعاملة يجب أن يكون income أو expense")
    replay = _is_replay(request)
    # ── Idempotency: one user intent executes exactly once. A repeated POST
    # (double-tap, timeout retry, offline sync replay) with the same key
    # returns the original transaction instead of creating a duplicate.
    op_key = (data.client_operation_id or "").strip() or None
    if op_key:
        dup = (await db.execute(
            select(PersonalTransaction).where(
                PersonalTransaction.user_id == user_id,
                PersonalTransaction.client_operation_id == op_key,
                PersonalTransaction.is_deleted == False,
            )
        )).scalar_one_or_none()
        if dup is not None:
            return created(data={**_tx_to_dict(dup), "deduped": True}, message="تم إنشاء المعاملة")
    # Idempotency 2: client-generated entity UUID. An offline-created row keeps
    # its identity; a retried replay returns the SAME row (exactly-once).
    existing = await _client_uuid_existing(db, PersonalTransaction, data.id, user_id)
    if existing is not None:
        return created(data={**_tx_to_dict(existing), "deduped": True}, message="تم إنشاء المعاملة")
    movement = SEMANTIC_TX_TYPE[data.tx_type]
    tx_date = None
    if data.date:
        try:
            tx_date = datetime.fromisoformat(data.date)
        except ValueError:
            raise HTTPException(status_code=422, detail="تاريخ غير صالح")

    # Resolve the target bank account (if any) so its balance can be updated
    # atomically with the transaction record.
    account = None
    if data.bank_account_id:
        try:
            account_uuid = UUID(data.bank_account_id)
        except ValueError:
            raise HTTPException(status_code=400, detail="معرف الحساب البنكي غير صالح")
        # Row-level lock: concurrent double-taps serialize here so the
        # balance check below can never pass twice on the same funds.
        account_q = select(PersonalBankAccount).where(
            PersonalBankAccount.id == account_uuid,
            PersonalBankAccount.user_id == user_id,
        )
        if not replay:
            account_q = account_q.where(PersonalBankAccount.is_deleted == False)
        account = (await db.execute(account_q.with_for_update())).scalar_one_or_none()
        if not account:
            raise HTTPException(status_code=400, detail="الحساب البنكي غير موجود")
    else:
        # No bank account provided → the transaction targets the user's cash
        # (كاش) account: cash income adds to it, cash expense is deducted from
        # it, exactly like a bank account.
        account = await _ensure_cash_account(
            db, user_id, currency=(data.currency or "SAR"))

    amount = Decimal(str(data.amount))
    if not replay and movement == "expense" and account is not None:
        current_balance = Decimal(account.balance or 0)
        if current_balance < amount:
            detail = (
                "لا يوجد مبلغ كافٍ للتحويل"
                if data.tx_type == "transfer_out"
                else "لا يوجد مبلغ كافٍ لتسجيل عملية مصروف"
            )
            raise HTTPException(status_code=400, detail=detail)

    def _parse_uuid(value: Optional[str], label: str) -> Optional[UUID]:
        if not value:
            return None
        try:
            return UUID(value)
        except ValueError:
            raise HTTPException(status_code=400, detail=f"معرف غير صالح: {label}")

    budget_uuid = _parse_uuid(data.budget_id, "budget_id")
    budget_cat_uuid = _parse_uuid(data.budget_category_id, "budget_category_id")
    goal_uuid = _parse_uuid(data.goal_id, "goal_id")
    debt_uuid = _parse_uuid(data.debt_id, "debt_id")

    # Load the linked rows so their derived fields (goal credit, debt paid,
    # budget spent) move atomically with the transaction. Replay tolerates a
    # soft-deleted parent: the operation already happened on the device.
    budget_row = None
    goal_row = None
    debt_row = None
    if budget_uuid is not None:
        q = select(PersonalBudget).where(
            PersonalBudget.id == budget_uuid,
            PersonalBudget.user_id == user_id,
        )
        if not replay:
            q = q.where(PersonalBudget.is_deleted == False)
        budget_row = (await db.execute(q)).scalar_one_or_none()
        if not budget_row:
            raise HTTPException(status_code=400, detail="الميزانية غير موجودة")
    if budget_cat_uuid is not None:
        c_exists = (await db.execute(
            select(PersonalBudgetCategory.id).where(
                PersonalBudgetCategory.id == budget_cat_uuid,
            )
        )).scalar_one_or_none()
        if not c_exists:
            raise HTTPException(status_code=400, detail="تصنيف الميزانية غير موجود")
    if goal_uuid is not None:
        q = select(PersonalSavingsGoal).where(
            PersonalSavingsGoal.id == goal_uuid,
            PersonalSavingsGoal.user_id == user_id,
        )
        if not replay:
            q = q.where(PersonalSavingsGoal.is_deleted == False)
        goal_row = (await db.execute(q)).scalar_one_or_none()
        if not goal_row:
            raise HTTPException(status_code=400, detail="الهدف غير موجود")
    if debt_uuid is not None:
        q = select(PersonalDebt).where(
            PersonalDebt.id == debt_uuid,
            PersonalDebt.user_id == user_id,
        )
        if not replay:
            q = q.where(PersonalDebt.is_deleted == False)
        debt_row = (await db.execute(q)).scalar_one_or_none()
        if not debt_row:
            raise HTTPException(status_code=400, detail="الدين غير موجود")

    tx = PersonalTransaction(
        id=data.id,
        user_id=user_id,
        tx_type=movement,
        amount=amount,
        currency=data.currency.upper() if data.currency else "SAR",
        category=data.category.strip(),
        description=data.description,
        bank_account_id=account.id if account is not None else None,
        budget_id=budget_uuid,
        budget_category_id=budget_cat_uuid,
        goal_id=goal_uuid,
        debt_id=debt_uuid,
        payment_method=data.payment_method,
        date=tx_date or datetime.now(timezone.utc),
        exchange_rate=Decimal(str(data.exchange_rate)) if data.exchange_rate is not None else None,
        exchange_rate_currency=(data.exchange_rate_currency or "").upper() if data.exchange_rate_currency else None,
        fx_source=data.fx_source or ("api" if data.exchange_rate is not None else None),
        client_operation_id=op_key,
        goal_amount=(
            Decimal(str(data.goal_amount)) if data.goal_amount is not None else None
        ) if goal_uuid is not None else None,
    )
    if account is not None:
        current = Decimal(account.balance or 0)
        if movement == "income":
            account.balance = current + amount
        else:
            account.balance = current - amount
    # Goal credit moves with the transaction (creation side of the exact
    # reversal performed on delete). goal_amount allows cross-currency credit.
    if goal_row is not None:
        credited = (
            Decimal(str(data.goal_amount))
            if data.goal_amount is not None
            else amount
        )
        goal_row.current_amount = Decimal(str(goal_row.current_amount or 0)) + credited
        if float(goal_row.current_amount) >= float(goal_row.target_amount or 0):
            goal_row.is_completed = True
    # A debt-linked transaction IS a payment record: create it so paid totals
    # (derived server-side from payments) stay exact.
    payment_row = None
    if debt_row is not None:
        payment_row = PersonalDebtPayment(
            debt_id=debt_row.id,
            user_id=user_id,
            amount=amount,
            currency=debt_row.currency or "SAR",
            payment_date=tx.date,
            notes=data.description,
            budget_id=getattr(debt_row, "budget_id", None),
        )
        existing_paid = sum(
            float(p.amount or 0) for p in (await db.execute(
                select(PersonalDebtPayment).where(
                    PersonalDebtPayment.debt_id == debt_row.id,
                    PersonalDebtPayment.is_deleted == False,
                )
            )).scalars().all()
        )
        if existing_paid + float(amount) >= float(debt_row.amount or 0):
            debt_row.is_paid = True
            debt_row.paid_date = (tx.date or datetime.now(timezone.utc)).date()
    # Budget spent maintenance (expense only), mirroring the client display.
    if budget_row is not None and movement == "expense":
        budget_row.spent = Decimal(str(budget_row.spent or 0)) + amount
        if budget_row.total_amount is None and budget_row.amount is None:
            pass
    db.add(tx)
    if payment_row is not None:
        db.add(payment_row)
    # Atomic commit. A duplicate client UUID (concurrent replay of the same
    # offline intent) rolls back and returns the already-created row.
    try:
        await db.commit()
    except IntegrityError:
        await db.rollback()
        existing = await _client_uuid_existing(db, PersonalTransaction, data.id, user_id)
        if existing is not None:
            return created(data={**_tx_to_dict(existing), "deduped": True},
                           message="تم إنشاء المعاملة")
        raise
    await db.refresh(tx)

    # Record in the sync ledger so OTHER devices see this change on pull.
    org_id = await _user_org_id(db, user_id)
    await record_entity_version(
        db, org_id, user_id, "personal_transaction", tx.id,
        _tx_to_dict(tx), operation_id=f"crud_{tx.id}",
    )
    # The ACCOUNT balance moved with this transaction: other devices must
    # receive the new derived balance through their incremental pull.
    if account is not None and movement != 0:
        await record_entity_version(
            db, org_id, user_id, "personal_bank_account", account.id,
            _account_to_dict(account), operation_id=f"crud_tx_acct_{tx.id}",
            deleted=bool(getattr(account, "is_deleted", False)),
        )
    if goal_row is not None:
        await record_entity_version(
            db, org_id, user_id, "personal_savings_goal", goal_row.id,
            _goal_to_dict(goal_row), operation_id=f"crud_tx_goal_{tx.id}",
            deleted=bool(getattr(goal_row, "is_deleted", False)),
        )
    if debt_row is not None:
        await record_entity_version(
            db, org_id, user_id, "personal_debt", debt_row.id,
            await _debt_to_dict(debt_row, db), operation_id=f"crud_tx_debt_{tx.id}",
            deleted=bool(getattr(debt_row, "is_deleted", False)),
        )
    if budget_row is not None:
        await record_entity_version(
            db, org_id, user_id, "personal_budget", budget_row.id,
            _budget_to_dict(budget_row), operation_id=f"crud_tx_budget_{tx.id}",
            deleted=bool(getattr(budget_row, "is_deleted", False)),
        )
    await db.commit()

    return created(data=_tx_to_dict(tx), message="تم إنشاء المعاملة")


@router.patch("/personal/finance/transactions/{tx_id}", summary="Update transaction")
async def update_my_transaction(
    tx_id: UUID,
    data: PersonalTransactionUpdate,
    request: Request,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "update")),
):
    replay = _is_replay(request)
    result = await db.execute(
        select(PersonalTransaction).where(
            PersonalTransaction.id == tx_id,
            PersonalTransaction.user_id == user_id,
            PersonalTransaction.is_deleted == False,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="المعاملة غير موجودة")

    # Capture the PRE-EDIT state — the goal/debt/budget deltas are computed
    # from the difference between old and new values.
    old_type = row.tx_type
    old_amount = Decimal(row.amount)
    old_goal_id = getattr(row, "goal_id", None)
    old_budget_id = getattr(row, "budget_id", None)
    old_debt_id = getattr(row, "debt_id", None)

    new_type = row.tx_type
    if data.tx_type is not None:
        if data.tx_type not in VALID_TX_TYPES:
            raise HTTPException(status_code=422, detail="نوع المعاملة غير صالح")
        new_type = SEMANTIC_TX_TYPE[data.tx_type]
    new_amount = Decimal(row.amount)
    if data.amount is not None:
        new_amount = Decimal(str(data.amount))

    # Adjust the linked account balance: reverse the old movement, then apply
    # the new one, so the balance always stays consistent with the data.
    account = None
    if row.bank_account_id:
        account = (await db.execute(
            select(PersonalBankAccount).where(
                PersonalBankAccount.id == row.bank_account_id,
                PersonalBankAccount.user_id == user_id,
            )
        )).scalar_one_or_none()
    if account is not None:
        current = Decimal(account.balance or 0)
        if old_type == "income":
            current -= old_amount
        else:
            current += old_amount
        if not replay and new_type == "expense" and current < new_amount:
            raise HTTPException(status_code=400, detail="لا يوجد مبلغ كافٍ لتسجيل عملية مصروف")
        if new_type == "income":
            account.balance = current + new_amount
        else:
            account.balance = current - new_amount

    row.tx_type = new_type
    row.amount = new_amount
    if data.category is not None: row.category = data.category.strip()
    if data.description is not None: row.description = data.description
    if data.currency is not None: row.currency = data.currency.upper()
    if data.payment_method is not None: row.payment_method = data.payment_method
    if data.exchange_rate is not None: row.exchange_rate = Decimal(str(data.exchange_rate))
    if data.exchange_rate_currency is not None: row.exchange_rate_currency = data.exchange_rate_currency.upper()
    if data.fx_source is not None: row.fx_source = data.fx_source
    if data.date is not None:
        try:
            row.date = datetime.fromisoformat(data.date)
        except ValueError:
            raise HTTPException(status_code=422, detail="تاريخ غير صالح")
    # Budget relations are updatable; empty string clears the link.
    for field, column in (
        ("budget_id", "budget_id"),
        ("budget_category_id", "budget_category_id"),
        ("goal_id", "goal_id"),
        ("debt_id", "debt_id"),
    ):
        raw = getattr(data, field)
        if raw is not None:
            if raw == "":
                setattr(row, column, None)
            else:
                try:
                    setattr(row, column, UUID(raw))
                except ValueError:
                    raise HTTPException(status_code=400, detail=f"معرف غير صالح: {field}")
    if data.bank_account_id is not None:
        if data.bank_account_id == "":
            row.bank_account_id = None
        else:
            try:
                row.bank_account_id = UUID(data.bank_account_id)
            except ValueError:
                raise HTTPException(status_code=400, detail="معرف الحساب البنكي غير صالح")
    # ── Derived-state deltas ──────────────────────────────────────────────
    # Goal: reverse the OLD credit and apply the NEW one (exact, even when the
    # transaction is re-linked to another goal). The credit is the stored
    # `goal_amount` for cross-currency contributions, else the tx amount.
    touched = {"goals": [], "debts": [], "budgets": []}
    new_goal_id = getattr(row, "goal_id", None)
    if old_goal_id or new_goal_id:
        if old_goal_id:
            old_goal = (await db.execute(
                select(PersonalSavingsGoal).where(
                    PersonalSavingsGoal.id == old_goal_id,
                    PersonalSavingsGoal.user_id == user_id,
                )
            )).scalar_one_or_none()
            if old_goal is not None:
                old_credit = (
                    Decimal(str(getattr(row, "goal_amount", None)))
                    if getattr(row, "goal_amount", None) is not None
                    else old_amount
                )
                old_goal.current_amount = max(
                    Decimal("0"),
                    Decimal(str(old_goal.current_amount or 0)) - old_credit,
                )
                touched["goals"].append(old_goal)
        if new_goal_id:
            new_goal = (await db.execute(
                select(PersonalSavingsGoal).where(
                    PersonalSavingsGoal.id == new_goal_id,
                    PersonalSavingsGoal.user_id == user_id,
                )
            )).scalar_one_or_none()
            if new_goal is not None:
                new_credit = (
                    Decimal(str(getattr(row, "goal_amount", None)))
                    if getattr(row, "goal_amount", None) is not None
                    else new_amount
                )
                new_goal.current_amount = Decimal(
                    str(new_goal.current_amount or 0)) + new_credit
                if float(new_goal.current_amount) >= float(new_goal.target_amount or 0):
                    new_goal.is_completed = True
                if new_goal not in touched["goals"]:
                    touched["goals"].append(new_goal)

    # Debt: keep the matching payment record exact when amount/debt changes.
    # The payment is matched by the stored debt credit (goals-style), not
    # the raw tx amount — they differ for cross-currency payments.
    new_debt_id = getattr(row, "debt_id", None)
    if old_debt_id:
        old_match = getattr(row, "debt_amount", None) or old_amount
        old_pay = (await db.execute(
            select(PersonalDebtPayment).where(
                PersonalDebtPayment.debt_id == old_debt_id,
                PersonalDebtPayment.user_id == user_id,
                PersonalDebtPayment.is_deleted == False,
                PersonalDebtPayment.amount == old_match,
            ).order_by(PersonalDebtPayment.created_at.desc()).limit(1)
        )).scalar_one_or_none()
        if old_pay is not None:
            if new_debt_id == old_debt_id and new_amount != old_amount:
                # Same-currency payments track the edited amount; a stored
                # cross-currency credit stays fixed (goals-style: the credit
                # is fixed at execution time).
                if getattr(row, "debt_amount", None) is None:
                    old_pay.amount = new_amount
                touched["debts"].append(old_debt_id)
            elif new_debt_id != old_debt_id:
                await db.delete(old_pay)
                touched["debts"].append(old_debt_id)
    if new_debt_id and new_debt_id != old_debt_id:
        db.add(PersonalDebtPayment(
            debt_id=new_debt_id,
            user_id=user_id,
            amount=new_amount,
            currency=row.currency or "SAR",
            payment_date=row.date or datetime.now(timezone.utc),
            notes=row.description,
        ))
        touched["debts"].append(new_debt_id)
    # Recompute is_paid for every touched debt from its payment records.
    for debt_id in {d for d in touched["debts"] if d is not None}:
        debt = (await db.execute(
            select(PersonalDebt).where(PersonalDebt.id == debt_id)
        )).scalar_one_or_none()
        if debt is None:
            continue
        await db.flush()
        paid_total = sum(
            float(p.amount or 0) for p in (await db.execute(
                select(PersonalDebtPayment).where(
                    PersonalDebtPayment.debt_id == debt_id,
                    PersonalDebtPayment.is_deleted == False,
                )
            )).scalars().all()
        )
        if paid_total >= float(debt.amount or 0):
            debt.is_paid = True
            if debt.paid_date is None:
                debt.paid_date = datetime.now(timezone.utc).date()
        else:
            debt.is_paid = False
            debt.paid_date = None

    # Budget spent: reverse the old expense, apply the new one.
    new_budget_id = getattr(row, "budget_id", None)
    if old_budget_id and old_type == "expense":
        old_budget = (await db.execute(
            select(PersonalBudget).where(
                PersonalBudget.id == old_budget_id,
                PersonalBudget.user_id == user_id,
            )
        )).scalar_one_or_none()
        if old_budget is not None:
            old_budget.spent = max(
                Decimal("0"),
                Decimal(str(old_budget.spent or 0)) - old_amount,
            )
            touched["budgets"].append(old_budget)
    if new_budget_id and new_type == "expense":
        new_budget = (await db.execute(
            select(PersonalBudget).where(
                PersonalBudget.id == new_budget_id,
                PersonalBudget.user_id == user_id,
            )
        )).scalar_one_or_none()
        if new_budget is not None and new_budget not in touched["budgets"]:
            new_budget.spent = Decimal(str(new_budget.spent or 0)) + new_amount
            touched["budgets"].append(new_budget)
        elif new_budget is not None:
            new_budget.spent = Decimal(str(new_budget.spent or 0)) + new_amount

    await db.commit()
    await db.refresh(row)
    org_id = await _user_org_id(db, user_id)
    await record_entity_version(
        db, org_id, user_id, "personal_transaction", row.id,
        _tx_to_dict(row), operation_id=f"crud_upd_{row.id}",
    )
    if account is not None:
        await record_entity_version(
            db, org_id, user_id, "personal_bank_account", account.id,
            _account_to_dict(account), operation_id=f"crud_upd_tx_acct_{row.id}",
            deleted=bool(getattr(account, "is_deleted", False)),
        )
    for goal in touched["goals"]:
        await record_entity_version(
            db, org_id, user_id, "personal_savings_goal", goal.id,
            _goal_to_dict(goal), operation_id=f"crud_upd_tx_goal_{row.id}",
            deleted=bool(getattr(goal, "is_deleted", False)),
        )
    for budget in touched["budgets"]:
        await record_entity_version(
            db, org_id, user_id, "personal_budget", budget.id,
            _budget_to_dict(budget), operation_id=f"crud_upd_tx_budget_{row.id}",
            deleted=bool(getattr(budget, "is_deleted", False)),
        )
    for debt_id in {d for d in touched["debts"] if d is not None}:
        debt = (await db.execute(
            select(PersonalDebt).where(PersonalDebt.id == debt_id)
        )).scalar_one_or_none()
        if debt is not None:
            await record_entity_version(
                db, org_id, user_id, "personal_debt", debt.id,
                await _debt_to_dict(debt, db), operation_id=f"crud_upd_tx_debt_{row.id}",
                deleted=bool(getattr(debt, "is_deleted", False)),
            )
    await db.commit()
    return ok(data=_tx_to_dict(row))


@router.delete("/personal/finance/transactions/{tx_id}", summary="Delete transaction")
async def delete_my_transaction(
    tx_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "delete")),
):
    result = await db.execute(
        select(PersonalTransaction).where(
            PersonalTransaction.id == tx_id,
            PersonalTransaction.user_id == user_id,
            PersonalTransaction.is_deleted == False,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="المعاملة غير موجودة")

    # Deleting a transaction reverses its effect on the linked account balance
    # immediately (income credits are subtracted back, expenses debits are
    # added back). This applies to the cash (كاش) account as well.
    touched_account = None
    if row.bank_account_id:
        account = (await db.execute(
            select(PersonalBankAccount).where(
                PersonalBankAccount.id == row.bank_account_id,
                PersonalBankAccount.user_id == user_id,
            )
        )).scalar_one_or_none()
        if account:
            touched_account = account
            current = Decimal(account.balance or 0)
            if row.tx_type == "income":
                account.balance = current - Decimal(row.amount)
            else:
                account.balance = current + Decimal(row.amount)

    # Keep linked records consistent on delete (single delete path):
    # - goal contribution tx → decrement goal.current_amount.
    # - debt payment tx → delete the matching payment row so paid totals stay correct.
    if getattr(row, "goal_id", None):
        goal = (await db.execute(
            select(PersonalSavingsGoal).where(
                PersonalSavingsGoal.id == row.goal_id,
                PersonalSavingsGoal.user_id == user_id,
            )
        )).scalar_one_or_none()
        if goal is not None:
            # Reverse the EXACT credited amount (goal_amount), not the raw
            # tx amount — they differ for cross-currency contributions.
            # The completion flag follows the real state back down, exactly
            # mirroring the contribute path that sets it on completion.
            credited = getattr(row, "goal_amount", None) or row.amount
            goal.current_amount = max(
                Decimal("0"),
                Decimal(str(goal.current_amount or 0)) - Decimal(str(credited or 0)),
            )
            target = float(goal.target_amount or 0)
            goal.is_completed = bool(
                target > 0 and float(goal.current_amount or 0) >= target
            )
    tx_id = row.id
    if getattr(row, "debt_id", None):
        # Match the payment by the EXACT credited amount (debt_amount), not
        # the raw tx amount — they differ for cross-currency payments.
        match_amount = getattr(row, "debt_amount", None) or row.amount
        pay = (await db.execute(
            select(PersonalDebtPayment).where(
                PersonalDebtPayment.debt_id == row.debt_id,
                PersonalDebtPayment.user_id == user_id,
                PersonalDebtPayment.is_deleted == False,
                PersonalDebtPayment.amount == match_amount,
            ).order_by(PersonalDebtPayment.created_at.desc()).limit(1)
        )).scalar_one_or_none()
        if pay is not None:
            await db.delete(pay)
        # A debt that is no longer fully paid must not stay marked as paid.
        debt = (await db.execute(
            select(PersonalDebt).where(PersonalDebt.id == row.debt_id)
        )).scalar_one_or_none()
        if debt is not None:
            await db.flush()
            paid_total = sum(
                float(p.amount or 0) for p in (await db.execute(
                    select(PersonalDebtPayment).where(
                        PersonalDebtPayment.debt_id == debt.id,
                        PersonalDebtPayment.is_deleted == False,
                    )
                )).scalars().all()
            )
            if paid_total < float(debt.amount or 0):
                debt.is_paid = False
                debt.paid_date = None
    # Budget spent is reduced by the deleted expense.
    budget_row = None
    if getattr(row, "budget_id", None) and row.tx_type == "expense":
        budget_row = (await db.execute(
            select(PersonalBudget).where(PersonalBudget.id == row.budget_id)
        )).scalar_one_or_none()
        if budget_row is not None:
            budget_row.spent = max(
                Decimal("0"),
                Decimal(str(budget_row.spent or 0)) - Decimal(row.amount),
            )
    # HARD DELETE: remove the row entirely so the app and its data revert to
    # the pre-operation state (no soft-deleted residue anywhere).
    await db.delete(row)
    await db.commit()
    org_id = await _user_org_id(db, user_id)
    await record_entity_version(
        db, org_id, user_id, "personal_transaction", tx_id,
        {"id": str(tx_id), "deleted_at": datetime.now(timezone.utc).isoformat()},
        deleted=True, operation_id=f"crud_del_{tx_id}",
    )
    if touched_account is not None:
        await record_entity_version(
            db, org_id, user_id, "personal_bank_account", touched_account.id,
            _account_to_dict(touched_account), operation_id=f"crud_del_tx_acct_{tx_id}",
            deleted=bool(getattr(touched_account, "is_deleted", False)),
        )
    if budget_row is not None:
        await record_entity_version(
            db, org_id, user_id, "personal_budget", budget_row.id,
            _budget_to_dict(budget_row), operation_id=f"crud_del_tx_budget_{tx_id}",
        )
    await db.commit()
    return no_content(message="تم حذف المعاملة")


# ── Savings Goals ──


@router.get("/personal/finance/goals", summary="List my savings goals")
async def list_my_goals(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "read")),
):
    result = await db.execute(
        select(PersonalSavingsGoal).where(
            PersonalSavingsGoal.user_id == user_id,
            PersonalSavingsGoal.is_deleted == False,
        ).order_by(PersonalSavingsGoal.is_completed, PersonalSavingsGoal.created_at.desc())
    )
    return ok(data=[_goal_to_dict(g) for g in result.scalars().all()])


@router.post("/personal/finance/goals", status_code=status.HTTP_201_CREATED, summary="Create savings goal")
async def create_my_goal(
    data: PersonalGoalCreate,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "create")),
):
    deadline = None
    if data.deadline:
        try:
            deadline = datetime.fromisoformat(data.deadline).date()
        except ValueError:
            raise HTTPException(status_code=422, detail="تاريخ غير صالح")
    goal_budget = None
    if data.budget_id:
        try:
            goal_budget = UUID(data.budget_id)
        except ValueError:
            raise HTTPException(status_code=400, detail="معرف الميزانية غير صالح")
        b_exists = (await db.execute(
            select(PersonalBudget.id).where(
                PersonalBudget.id == goal_budget,
                PersonalBudget.user_id == user_id,
                PersonalBudget.is_deleted == False,
            )
        )).scalar_one_or_none()
        if not b_exists:
            raise HTTPException(status_code=400, detail="الميزانية غير موجودة")
    goal = PersonalSavingsGoal(
        id=data.id,
        user_id=user_id,
        name=data.name.strip(),
        target_amount=Decimal(str(data.target_amount)),
        current_amount=Decimal(str(data.current_amount)),
        currency=data.currency or "SAR",
        deadline=deadline,
        icon=data.icon or "SAVINGS",
        notes=data.notes,
        budget_id=goal_budget,
    )
    db.add(goal)
    duplicate = await _commit_or_dedupe(db, PersonalSavingsGoal, data.id, user_id)
    if duplicate is not None:
        return created(data=_goal_to_dict(duplicate), message="تم إنشاء الهدف")
    await db.refresh(goal)
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_savings_goal", goal.id,
        _goal_to_dict(goal), operation_id=f"crud_{goal.id}",
    )
    await db.commit()
    return created(data=_goal_to_dict(goal), message="تم إنشاء الهدف")


@router.patch("/personal/finance/goals/{goal_id}", summary="Update savings goal")
async def update_my_goal(
    goal_id: UUID,
    data: PersonalGoalUpdate,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "update")),
):
    result = await db.execute(
        select(PersonalSavingsGoal).where(
            PersonalSavingsGoal.id == goal_id,
            PersonalSavingsGoal.user_id == user_id,
            PersonalSavingsGoal.is_deleted == False,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="الهدف غير موجود")
    if data.name is not None: row.name = data.name.strip()
    if data.target_amount is not None: row.target_amount = Decimal(str(data.target_amount))
    if data.current_amount is not None: row.current_amount = Decimal(str(data.current_amount))
    if data.deadline is not None:
        try:
            row.deadline = datetime.fromisoformat(data.deadline).date() if data.deadline else None
        except ValueError:
            raise HTTPException(status_code=422, detail="تاريخ غير صالح")
    if data.icon is not None: row.icon = data.icon
    if data.notes is not None: row.notes = data.notes
    if data.is_completed is not None: row.is_completed = data.is_completed
    if data.budget_id is not None:
        if data.budget_id == "":
            row.budget_id = None
        else:
            try:
                new_b = UUID(data.budget_id)
            except ValueError:
                raise HTTPException(status_code=400, detail="معرف الميزانية غير صالح")
            b_exists = (await db.execute(
                select(PersonalBudget.id).where(
                    PersonalBudget.id == new_b,
                    PersonalBudget.user_id == user_id,
                    PersonalBudget.is_deleted == False,
                )
            )).scalar_one_or_none()
            if not b_exists:
                raise HTTPException(status_code=400, detail="الميزانية غير موجودة")
            row.budget_id = new_b
    if float(row.current_amount or 0) >= float(row.target_amount or 0):
        row.is_completed = True
    await db.commit()
    await db.refresh(row)
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_savings_goal", row.id,
        _goal_to_dict(row), operation_id=f"crud_upd_{row.id}",
    )
    await db.commit()
    return ok(data=_goal_to_dict(row))


@router.post("/personal/finance/goals/{goal_id}/contribute", summary="Add amount to savings goal")
async def contribute_to_goal(
    goal_id: UUID,
    data: PersonalGoalContribute,
    request: Request,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "update")),
):
    replay = _is_replay(request)
    result = await db.execute(
        select(PersonalSavingsGoal).where(
            PersonalSavingsGoal.id == goal_id,
            PersonalSavingsGoal.user_id == user_id,
        )
    )
    row = result.scalar_one_or_none()
    if not row or (row.is_deleted and not replay):
        raise HTTPException(status_code=404, detail="الهدف غير موجود")
    # ── Idempotency: repeated contributes with the same key return the
    # original goal state + contribution tx instead of duplicating.
    op_key = (data.client_operation_id or "").strip() or None
    if op_key:
        dup = (await db.execute(
            select(PersonalTransaction).where(
                PersonalTransaction.user_id == user_id,
                PersonalTransaction.client_operation_id == op_key,
                PersonalTransaction.is_deleted == False,
            )
        )).scalar_one_or_none()
        if dup is not None:
            return ok(data={**_goal_to_dict(row), "contribution_tx": _tx_to_dict(dup), "deduped": True})
    tx_amount = Decimal(str(data.amount))
    goal_credit = Decimal(str(data.goal_amount)) if data.goal_amount else tx_amount
    tx_currency = (data.currency or row.currency or "SAR").upper()
    # Resolve the source account (explicit or cash), same rule as debt payments.
    account = None
    if data.bank_account_id:
        try:
            acc_uuid = UUID(data.bank_account_id)
        except ValueError:
            raise HTTPException(status_code=400, detail="معرف الحساب البنكي غير صالح")
        # Row-level lock: concurrent double-taps serialize here so the
        # balance check below can never pass twice on the same funds.
        acc_q = select(PersonalBankAccount).where(
            PersonalBankAccount.id == acc_uuid,
            PersonalBankAccount.user_id == user_id,
        )
        if not replay:
            acc_q = acc_q.where(PersonalBankAccount.is_deleted == False)
        account = (await db.execute(acc_q.with_for_update())).scalar_one_or_none()
        if not account:
            raise HTTPException(status_code=400, detail="الحساب البنكي غير موجود")
    else:
        account = await _ensure_cash_account(db, user_id, currency=tx_currency)
    if not replay and account is not None and Decimal(account.balance or 0) < tx_amount:
        raise HTTPException(status_code=400, detail="الرصيد غير كافٍ في الحساب المختار")
    row.current_amount = Decimal(str(row.current_amount or 0)) + goal_credit
    if float(row.current_amount) >= float(row.target_amount or 0):
        row.is_completed = True
    # Record the contribution as a real transaction linked by IDs:
    # goal_id = G, budget_id = B (from goal.budget_id). No name matching.
    contrib_tx = PersonalTransaction(
        id=data.tx_id,
        user_id=user_id,
        tx_type="expense",
        amount=tx_amount,
        currency=tx_currency,
        category=data.category or f"ادخار - {row.name}",
        description=data.description or f"مساهمة في هدف {row.name}",
        bank_account_id=account.id if account is not None else None,
        budget_id=getattr(row, "budget_id", None),
        budget_category_id=None,
        goal_id=row.id,
        debt_id=None,
        goal_amount=goal_credit,
        payment_method=data.payment_method or "cash",
        date=datetime.now(timezone.utc),
        client_operation_id=op_key,
    )
    if account is not None:
        account.balance = Decimal(account.balance or 0) - tx_amount
    # Budget spent follows the contribution expense (same as a normal expense).
    budget_row = None
    if getattr(row, "budget_id", None):
        budget_row = (await db.execute(
            select(PersonalBudget).where(PersonalBudget.id == row.budget_id)
        )).scalar_one_or_none()
        if budget_row is not None:
            budget_row.spent = Decimal(str(budget_row.spent or 0)) + tx_amount
    db.add(contrib_tx)
    try:
        await db.commit()
    except IntegrityError:
        await db.rollback()
        existing = await _client_uuid_existing(
            db, PersonalTransaction, data.tx_id, user_id)
        if existing is not None:
            row = (await db.execute(
                select(PersonalSavingsGoal).where(
                    PersonalSavingsGoal.id == goal_id,
                    PersonalSavingsGoal.user_id == user_id,
                )
            )).scalar_one_or_none()
            return ok(data={**_goal_to_dict(row), "contribution_tx": _tx_to_dict(existing), "deduped": True})
        raise
    await db.refresh(row)
    await db.refresh(contrib_tx)
    org_id = await _user_org_id(db, user_id)
    await record_entity_version(
        db, org_id, user_id, "personal_savings_goal", row.id,
        _goal_to_dict(row), operation_id=f"crud_contrib_{row.id}",
        deleted=bool(getattr(row, "is_deleted", False)),
    )
    await record_entity_version(
        db, org_id, user_id, "personal_transaction", contrib_tx.id,
        _tx_to_dict(contrib_tx), operation_id=f"crud_contrib_tx_{contrib_tx.id}",
    )
    if account is not None:
        await record_entity_version(
            db, org_id, user_id, "personal_bank_account", account.id,
            _account_to_dict(account), operation_id=f"crud_contrib_acct_{contrib_tx.id}",
            deleted=bool(getattr(account, "is_deleted", False)),
        )
    if budget_row is not None:
        await record_entity_version(
            db, org_id, user_id, "personal_budget", budget_row.id,
            _budget_to_dict(budget_row), operation_id=f"crud_contrib_budget_{row.id}",
            deleted=bool(getattr(budget_row, "is_deleted", False)),
        )
    await db.commit()
    return ok(data={**_goal_to_dict(row), "contribution_tx": _tx_to_dict(contrib_tx)})


@router.delete("/personal/finance/goals/{goal_id}", summary="Delete savings goal")
async def delete_my_goal(
    goal_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "delete")),
):
    result = await db.execute(
        select(PersonalSavingsGoal).where(
            PersonalSavingsGoal.id == goal_id,
            PersonalSavingsGoal.user_id == user_id,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="الهدف غير موجود")
    row.is_deleted = True
    row.deleted_at = datetime.now(timezone.utc)
    await db.commit()
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_savings_goal", row.id,
        {"id": str(row.id), "deleted_at": row.deleted_at.isoformat()},
        deleted=True, operation_id=f"crud_del_{row.id}",
    )
    await db.commit()
    return no_content(message="تم حذف الهدف")


# ── Debts ──


@router.get("/personal/finance/debts", summary="List my debts")
async def list_my_debts(
    debt_type: Optional[str] = Query(None),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "read")),
):
    query = select(PersonalDebt).where(
        PersonalDebt.user_id == user_id,
        PersonalDebt.is_deleted == False,
    )
    if debt_type:
        query = query.where(PersonalDebt.debt_type == debt_type)
    result = await db.execute(query.order_by(PersonalDebt.is_paid, PersonalDebt.due_date))
    debts = result.scalars().all()
    # Batch fetch payments to avoid N+1
    if debts:
        debt_ids = [d.id for d in debts]
        pay_rows = (await db.execute(
            select(PersonalDebtPayment.debt_id, func.coalesce(func.sum(PersonalDebtPayment.amount), 0))
            .where(PersonalDebtPayment.debt_id.in_(debt_ids), PersonalDebtPayment.is_deleted == False)
            .group_by(PersonalDebtPayment.debt_id)
        )).all()
        paid_map = {r[0]: float(r[1] or 0) for r in pay_rows}
    else:
        paid_map = {}
    return ok(data=[await _debt_to_dict(d, None, paid_map.get(d.id, 0)) for d in debts])


@router.post("/personal/finance/debts", status_code=status.HTTP_201_CREATED, summary="Create debt")
async def create_my_debt(
    data: PersonalDebtCreate,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "create")),
):
    if data.debt_type not in VALID_DEBT_TYPES:
        raise HTTPException(status_code=422, detail="نوع الدين غير صالح")
    due_date = None
    if data.due_date:
        try:
            due_date = datetime.fromisoformat(data.due_date).date()
        except ValueError:
            raise HTTPException(status_code=422, detail="تاريخ غير صالح")
    debt_budget = None
    if data.budget_id:
        try:
            debt_budget = UUID(data.budget_id)
        except ValueError:
            raise HTTPException(status_code=400, detail="معرف الميزانية غير صالح")
        b_exists = (await db.execute(
            select(PersonalBudget.id).where(
                PersonalBudget.id == debt_budget,
                PersonalBudget.user_id == user_id,
                PersonalBudget.is_deleted == False,
            )
        )).scalar_one_or_none()
        if not b_exists:
            raise HTTPException(status_code=400, detail="الميزانية غير موجودة")
    debt = PersonalDebt(
        id=data.id,
        user_id=user_id,
        debt_type=data.debt_type,
        person_name=data.person_name.strip(),
        amount=Decimal(str(data.amount)),
        currency=data.currency or "SAR",
        description=data.description,
        due_date=due_date,
        reminder=bool(data.reminder) if hasattr(data, "reminder") else False,
        budget_id=debt_budget,
    )
    db.add(debt)
    duplicate = await _commit_or_dedupe(db, PersonalDebt, data.id, user_id)
    if duplicate is not None:
        return created(data=await _debt_to_dict(duplicate, db), message="تم إنشاء الدين")
    await db.refresh(debt)
    # Record in the sync ledger so OTHER devices see this debt on pull.
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_debt", debt.id,
        await _debt_to_dict(debt, db), operation_id=f"crud_{debt.id}",
    )
    await db.commit()
    return created(data=await _debt_to_dict(debt, db), message="تم إنشاء الدين")


@router.patch("/personal/finance/debts/{debt_id}", summary="Update debt")
async def update_my_debt(
    debt_id: UUID,
    data: PersonalDebtUpdate,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "update")),
):
    result = await db.execute(
        select(PersonalDebt).where(
            PersonalDebt.id == debt_id,
            PersonalDebt.user_id == user_id,
            PersonalDebt.is_deleted == False,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="الدين غير موجود")
    if data.debt_type is not None:
        if data.debt_type not in VALID_DEBT_TYPES:
            raise HTTPException(status_code=422, detail="نوع الدين غير صالح")
        row.debt_type = data.debt_type
    if data.person_name is not None: row.person_name = data.person_name.strip()
    if data.amount is not None: row.amount = Decimal(str(data.amount))
    if data.currency is not None: row.currency = data.currency
    if data.description is not None: row.description = data.description
    if data.due_date is not None:
        try:
            row.due_date = datetime.fromisoformat(data.due_date).date() if data.due_date else None
        except ValueError:
            raise HTTPException(status_code=422, detail="تاريخ غير صالح")
    if data.is_paid is not None:
        row.is_paid = data.is_paid
        row.paid_date = datetime.now(timezone.utc).date() if data.is_paid else None
    if data.reminder is not None:
        row.reminder = bool(data.reminder)
    if data.budget_id is not None:
        if data.budget_id == "":
            row.budget_id = None
        else:
            try:
                new_b = UUID(data.budget_id)
            except ValueError:
                raise HTTPException(status_code=400, detail="معرف الميزانية غير صالح")
            b_exists = (await db.execute(
                select(PersonalBudget.id).where(
                    PersonalBudget.id == new_b,
                    PersonalBudget.user_id == user_id,
                    PersonalBudget.is_deleted == False,
                )
            )).scalar_one_or_none()
            if not b_exists:
                raise HTTPException(status_code=400, detail="الميزانية غير موجودة")
            row.budget_id = new_b
    await db.commit()
    await db.refresh(row)
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_debt", row.id,
        await _debt_to_dict(row, db), operation_id=f"crud_upd_{row.id}",
    )
    await db.commit()
    return ok(data=await _debt_to_dict(row, db))


@router.delete("/personal/finance/debts/{debt_id}", summary="Delete debt")
async def delete_my_debt(
    debt_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "delete")),
):
    result = await db.execute(
        select(PersonalDebt).where(
            PersonalDebt.id == debt_id,
            PersonalDebt.user_id == user_id,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="الدين غير موجود")

    # --- Reverse all payments: restore bank account balances & delete transactions ---
    debt_type = row.debt_type
    touched_accounts: dict = {}
    deleted_tx_ids: set = set()
    payments = (await db.execute(
        select(PersonalDebtPayment).where(
            PersonalDebtPayment.debt_id == debt_id,
            PersonalDebtPayment.is_deleted == False,
        )
    )).scalars().all()

    for p in payments:
        # Prefer the EXACT linked transaction (debt_id + amount); fall back to
        # the legacy description match for rows created before the link.
        tx = (await db.execute(
            select(PersonalTransaction).where(
                PersonalTransaction.user_id == user_id,
                PersonalTransaction.debt_id == debt_id,
                PersonalTransaction.is_deleted == False,
                PersonalTransaction.amount == p.amount,
            ).order_by(PersonalTransaction.created_at.desc()).limit(1)
        )).scalar_one_or_none()
        if tx is None:
            tx_desc = p.notes or row.person_name
            tx_cat = "سداد دين" if debt_type == "payable" else "تحصيل دين"
            tx_result = await db.execute(
                select(PersonalTransaction).where(
                    PersonalTransaction.user_id == user_id,
                    PersonalTransaction.category == tx_cat,
                    PersonalTransaction.description == tx_desc,
                    PersonalTransaction.is_deleted == False,
                ).order_by(PersonalTransaction.created_at.desc()).limit(1)
            )
            tx = tx_result.scalar_one_or_none()

        if tx and tx.bank_account_id:
            acc_result = await db.execute(
                select(PersonalBankAccount).where(
                    PersonalBankAccount.id == tx.bank_account_id,
                    PersonalBankAccount.user_id == user_id,
                )
            )
            acc = acc_result.scalar_one_or_none()
            if acc:
                pay_amount = Decimal(str(p.amount or 0))
                current_bal = Decimal(acc.balance or 0)
                if debt_type == "payable":
                    acc.balance = current_bal + pay_amount
                else:
                    acc.balance = current_bal - pay_amount
                if not acc.is_deleted:
                    touched_accounts[acc.id] = acc

        if tx:
            tx.is_deleted = True
            tx.deleted_at = datetime.now(timezone.utc)
            deleted_tx_ids.add(tx.id)

        p.is_deleted = True

    # --- Soft-delete the debt ---
    row.is_deleted = True
    row.deleted_at = datetime.now(timezone.utc)
    await db.commit()
    org_id = await _user_org_id(db, user_id)
    await record_entity_version(
        db, org_id, user_id, "personal_debt", row.id,
        await _debt_to_dict(row, db), deleted=True, operation_id=f"crud_del_{row.id}",
    )
    # Payments and their transactions must disappear on EVERY device.
    for tx_id in deleted_tx_ids:
        await record_entity_version(
            db, org_id, user_id, "personal_transaction", tx_id,
            {"id": str(tx_id), "deleted_at": datetime.now(timezone.utc).isoformat()},
            deleted=True, operation_id=f"crud_del_debt_tx_{tx_id}",
        )
    for acc in touched_accounts.values():
        await record_entity_version(
            db, org_id, user_id, "personal_bank_account", acc.id,
            _account_to_dict(acc), operation_id=f"crud_del_debt_acct_{row.id}",
            deleted=bool(getattr(acc, "is_deleted", False)),
        )
    await db.commit()
    return no_content(message="تم حذف الدين وإرجاع المبالغ")


@router.get("/personal/finance/debts/{debt_id}/payments", summary="List debt payments")
async def list_debt_payments(
    debt_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "read")),
):
    debt = (await db.execute(
        select(PersonalDebt).where(
            PersonalDebt.id == debt_id,
            PersonalDebt.user_id == user_id,
            PersonalDebt.is_deleted == False,
        )
    )).scalar_one_or_none()
    if not debt:
        raise HTTPException(status_code=404, detail="الدين غير موجود")
    result = await db.execute(
        select(PersonalDebtPayment).where(
            PersonalDebtPayment.debt_id == debt_id,
            PersonalDebtPayment.user_id == user_id,
            PersonalDebtPayment.is_deleted == False,
        ).order_by(PersonalDebtPayment.payment_date.desc())
    )
    return ok(data=[_payment_to_dict(p) for p in result.scalars().all()])


@router.post("/personal/finance/debts/{debt_id}/payments", status_code=status.HTTP_201_CREATED, summary="Record debt payment")
async def create_debt_payment(
    debt_id: UUID,
    data: PersonalDebtPaymentCreate,
    request: Request,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "create")),
):
    replay = _is_replay(request)
    debt_q = select(PersonalDebt).where(
        PersonalDebt.id == debt_id,
        PersonalDebt.user_id == user_id,
    )
    if not replay:
        debt_q = debt_q.where(PersonalDebt.is_deleted == False)
    debt = (await db.execute(debt_q)).scalar_one_or_none()
    if not debt:
        raise HTTPException(status_code=404, detail="الدين غير موجود")

    # ── Idempotency: repeated payments with the same key return the
    # original payment instead of duplicating it.
    op_key = (data.client_operation_id or "").strip() or None
    if op_key:
        dup = (await db.execute(
            select(PersonalTransaction).where(
                PersonalTransaction.user_id == user_id,
                PersonalTransaction.client_operation_id == op_key,
                PersonalTransaction.is_deleted == False,
            )
        )).scalar_one_or_none()
        if dup is not None:
            return created(data={**_tx_to_dict(dup), "deduped": True}, message="تم تسجيل السداد")
    # Idempotency 2: client-generated UUID of the linked transaction.
    existing_tx = await _client_uuid_existing(db, PersonalTransaction, data.tx_id, user_id)
    if existing_tx is not None:
        return created(data={**_tx_to_dict(existing_tx), "deduped": True}, message="تم تسجيل السداد")

    payment_date = None
    if data.payment_date:
        try:
            payment_date = datetime.fromisoformat(data.payment_date)
        except ValueError:
            raise HTTPException(status_code=422, detail="تاريخ غير صالح")

    # --- Bank account handling & balance update ---
    target_account = None
    amount_dec = Decimal(str(data.amount))
    if data.bank_account_id:
        try:
            acc_uuid = UUID(data.bank_account_id)
        except ValueError:
            raise HTTPException(status_code=400, detail="معرف الحساب البنكي غير صالح")
        # Row-level lock: concurrent double-taps serialize here so the
        # balance check below can never pass twice on the same funds.
        acc_q = select(PersonalBankAccount).where(
            PersonalBankAccount.id == acc_uuid,
            PersonalBankAccount.user_id == user_id,
        )
        if not replay:
            acc_q = acc_q.where(PersonalBankAccount.is_deleted == False)
        target_account = (await db.execute(acc_q.with_for_update())).scalar_one_or_none()
        if not target_account:
            raise HTTPException(status_code=400, detail="الحساب البنكي غير موجود")
    elif (data.payment_method or "cash") == "cash":
        # Require existing cash account; do not auto-create - user must have an account
        cash_q = select(PersonalBankAccount).where(PersonalBankAccount.user_id == user_id, PersonalBankAccount.bank_name.in_(CASH_ACCOUNT_NAMES))
        if not replay:
            cash_q = cash_q.where(PersonalBankAccount.is_deleted == False)
        cash_res = await db.execute(cash_q)
        target_account = cash_res.scalar_one_or_none()
        if not target_account:
            # No cash account exists
            raise HTTPException(status_code=400, detail="لا يوجد حساب لسداد المبلغ")
    else:
        raise HTTPException(status_code=400, detail="لا يوجد حساب لسداد المبلغ")
    if target_account is None:
        raise HTTPException(status_code=400, detail="لا يوجد حساب لسداد المبلغ")
    # Cross-currency payments (goals-style): the account moves `amount` in
    # the account currency, the debt is credited `debt_amount` in the debt
    # currency. Same-currency payments behave exactly as before.
    account_currency = (target_account.currency or "SAR").upper()
    debt_currency = (debt.currency or "SAR").upper()
    debt_credit = Decimal(str(data.debt_amount)) if data.debt_amount is not None else amount_dec
    tx_currency = ((data.currency or target_account.currency) or "SAR").upper()
    if True:
        current_bal = Decimal(target_account.balance or 0)
        if not replay and debt.debt_type == "payable" and current_bal < amount_dec:
            raise HTTPException(status_code=400, detail="الرصيد غير كافٍ في الحساب المختار لسداد هذا الدين")
        if debt.debt_type == "payable":
            target_account.balance = current_bal - amount_dec
        else:
            target_account.balance = current_bal + amount_dec
        tx = PersonalTransaction(
            id=data.tx_id,
            user_id=user_id,
            tx_type="expense" if debt.debt_type == "payable" else "income",
            amount=amount_dec,
            currency=tx_currency,
            category="سداد دين" if debt.debt_type == "payable" else "تحصيل دين",
            description=data.notes or debt.person_name,
            bank_account_id=target_account.id,
            budget_id=getattr(debt, "budget_id", None),
            budget_category_id=None,
            goal_id=None,
            debt_id=debt_id,
            debt_amount=debt_credit,
            payment_method=data.payment_method or "cash",
            date=payment_date or datetime.now(timezone.utc),
            client_operation_id=op_key,
        )
        db.add(tx)

    payment = PersonalDebtPayment(
        debt_id=debt_id,
        user_id=user_id,
        amount=debt_credit,
        currency=debt.currency or "SAR",
        payment_date=payment_date or datetime.now(timezone.utc),
        notes=data.notes,
        budget_id=getattr(debt, "budget_id", None),
    )

    paid_total = sum(
        float(p.amount or 0) for p in (await db.execute(
            select(PersonalDebtPayment).where(
                PersonalDebtPayment.debt_id == debt_id,
                PersonalDebtPayment.is_deleted == False,
            )
        )).scalars().all()
    ) + float(debt_credit)
    if paid_total >= float(debt.amount or 0):
        debt.is_paid = True
        debt.paid_date = datetime.now(timezone.utc).date()

    db.add(payment)

    try:
        await db.commit()
    except IntegrityError:
        await db.rollback()
        existing = await _client_uuid_existing(
            db, PersonalTransaction, data.tx_id, user_id)
        if existing is not None:
            return created(data={**_tx_to_dict(existing), "deduped": True}, message="تم تسجيل السداد")
        raise
    await db.refresh(payment)
    # Record debt + linked payment tx versions so OTHER devices sync them.
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_debt", debt.id,
        await _debt_to_dict(debt, db), operation_id=f"crud_pay_{debt.id}",
    )
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_transaction", tx.id,
        _tx_to_dict(tx), operation_id=f"crud_pay_tx_{tx.id}",
    )
    # Other devices must receive the moved account balance on pull.
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_bank_account",
        target_account.id, _account_to_dict(target_account),
        operation_id=f"crud_pay_acct_{tx.id}",
        deleted=bool(getattr(target_account, "is_deleted", False)),
    )
    await db.commit()
    return created(data=_payment_to_dict(payment), message="تم تسجيل الدفعة")


# ── Budgets ──


@router.get("/personal/finance/budgets", summary="List my budgets")
async def list_my_budgets(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "read")),
):
    result = await db.execute(
        select(PersonalBudget).where(
            PersonalBudget.user_id == user_id,
            PersonalBudget.is_deleted == False,
        ).order_by(PersonalBudget.created_at.desc())
    )
    budgets = result.scalars().all()

    # Load categories for all budgets
    budget_ids = [b.id for b in budgets]
    cats_map = {}
    if budget_ids:
        cats_result = await db.execute(
            select(PersonalBudgetCategory).where(
                PersonalBudgetCategory.budget_id.in_(budget_ids)
            )
        )
        for c in cats_result.scalars().all():
            cats_map.setdefault(str(c.budget_id), []).append(c)

    items = []
    for b in budgets:
        cats = cats_map.get(str(b.id), [])
        b._categories_loaded = [
            {"id": str(c.id), "budget_id": str(c.budget_id), "name": c.name, "type": c.type,
             "allocated_amount": float(c.allocated_amount) if c.allocated_amount else 0,
             "spent_amount": float(c.spent_amount) if c.spent_amount else 0,
             "currency": c.currency,
             "goal_id": str(c.goal_id) if getattr(c, "goal_id", None) else None,
             "debt_id": str(c.debt_id) if getattr(c, "debt_id", None) else None}
            for c in cats
        ]
        items.append(_budget_to_dict(b))

    return ok(data=items)


def _client_category_id(raw_id, taken: set) -> UUID:
    """Resolve a category id for create/update: honor the client-provided
    UUID when valid and unused (keeps offline transaction links valid after
    sync); otherwise mint a fresh one. Never raises, never reuses."""
    try:
        cid = UUID(str(raw_id)) if raw_id else None
    except (ValueError, TypeError, AttributeError):
        cid = None
    if cid is None or cid in taken:
        import uuid as _uuid_lib

        cid = _uuid_lib.uuid4()
    taken.add(cid)
    return cid


@router.post("/personal/finance/budgets", status_code=status.HTTP_201_CREATED, summary="Create budget")
async def create_my_budget(
    data: PersonalBudgetCreate,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "create")),
):
    # Idempotent replay: a retried offline create returns the same budget.
    existing = await _client_uuid_existing(db, PersonalBudget, data.id, user_id)
    if existing is not None:
        existing._categories_loaded = await _budget_categories_payload(db, existing.id)
        return created(data=_budget_to_dict(existing), message="تم إنشاء الميزانية")
    budget = PersonalBudget(
        id=data.id,
        user_id=user_id,
        name=data.name.strip(),
        total_amount=Decimal(str(data.amount)),
        amount=Decimal(str(data.amount)),
        period_type=data.period_type,
        currency=data.currency or "SAR",
        bank_account_ids=data.bank_account_ids or [],
        budget_types=data.budget_types or ["expenses"],
        custom_days=data.custom_days,
        start_date=datetime.fromisoformat(data.start_date) if data.start_date else None,
        end_date=datetime.fromisoformat(data.end_date) if data.end_date else None,
    )
    db.add(budget)
    try:
        await db.flush()
    except IntegrityError:
        await db.rollback()
        existing = await _client_uuid_existing(db, PersonalBudget, data.id, user_id)
        if existing is not None:
            existing._categories_loaded = await _budget_categories_payload(db, existing.id)
            return created(data=_budget_to_dict(existing), message="تم إنشاء الميزانية")
        raise

    # Create categories (support goal_id / debt_id links for goal & debt types).
    # Client-provided category ids (offline-created UUIDs) are honored when
    # valid and unused, so transaction links staged offline stay valid after
    # sync instead of dangling against server-generated ids.
    taken_cat_ids: set = set()
    if data.categories:
        try:
            _cand = set()
            for _c in data.categories:
                try:
                    _cid = UUID(str(_c.get("id"))) if _c.get("id") else None
                except (ValueError, TypeError, AttributeError):
                    _cid = None
                if _cid is not None:
                    _cand.add(_cid)
            if _cand:
                _rows = await db.execute(
                    select(PersonalBudgetCategory.id).where(
                        PersonalBudgetCategory.id.in_(_cand)
                    )
                )
                taken_cat_ids = {r for r in _rows.scalars().all()}
        except Exception:
            taken_cat_ids = set()
    if data.categories:
        for cat in data.categories:
            goal_uuid = None
            debt_uuid = None
            if cat.get("goal_id"):
                try:
                    goal_uuid = UUID(str(cat.get("goal_id")))
                except ValueError:
                    raise HTTPException(status_code=400, detail="معرف الهدف في التصنيف غير صالح")
            if cat.get("debt_id"):
                try:
                    debt_uuid = UUID(str(cat.get("debt_id")))
                except ValueError:
                    raise HTTPException(status_code=400, detail="معرف الدين في التصنيف غير صالح")
            cat_id = _client_category_id(cat.get("id"), taken_cat_ids)
            taken_cat_ids.add(cat_id)
            db_cat = PersonalBudgetCategory(
                id=cat_id,
                budget_id=budget.id,
                name=cat.get("name", ""),
                type=cat.get("type", "expense"),
                allocated_amount=Decimal(str(cat.get("amount", cat.get("allocated_amount", 0)))),
                currency=cat.get("currency", data.currency or "SAR"),
                goal_id=goal_uuid,
                debt_id=debt_uuid,
            )
            db.add(db_cat)

    await db.commit()
    await db.refresh(budget)
    fresh_cats = (await db.execute(
        select(PersonalBudgetCategory).where(PersonalBudgetCategory.budget_id == budget.id)
    )).scalars().all()
    budget._categories_loaded = [
        {"id": str(c.id), "budget_id": str(c.budget_id), "name": c.name, "type": c.type,
         "allocated_amount": float(c.allocated_amount) if c.allocated_amount else 0,
         "spent_amount": float(c.spent_amount) if c.spent_amount else 0,
         "currency": c.currency,
         "goal_id": str(c.goal_id) if getattr(c, "goal_id", None) else None,
         "debt_id": str(c.debt_id) if getattr(c, "debt_id", None) else None}
        for c in fresh_cats
    ]
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_budget", budget.id,
        _budget_to_dict(budget), operation_id=f"crud_{budget.id}",
    )
    await db.commit()
    return created(data=_budget_to_dict(budget), message="تم إنشاء الميزانية")


@router.patch("/personal/finance/budgets/{budget_id}", summary="Update budget")
async def update_my_budget(
    budget_id: UUID,
    data: PersonalBudgetUpdate,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "update")),
):
    result = await db.execute(
        select(PersonalBudget).where(
            PersonalBudget.id == budget_id,
            PersonalBudget.user_id == user_id,
            PersonalBudget.is_deleted == False,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="الميزانية غير موجودة")
    if data.name is not None: row.name = data.name
    if data.amount is not None:
        row.total_amount = Decimal(str(data.amount))
        row.amount = Decimal(str(data.amount))
    if data.currency is not None: row.currency = data.currency
    if data.period_type is not None: row.period_type = data.period_type
    if data.start_date is not None: row.start_date = datetime.fromisoformat(data.start_date) if data.start_date else None
    if data.end_date is not None: row.end_date = datetime.fromisoformat(data.end_date) if data.end_date else None
    if data.custom_days is not None: row.custom_days = data.custom_days
    if data.bank_account_ids is not None: row.bank_account_ids = data.bank_account_ids
    if data.budget_types is not None: row.budget_types = data.budget_types

    # Replace categories if provided. Client-provided ids are honored when
    # valid and unused (same rule as create), so edits never break the
    # transaction links staged offline.
    if data.categories is not None:
        await db.execute(delete(PersonalBudgetCategory).where(PersonalBudgetCategory.budget_id == budget_id))
        taken_cat_ids: set = set()
        try:
            _cand = set()
            for _c in data.categories:
                try:
                    _cid = UUID(str(_c.get("id"))) if _c.get("id") else None
                except (ValueError, TypeError, AttributeError):
                    _cid = None
                if _cid is not None:
                    _cand.add(_cid)
            if _cand:
                _rows = await db.execute(
                    select(PersonalBudgetCategory.id).where(
                        PersonalBudgetCategory.id.in_(_cand)
                    )
                )
                taken_cat_ids = {r for r in _rows.scalars().all()}
        except Exception:
            taken_cat_ids = set()
        for cat in data.categories:
            goal_uuid = None
            debt_uuid = None
            if cat.get("goal_id"):
                try:
                    goal_uuid = UUID(str(cat.get("goal_id")))
                except ValueError:
                    raise HTTPException(status_code=400, detail="معرف الهدف في التصنيف غير صالح")
            if cat.get("debt_id"):
                try:
                    debt_uuid = UUID(str(cat.get("debt_id")))
                except ValueError:
                    raise HTTPException(status_code=400, detail="معرف الدين في التصنيف غير صالح")
            cat_id = _client_category_id(cat.get("id"), taken_cat_ids)
            taken_cat_ids.add(cat_id)
            db_cat = PersonalBudgetCategory(
                id=cat_id,
                budget_id=budget_id,
                name=cat.get("name", ""),
                type=cat.get("type", "expense"),
                allocated_amount=Decimal(str(cat.get("amount", cat.get("allocated_amount", 0)))),
                currency=cat.get("currency", row.currency or "SAR"),
                goal_id=goal_uuid,
                debt_id=debt_uuid,
            )
            db.add(db_cat)

    await db.commit()
    await db.refresh(row)
    fresh_cats = (await db.execute(
        select(PersonalBudgetCategory).where(PersonalBudgetCategory.budget_id == budget_id)
    )).scalars().all()
    row._categories_loaded = [
        {"id": str(c.id), "budget_id": str(c.budget_id), "name": c.name, "type": c.type,
         "allocated_amount": float(c.allocated_amount) if c.allocated_amount else 0,
         "spent_amount": float(c.spent_amount) if c.spent_amount else 0,
         "currency": c.currency,
         "goal_id": str(c.goal_id) if getattr(c, "goal_id", None) else None,
         "debt_id": str(c.debt_id) if getattr(c, "debt_id", None) else None}
        for c in fresh_cats
    ]
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_budget", row.id,
        _budget_to_dict(row), operation_id=f"crud_upd_{row.id}",
    )
    await db.commit()
    return ok(data=_budget_to_dict(row))


@router.delete("/personal/finance/budgets/{budget_id}", summary="Delete budget")
async def delete_my_budget(
    budget_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "delete")),
):
    result = await db.execute(
        select(PersonalBudget).where(
            PersonalBudget.id == budget_id,
            PersonalBudget.user_id == user_id,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="الميزانية غير موجودة")
    row.is_deleted = True
    row.deleted_at = datetime.now(timezone.utc)
    await db.commit()
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_budget", row.id,
        {"id": str(row.id), "deleted_at": row.deleted_at.isoformat()},
        deleted=True, operation_id=f"crud_del_{row.id}",
    )
    await db.commit()
    return no_content(message="تم حذف الميزانية")


@router.get("/personal/finance/budgets/{budget_id}/aggregation", summary="Budget aggregation (single source of truth)")
async def budget_aggregation(
    budget_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "read")),
):
    """Single source of truth for budget statistics.

    Rules (IDs only, no name matching):
    - Transaction belongs to budget iff tx.budget_id == budget.id
      OR tx.goal_id in goals(budget) OR tx.debt_id in debts(budget).
    - Category C used += tx.amount iff tx.budget_category_id == C.id.
    - Goal G (budget-linked) stats from transactions with goal_id == G.id.
    - Debt D (budget-linked) stats from transactions with debt_id == D.id
      plus debt_payments with debt_id == D.id (dedup by payment<->tx link is
      implicit: payments create exactly one tx each; aggregation dedups by tx id).
    - Period filter: budget.start_date <= op.datetime <= budget.end_date
      (open ends are unbounded). Operations outside are excluded.
    - Dedup: each transaction id counted at most once in budget total.
    """
    b_res = await db.execute(
        select(PersonalBudget).where(
            PersonalBudget.id == budget_id,
            PersonalBudget.user_id == user_id,
            PersonalBudget.is_deleted == False,
        )
    )
    budget = b_res.scalar_one_or_none()
    if not budget:
        raise HTTPException(status_code=404, detail="الميزانية غير موجودة")

    cats = (await db.execute(
        select(PersonalBudgetCategory).where(PersonalBudgetCategory.budget_id == budget_id)
    )).scalars().all()
    goals = (await db.execute(
        select(PersonalSavingsGoal).where(
            PersonalSavingsGoal.user_id == user_id,
            PersonalSavingsGoal.is_deleted == False,
            PersonalSavingsGoal.budget_id == budget_id,
        )
    )).scalars().all()
    debts = (await db.execute(
        select(PersonalDebt).where(
            PersonalDebt.user_id == user_id,
            PersonalDebt.is_deleted == False,
            PersonalDebt.budget_id == budget_id,
        )
    )).scalars().all()

    goal_ids = {g.id for g in goals}
    debt_ids = {d.id for d in debts}
    cat_ids = {c.id for c in cats}

    txs = (await db.execute(
        select(PersonalTransaction).where(
            PersonalTransaction.user_id == user_id,
            PersonalTransaction.is_deleted == False,
            PersonalTransaction.tx_type == "expense",
            or_(
                PersonalTransaction.budget_id == budget_id,
                PersonalTransaction.goal_id.in_(goal_ids) if goal_ids else False,
                PersonalTransaction.debt_id.in_(debt_ids) if debt_ids else False,
            ),
        ).order_by(PersonalTransaction.date.desc())
    )).scalars().all()

    def _in_period(dt) -> bool:
        if dt is None:
            return False
        d = dt
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        if budget.start_date is not None:
            s = budget.start_date
            if s.tzinfo is None:
                s = s.replace(tzinfo=timezone.utc)
            if d < s:
                return False
        if budget.end_date is not None:
            e = budget.end_date
            if e.tzinfo is None:
                e = e.replace(tzinfo=timezone.utc)
            if d > e:
                return False
        return True

    seen: set[str] = set()
    cat_used: dict[str, float] = {str(c.id): 0.0 for c in cats}
    goal_used: dict[str, float] = {str(g.id): 0.0 for g in goals}
    debt_used: dict[str, float] = {str(d.id): 0.0 for d in debts}
    operations: list[dict] = []
    total_used = 0.0

    for t in txs:
        tid = str(t.id)
        if tid in seen:
            continue
        if not _in_period(t.date):
            continue
        belongs = False
        if t.budget_id == budget_id:
            belongs = True
        if getattr(t, "goal_id", None) in goal_ids:
            belongs = True
        if getattr(t, "debt_id", None) in debt_ids:
            belongs = True
        if not belongs:
            continue
        seen.add(tid)
        amt = float(t.amount or 0)
        total_used += amt
        d = _tx_to_dict(t)
        operations.append(d)
        if getattr(t, "budget_category_id", None) in cat_ids:
            cat_used[str(t.budget_category_id)] += amt
        if getattr(t, "goal_id", None) in goal_ids:
            goal_used[str(t.goal_id)] += amt
        if getattr(t, "debt_id", None) in debt_ids:
            debt_used[str(t.debt_id)] += amt

    total_amount = float(budget.total_amount or budget.amount or 0)
    return ok(data={
        "budget": _budget_to_dict(budget),
        "total_amount": total_amount,
        "total_used": round(total_used, 2),
        "remaining": round(total_amount - total_used, 2),
        "progress": round((total_used / total_amount) if total_amount > 0 else 0, 4),
        "currency": budget.currency,
        "categories": [
            {
                "id": str(c.id),
                "budget_id": str(c.budget_id),
                "name": c.name,
                "type": c.type,
                "allocated_amount": float(c.allocated_amount or 0),
                "used": round(cat_used.get(str(c.id), 0.0), 2),
                "remaining": round(float(c.allocated_amount or 0) - cat_used.get(str(c.id), 0.0), 2),
                "currency": c.currency or budget.currency,
                "goal_id": str(c.goal_id) if getattr(c, "goal_id", None) else None,
                "debt_id": str(c.debt_id) if getattr(c, "debt_id", None) else None,
            }
            for c in cats
        ],
        "goals": [
            {
                "id": str(g.id),
                "name": g.name,
                "target_amount": float(g.target_amount or 0),
                "current_amount": float(g.current_amount or 0),
                "contributed_in_period": round(goal_used.get(str(g.id), 0.0), 2),
                "currency": g.currency,
                "budget_id": str(g.budget_id) if getattr(g, "budget_id", None) else None,
            }
            for g in goals
        ],
        "debts": [
            {
                "id": str(d.id),
                "person_name": d.person_name,
                "amount": float(d.amount or 0),
                "paid_in_period": round(debt_used.get(str(d.id), 0.0), 2),
                "currency": d.currency,
                "budget_id": str(d.budget_id) if getattr(d, "budget_id", None) else None,
            }
            for d in debts
        ],
        "operations": operations,
        "operations_count": len(operations),
    })


# ── Recurring Transactions ──


@router.get("/personal/finance/recurring", summary="List my recurring transactions")
async def list_my_recurring(
    is_active: Optional[bool] = Query(None),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "read")),
):
    query = select(PersonalRecurringTransaction).where(
        PersonalRecurringTransaction.user_id == user_id,
        PersonalRecurringTransaction.is_deleted == False,
    )
    if is_active is not None:
        query = query.where(PersonalRecurringTransaction.is_active == is_active)
    result = await db.execute(query.order_by(PersonalRecurringTransaction.created_at.desc()))
    return ok(data=[_recurring_to_dict(r) for r in result.scalars().all()])


async def _resolve_bank_account_uuid(raw_id: str, user_id: UUID, db: AsyncSession):
    if not raw_id:
        return None
    try:
        return UUID(raw_id)
    except ValueError:
        pass
    try:
        local_id = int(raw_id)
    except (ValueError, TypeError):
        return None
    result = await db.execute(
        select(PersonalBankAccount.id).where(
            PersonalBankAccount.user_id == user_id,
            PersonalBankAccount.is_deleted == False,
        ).offset(local_id - 1).limit(1)
    )
    row = result.scalar_one_or_none()
    return row


@router.post("/personal/finance/recurring", status_code=status.HTTP_201_CREATED, summary="Create recurring transaction")
async def create_my_recurring(
    data: PersonalRecurringCreate,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "create")),
):
    if data.tx_type not in VALID_TX_TYPES:
        raise HTTPException(status_code=422, detail="نوع المعاملة غير صالح")
    if data.frequency not in VALID_FREQUENCIES:
        raise HTTPException(status_code=422, detail="التكرار غير صالح")
    next_run = None
    if data.next_run_date:
        try:
            next_run = datetime.fromisoformat(data.next_run_date).date()
        except ValueError:
            raise HTTPException(status_code=422, detail="تاريخ غير صالح")
    bank_uuid = await _resolve_bank_account_uuid(data.bank_account_id, user_id, db) if data.bank_account_id else None
    recurring = PersonalRecurringTransaction(
        id=data.id,
        user_id=user_id,
        name=data.name,
        tx_type=data.tx_type,
        amount=Decimal(str(data.amount)),
        currency=data.currency or "SAR",
        category=data.category.strip(),
        description=data.description,
        frequency=data.frequency,
        interval_value=data.interval_value,
        next_run_date=next_run,
        account_type=data.account_type,
        bank_account_id=bank_uuid,
        execution_type=data.execution_type,
        reminder_time=data.reminder_time,
        approximate_start_day=data.approximate_start_day,
        approximate_end_day=data.approximate_end_day,
        is_active=data.is_active,
    )
    db.add(recurring)
    duplicate = await _commit_or_dedupe(
        db, PersonalRecurringTransaction, data.id, user_id)
    if duplicate is not None:
        return created(data=_recurring_to_dict(duplicate),
                       message="تم إنشاء المعاملة المتكررة")
    await db.refresh(recurring)
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id, "personal_recurring_transaction", recurring.id,
        _recurring_to_dict(recurring), operation_id=f"crud_{recurring.id}",
    )
    await db.commit()
    return created(data=_recurring_to_dict(recurring), message="تم إنشاء المعاملة المتكررة")


@router.patch("/personal/finance/recurring/{recurring_id}", summary="Update recurring transaction")
async def update_my_recurring(
    recurring_id: UUID,
    data: PersonalRecurringUpdate,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "update")),
):
    result = await db.execute(
        select(PersonalRecurringTransaction).where(
            PersonalRecurringTransaction.id == recurring_id,
            PersonalRecurringTransaction.user_id == user_id,
            PersonalRecurringTransaction.is_deleted == False,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="المعاملة المتكررة غير موجودة")
    if data.tx_type is not None:
        if data.tx_type not in VALID_TX_TYPES:
            raise HTTPException(status_code=422, detail="نوع المعاملة غير صالح")
        row.tx_type = data.tx_type
    if data.amount is not None: row.amount = Decimal(str(data.amount))
    if data.currency is not None: row.currency = data.currency.strip()
    if data.category is not None: row.category = data.category.strip()
    if data.description is not None: row.description = data.description
    if data.frequency is not None:
        if data.frequency not in VALID_FREQUENCIES:
            raise HTTPException(status_code=422, detail="التكرار غير صالح")
        row.frequency = data.frequency
    if data.interval_value is not None: row.interval_value = data.interval_value
    if data.next_run_date is not None:
        try:
            row.next_run_date = datetime.fromisoformat(data.next_run_date).date() if data.next_run_date else None
        except ValueError:
            raise HTTPException(status_code=422, detail="تاريخ غير صالح")
    if data.is_active is not None: row.is_active = data.is_active
    if data.name is not None: row.name = data.name
    if data.account_type is not None: row.account_type = data.account_type
    if data.bank_account_id is not None:
        row.bank_account_id = await _resolve_bank_account_uuid(data.bank_account_id, user_id, db) if data.bank_account_id else None
    if data.execution_type is not None: row.execution_type = data.execution_type
    if data.reminder_time is not None: row.reminder_time = data.reminder_time
    if data.approximate_start_day is not None: row.approximate_start_day = data.approximate_start_day
    if data.approximate_end_day is not None: row.approximate_end_day = data.approximate_end_day
    await db.commit()
    await db.refresh(row)
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id,
        "personal_recurring_transaction", row.id, _recurring_to_dict(row),
        operation_id=f"crud_upd_{row.id}",
    )
    await db.commit()
    return ok(data=_recurring_to_dict(row))


@router.delete("/personal/finance/recurring/{recurring_id}", summary="Delete recurring transaction")
async def delete_my_recurring(
    recurring_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "delete")),
):
    result = await db.execute(
        select(PersonalRecurringTransaction).where(
            PersonalRecurringTransaction.id == recurring_id,
            PersonalRecurringTransaction.user_id == user_id,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="المعاملة المتكررة غير موجودة")
    row.is_deleted = True
    row.deleted_at = datetime.now(timezone.utc)
    await db.commit()
    await record_entity_version(
        db, await _user_org_id(db, user_id), user_id,
        "personal_recurring_transaction", row.id,
        {"id": str(row.id), "deleted_at": row.deleted_at.isoformat()},
        deleted=True, operation_id=f"crud_del_{row.id}",
    )
    await db.commit()
    return no_content(message="تم حذف المعاملة المتكررة")


# ── Categories ──


@router.get("/personal/finance/categories", summary="List my spending categories")
async def list_my_categories(
    tx_type: Optional[str] = Query(None),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "read")),
):
    query = select(PersonalTransaction.category).where(
        PersonalTransaction.user_id == user_id,
        PersonalTransaction.is_deleted == False,
    )
    if tx_type:
        query = query.where(PersonalTransaction.tx_type == tx_type)
    query = query.distinct().order_by(PersonalTransaction.category)
    result = await db.execute(query)
    return ok(data=[row[0] for row in result.all() if row[0]])


# ── Reset (bulk wipe of the current user's personal finance data) ──


@router.delete("/personal/finance/reset", summary="Permanently delete all my personal finance data")
async def reset_my_personal(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "delete")),
):
    """Hard-deletes every personal-finance row for the signed-in user and purges
    the org-scoped sync ledger entries for the personal entity types so the
    phone can never re-download them. The user account itself is kept active."""
    user_result = await db.execute(select(User).where(User.id == user_id))
    user = user_result.scalar_one_or_none()

    personal_reset_models = (
        PersonalBankAccount,
        PersonalTransaction,
        PersonalSavingsGoal,
        PersonalDebt,
        PersonalDebtPayment,
        PersonalBudget,
        PersonalRecurringTransaction,
    )
    for model in personal_reset_models:
        await db.execute(delete(model).where(model.user_id == user_id))

    if user is not None and user.organization_id is not None:
        personal_types = tuple(PERSONAL_MODELS.keys())
        await db.execute(
            delete(EntityVersion).where(
                EntityVersion.organization_id == user.organization_id,
                EntityVersion.entity_type.in_(personal_types),
            )
        )
        await db.execute(
            delete(ConflictLog).where(
                ConflictLog.organization_id == user.organization_id,
                ConflictLog.entity_type.in_(personal_types),
            )
        )
        await db.execute(
            delete(SyncLog).where(
                SyncLog.organization_id == user.organization_id,
                SyncLog.entity_type.in_(personal_types),
            )
        )

    await db.commit()
    return no_content(message="تم تصفير الحساب بنجاح")


# ── Bulk Restore v2 (schema 4.0.0 — validated safe-merge, verified) ──
#
# Flow (strict order, never violated):
#   VALIDATE (pure, no writes) → SAFE-MERGE UPSERT → VERIFY → COMMIT.
# Semantics are UPSERT by stable UUID identity — never wipe:
#   same stable id    → row updated to backup values (no duplicate),
#   unknown id        → row inserted,
#   ids outside backup → left untouched (newer data is never deleted).
# Any validation failure returns 422 BEFORE any write. Any write failure
# rolls the whole transaction back. Every FK is checked against the payload
# itself, so no orphan references can land. There is intentionally NO
# per-row try/except-pass here: one bad row fails the restore loudly
# instead of silently dropping financial data.


class BulkRestoreRequest(BaseModel):
    """Schema-4.0.0 entity payload produced by the client's backup snapshot."""
    schema_version: str = "4.0.0"
    backup_id: Optional[str] = None
    entities: dict = {}


_RESTORE_SUPPORTED_SCHEMAS = ("4.0.0",)


class _RestoreValidationError(Exception):
    def __init__(self, errors: list[str]):
        super().__init__("; ".join(errors[:10]))
        self.errors = errors


def _rdatetime_static(raw):
    """Optional aware-datetime parser for non-critical date fields (never raises)."""
    if raw is None or str(raw).strip() == "":
        return None
    try:
        parsed = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    except Exception:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _account_merge_key(bank_name: str, currency: str) -> tuple:
    """Logical account identity for restore-time dedup (mirrors the
    engine's cash rules exactly — see PersonalFinanceService.cashBucket /
    isCashAccount; never redefined here):
    - cash names (كاش/Cash/CASH) collapse by currency BUCKET, so a
      reset-created stub and a backup row are the same logical account;
      YER and YER_NEW share bucket 'YER', YER_OLD stays distinct.
    - every other bank keys by (lowercased name, exact currency): different
      banks or different currencies never merge.
    """
    name = (bank_name or "").strip()
    cur = (currency or "").strip().upper() or "SAR"
    if name in ("كاش", "Cash", "CASH"):
        bucket = "YER" if cur == "YER_NEW" else cur
        return ("cash", bucket)
    return ("bank", name.lower(), cur)


def _ruuid(raw, *, field: str, errors: list[str]) -> Optional[UUID]:
    try:
        return UUID(str(raw))
    except Exception:
        errors.append(f"invalid uuid in {field}: {raw!r}")
        return None


def _rdecimal(raw, *, field: str, errors: list[str]) -> Optional[Decimal]:
    try:
        text = str(raw).strip()
        if text == "":
            raise ValueError("empty")
        value = Decimal(text)
    except Exception:
        errors.append(f"invalid amount in {field}: {raw!r}")
        return None
    return value


def _rdate(raw, *, field: str, errors: list[str]):
    if raw is None or str(raw).strip() == "":
        return None
    try:
        return datetime.fromisoformat(str(raw)).date()
    except Exception:
        errors.append(f"invalid date in {field}: {raw!r}")
        return None


def _rdatetime(raw, *, field: str, errors: list[str]):
    if raw is None or str(raw).strip() == "":
        return None
    try:
        parsed = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    except Exception:
        errors.append(f"invalid datetime in {field}: {raw!r}")
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _rtext(raw, *, field: str, errors: list[str], required: bool = False) -> Optional[str]:
    if raw is None:
        if required:
            errors.append(f"missing required field: {field}")
        return None
    text = str(raw)
    if required and text.strip() == "":
        errors.append(f"empty required field: {field}")
        return None
    return text


def _validate_restore_payload(entities: dict) -> dict:
    """Pure validation. Returns normalized rows per entity or raises
    _RestoreValidationError with the complete error list."""
    errors: list[str] = []
    norm: dict[str, list[dict]] = {}

    def section(name: str) -> list[dict]:
        items = entities.get(name, []) or []
        if not isinstance(items, list):
            errors.append(f"section '{name}' must be a list")
            return []
        out = []
        for i, it in enumerate(items):
            if not isinstance(it, dict):
                errors.append(f"section '{name}[{i}]' must be an object")
                continue
            out.append(it)
        return out

    accounts = section("accounts")
    transactions = section("transactions")
    goals = section("goals")
    debts = section("debts")
    payments = section("debt_payments")
    budgets = section("budgets")
    recurring = section("recurring")

    def norm_ids(items: list[dict], label: str) -> set[str]:
        seen: set[str] = set()
        for i, it in enumerate(items):
            uid = _ruuid(it.get("id"), field=f"{label}[{i}].id", errors=errors)
            if uid is None:
                continue
            key = str(uid)
            if key in seen:
                errors.append(f"duplicate id in {label}[{i}]: {key}")
            seen.add(key)
            it["_pid"] = key
        return seen

    acc_ids = norm_ids(accounts, "accounts")
    tx_ids = norm_ids(transactions, "transactions")
    goal_ids = norm_ids(goals, "goals")
    debt_ids = norm_ids(debts, "debts")
    pay_ids = norm_ids(payments, "debt_payments")
    bud_ids = norm_ids(budgets, "budgets")
    rec_ids = norm_ids(recurring, "recurring")

    cat_ids: set[str] = set()
    for bi, b in enumerate(budgets):
        cats = b.get("categories", []) or []
        if not isinstance(cats, list):
            errors.append(f"budgets[{bi}].categories must be a list")
            continue
        for ci, c in enumerate(cats):
            if not isinstance(c, dict):
                errors.append(f"budgets[{bi}].categories[{ci}] must be an object")
                continue
            uid = _ruuid(c.get("id"), field=f"budgets[{bi}].categories[{ci}].id", errors=errors)
            if uid is None:
                continue
            key = str(uid)
            if key in cat_ids:
                errors.append(f"duplicate category id: {key}")
            cat_ids.add(key)
            c["_pid"] = key

    def fk(raw, allowed: set[str], *, field: str, nullable: bool = True) -> Optional[str]:
        if raw is None or str(raw).strip() == "":
            if not nullable:
                errors.append(f"missing required reference: {field}")
            return None
        try:
            key = str(UUID(str(raw)))
        except Exception:
            errors.append(f"invalid uuid reference in {field}: {raw!r}")
            return None
        if key not in allowed:
            errors.append(f"orphan reference in {field}: {key} (target missing from backup)")
            return None
        return key

    for i, a in enumerate(accounts):
        _rtext(a.get("bank_name"), field=f"accounts[{i}].bank_name", errors=errors, required=True)
        _rdecimal(a.get("balance", 0), field=f"accounts[{i}].balance", errors=errors)
        cur = _rtext(a.get("currency", "SAR"), field=f"accounts[{i}].currency", errors=errors)
        if cur is not None and cur.strip() == "":
            errors.append(f"empty currency in accounts[{i}]")
        if a.get("sort_order") is not None:
            try:
                int(a["sort_order"])
            except Exception:
                errors.append(f"invalid sort_order in accounts[{i}]")
        if a.get("is_active") is not None and not isinstance(a.get("is_active"), (bool, int)):
            errors.append(f"invalid is_active in accounts[{i}]")

    for i, t in enumerate(transactions):
        _rtext(t.get("tx_type"), field=f"transactions[{i}].tx_type", errors=errors, required=True)
        _rdecimal(t.get("amount"), field=f"transactions[{i}].amount", errors=errors)
        if t.get("category") is None:
            errors.append(f"missing required field: transactions[{i}].category")
        t["_bank_account_id"] = fk(t.get("bank_account_id"), acc_ids, field=f"transactions[{i}].bank_account_id")
        t["_goal_id"] = fk(t.get("goal_id"), goal_ids, field=f"transactions[{i}].goal_id")
        t["_debt_id"] = fk(t.get("debt_id"), debt_ids, field=f"transactions[{i}].debt_id")
        t["_budget_id"] = fk(t.get("budget_id"), bud_ids, field=f"transactions[{i}].budget_id")
        t["_budget_category_id"] = fk(t.get("budget_category_id"), cat_ids, field=f"transactions[{i}].budget_category_id")
        t["_date"] = _rdatetime(t.get("date"), field=f"transactions[{i}].date", errors=errors)
        for extra in ("goal_amount", "debt_amount", "exchange_rate"):
            if t.get(extra) is not None:
                _rdecimal(t.get(extra), field=f"transactions[{i}].{extra}", errors=errors)
        if t.get("client_operation_id") is not None and not str(t.get("client_operation_id")).strip():
            errors.append(f"empty client_operation_id in transactions[{i}]")

    for i, g in enumerate(goals):
        _rtext(g.get("name"), field=f"goals[{i}].name", errors=errors, required=True)
        _rdecimal(g.get("target_amount"), field=f"goals[{i}].target_amount", errors=errors)
        if g.get("current_amount") is not None:
            _rdecimal(g.get("current_amount"), field=f"goals[{i}].current_amount", errors=errors)
        g["_deadline"] = _rdate(g.get("deadline"), field=f"goals[{i}].deadline", errors=errors)
        g["_budget_id"] = fk(g.get("budget_id"), bud_ids, field=f"goals[{i}].budget_id")

    for i, d in enumerate(debts):
        dtype = _rtext(d.get("debt_type"), field=f"debts[{i}].debt_type", errors=errors, required=True)
        if dtype is not None and dtype not in ("payable", "receivable"):
            errors.append(f"invalid debt_type in debts[{i}]: {dtype!r}")
        _rtext(d.get("person_name"), field=f"debts[{i}].person_name", errors=errors, required=True)
        _rdecimal(d.get("amount"), field=f"debts[{i}].amount", errors=errors)
        d["_due_date"] = _rdate(d.get("due_date"), field=f"debts[{i}].due_date", errors=errors)
        d["_budget_id"] = fk(d.get("budget_id"), bud_ids, field=f"debts[{i}].budget_id")

    for i, p in enumerate(payments):
        p["_debt_id"] = fk(p.get("debt_id"), debt_ids, field=f"debt_payments[{i}].debt_id", nullable=False)
        _rdecimal(p.get("amount"), field=f"debt_payments[{i}].amount", errors=errors)
        p["_payment_date"] = _rdatetime(p.get("payment_date"), field=f"debt_payments[{i}].payment_date", errors=errors)
        p["_budget_id"] = fk(p.get("budget_id"), bud_ids, field=f"debt_payments[{i}].budget_id")

    for bi, b in enumerate(budgets):
        _rtext(b.get("name"), field=f"budgets[{bi}].name", errors=errors, required=True)
        _rdecimal(b.get("total_amount"), field=f"budgets[{bi}].total_amount", errors=errors)
        for ci, c in enumerate(b.get("categories", []) or []):
            if not isinstance(c, dict):
                continue
            _rtext(c.get("name"), field=f"budgets[{bi}].categories[{ci}].name", errors=errors, required=True)
            _rdecimal(c.get("amount"), field=f"budgets[{bi}].categories[{ci}].amount", errors=errors)
            if c.get("spent_amount") is not None:
                _rdecimal(c.get("spent_amount"), field=f"budgets[{bi}].categories[{ci}].spent_amount", errors=errors)
            c["_goal_id"] = fk(c.get("goal_id"), goal_ids, field=f"budgets[{bi}].categories[{ci}].goal_id")
            c["_debt_id"] = fk(c.get("debt_id"), debt_ids, field=f"budgets[{bi}].categories[{ci}].debt_id")

    for i, r in enumerate(recurring):
        _rtext(r.get("tx_type"), field=f"recurring[{i}].tx_type", errors=errors, required=True)
        _rdecimal(r.get("amount"), field=f"recurring[{i}].amount", errors=errors)
        if r.get("category") is None:
            errors.append(f"missing required field: recurring[{i}].category")
        freq = _rtext(r.get("frequency", "monthly"), field=f"recurring[{i}].frequency", errors=errors)
        if freq is not None and freq not in ("daily", "weekly", "monthly", "yearly"):
            errors.append(f"invalid frequency in recurring[{i}]: {freq!r}")
        r["_next_run_date"] = _rdate(r.get("next_run_date"), field=f"recurring[{i}].next_run_date", errors=errors)
        r["_last_executed_at"] = _rdatetime(r.get("last_executed_at"), field=f"recurring[{i}].last_executed_at", errors=errors)
        r["_bank_account_id"] = fk(r.get("bank_account_id"), acc_ids, field=f"recurring[{i}].bank_account_id")

    if errors:
        raise _RestoreValidationError(errors)

    norm.update({
        "accounts": accounts, "transactions": transactions, "goals": goals,
        "debts": debts, "debt_payments": payments, "budgets": budgets,
        "recurring": recurring,
    })
    return norm


@router.post("/personal/finance/restore", summary="Validated atomic restore of personal finance data (schema 4.0.0)")
async def bulk_restore_personal(
    payload: BulkRestoreRequest,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "write")),
):
    """VALIDATE → ATOMIC REPLACE → VERIFY → COMMIT.

    The payload must be a schema-4.0.0 ``entities`` snapshot with original
    UUIDs. Everything is validated first (422 with the full error list, zero
    writes). Replacement + verification run inside one transaction; any
    failure rolls back, so the user keeps the previous data intact.
    Original IDs are preserved, so all FK links resolve naturally.
    """
    if (payload.schema_version or "") not in _RESTORE_SUPPORTED_SCHEMAS:
        raise HTTPException(
            status_code=422,
            detail=f"Unsupported restore schema: {payload.schema_version or 'missing'} "
                   f"(supported: {', '.join(_RESTORE_SUPPORTED_SCHEMAS)}). "
                   "Partial restore of an unknown schema is refused.",
        )
    if not isinstance(payload.entities, dict):
        raise HTTPException(status_code=422, detail="Restore payload must contain an 'entities' object")

    try:
        norm = _validate_restore_payload(payload.entities)
    except _RestoreValidationError as exc:
        raise HTTPException(status_code=422, detail={
            "code": "restore_validation_failed",
            "message": "Backup failed validation — current data was NOT touched",
            "errors": exc.errors,
        })

    expected = {k: len(v) for k, v in norm.items()}
    expected["budget_categories"] = sum(len(b.get("categories", []) or []) for b in norm["budgets"])

    # ── ACCOUNT MERGE (logical identity, never fuzzy) ──
    # A snapshot row whose logical key already exists locally merges into
    # the surviving row (backup values win, per restore semantics) instead
    # of creating a duplicate; referencing rows are remapped to the
    # survivor. Different keys never merge.
    merged_accounts: list[dict] = []
    account_remap: dict[str, str] = {}
    existing_accs = (await db.execute(
        select(PersonalBankAccount).where(PersonalBankAccount.user_id == user_id)
    )).scalars().all()
    by_key: dict[tuple, list] = {}
    for row in existing_accs:
        by_key.setdefault(
            _account_merge_key(row.bank_name or "", row.currency or "SAR"), []
        ).append(row)

    def _pick_survivor(cands: list, snap_id: str):
        for r in cands:
            if str(r.id) == snap_id:
                return r, False
        alive = [r for r in cands if not r.is_deleted]
        pool = alive or cands
        try:
            for r in pool:
                if Decimal(str(r.balance or 0)) != 0:
                    return r, True
        except Exception:
            pass
        return (pool[0], True) if pool else (None, False)

    for a in norm["accounts"]:
        snap_id = a["_pid"]
        key = _account_merge_key(str(a.get("bank_name", "")),
                                 str(a.get("currency", "SAR") or "SAR"))
        survivor, remapped = _pick_survivor(by_key.get(key, []), snap_id)
        if survivor is not None and remapped:
            kept = str(survivor.id)
            account_remap[snap_id] = kept
            a["_pid"] = kept
            merged_accounts.append({"snapshot_id": snap_id, "kept_id": kept,
                                    "key": list(key)})
            by_key.setdefault(key, []).append(survivor)

    def _remap_fk(raw):
        if raw is None or str(raw).strip() == "":
            return raw
        return account_remap.get(str(raw), raw)

    for t in norm["transactions"]:
        t["bank_account_id"] = _remap_fk(t.get("bank_account_id"))
        t["_bank_account_id"] = _remap_fk(t.get("_bank_account_id"))
    for r_ in norm["recurring"]:
        r_["bank_account_id"] = _remap_fk(r_.get("bank_account_id"))
        r_["_bank_account_id"] = _remap_fk(r_.get("_bank_account_id"))

    # ── CATEGORY MERGE (same budget + normalized name) ──
    # Categories recreated with fresh UUIDs (budget rebuilds, other devices)
    # must land on the live row instead of duplicating it — otherwise
    # per-category spent shows twice after a restore. Same rule as accounts:
    # first snapshot row per key wins values (never fabricates money);
    # absorbed ids remap so their transactions keep pointing at the kept
    # row. A second restore of the same snapshot is a strict no-op.
    def _cat_key(budget_pid: str, name) -> tuple:
        return (str(budget_pid), str(name or "").strip())
    cat_remap: dict[str, str] = {}
    existing_cats = (await db.execute(
        select(PersonalBudgetCategory).where(
            PersonalBudgetCategory.budget_id.in_(
                [UUID(b["_pid"]) for b in norm["budgets"]])
        )
    )).scalars().all() if norm["budgets"] else []
    by_ckey: dict[tuple, list] = {}
    for row in existing_cats:
        by_ckey.setdefault(
            _cat_key(str(row.budget_id), row.name or ""), []).append(row)
    for b in norm["budgets"]:
        seen_ckey: dict[tuple, str] = {}
        for c in (b.get("categories", []) or []):
            if not isinstance(c, dict):
                continue
            key = _cat_key(b["_pid"], c.get("name", ""))
            if key in seen_ckey:
                # Intra-snapshot duplicate: fold onto the kept id.
                if c["_pid"] != seen_ckey[key]:
                    cat_remap[c["_pid"]] = seen_ckey[key]
                continue
            group = by_ckey.get(key, [])
            if any(str(r.id) == c["_pid"] for r in group):
                seen_ckey[key] = c["_pid"]
                continue
            if group:
                survivor = group[0]
                kept = str(survivor.id)
                if kept != c["_pid"]:
                    cat_remap[c["_pid"]] = kept
                    c["_pid"] = kept
                seen_ckey[key] = kept
            else:
                seen_ckey[key] = c["_pid"]
    for t in norm["transactions"]:
        if t.get("_budget_category_id") in cat_remap:
            t["_budget_category_id"] = cat_remap[t["_budget_category_id"]]

    def dec(raw, default="0"):
        return Decimal(str(raw if raw is not None else default))

    def _ts(raw):
        # None when unknown: callers must not overwrite stored timestamps
        # with a fallback "now" (see _upsert stripping below).
        return _rdatetime_static(raw)

    async def _upsert(model, row_id: UUID, values: dict):
        """Insert-or-update by stable UUID. Existing rows take backup values
        (revived when soft-deleted); unknown ids are inserted. Keys that are
        not real table columns are dropped (schema drift can never crash a
        restore); timestamp keys with unknown (None) values are dropped so
        stored stamps are never clobbered — except on true inserts, which
        fall back to now(). Returns True when newly inserted."""
        cols = set(model.__table__.columns.keys())
        values = {k: v for k, v in dict(values).items() if k in cols}
        for ts_key in ("created_at", "updated_at"):
            if values.get(ts_key) is None:
                values.pop(ts_key, None)
        existing = await db.get(model, row_id)
        if existing is None:
            values.setdefault("created_at", datetime.now(timezone.utc))
            if "updated_at" in cols:
                values.setdefault("updated_at", datetime.now(timezone.utc))
            db.add(model(id=row_id, user_id=user_id, **values))
            return True
        for key, val in values.items():
            setattr(existing, key, val)
        existing.is_deleted = False
        if hasattr(existing, "deleted_at"):
            existing.deleted_at = None
        return False

    try:
        # ── SAFE MERGE (upsert by stable identity, never wipe) ──
        for a in norm["accounts"]:
            await _upsert(PersonalBankAccount, UUID(a["_pid"]), dict(
                bank_name=str(a.get("bank_name", "")),
                currency=str(a.get("currency", "SAR") or "SAR"),
                balance=dec(a.get("balance", 0)),
                notes=a.get("notes"),
                sort_order=int(a["sort_order"]) if a.get("sort_order") is not None else 0,
                is_active=bool(a["is_active"]) if a.get("is_active") is not None else True,
                is_deleted=False,
                created_at=_ts(a.get("created_at")),
                updated_at=_ts(a.get("updated_at")),
            ))
        for t in norm["transactions"]:
            await _upsert(PersonalTransaction, UUID(t["_pid"]), dict(
                tx_type=str(t.get("tx_type", "expense")),
                amount=dec(t.get("amount", 0)),
                currency=str(t.get("currency", "SAR") or "SAR"),
                category=str(t.get("category", "")),
                description=t.get("description"),
                bank_account_id=UUID(t["_bank_account_id"]) if t.get("_bank_account_id") else None,
                budget_id=UUID(t["_budget_id"]) if t.get("_budget_id") else None,
                budget_category_id=UUID(t["_budget_category_id"]) if t.get("_budget_category_id") else None,
                goal_id=UUID(t["_goal_id"]) if t.get("_goal_id") else None,
                debt_id=UUID(t["_debt_id"]) if t.get("_debt_id") else None,
                goal_amount=dec(t["goal_amount"]) if t.get("goal_amount") is not None else None,
                debt_amount=dec(t["debt_amount"]) if t.get("debt_amount") is not None else None,
                payment_method=t.get("payment_method"),
                date=t.get("_date") or datetime.now(timezone.utc),
                client_operation_id=(str(t.get("client_operation_id")).strip()
                                     if t.get("client_operation_id") is not None else None),
                exchange_rate=dec(t["exchange_rate"]) if t.get("exchange_rate") is not None else None,
                exchange_rate_currency=t.get("exchange_rate_currency"),
                fx_source=t.get("fx_source"),
                is_deleted=False,
                created_at=_ts(t.get("created_at")),
                updated_at=_ts(t.get("updated_at")),
            ))
        for g in norm["goals"]:
            await _upsert(PersonalSavingsGoal, UUID(g["_pid"]), dict(
                name=str(g.get("name", "")),
                target_amount=dec(g.get("target_amount", 0)),
                current_amount=dec(g.get("current_amount", 0)),
                currency=str(g.get("currency", "SAR") or "SAR"),
                deadline=g.get("_deadline"),
                icon=str(g.get("icon", "SAVINGS") or "SAVINGS"),
                notes=g.get("notes"),
                budget_id=UUID(g["_budget_id"]) if g.get("_budget_id") else None,
                is_completed=bool(g.get("is_completed", False)),
                is_deleted=False,
                created_at=_ts(g.get("created_at")),
                updated_at=_ts(g.get("updated_at")),
            ))
        for d in norm["debts"]:
            await _upsert(PersonalDebt, UUID(d["_pid"]), dict(
                debt_type=str(d.get("debt_type", "payable")),
                person_name=str(d.get("person_name", "")),
                amount=dec(d.get("amount", 0)),
                currency=str(d.get("currency", "SAR") or "SAR"),
                description=d.get("description"),
                due_date=d.get("_due_date"),
                is_paid=bool(d.get("is_paid", False)),
                reminder=bool(d.get("reminder", False)),
                budget_id=UUID(d["_budget_id"]) if d.get("_budget_id") else None,
                is_deleted=False,
                created_at=_ts(d.get("created_at")),
                updated_at=_ts(d.get("updated_at")),
            ))
        for p in norm["debt_payments"]:
            await _upsert(PersonalDebtPayment, UUID(p["_pid"]), dict(
                debt_id=UUID(p["_debt_id"]),
                amount=dec(p.get("amount", 0)),
                currency=str(p.get("currency", "SAR") or "SAR"),
                payment_date=p.get("_payment_date") or datetime.now(timezone.utc),
                notes=p.get("notes"),
                budget_id=UUID(p["_budget_id"]) if p.get("_budget_id") else None,
                is_deleted=False,
                created_at=_ts(p.get("created_at")),
            ))
        for b in norm["budgets"]:
            bid = UUID(b["_pid"])
            await _upsert(PersonalBudget, bid, dict(
                name=str(b.get("name", "")),
                period_type=str(b.get("period_type", "monthly") or "monthly"),
                start_date=_rdatetime_static(b.get("start_date")),
                end_date=_rdatetime_static(b.get("end_date")),
                custom_days=int(b["custom_days"]) if b.get("custom_days") is not None else None,
                total_amount=dec(b.get("total_amount", 0)),
                currency=str(b.get("currency", "SAR") or "SAR"),
                bank_account_ids=b.get("bank_account_ids") or [],
                budget_types=b.get("budget_types") or ["expenses"],
                category=b.get("category"),
                month=int(b["month"]) if b.get("month") is not None else None,
                year=int(b["year"]) if b.get("year") is not None else None,
                is_deleted=False,
                created_at=_ts(b.get("created_at")),
                updated_at=_ts(b.get("updated_at")),
            ))
            for c in (b.get("categories", []) or []):
                if not isinstance(c, dict):
                    continue
                existing_cat = await db.get(PersonalBudgetCategory, UUID(c["_pid"]))
                cat_values = dict(
                    budget_id=bid,
                    name=str(c.get("name", "")),
                    type=str(c.get("type", "expense") or "expense"),
                    allocated_amount=dec(c.get("amount", 0)),
                    spent_amount=dec(c["spent_amount"]) if c.get("spent_amount") is not None else Decimal("0"),
                    currency=str(c.get("currency", b.get("currency", "SAR")) or "SAR"),
                    goal_id=UUID(c["_goal_id"]) if c.get("_goal_id") else None,
                    debt_id=UUID(c["_debt_id"]) if c.get("_debt_id") else None,
                    created_at=_ts(c.get("created_at")),
                    updated_at=_ts(c.get("updated_at")),
                )
                if existing_cat is None:
                    for ts_key in ("created_at", "updated_at"):
                        if cat_values.get(ts_key) is None:
                            cat_values[ts_key] = datetime.now(timezone.utc)
                    db.add(PersonalBudgetCategory(id=UUID(c["_pid"]), **cat_values))
                else:
                    for key, val in cat_values.items():
                        if key in ("created_at", "updated_at") and val is None:
                            continue
                        setattr(existing_cat, key, val)
        for r in norm["recurring"]:
            await _upsert(PersonalRecurringTransaction, UUID(r["_pid"]), dict(
                name=r.get("name"),
                tx_type=str(r.get("tx_type", "expense")),
                amount=dec(r.get("amount", 0)),
                currency=str(r.get("currency", "SAR") or "SAR"),
                category=str(r.get("category", "")),
                description=r.get("description"),
                frequency=str(r.get("frequency", "monthly") or "monthly"),
                interval_value=int(r.get("interval_value", 1) or 1),
                next_run_date=r.get("_next_run_date"),
                account_type=str(r.get("account_type", "fixed") or "fixed"),
                bank_account_id=UUID(r["_bank_account_id"]) if r.get("_bank_account_id") else None,
                execution_type=str(r.get("execution_type", "auto") or "auto"),
                reminder_time=r.get("reminder_time"),
                approximate_start_day=int(r["approximate_start_day"]) if r.get("approximate_start_day") is not None else None,
                approximate_end_day=int(r["approximate_end_day"]) if r.get("approximate_end_day") is not None else None,
                last_executed_at=r.get("_last_executed_at"),
                is_active=bool(r.get("is_active", True)),
                is_deleted=False,
                created_at=_ts(r.get("created_at")),
                updated_at=_ts(r.get("updated_at")),
            ))
        await db.flush()

        # ── VERIFY (before commit): every backup entity re-read by its
        # stable ID and compared field-by-field (amounts as exact Decimal
        # strings, links as UUID strings). Extra pre-existing rows are
        # allowed — only backup rows must match exactly.
        verify_errors: list[str] = []

        def _same(a, b) -> bool:
            if a is None or b is None:
                return a is None and b is None
            return str(a) == str(b)

        async def _check(model, row_id: UUID, label: str, fields: dict):
            row = await db.get(model, row_id)
            if row is None or getattr(row, "user_id", user_id) != user_id:
                verify_errors.append(f"missing after restore: {label}")
                return
            for fname, want in fields.items():
                got = getattr(row, fname, None)
                if isinstance(want, Decimal):
                    try:
                        same = Decimal(str(got)) == want
                    except Exception:
                        same = False
                elif isinstance(want, bool):
                    same = bool(got) is want
                else:
                    same = _same(got, want)
                if not same:
                    verify_errors.append(
                        f"value mismatch: {label}.{fname} "
                        f"(expected {want!r}, stored {got!r})")
                    return

        for a in norm["accounts"]:
            await _check(PersonalBankAccount, UUID(a["_pid"]),
                         f"accounts[{a['_pid']}]", {
                             "bank_name": str(a.get("bank_name", "")),
                             "currency": str(a.get("currency", "SAR") or "SAR"),
                             "balance": dec(a.get("balance", 0)),
                             "sort_order": int(a["sort_order"]) if a.get("sort_order") is not None else 0,
                             "is_active": bool(a["is_active"]) if a.get("is_active") is not None else True,
                         })
        for t in norm["transactions"]:
            tx_fields = {
                "tx_type": str(t.get("tx_type", "expense")),
                "amount": dec(t.get("amount", 0)),
                "currency": str(t.get("currency", "SAR") or "SAR"),
                "category": str(t.get("category", "")),
                "bank_account_id": UUID(t["_bank_account_id"]) if t.get("_bank_account_id") else None,
                "goal_id": UUID(t["_goal_id"]) if t.get("_goal_id") else None,
                "debt_id": UUID(t["_debt_id"]) if t.get("_debt_id") else None,
                "budget_id": UUID(t["_budget_id"]) if t.get("_budget_id") else None,
                "budget_category_id": UUID(t["_budget_category_id"]) if t.get("_budget_category_id") else None,
            }
            if t.get("client_operation_id") is not None:
                tx_fields["client_operation_id"] = str(t.get("client_operation_id")).strip()
            await _check(PersonalTransaction, UUID(t["_pid"]),
                         f"transactions[{t['_pid']}]", tx_fields)
        for g in norm["goals"]:
            await _check(PersonalSavingsGoal, UUID(g["_pid"]),
                         f"goals[{g['_pid']}]", {
                             "name": str(g.get("name", "")),
                             "target_amount": dec(g.get("target_amount", 0)),
                             "current_amount": dec(g.get("current_amount", 0)),
                             "currency": str(g.get("currency", "SAR") or "SAR"),
                         })
        for d in norm["debts"]:
            await _check(PersonalDebt, UUID(d["_pid"]),
                         f"debts[{d['_pid']}]", {
                             "debt_type": str(d.get("debt_type", "payable")),
                             "person_name": str(d.get("person_name", "")),
                             "amount": dec(d.get("amount", 0)),
                             "currency": str(d.get("currency", "SAR") or "SAR"),
                         })
        for p in norm["debt_payments"]:
            await _check(PersonalDebtPayment, UUID(p["_pid"]),
                         f"debt_payments[{p['_pid']}]", {
                             "debt_id": UUID(p["_debt_id"]),
                             "amount": dec(p.get("amount", 0)),
                             "currency": str(p.get("currency", "SAR") or "SAR"),
                         })
        for b in norm["budgets"]:
            await _check(PersonalBudget, UUID(b["_pid"]),
                         f"budgets[{b['_pid']}]", {
                             "name": str(b.get("name", "")),
                             "total_amount": dec(b.get("total_amount", 0)),
                             "currency": str(b.get("currency", "SAR") or "SAR"),
                         })
            for c in (b.get("categories", []) or []):
                if not isinstance(c, dict):
                    continue
                await _check(PersonalBudgetCategory, UUID(c["_pid"]),
                             f"budgets[{b['_pid']}].categories[{c['_pid']}]", {
                                 "budget_id": UUID(b["_pid"]),
                                 "name": str(c.get("name", "")),
                                 "allocated_amount": dec(c.get("amount", 0)),
                                 "spent_amount": dec(c["spent_amount"]) if c.get("spent_amount") is not None else Decimal("0"),
                                 "currency": str(c.get("currency", b.get("currency", "SAR")) or "SAR"),
                             })
        for r in norm["recurring"]:
            await _check(PersonalRecurringTransaction, UUID(r["_pid"]),
                         f"recurring[{r['_pid']}]", {
                             "tx_type": str(r.get("tx_type", "expense")),
                             "amount": dec(r.get("amount", 0)),
                             "currency": str(r.get("currency", "SAR") or "SAR"),
                             "category": str(r.get("category", "")),
                             "frequency": str(r.get("frequency", "monthly") or "monthly"),
                             "bank_account_id": UUID(r["_bank_account_id"]) if r.get("_bank_account_id") else None,
                         })
        if verify_errors:
            raise _RestoreValidationError(verify_errors)
        await db.commit()
    except _RestoreValidationError as exc:
        await db.rollback()
        raise HTTPException(status_code=422, detail={
            "code": "restore_verify_failed",
            "message": "Restore verification failed — previous data was kept intact",
            "errors": exc.errors,
        })
    except HTTPException:
        await db.rollback()
        raise
    except Exception as exc:
        await db.rollback()
        raise HTTPException(status_code=500, detail={
            "code": "restore_failed",
            "message": "Restore failed — previous data was kept intact",
            "errors": [f"{exc.__class__.__name__}: {exc}"],
        })

    total = sum(expected.values())
    return ok(data={
        "expected": expected,
        "verified": True,
        "backup_id": payload.backup_id,
        "merged_accounts": merged_accounts,
    }, message=f"RESTORE VERIFIED — {total} records")
