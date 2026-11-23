import uuid
from datetime import datetime, timezone
from urllib.parse import quote, unquote
from decimal import Decimal
from typing import Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status, Request
from pydantic import BaseModel as _BaseModel
from sqlalchemy import select, func, update, or_
from sqlalchemy.ext.asyncio import AsyncSession

from ...core.database import get_db
from ...api.deps import (get_branch_context, get_branch_scope,
                         get_current_org_id, get_current_user_uuid, require_permission)
from ...api.responses import ok, created, no_content, ok_paginated
from ...domain.entities.finance_entities import (
    BankAccount, BankTransaction, FinancialPayment, Cheque,
)
from ...domain.models.finance_models import (
    BankAccountCreate, BankAccountUpdate, BankAccountResponse,
    BankTransactionResponse, TransferRequest, AmountRequest,
    PaymentCreate, PaymentResponse,
    ExpenseCreate, ExpenseResponse,
    ChequeCreate, ChequeStatusUpdate, ChequeResponse,
)
from ...domain.services import business_expense_service, business_cheque_service

router = APIRouter(tags=["Finance"])


# ══════════════════════════════════════════════════
#  BANK ACCOUNTS
# ══════════════════════════════════════════════════

#: Canonical cash-account names (mirrors the personal section's CASH names).
BUSINESS_CASH_NAMES = ("كاش", "Cash", "CASH")


def _scope_cond(scope, column):
    """Accept a BranchScopeContext (HTTP) or a Branch object (direct callers)."""
    if hasattr(scope, "all_mode"):
        return (column.in_(scope.branch_ids)
                if scope.all_mode else column == scope.branch_id)
    if hasattr(scope, "id"):
        return column == scope.id
    return True


def _bank_key(name) -> str:
    """Stable display-group key for a REAL bank row (exact normalized name).

    Deliberately exact: similar-looking names are never merged, so two
    genuinely different banks can never share a balance by accident.
    """
    return " ".join(str(name or "").strip().lower().split())


def _group_id(identity) -> str:
    return "all:" + quote(str(identity), safe="")


def _iban_identity(account) -> Optional[str]:
    raw = "".join(ch for ch in str(account.iban or "").upper()
                  if ch.isalnum())
    if len(raw) < 8:
        return None
    # country + check digits + the bank identifier; the account part is NOT
    # included, so different accounts at the SAME bank group together.
    return "iban:" + raw[:8]


def _account_bank_identity(account) -> str:
    # A confirmed link always wins.
    if account.bank_group_key:
        return account.bank_group_key
    # Within ONE organization an exact bank name is the bank identity the
    # merchant sees in every branch ("كاش", "الكريمي", ...). This is exact
    # normalized matching (spaces/case only), never fuzzy similarity.
    name = _bank_key(account.bank_name)
    if name:
        return f"name:{name}"
    iban = _iban_identity(account)
    if iban:
        return iban
    return f"acct:{account.id}"


def _single_branch_group(account) -> str:
    return f"branch:{account.branch_id}:name:{_bank_key(account.bank_name)}"


async def _require_connected_bank_read(db: AsyncSession, branch_ids):
    from ...core.qa_business_ledger import contains_registered_branch

    # No lazy cash writes, and no deceptively partial aggregate for a scope
    # containing a device ledger. Mixed-source aggregates are a separate path.
    if await contains_registered_branch(db, branch_ids):
        raise HTTPException(409, detail="حسابات هذا الفرع تُقرأ من دفتر الجهاز")


async def _ensure_business_cash_account(db: AsyncSession, org_id: str,
                                        branch_id=None):
    """Lazily create the org's 'كاش' account so the business home always has
    its default, non-deletable cash card (same rule as the personal section).
    """
    rows = (
        await db.execute(
            select(BankAccount).where(
                BankAccount.organization_id == UUID(org_id),
                BankAccount.bank_name.in_(BUSINESS_CASH_NAMES),
                BankAccount.branch_id == branch_id
                if branch_id is not None else True,
                ~BankAccount.is_deleted,
            )
        )
    ).scalars().all()
    if rows:
        rows[0].account_type = 'cash'
        return rows[0]
    cash = BankAccount(
        organization_id=UUID(org_id),
        branch_id=branch_id,
        bank_name="كاش",
        account_name="حساب الكاش",
        account_number="CASH",
        account_type="cash",
        currency="SAR",
        balance=0,
    )
    db.add(cash)
    await db.flush()
    return cash


