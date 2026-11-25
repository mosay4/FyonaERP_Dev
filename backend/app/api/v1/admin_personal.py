"""Admin endpoints for managing personal finance data across all users.

Platform admins can view, edit, and delete any user's personal financial data.
"""
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from fastapi import APIRouter, Depends, HTTPException, status, Query
from pydantic import BaseModel, Field
from sqlalchemy import select, func, or_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from ...api.deps import get_current_user_id, require_admin_perm
from ...api.responses import ok, created, no_content
from ...core.database import get_db
from ...domain.entities.auth_entities import User
from ...domain.entities.personal_entities import (
    PersonalBankAccount, PersonalTransaction, PersonalSavingsGoal,
    PersonalDebt, PersonalDebtPayment, PersonalBudget, PersonalRecurringTransaction,
)

router = APIRouter(tags=["Admin - Personal Finance"])


# ── Helpers ──

def _user_to_dict(u: User) -> dict:
    return {
        "id": str(u.id),
        "full_name": u.full_name,
        "email": u.email,
        "phone": u.phone or "",
        "role": u.role,
        "is_active": u.is_active,
        "preferred_currency": u.preferred_currency or "SAR",
        "created_at": u.created_at.isoformat() if u.created_at else None,
        "last_login": u.last_login.isoformat() if hasattr(u, 'last_login') and u.last_login else None,
    }


def _account_to_dict(a: PersonalBankAccount) -> dict:
    return {
        "id": str(a.id),
        "bank_name": a.bank_name,
        "currency": a.currency,
        "balance": float(a.balance) if a.balance else 0,
        "notes": a.notes,
        "account_type": getattr(a, "account_type", None) or "current",
        "is_active": a.is_active,
        "created_at": a.created_at.isoformat() if a.created_at else None,
        "updated_at": a.updated_at.isoformat() if a.updated_at else None,
    }


def _tx_to_dict(t: PersonalTransaction) -> dict:
    return {
        "id": str(t.id),
        "tx_type": t.tx_type,
        "amount": float(t.amount) if t.amount else 0,
        "category": t.category,
        "description": t.description or "",
        "date": t.date.isoformat() if t.date else None,
        "created_at": t.created_at.isoformat() if t.created_at else None,
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
        "is_completed": g.is_completed,
        "created_at": g.created_at.isoformat() if g.created_at else None,
        "progress_pct": round(float(g.current_amount or 0) / float(g.target_amount or 1) * 100, 1) if g.target_amount and g.target_amount > 0 else 0,
    }


async def _debt_to_dict(d: PersonalDebt, db: AsyncSession = None) -> dict:
    paid_total = 0.0
    if db is not None:
        rows = (await db.execute(
            select(PersonalDebtPayment.amount).where(
                PersonalDebtPayment.debt_id == d.id,
                PersonalDebtPayment.is_deleted == False,
            )
        )).scalars().all()
        paid_total = sum(float(r or 0) for r in rows)
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
        "created_at": d.created_at.isoformat() if d.created_at else None,
    }


# ── Schemas ──

class PersonalAccountUpdate(BaseModel):
    bank_name: str | None = None
    currency: str | None = None
    balance: float | None = None
    notes: str | None = None
    is_active: bool | None = None


class PersonalTransactionUpdate(BaseModel):
    tx_type: str | None = None
    amount: float | None = None
    category: str | None = None
    description: str | None = None
    date: str | None = None


class PersonalGoalUpdate(BaseModel):
    name: str | None = None
    target_amount: float | None = None
    current_amount: float | None = None
    deadline: str | None = None
    icon: str | None = None
    notes: str | None = None
    is_completed: bool | None = None


class PersonalDebtUpdate(BaseModel):
    debt_type: str | None = None
    person_name: str | None = None
    amount: float | None = None
    currency: str | None = None
    description: str | None = None
    due_date: str | None = None
    is_paid: bool | None = None


# ── Stats ──

