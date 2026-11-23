"""Connected Business bank operations with row locks on account updates."""
import json
import uuid as _uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Optional
from uuid import UUID

from sqlalchemy import select, func

from ..entities.business_settings_entities import BusinessProjectSettings
from ..entities.finance_entities import BankAccount, BankTransaction
from ..entities.sale_entities import Branch
from ..entities.finance_entities import Expense


CASH_NAMES = ("كاش", "Cash", "CASH")


async def create_account(db, org_id, branch_id, data, *, account_id=None):
    opening = Decimal(str(data.get('balance') or 0))
    if opening < 0:
        raise ValueError("الرصيد الافتتاحي لا يمكن أن يكون سالبًا")
    account = BankAccount(
        **({'id': account_id} if account_id else {}),
        organization_id=org_id, branch_id=branch_id,
        bank_name=data['bank_name'], account_name=data['account_name'],
        account_number=data['account_number'], iban=data.get('iban'),
        currency=data.get('currency', 'SAR'),
        account_type=data.get('account_type') or 'checking', balance=opening)
    db.add(account)
    await db.flush()
    if opening > 0:
        db.add(BankTransaction(
            organization_id=org_id, bank_account_id=account.id,
            date=datetime.now(timezone.utc), description="رصيد افتتاحي",
            tx_type='opening_balance', amount=opening,
            currency=account.currency, running_balance=opening))
        await db.flush()
    return account


async def update_account(db, org_id, branch_id, account_id, data):
    account = await account_in_scope(db, org_id, branch_id, account_id)
    for key, value in data.items():
        setattr(account, key, value)
    await db.flush()
    return account


async def delete_account(db, org_id, branch_id, account_id):
    account = await account_in_scope(db, org_id, branch_id, account_id)
    if (account.bank_name or '').strip() in CASH_NAMES:
        remaining = await db.scalar(select(func.count()).select_from(BankAccount).where(
            BankAccount.organization_id == org_id,
            BankAccount.bank_name.in_(CASH_NAMES), ~BankAccount.is_deleted,
            BankAccount.id != account.id))
        if not remaining:
            raise ValueError("لا يمكن حذف حساب الكاش — هذا الحساب أساسي ولا يمكن حذفه")
    account.is_deleted = True
    account.deleted_at = datetime.now(timezone.utc)
    await db.flush()
    return account


async def transfer(db, org_id, branch_id, from_id, to_id, amount,
                   to_amount=None, description=None):
    if from_id == to_id:
        raise ValueError("لا يمكن التحويل إلى نفس الحساب")
    # Acquire account locks in deterministic order.
    accounts = {}
    for identity in sorted((from_id, to_id), key=str):
        accounts[identity] = await account_in_scope(db, org_id, branch_id, identity)
    source, target = accounts[from_id], accounts[to_id]
    if Decimal(str(source.balance)) < amount:
        raise ValueError("الرصيد غير كافٍ")
    from_cur = (source.currency or 'SAR').strip().upper()
    to_cur = (target.currency or 'SAR').strip().upper()
    if from_cur == to_cur:
        if to_amount is not None and abs(to_amount - amount) > Decimal('0.005'):
            raise ValueError("مبلغ الاستلام يجب أن يساوي مبلغ التحويل لنفس العملة")
        to_amount = amount
    elif to_amount is None:
        raise ValueError("التحويل بين عملتين يتطلب مبلغ الاستلام المحسوب بسعر الصرف")
    source.balance = Decimal(str(source.balance)) - amount
    target.balance = Decimal(str(target.balance)) + to_amount
    now = datetime.now(timezone.utc)
    desc = description or 'تحويل'
    db.add(BankTransaction(
        organization_id=org_id, bank_account_id=from_id, date=now,
        description=f"تحويل إلى {target.account_name}: {desc}",
        tx_type='transfer_out', amount=amount, currency=from_cur,
        running_balance=source.balance))
    db.add(BankTransaction(
        organization_id=org_id, bank_account_id=to_id, date=now,
        description=f"تحويل من {source.account_name}: {desc}",
        tx_type='transfer_in', amount=to_amount, currency=to_cur,
        running_balance=target.balance))
    await db.flush()
    return source, target


async def account_in_scope(db, org_id: UUID, branch_id: UUID, account_id: UUID,
                           *, lock: bool = True) -> BankAccount:
    is_main = bool((await db.execute(select(Branch.is_default).where(
        Branch.id == branch_id, Branch.organization_id == org_id))).scalar_one_or_none())
    cond = BankAccount.branch_id == branch_id
    if is_main:
        cond = (BankAccount.branch_id == branch_id) | BankAccount.branch_id.is_(None)
    stmt = select(BankAccount).where(
        BankAccount.id == account_id,
        BankAccount.organization_id == org_id,
        cond,
        ~BankAccount.is_deleted,
    )
    if lock:
        stmt = stmt.with_for_update().execution_options(populate_existing=True)
    account = (await db.execute(stmt)).scalar_one_or_none()
    if not account:
        raise ValueError("الحساب البنكي غير موجود")
    return account


async def deposit(db, org_id: UUID, branch_id: UUID, account_id: UUID,
                  amount: Decimal, description: Optional[str] = None):
    account = await account_in_scope(db, org_id, branch_id, account_id)
    account.balance = Decimal(str(account.balance)) + amount
    tx = BankTransaction(
        organization_id=org_id, bank_account_id=account_id,
        date=datetime.now(timezone.utc),
        description=description or "إيداع",
        tx_type="deposit", amount=amount,
        currency=(account.currency or "SAR").strip().upper(),
        running_balance=account.balance,
    )
    db.add(tx)
    await db.flush()
    return account, tx


async def withdraw(db, org_id: UUID, branch_id: UUID, account_id: UUID,
                   amount: Decimal, description: Optional[str] = None,
                   is_expense: bool = False, category: Optional[str] = None):
    account = await account_in_scope(db, org_id, branch_id, account_id)
    settings_row = await db.get(BusinessProjectSettings, org_id)
    allow_negative = bool(json.loads(settings_row.settings or '{}').get('allow_negative')) \
        if settings_row else False
    if Decimal(str(account.balance)) < amount and not allow_negative:
        raise ValueError("الرصيد غير كافٍ")
    account.balance = Decimal(str(account.balance)) - amount
    now = datetime.now(timezone.utc)
    tx = BankTransaction(
        organization_id=org_id, bank_account_id=account_id, date=now,
        description=description or "سحب", tx_type="withdrawal", amount=amount,
        currency=(account.currency or "SAR").strip().upper(),
        running_balance=account.balance,
    )
    db.add(tx)
    if is_expense:
        cur = (account.currency or "SAR").strip().upper()
        is_cash = (account.bank_name or "").strip() in ("كاش", "Cash", "CASH")
        expense = Expense(
            organization_id=org_id, branch_id=branch_id,
            expense_no=f"EXP-{now.strftime('%Y%m%d')}-{_uuid.uuid4().hex[:6].upper()}",
            category=(category or "").strip() or "متنوعة",
            amount=amount, currency=cur,
            description=description or "",
            payment_method="cash" if is_cash else "bank",
            bank_account_id=account_id, expense_date=now)
        db.add(expense)
        # Exact association for the sync adapter; never guess by amount/date.
        tx._business_expense = expense
    await db.flush()
    return account, tx