class BankLinkRequest(_BaseModel):
    account_ids: list[UUID]


@router.post("/banking/banks/link", summary="تأكيد ربط حسابات كبنك واحد")
async def link_bank_accounts(
    data: BankLinkRequest,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "update")),
):
    if not scope.all_mode:
        raise HTTPException(status_code=400,
                            detail="ربط البنوك متاح في وضع جميع الفروع فقط")
    ids = list(dict.fromkeys(data.account_ids))
    if len(ids) < 2:
        raise HTTPException(status_code=400,
                            detail="اختر حسابين على الأقل من فرعين مختلفين")
    rows = (await db.execute(select(BankAccount).where(
        BankAccount.id.in_(ids),
        BankAccount.organization_id == UUID(org_id),
        BankAccount.branch_id.in_(scope.branch_ids),
        ~BankAccount.is_deleted,
    ))).scalars().all()
    if len(rows) != len(ids):
        raise HTTPException(status_code=404,
                            detail="بعض الحسابات غير موجودة أو خارج نطاقك")
    if len({str(a.branch_id) for a in rows}) < 2:
        raise HTTPException(status_code=400,
                            detail="الربط المقصود يخص حسابات في أكثر من فرع")
    key = f"link:{uuid.uuid4().hex}"
    for a in rows:
        a.bank_group_key = key
    await db.flush()
    return ok({"bank_group_key": key, "bank_key": quote(key, safe=""),
               "account_ids": [str(a.id) for a in rows]},
              "تم تأكيد ربط البنك")


@router.post("/banking/banks/unlink", summary="فك ربط البنك المؤكد")
async def unlink_bank_accounts(
    data: BankLinkRequest,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "update")),
):
    if not scope.all_mode:
        raise HTTPException(status_code=400,
                            detail="فك الربط متاح في وضع جميع الفروع فقط")
    rows = (await db.execute(select(BankAccount).where(
        BankAccount.id.in_(data.account_ids),
        BankAccount.organization_id == UUID(org_id),
        BankAccount.branch_id.in_(scope.branch_ids),
        ~BankAccount.is_deleted,
    ))).scalars().all()
    for a in rows:
        if (a.bank_group_key or "").startswith("link:"):
            a.bank_group_key = None
    await db.flush()
    return ok({"account_ids": [str(a.id) for a in rows]}, "تم فك الربط")