@router.get("/admin/personal/stats")
async def get_personal_stats(
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "read")),
    db: AsyncSession = Depends(get_db),
):
    """Aggregate personal finance statistics across all users."""

    # Personal users count
    total_users = (await db.execute(
        select(func.count(User.id)).where(User.role == "personal")
    )).scalar() or 0

    # Active users
    active_users = (await db.execute(
        select(func.count(User.id)).where(User.role == "personal", User.status == "active")
    )).scalar() or 0

    # Total accounts
    total_accounts = (await db.execute(
        select(func.count(PersonalBankAccount.id)).where(PersonalBankAccount.is_deleted == False)
    )).scalar() or 0

    # Total balance
    total_balance = (await db.execute(
        select(func.sum(PersonalBankAccount.balance)).where(PersonalBankAccount.is_deleted == False)
    )).scalar() or 0

    # Goals
    total_goals = (await db.execute(
        select(func.count(PersonalSavingsGoal.id)).where(PersonalSavingsGoal.is_deleted == False)
    )).scalar() or 0
    completed_goals = (await db.execute(
        select(func.count(PersonalSavingsGoal.id)).where(
            PersonalSavingsGoal.is_deleted == False,
            PersonalSavingsGoal.is_completed == True,
        )
    )).scalar() or 0

    # Debts
    total_debts = (await db.execute(
        select(func.count(PersonalDebt.id)).where(PersonalDebt.is_deleted == False)
    )).scalar() or 0
    active_debts = (await db.execute(
        select(func.count(PersonalDebt.id)).where(
            PersonalDebt.is_deleted == False,
            PersonalDebt.is_paid == False,
        )
    )).scalar() or 0
    debts_amount = (await db.execute(
        select(func.sum(PersonalDebt.amount)).where(
            PersonalDebt.is_deleted == False,
            PersonalDebt.is_paid == False,
        )
    )).scalar() or 0

    total_transactions = (await db.execute(
        select(func.count(PersonalTransaction.id)).where(PersonalTransaction.is_deleted == False)
    )).scalar() or 0

    return ok(data={
        "total_users": total_users,
        "active_users": active_users,
        "total_accounts": total_accounts,
        "total_balance": float(total_balance or 0),
        "total_goals": total_goals,
        "completed_goals": completed_goals,
        "goal_completion_pct": round(completed_goals / total_goals * 100, 1) if total_goals > 0 else 0,
        "total_debts": total_debts,
        "active_debts": active_debts,
        "debts_amount": float(debts_amount or 0),
        "total_transactions": total_transactions,
    })


# ── Users ──

@router.get("/admin/personal/users")
async def list_personal_users(
    search: str | None = Query(None, description="Search by name or email"),
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "read")),
    db: AsyncSession = Depends(get_db),
):
    """List all personal users with their aggregated data."""

    query = select(User).where(User.role == "personal")

    if search:
        query = query.where(
            or_(
                User.full_name.ilike(f"%{search}%"),
                User.email.ilike(f"%{search}%"),
            )
        )

    query = query.order_by(User.created_at.desc())
    result = await db.execute(query)
    users = result.scalars().all()

    items = []
    for u in users:
        accounts = (await db.execute(
            select(PersonalBankAccount).where(
                PersonalBankAccount.user_id == u.id,
                PersonalBankAccount.is_deleted == False,
            )
        )).scalars().all()

        goals = (await db.execute(
            select(PersonalSavingsGoal).where(
                PersonalSavingsGoal.user_id == u.id,
                PersonalSavingsGoal.is_deleted == False,
            )
        )).scalars().all()

        debts = (await db.execute(
            select(PersonalDebt).where(
                PersonalDebt.user_id == u.id,
                PersonalDebt.is_deleted == False,
            )
        )).scalars().all()

        transactions = (await db.execute(
            select(PersonalTransaction).where(
                PersonalTransaction.user_id == u.id,
                PersonalTransaction.is_deleted == False,
            )
        )).scalars().all()

        total_balance = sum(float(a.balance or 0) for a in accounts)
        total_income = sum(float(t.amount or 0) for t in transactions if t.tx_type == "income")
        total_expense = sum(float(t.amount or 0) for t in transactions if t.tx_type == "expense")
        debt_total = sum(float(d.amount or 0) for d in debts if not d.is_paid)

        items.append({
            **_user_to_dict(u),
            "accounts_count": len(accounts),
            "total_balance": total_balance,
            "goals_count": len(goals),
            "goals_completed": sum(1 for g in goals if g.is_completed),
            "debts_count": len(debts),
            "active_debts_count": sum(1 for d in debts if not d.is_paid),
            "debts_total": debt_total,
            "transactions_count": len(transactions),
            "total_income": total_income,
            "total_expense": total_expense,
        })

    return ok(data=items)


