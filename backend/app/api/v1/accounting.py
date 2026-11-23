from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from typing import Optional
from uuid import UUID
from datetime import date

from ...core.database import get_db
from ...api.deps import (get_branch_context, get_branch_scope, get_current_org_id,
                         get_current_user_uuid, require_permission)
from ...api.responses import ok, created, ok_paginated
from ...domain.models.accounting_models import (
    AccountCreate,
    JournalEntryCreate,
    TrialBalanceResponse,
    ProfitLossResponse,
    BalanceSheetResponse,
)
from ...domain.services.business_accounting_service import BusinessAccountingService

router = APIRouter(tags=["Accounting"])


def _svc(db):
    return BusinessAccountingService(db)


# ── Chart of Accounts ──


@router.post(
    "/accounting/init", summary="Initialize default chart of accounts", status_code=201
)
async def init_chart(
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("accounting", "create")),
):
    r = await _svc(db).init_default_chart(UUID(org_id))
    return created(r, "تم تهيئة دليل الحسابات")


@router.post("/accounting/accounts", summary="Create an account", status_code=201)
async def create_account(
    data: AccountCreate,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("accounting", "create")),
):
    try:
        r = await _svc(db).create_account(UUID(org_id), data)
        return created(r, "تم إنشاء الحساب")
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.get("/accounting/accounts", summary="List accounts")
async def list_accounts(
    type_filter: Optional[str] = None,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("accounting", "read")),
):
    r = await _svc(db).list_accounts(UUID(org_id), type_filter)
    return ok(r)


# ── Journal Entries ──


@router.post("/accounting/journal", summary="Create a journal entry", status_code=201)
async def create_journal(
    data: JournalEntryCreate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    uid: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("accounting", "create")),
):
    try:
        r = await _svc(db).create_journal_entry(
            UUID(org_id), uid, data, branch_id=branch.id)
        return created(r, "تم إنشاء القيد")
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.get("/accounting/journal", summary="List journal entries")
async def list_journal(
    page: int = Query(1, ge=1),
    per_page: int = Query(20, ge=1, le=200),
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("accounting", "read")),
):
    items, total = await _svc(db).list_journal_entries(
        UUID(org_id), page, per_page, scope.branch_id,
        scope.branch_ids if scope.all_mode else None)
    return ok_paginated([i.model_dump() for i in items], total, page, per_page)


@router.post("/accounting/journal/{eid}/post", summary="Post a journal entry")
async def post_journal(
    eid: UUID,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    uid: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("accounting", "update")),
):
    try:
        r = await _svc(db).post_journal_entry(eid, UUID(org_id), uid, branch_id=branch.id)
        return ok(r, "تم ترحيل القيد")
    except ValueError as e:
        raise HTTPException(400, str(e))


# ── Reports ──


@router.get(
    "/accounting/trial-balance",
    summary="Trial balance",
    response_model=TrialBalanceResponse,
)
async def trial_balance(
    entry_date: Optional[date] = None,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("accounting", "read")),
):
    return await _svc(db).trial_balance(UUID(org_id), entry_date)


@router.get(
    "/accounting/profit-loss",
    summary="Profit & loss statement",
    response_model=ProfitLossResponse,
)
async def profit_loss(
    from_date: date,
    to_date: date,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("accounting", "read")),
):
    return await _svc(db).profit_loss(UUID(org_id), from_date, to_date)


@router.get(
    "/accounting/balance-sheet",
    summary="Balance sheet",
    response_model=BalanceSheetResponse,
)
async def balance_sheet(
    as_of: date,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("accounting", "read")),
):
    return await _svc(db).balance_sheet(UUID(org_id), as_of)