@router.get('/business/payment-options', summary='Permitted settlement accounts, without unauthorized balances')
async def payment_options(request: Request, org_id: str = Depends(get_current_org_id),
                          user_id: UUID = Depends(get_current_user_uuid),
                          scope=Depends(get_branch_scope), db: AsyncSession = Depends(get_db),
                          branch_id: Optional[UUID] = Query(default=None)):
    from ...domain.services.employee_access_policy import member_policy, allowed
    policy = await member_policy(db, request, user_id)
    if policy is not None and not any(allowed(policy, k) for k in (
            'sales.create', 'purchases.create', 'sales.returns', 'purchases.returns',
            'income', 'expenses', 'debts.add', 'debts.settle', 'banks')):
        raise HTTPException(403, detail='لا تملك صلاحية اختيار حساب دفع')
    ids = scope.branch_ids if scope.all_mode else [scope.branch_id]
    if branch_id is not None:
        from ...domain.services.branch_access_service import effective_branch_ids
        permitted = ids if scope.all_mode else await effective_branch_ids(db, UUID(org_id), user_id)
        if branch_id not in permitted:
            raise HTTPException(403, detail='الفرع خارج نطاق وصولك')
        ids = [branch_id]
    await _require_connected_bank_read(db, ids)
    # Use the same mandatory, real cash account as banking; never synthesize
    # a client-side id or leak cash from another branch/organization.
    for bid in ids:
        from ...domain.entities.sale_entities import Branch
        await db.execute(select(Branch.id).where(
            Branch.id == bid, Branch.organization_id == UUID(org_id)).with_for_update())
        cash = await _ensure_business_cash_account(db, org_id, bid)
        cash.is_active = True
    await db.flush()
    rows = (await db.execute(select(BankAccount).where(
        BankAccount.organization_id == UUID(org_id), BankAccount.is_deleted.is_(False),
        BankAccount.branch_id.in_(ids), BankAccount.is_active.is_(True)))).scalars().all()
    show_balance = policy is None or allowed(policy, 'banks.balances')
    return [{'id': str(a.id), 'bank_name': a.bank_name, 'account_name': a.account_name,
        'branch_id': str(a.branch_id),
        'account_type': a.account_type, 'currency': a.currency, 'is_active': a.is_active,
        'balance_visible': show_balance,
        **({'balance': str(a.balance)} if show_balance else {})} for a in rows]


@router.get("/banking/accounts", summary="List bank accounts")
async def list_bank_accounts(
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "read")),
):
    await _require_connected_bank_read(
        db, scope.branch_ids if scope.all_mode else [scope.branch_id],
    )
    if scope.all_mode:
        # Every active branch always has its mandatory cash account, even if
        # it was never opened individually yet.
        for bid in scope.branch_ids:
            await _ensure_business_cash_account(db, org_id, bid)
        # Unified view: ONE row per real bank identity + currency, with the
        # original per-branch accounts kept underneath (never mutated).
        rows = (await db.execute(select(BankAccount).where(
            BankAccount.organization_id == UUID(org_id),
            BankAccount.branch_id.in_(scope.branch_ids),
            ~BankAccount.is_deleted,
        ).order_by(BankAccount.created_at.desc()))).scalars().all()
        banks: dict = {}
        for a in rows:
            key = _account_bank_identity(a)
            cur = (a.currency or 'SAR').strip().upper()
            entry = banks.setdefault(key, {
                'id': _group_id(key),
                'bank_key': quote(key, safe=''),
                'bank_name': a.bank_name,
                'bank_group_key': a.bank_group_key,
                'names': [],
                'is_aggregate': True,
                'currencies': {},
                'accounts': [],
                'branch_ids': [],
            })
            if a.bank_name not in entry['names']:
                entry['names'].append(a.bank_name)
            entry['currencies'][cur] = (
                Decimal(str(entry['currencies'].get(cur, 0)))
                + Decimal(str(a.balance or 0)))
            account_data = BankAccountResponse.model_validate(a).model_dump()
            account_data['group_key'] = key
            entry['accounts'].append(account_data)
            if str(a.branch_id) not in entry['branch_ids']:
                entry['branch_ids'].append(str(a.branch_id))
        return [{
            **e,
            'currencies': {k: str(v) for k, v in e['currencies'].items()},
        } for e in banks.values()]
    await _ensure_business_cash_account(db, org_id, scope.branch_id)
    from ...domain.entities.sale_entities import Branch as _Branch
    is_main = bool((await db.execute(select(_Branch.is_default).where(
        _Branch.id == scope.branch_id))).scalar_one_or_none())
    stmt = (
        select(BankAccount)
        .where(BankAccount.organization_id == UUID(org_id),
               or_(BankAccount.branch_id == scope.branch_id,
                   BankAccount.branch_id.is_(None) if is_main else False),
               ~BankAccount.is_deleted)
        .order_by(BankAccount.created_at.desc())
    )
    result = await db.execute(stmt)
    items = result.scalars().all()
    out = []
    for i in items:
        d = BankAccountResponse.model_validate(i).model_dump()
        d['group_key'] = _single_branch_group(i)
        out.append(d)
    return out