@router.get("/admin/personal/users/{user_id}")
async def get_personal_user_detail(
    user_id: str,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "read")),
    db: AsyncSession = Depends(get_db),
):
    """Get full details of a specific personal user."""

    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="المستخدم غير موجود")

    accounts = (await db.execute(
        select(PersonalBankAccount).where(
            PersonalBankAccount.user_id == user.id,
            PersonalBankAccount.is_deleted == False,
        ).order_by(PersonalBankAccount.sort_order)
    )).scalars().all()

    transactions = (await db.execute(
        select(PersonalTransaction).where(
            PersonalTransaction.user_id == user.id,
            PersonalTransaction.is_deleted == False,
        ).order_by(PersonalTransaction.date.desc()).limit(50)
    )).scalars().all()

    goals = (await db.execute(
        select(PersonalSavingsGoal).where(
            PersonalSavingsGoal.user_id == user.id,
            PersonalSavingsGoal.is_deleted == False,
        ).order_by(PersonalSavingsGoal.is_completed, PersonalSavingsGoal.created_at.desc())
    )).scalars().all()

    debts = (await db.execute(
        select(PersonalDebt).where(
            PersonalDebt.user_id == user.id,
            PersonalDebt.is_deleted == False,
        ).order_by(PersonalDebt.is_paid, PersonalDebt.due_date)
    )).scalars().all()

    total_income = sum(float(t.amount or 0) for t in transactions if t.tx_type == "income")
    total_expense = sum(float(t.amount or 0) for t in transactions if t.tx_type == "expense")

    return ok(data={
        **_user_to_dict(user),
        "accounts": [_account_to_dict(a) for a in accounts],
        "transactions": [_tx_to_dict(t) for t in transactions],
        "goals": [_goal_to_dict(g) for g in goals],
        "debts": [await _debt_to_dict(d, db) for d in debts],
        "total_income": total_income,
        "total_expense": total_expense,
        "accounts_count": len(accounts),
        "goals_count": len(goals),
        "debts_count": len(debts),
        "transactions_count": len(transactions),
    })


# ── User-specific CRUD ──

@router.get("/admin/personal/users/{user_id}/accounts")
async def list_user_accounts(
    user_id: str,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "read")),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(PersonalBankAccount).where(
            PersonalBankAccount.user_id == user_id,
            PersonalBankAccount.is_deleted == False,
        ).order_by(PersonalBankAccount.sort_order)
    )
    return ok(data=[_account_to_dict(a) for a in result.scalars().all()])


@router.patch("/admin/personal/users/{user_id}/accounts/{account_id}")
async def update_user_account(
    user_id: str,
    account_id: str,
    body: PersonalAccountUpdate,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "update")),
    db: AsyncSession = Depends(get_db),
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
    if body.bank_name is not None: row.bank_name = body.bank_name
    if body.currency is not None: row.currency = body.currency
    if body.balance is not None: row.balance = Decimal(str(body.balance))
    if body.notes is not None: row.notes = body.notes
    if body.is_active is not None: row.is_active = body.is_active
    await db.commit()
    await db.refresh(row)
    return ok(data=_account_to_dict(row))


@router.delete("/admin/personal/users/{user_id}/accounts/{account_id}")
async def delete_user_account(
    user_id: str,
    account_id: str,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "delete")),
    db: AsyncSession = Depends(get_db),
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
    row.is_deleted = True
    row.deleted_at = datetime.utcnow()
    await db.commit()
    return no_content(message="تم حذف الحساب")


@router.get("/admin/personal/users/{user_id}/transactions")
async def list_user_transactions(
    user_id: str,
    tx_type: str | None = Query(None),
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "read")),
    db: AsyncSession = Depends(get_db),
):
    q = select(PersonalTransaction).where(
        PersonalTransaction.user_id == user_id,
        PersonalTransaction.is_deleted == False,
    )
    if tx_type:
        q = q.where(PersonalTransaction.tx_type == tx_type)
    q = q.order_by(PersonalTransaction.date.desc()).limit(100)
    result = await db.execute(q)
    return ok(data=[_tx_to_dict(t) for t in result.scalars().all()])


@router.patch("/admin/personal/users/{user_id}/transactions/{tx_id}")
async def update_user_transaction(
    user_id: str,
    tx_id: str,
    body: PersonalTransactionUpdate,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "update")),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(PersonalTransaction).where(
            PersonalTransaction.id == tx_id,
            PersonalTransaction.user_id == user_id,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="المعاملة غير موجودة")
    if body.tx_type is not None: row.tx_type = body.tx_type
    if body.amount is not None: row.amount = Decimal(str(body.amount))
    if body.category is not None: row.category = body.category
    if body.description is not None: row.description = body.description
    if body.date is not None: row.date = datetime.fromisoformat(body.date)
    await db.commit()
    await db.refresh(row)
    return ok(data=_tx_to_dict(row))


