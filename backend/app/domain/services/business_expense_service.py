"""Original Business expense CRUD, without bank or ledger side effects.

Categorized withdrawals are a separate bank operation: editing/deleting their
expense record has never reversed the withdrawal. Callers own authorization and
the transaction; this service never commits. No attachment field exists in the
original Expense entity/DTO, so none is inferred from a receipt or bank row.
"""
from datetime import datetime, timezone

from fastapi import HTTPException
from sqlalchemy import func, select

from ..entities.finance_entities import Expense


async def list_expenses(db, organization_id, branch_ids, *, page=1, per_page=50):
    result = await db.execute(select(Expense).where(
        Expense.organization_id == organization_id,
        Expense.branch_id.in_(branch_ids), ~Expense.is_deleted,
    ).order_by(Expense.created_at.desc()).offset((page - 1) * per_page).limit(per_page))
    return result.scalars().all()


async def get_expense(db, organization_id, branch_ids, expense_id, *, lock=False):
    query = select(Expense).where(
        Expense.id == expense_id, Expense.organization_id == organization_id,
        Expense.branch_id.in_(branch_ids), ~Expense.is_deleted,
    )
    if lock:
        query = query.with_for_update().execution_options(populate_existing=True)
    expense = (await db.execute(query)).scalar_one_or_none()
    if expense is None:
        raise HTTPException(status_code=404, detail="المصروف غير موجود")
    return expense


async def create_expense(db, organization_id, branch_id, data, *, expense_id=None):
    count = await db.scalar(select(func.count(Expense.id)).where(
        Expense.organization_id == organization_id, ~Expense.is_deleted)) or 0
    expense = Expense(
        **({'id': expense_id} if expense_id is not None else {}),
        organization_id=organization_id, branch_id=branch_id,
        expense_no=data.expense_no or f"EXP-{datetime.now().strftime('%Y%m%d')}-{count + 1:04d}",
        category=data.category, amount=data.amount,
        currency=(data.currency or "SAR").strip().upper(),
        description=data.description, payment_method=data.payment_method,
        expense_date=data.expense_date or datetime.now(timezone.utc),
    )
    db.add(expense)
    await db.flush()
    return expense


async def update_expense(db, organization_id, branch_id, expense_id, data):
    expense = await get_expense(db, organization_id, (branch_id,), expense_id, lock=True)
    # Retain the original partial-PUT behavior and linked account unchanged.
    for key, value in data.model_dump(exclude_unset=True).items():
        setattr(expense, key, value)
    await db.flush()
    return expense


async def delete_expense(db, organization_id, branch_id, expense_id):
    expense = await get_expense(db, organization_id, (branch_id,), expense_id, lock=True)
    expense.is_deleted = True
    expense.deleted_at = datetime.now(timezone.utc)
    await db.flush()
    return expense