@router.get("/banking/group/{bank_key}", summary="Unified bank details (all branches)")
async def get_bank_group(
    bank_key: str,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "read")),
):
    if not scope.all_mode:
        raise HTTPException(status_code=400,
                            detail="هذا العرض متاح في وضع جميع الفروع فقط")
    wanted = unquote(bank_key)
    rows = (await db.execute(select(BankAccount).where(
        BankAccount.organization_id == UUID(org_id),
        BankAccount.branch_id.in_(scope.branch_ids),
        ~BankAccount.is_deleted,
    ).order_by(BankAccount.created_at.desc()))).scalars().all()
    rows = [a for a in rows if _account_bank_identity(a) == wanted]
    if not rows:
        raise HTTPException(status_code=404, detail="البنك غير موجود")
    balances: dict = {}
    accounts = []
    for a in rows:
        cur = (a.currency or "SAR").strip().upper()
        balances[cur] = Decimal(str(balances.get(cur, 0))) + Decimal(
            str(a.balance or 0))
        accounts.append(BankAccountResponse.model_validate(a).model_dump())
    return {
        "id": _group_id(wanted),
        "bank_name": rows[0].bank_name,
        "bank_key": quote(wanted, safe=""),
        "bank_group_key": rows[0].bank_group_key,
        "is_aggregate": True,
        "currencies": {k: str(v) for k, v in balances.items()},
        "accounts": accounts,
        "branch_ids": list(dict.fromkeys(str(a.branch_id) for a in rows)),
    }


@router.get("/banking/group/{bank_key}/transactions",
            summary="Unified bank transactions (all branches)")
async def get_bank_group_transactions(
    bank_key: str,
    page: int = 1,
    per_page: int = 20,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "read")),
):
    if not scope.all_mode:
        raise HTTPException(status_code=400,
                            detail="هذا العرض متاح في وضع جميع الفروع فقط")
    wanted = unquote(bank_key)
    accounts = (await db.execute(select(BankAccount).where(
        BankAccount.organization_id == UUID(org_id),
        BankAccount.branch_id.in_(scope.branch_ids),
        ~BankAccount.is_deleted,
    ))).scalars().all()
    ids = [a.id for a in accounts if _account_bank_identity(a) == wanted]
    if not ids:
        return ok_paginated([], 0, page, per_page)
    base = select(BankTransaction).where(
        BankTransaction.organization_id == UUID(org_id),
        BankTransaction.bank_account_id.in_(ids),
        ~BankTransaction.is_deleted,
    )
    total = (await db.execute(select(func.count()).select_from(
        base.subquery()))).scalar() or 0
    rows = (await db.execute(base.order_by(
        BankTransaction.date.desc()).offset((page - 1) * per_page)
        .limit(per_page))).scalars().all()
    by_id = {a.id: a for a in accounts}
    out = []
    for t in rows:
        d = BankTransactionResponse.model_validate(t).model_dump()
        acc = by_id.get(t.bank_account_id)
        d["account_name"] = acc.account_name if acc else None
        d["account_number"] = acc.account_number if acc else None
        d["branch_id"] = str(acc.branch_id) if acc and acc.branch_id else None
        out.append(d)
    return ok_paginated(out, total, page, per_page)


@router.get("/banking/group/{bank_key}/statement",
            summary="Unified bank statement (all branches)")