@router.delete("/admin/personal/users/{user_id}/transactions/{tx_id}")
async def delete_user_transaction(
    user_id: str,
    tx_id: str,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "delete")),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(PersonalTransaction).where(
            PersonalTransaction.id == tx_id,
            PersonalTransaction.user_id == user_id,
        )
    )
    row = result.scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="المعاملة غير موجودة")
    row.is_deleted = True
    row.deleted_at = datetime.utcnow()
    await db.commit()
    return no_content(message="تم حذف المعاملة")


@router.get("/admin/personal/users/{user_id}/goals")
async def list_user_goals(
    user_id: str,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "read")),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(
        select(PersonalSavingsGoal).where(
            PersonalSavingsGoal.user_id == user_id,
            PersonalSavingsGoal.is_deleted == False,
        ).order_by(PersonalSavingsGoal.is_completed, PersonalSavingsGoal.created_at.desc())
    )
    return ok(data=[_goal_to_dict(g) for g in result.scalars().all()])


@router.patch("/admin/personal/users/{user_id}/goals/{goal_id}")
async def update_user_goal(
    user_id: str,
    goal_id: str,
    body: PersonalGoalUpdate,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "update")),
    db: AsyncSession = Depends(get_db),
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
    if body.name is not None: row.name = body.name
    if body.target_amount is not None: row.target_amount = Decimal(str(body.target_amount))
    if body.current_amount is not None: row.current_amount = Decimal(str(body.current_amount))
    if body.deadline is not None: row.deadline = datetime.fromisoformat(body.deadline).date() if body.deadline else None
    if body.icon is not None: row.icon = body.icon
    if body.notes is not None: row.notes = body.notes
    if body.is_completed is not None: row.is_completed = body.is_completed
    await db.commit()
    await db.refresh(row)
    return ok(data=_goal_to_dict(row))


@router.delete("/admin/personal/users/{user_id}/goals/{goal_id}")
async def delete_user_goal(
    user_id: str,
    goal_id: str,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "delete")),
    db: AsyncSession = Depends(get_db),
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
    row.deleted_at = datetime.utcnow()
    await db.commit()
    return no_content(message="تم حذف الهدف")


@router.get("/admin/personal/users/{user_id}/debts")
async def list_user_debts(
    user_id: str,
    debt_type: str | None = Query(None),
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "read")),
    db: AsyncSession = Depends(get_db),
):
    q = select(PersonalDebt).where(
        PersonalDebt.user_id == user_id,
        PersonalDebt.is_deleted == False,
    )
    if debt_type:
        q = q.where(PersonalDebt.debt_type == debt_type)
    q = q.order_by(PersonalDebt.is_paid, PersonalDebt.due_date)
    result = await db.execute(q)
    return ok(data=[await _debt_to_dict(d, db) for d in result.scalars().all()])


@router.patch("/admin/personal/users/{user_id}/debts/{debt_id}")
async def update_user_debt(
    user_id: str,
    debt_id: str,
    body: PersonalDebtUpdate,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "update")),
    db: AsyncSession = Depends(get_db),
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
    if body.debt_type is not None: row.debt_type = body.debt_type
    if body.person_name is not None: row.person_name = body.person_name
    if body.amount is not None: row.amount = Decimal(str(body.amount))
    if body.currency is not None: row.currency = body.currency
    if body.description is not None: row.description = body.description
    if body.due_date is not None: row.due_date = datetime.fromisoformat(body.due_date).date() if body.due_date else None
    if body.is_paid is not None: row.is_paid = body.is_paid
    await db.commit()
    await db.refresh(row)
    return ok(data=await _debt_to_dict(row, db))


@router.delete("/admin/personal/users/{user_id}/debts/{debt_id}")
async def delete_user_debt(
    user_id: str,
    debt_id: str,
    _user_id: str = Depends(get_current_user_id),
    _perm: bool = Depends(require_admin_perm("personal_finance", "delete")),
    db: AsyncSession = Depends(get_db),
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
    row.is_deleted = True
    row.deleted_at = datetime.utcnow()
    await db.commit()
    return no_content(message="تم حذف الدين")