async def get_bank_group_statement(
    bank_key: str,
    from_date: Optional[str] = None,
    to_date: Optional[str] = None,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "read")),
):
    if not scope.all_mode:
        raise HTTPException(status_code=400,
                            detail="هذا العرض متاح في وضع جميع الفروع فقط")
    wanted = unquote(bank_key)
    accounts = (await db.execute(select(BankAccount).where(
        BankAccount.organization_id == UUID(org_id),
        BankAccount.branch_id.in_(scope.branch_ids),
        ~BankAccount.is_deleted,
    ))).scalars().all()
    ids = [a.id for a in accounts if _account_bank_identity(a) == wanted]
    if not ids:
        return []
    query = select(BankTransaction).where(
        BankTransaction.organization_id == UUID(org_id),
        BankTransaction.bank_account_id.in_(ids),
        ~BankTransaction.is_deleted,
    ).order_by(BankTransaction.date.desc())
    if from_date:
        query = query.where(BankTransaction.date >= datetime.fromisoformat(from_date))
    if to_date:
        query = query.where(BankTransaction.date <= datetime.fromisoformat(to_date))
    rows = (await db.execute(query)).scalars().all()
    by_id = {a.id: a for a in accounts}
    out = []
    for t in rows:
        d = BankTransactionResponse.model_validate(t).model_dump()
        acc = by_id.get(t.bank_account_id)
        d["account_name"] = acc.account_name if acc else None
        d["account_number"] = acc.account_number if acc else None
        d["branch_id"] = str(acc.branch_id) if acc and acc.branch_id else None
        out.append(d)
    return out


@router.get("/banking/accounts/{account_id}", summary="Get bank account")
async def get_bank_account(
    account_id: UUID,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "read")),
):
    from ...domain.entities.sale_entities import Branch as _Branch
    if scope.all_mode:
        cond = BankAccount.branch_id.in_(scope.branch_ids)
    else:
        is_main = bool((await db.execute(select(_Branch.is_default).where(
            _Branch.id == scope.branch_id))).scalar_one_or_none())
        cond = or_(BankAccount.branch_id == scope.branch_id,
                   BankAccount.branch_id.is_(None) if is_main else False)
    stmt = select(BankAccount).where(
        BankAccount.id == account_id,
        BankAccount.organization_id == UUID(org_id),
        cond,
        ~BankAccount.is_deleted,
    )
    result = await db.execute(stmt)
    account = result.scalar_one_or_none()
    if not account:
        raise HTTPException(status_code=404, detail="الحساب البنكي غير موجود")
    return BankAccountResponse.model_validate(account).model_dump()


@router.post("/banking/accounts", status_code=status.HTTP_201_CREATED, summary="Create bank account")
async def create_bank_account(
    data: BankAccountCreate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "create")),
):
    from ...domain.services import bank_money_service
    try:
        account = await bank_money_service.create_account(
            db, UUID(org_id), branch.id, data.model_dump())
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return BankAccountResponse.model_validate(account).model_dump()


@router.put("/banking/accounts/{account_id}", summary="Update bank account")
async def update_bank_account(
    account_id: UUID,
    data: BankAccountUpdate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "update")),
):
    from ...domain.services import bank_money_service
    try:
        account = await bank_money_service.update_account(
            db, UUID(org_id), branch.id, account_id, data.model_dump(exclude_unset=True))
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc))
    return BankAccountResponse.model_validate(account).model_dump()


@router.delete("/banking/accounts/{account_id}", summary="Delete bank account")
async def delete_bank_account(
    account_id: UUID,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "delete")),
):
    from ...domain.services import bank_money_service
    try:
        await bank_money_service.delete_account(db, UUID(org_id), branch.id, account_id)
    except ValueError as exc:
        raise HTTPException(status_code=404 if str(exc) == "الحساب البنكي غير موجود" else 400,
                            detail=str(exc))
    return no_content("تم حذف الحساب البنكي")


@router.get("/banking/accounts/{account_id}/transactions", summary="List account transactions")
async def list_account_transactions(
    account_id: UUID,
    page: int = 1,
    per_page: int = 20,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "read")),
):
    await _get_account_in_scope(db, account_id, UUID(org_id), scope)
    query = (
        select(BankTransaction)
        .where(
            BankTransaction.bank_account_id == account_id,
            BankTransaction.organization_id == UUID(org_id),
            ~BankTransaction.is_deleted,
        )
        .order_by(BankTransaction.date.desc())
        .offset((page - 1) * per_page)
        .limit(per_page)
    )
    count_q = select(func.count(BankTransaction.id)).where(
        BankTransaction.bank_account_id == account_id,
        BankTransaction.organization_id == UUID(org_id),
        ~BankTransaction.is_deleted,
    )
    total = (await db.execute(count_q)).scalar() or 0
    result = await db.execute(query)
    items = result.scalars().all()
    return ok_paginated(
        [BankTransactionResponse.model_validate(i).model_dump() for i in items],
        total, page, per_page,
    )


@router.get("/banking/accounts/{account_id}/statement", summary="Get account statement")
async def get_account_statement(
    account_id: UUID,
    from_date: Optional[str] = None,
    to_date: Optional[str] = None,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "read")),
):
    await _get_account_in_scope(db, account_id, UUID(org_id), scope)
    query = (
        select(BankTransaction)
        .where(
            BankTransaction.bank_account_id == account_id,
            BankTransaction.organization_id == UUID(org_id),
            ~BankTransaction.is_deleted,
        )
        .order_by(BankTransaction.date.desc())
    )
    if from_date:
        fd = datetime.fromisoformat(from_date)
        query = query.where(BankTransaction.date >= fd)
    if to_date:
        td = datetime.fromisoformat(to_date)
        query = query.where(BankTransaction.date <= td)
    result = await db.execute(query)
    items = result.scalars().all()
    return [BankTransactionResponse.model_validate(i).model_dump() for i in items]


@router.post("/banking/transfer", summary="Transfer between accounts")
async def transfer_money(
    data: TransferRequest,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "create")),
):
    from ...domain.services import bank_money_service
    try:
        await bank_money_service.transfer(
            db, UUID(org_id), branch.id, UUID(data.from_account_id), UUID(data.to_account_id),
            data.amount, data.to_amount, data.description)
    except ValueError as exc:
        raise HTTPException(status_code=404 if str(exc) == "الحساب البنكي غير موجود" else 400,
                            detail=str(exc))
    return ok({"message": "تمت المصارفه بنجاح"})


@router.post("/banking/accounts/{account_id}/deposit", summary="Deposit to account")
async def deposit(
    request: Request,
    account_id: UUID,
    data: AmountRequest,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "create")),
):
    from ...domain.services import bank_money_service
    try:
        account, _tx = await bank_money_service.deposit(
            db, UUID(org_id), branch.id, account_id, data.amount, data.description)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    from ...domain.services.employee_access_policy import member_policy, allowed
    policy = await member_policy(db, request, user_id)
    return ok({"message": "تم الإيداع بنجاح", **({'balance': str(account.balance)}
        if policy is None or allowed(policy, 'banks.balances') else {})})


@router.post("/banking/accounts/{account_id}/withdraw", summary="Withdraw from account")
async def withdraw(
    request: Request,
    account_id: UUID,
    data: AmountRequest,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("banking", "create")),
):
    from ...domain.services import bank_money_service
    try:
        account, _tx = await bank_money_service.withdraw(
            db, UUID(org_id), branch.id, account_id, data.amount,
            data.description, data.is_expense, data.category)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    from ...domain.services.employee_access_policy import member_policy, allowed
    policy = await member_policy(db, request, user_id)
    return ok({"message": "تم السحب بنجاح", **({'balance': str(account.balance)}
        if policy is None or allowed(policy, 'banks.balances') else {})})


async def _get_account_in_scope(db: AsyncSession, account_id: UUID,
                                org_id: UUID, scope) -> BankAccount:
    stmt = select(BankAccount).where(
        BankAccount.id == account_id,
        BankAccount.organization_id == org_id,
        (BankAccount.branch_id.in_(scope.branch_ids)
         if scope.all_mode else BankAccount.branch_id == scope.branch_id),
        ~BankAccount.is_deleted,
    )
    account = (await db.execute(stmt)).scalar_one_or_none()
    if not account:
        raise HTTPException(status_code=404, detail="الحساب البنكي غير موجود")
    return account


async def _get_account(db: AsyncSession, account_id: UUID, org_id: UUID,
                       branch_id=None) -> BankAccount:
    from ...domain.entities.sale_entities import Branch
    is_main = False
    if branch_id is not None:
        is_main = bool((await db.execute(select(Branch.is_default).where(
            Branch.id == branch_id))).scalar_one_or_none())
    cond = True
    if branch_id is not None:
        cond = or_(
            BankAccount.branch_id == branch_id,
            BankAccount.branch_id.is_(None) if is_main else False,
        )
    stmt = select(BankAccount).where(
        BankAccount.id == account_id,
        BankAccount.organization_id == org_id,
        cond,
        ~BankAccount.is_deleted,
    )
    result = await db.execute(stmt)
    account = result.scalar_one_or_none()
    if not account:
        raise HTTPException(status_code=404, detail="الحساب البنكي غير موجود")
    return account


# ══════════════════════════════════════════════════
#  PAYMENTS
# ══════════════════════════════════════════════════

@router.get("/payments", summary="List payments")
async def list_payments(
    page: int = 1,
    per_page: int = 50,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("payments", "read")),
):
    query = (
        select(FinancialPayment)
        .where(FinancialPayment.organization_id == UUID(org_id),
               _scope_cond(scope, FinancialPayment.branch_id),
               ~FinancialPayment.is_deleted)
        .order_by(FinancialPayment.created_at.desc())
        .offset((page - 1) * per_page)
        .limit(per_page)
    )
    result = await db.execute(query)
    items = result.scalars().all()
    return [PaymentResponse.model_validate(i).model_dump() for i in items]


@router.get("/payments/{payment_id}", summary="Get payment")
async def get_payment(
    payment_id: UUID,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("payments", "read")),
):
    stmt = select(FinancialPayment).where(
        FinancialPayment.id == payment_id,
        FinancialPayment.organization_id == UUID(org_id),
        _scope_cond(scope, FinancialPayment.branch_id),
        ~FinancialPayment.is_deleted,
    )
    result = await db.execute(stmt)
    payment = result.scalar_one_or_none()
    if not payment:
        raise HTTPException(status_code=404, detail="الدفعة غير موجودة")
    return PaymentResponse.model_validate(payment).model_dump()


@router.post("/payments", status_code=status.HTTP_201_CREATED, summary="Create payment")
async def create_payment(
    data: PaymentCreate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("payments", "create")),
):
    # Auto-generate payment number
    count_q = select(func.count(FinancialPayment.id)).where(
        FinancialPayment.organization_id == UUID(org_id), ~FinancialPayment.is_deleted
    )
    count = (await db.execute(count_q)).scalar() or 0
    payment_no = data.payment_no or f"PAY-{datetime.now().strftime('%Y%m%d')}-{count + 1:04d}"

    payment = FinancialPayment(
        organization_id=UUID(org_id),
        branch_id=branch.id,
        payment_no=payment_no,
        payment_type=data.payment_type,
        payment_method=data.payment_method,
        amount=data.amount,
        notes=data.notes,
        payment_date=data.payment_date or datetime.now(timezone.utc),
    )
    db.add(payment)
    await db.flush()
    return PaymentResponse.model_validate(payment).model_dump()


@router.delete("/payments/{payment_id}", summary="Delete payment")
async def delete_payment(
    payment_id: UUID,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("payments", "delete")),
):
    stmt = select(FinancialPayment).where(
        FinancialPayment.id == payment_id,
        FinancialPayment.organization_id == UUID(org_id),
        FinancialPayment.branch_id == branch.id,
        ~FinancialPayment.is_deleted,
    )
    result = await db.execute(stmt)
    payment = result.scalar_one_or_none()
    if not payment:
        raise HTTPException(status_code=404, detail="الدفعة غير موجودة")
    payment.is_deleted = True
    payment.deleted_at = datetime.now(timezone.utc)
    await db.flush()
    return no_content("تم حذف الدفعة")


# ══════════════════════════════════════════════════
#  EXPENSES
# ══════════════════════════════════════════════════

def _expense_branch_ids(scope):
    if hasattr(scope, "all_mode"):
        return tuple(scope.branch_ids) if scope.all_mode else (scope.branch_id,)
    if hasattr(scope, "id"):
        return (scope.id,)
    raise HTTPException(status_code=403, detail="نطاق الفرع غير صالح")


@router.get("/expenses", summary="List expenses")
async def list_expenses(
    page: int = 1,
    per_page: int = 50,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("expenses", "read")),
):
    items = await business_expense_service.list_expenses(
        db, UUID(org_id), _expense_branch_ids(scope), page=page, per_page=per_page)
    return [ExpenseResponse.model_validate(i).model_dump() for i in items]


@router.get("/expenses/{expense_id}", summary="Get expense")
async def get_expense(
    expense_id: UUID,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("expenses", "read")),
):
    expense = await business_expense_service.get_expense(
        db, UUID(org_id), _expense_branch_ids(scope), expense_id)
    return ExpenseResponse.model_validate(expense).model_dump()


@router.post("/expenses", status_code=status.HTTP_201_CREATED, summary="Create expense")
async def create_expense(
    data: ExpenseCreate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("expenses", "create")),
):
    expense = await business_expense_service.create_expense(db, UUID(org_id), branch.id, data)
    return ExpenseResponse.model_validate(expense).model_dump()


@router.put("/expenses/{expense_id}", summary="Update expense")
async def update_expense(
    expense_id: UUID,
    data: ExpenseCreate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("expenses", "update")),
):
    expense = await business_expense_service.update_expense(
        db, UUID(org_id), branch.id, expense_id, data)
    return ExpenseResponse.model_validate(expense).model_dump()


@router.delete("/expenses/{expense_id}", summary="Delete expense")
async def delete_expense(
    expense_id: UUID,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("expenses", "delete")),
):
    await business_expense_service.delete_expense(db, UUID(org_id), branch.id, expense_id)
    return no_content("تم حذف المصروف")


# ══════════════════════════════════════════════════
#  CHEQUES
# ══════════════════════════════════════════════════

@router.get("/cheques", summary="List cheques")
async def list_cheques(
    page: int = 1,
    per_page: int = 50,
    cheque_status: Optional[str] = Query(None, alias="status"),
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("cheques", "read")),
):
    items = await business_cheque_service.list_cheques(
        db, UUID(org_id), _expense_branch_ids(scope), page=page,
        per_page=per_page, status=cheque_status)
    return [ChequeResponse.model_validate(i).model_dump() for i in items]


@router.get("/cheques/{cheque_id}", summary="Get cheque")
async def get_cheque(
    cheque_id: UUID,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("cheques", "read")),
):
    cheque = await business_cheque_service.get_cheque(
        db, UUID(org_id), _expense_branch_ids(scope), cheque_id)
    return ChequeResponse.model_validate(cheque).model_dump()


@router.post("/cheques", status_code=status.HTTP_201_CREATED, summary="Create cheque")
async def create_cheque(
    data: ChequeCreate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("cheques", "create")),
):
    cheque = await business_cheque_service.create_cheque(db, UUID(org_id), branch.id, data)
    return ChequeResponse.model_validate(cheque).model_dump()


@router.put("/cheques/{cheque_id}/status", summary="Update cheque status")
async def update_cheque_status(
    cheque_id: UUID,
    data: ChequeStatusUpdate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("cheques", "update")),
):
    cheque = await business_cheque_service.transition_cheque(
        db, UUID(org_id), branch.id, cheque_id, data)
    return ok(ChequeResponse.model_validate(cheque).model_dump())


@router.delete("/cheques/{cheque_id}", summary="Delete cheque")
async def delete_cheque(
    cheque_id: UUID,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("cheques", "delete")),
):
    await business_cheque_service.delete_cheque(db, UUID(org_id), branch.id, cheque_id)
    return no_content("تم حذف الشيك")
