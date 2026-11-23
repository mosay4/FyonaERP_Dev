"""Business reports endpoints (قسم التقارير) — read-only, permission-gated,
org/branch scoped, FX-honest. Nothing here mutates any balance or record."""

from datetime import date
from typing import Optional, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import (get_branch_scope, get_current_org_id, has_permission,
                          require_permission)
from app.api.responses import ok
from app.core.database import get_db
from app.core.qa_business_ledger import contains_registered_branch
from app.domain.entities.sale_entities import Branch
from app.domain.services import business_reports_service as svc
from app.domain.services.report_scope import ReportSession

router = APIRouter(tags=["Business Reports"])


async def _scoped(db, scope, org_id, requested=None, basis='latest_approved'):
    allowed = list(scope.branch_ids) if scope.all_mode else [scope.branch_id]
    if requested:
        bid = await _branch_or_fail(db, org_id, requested)
        if bid not in allowed:
            raise HTTPException(status_code=403, detail='الفرع خارج نطاق التقرير المسموح')
        allowed = [bid]
    if await contains_registered_branch(db, allowed):
        # The old writer cannot account for this branch's device ledger. Do
        # not return excluded/empty figures as a complete branch/org total.
        raise HTTPException(409, detail={
            'code': 'report_device_scope',
            'message': 'اختر فرع الدفتر المحلي لعرض تقريره من الجهاز.',
        })
    db.info['report_scope'] = [str(b) for b in allowed]
    db.info['report_fx_policy'] = basis
    return ReportSession(db, allowed)


def _result(db, payload):
    missing = db.info.get('report_fx_missing') or []
    if missing:
        if db.info.get('report_fx_policy') == 'latest_approved':
            raise HTTPException(status_code=409, detail={
                'code': 'report_rates_initializing',
                'message': 'جارٍ مزامنة أسعار العملات المعتمدة. القيم الأصلية محفوظة وسيكتمل التقرير بعد المزامنة.',
                'original_amounts': missing,
            })
        raise HTTPException(status_code=409, detail={
            'code': 'report_fx_missing',
            'message': 'لا يمكن اعتماد إجمالي التقرير دون سعر صرف موثق لتواريخ العمليات. القيم الأصلية محفوظة؛ أدخل السعر التاريخي المعتمد ثم أعد المحاولة.',
            'missing': missing,
        })
    metadata = db.info.get('report_fx_snapshot_metadata') or {}
    used = db.info.get('report_fx_used_currencies') or set()
    return ok({**payload, 'totals_complete': True,
               'fx_basis': {'operations':db.info.get('report_fx_policy', 'historical'),
                            'balances':'latest_approved'},
               'fx_valuation': {'basis': db.info.get('report_fx_policy', 'historical'),
                   'observed_at': metadata.get('fetched_at'),
                   'observations': {k:v for k,v in (metadata.get('observations') or {}).items() if k in used}},
               'branch_ids': db.info.get('report_scope', [])})


async def _branch_or_fail(
    db: AsyncSession, org_id: UUID, branch_id: Optional[str]
) -> Optional[UUID]:
    if not branch_id:
        return None
    bid = UUID(branch_id)
    row = (
        await db.execute(
            select(Branch).where(
                Branch.id == bid, Branch.organization_id == org_id)
        )
    ).scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="الفرع غير موجود")
    return bid


@router.get("/business-reports/home", summary="كيف شغلك؟ — KPIs + chart")
async def report_home(
    from_date: Optional[date] = Query(None),
    to_date: Optional[date] = Query(None),
    currency: str = Query("SAR"),
    valuation_basis: Literal['latest_approved', 'historical'] = 'latest_approved',
    branch_id: Optional[str] = Query(None),
    scope=Depends(get_branch_scope),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reports", "read")),
):
    start, end = svc._bounds(from_date, to_date)
    session = await _scoped(db, scope, UUID(org_id), branch_id, valuation_basis)
    return _result(db, await svc.home_report(session, UUID(org_id), start, end,
                                    currency.upper()))


@router.get("/business-reports/sales-purchases", summary="المبيعات والمشتريات")
async def report_sales_purchases(
    from_date: Optional[date] = Query(None),
    to_date: Optional[date] = Query(None),
    currency: str = Query("SAR"),
    valuation_basis: Literal['latest_approved', 'historical'] = 'latest_approved',
    branch_id: Optional[str] = Query(None),
    scope=Depends(get_branch_scope),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reports", "read")),
):
    start, end = svc._bounds(from_date, to_date)
    session = await _scoped(db, scope, UUID(org_id), branch_id, valuation_basis)
    return _result(db, await svc.sales_purchases_report(session, UUID(org_id), start, end,
                                               currency.upper()))


@router.get("/business-reports/money", summary="الفلوس والحسابات")
async def report_money(
    from_date: Optional[date] = Query(None),
    to_date: Optional[date] = Query(None),
    currency: str = Query("SAR"),
    valuation_basis: Literal['latest_approved', 'historical'] = 'latest_approved',
    account_id: Optional[str] = Query(None),
    branch_id: Optional[str] = Query(None),
    scope=Depends(get_branch_scope),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reports", "read")),
):
    start, end = svc._bounds(from_date, to_date)
    session = await _scoped(db, scope, UUID(org_id), branch_id, valuation_basis)
    return _result(db, await svc.money_report(session, UUID(org_id), start, end,
                                     currency.upper(), account_id=account_id))


@router.get("/business-reports/inventory", summary="المخزون")
async def report_inventory(
    from_date: Optional[date] = Query(None),
    to_date: Optional[date] = Query(None),
    currency: str = Query("SAR"),
    valuation_basis: Literal['latest_approved', 'historical'] = 'latest_approved',
    branch_id: Optional[str] = Query(None),
    scope=Depends(get_branch_scope),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reports", "read")),
    can_view_cost: bool = Depends(has_permission("inventory_cost", "read")),
):
    start, end = svc._bounds(from_date, to_date)
    session = await _scoped(db, scope, UUID(org_id), branch_id, valuation_basis)
    return _result(db, await svc.inventory_report_data(session, UUID(org_id), start, end,
                                              currency.upper(),
                                              can_view_cost))


@router.get("/business-reports/debts", summary="الديون")
async def report_debts(
    from_date: Optional[date] = Query(None),
    to_date: Optional[date] = Query(None),
    currency: str = Query("SAR"),
    valuation_basis: Literal['latest_approved', 'historical'] = 'latest_approved',
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reports", "read")),
):
    start, end = svc._bounds(from_date, to_date)
    session = await _scoped(db, scope, UUID(org_id), basis=valuation_basis)
    return _result(db, await svc.debts_report_data(session, UUID(org_id), start, end,
                                          currency.upper(),
                                          scope.branch_ids if scope.all_mode else [scope.branch_id]))


@router.get("/business-reports/overview", summary="نظرة شاملة على الشغل")
async def report_overview(
    from_date: Optional[date] = Query(None),
    to_date: Optional[date] = Query(None),
    currency: str = Query("SAR"),
    valuation_basis: Literal['latest_approved', 'historical'] = 'latest_approved',
    branch_id: Optional[str] = Query(None),
    scope=Depends(get_branch_scope),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reports", "read")),
):
    start, end = svc._bounds(from_date, to_date)
    session = await _scoped(db, scope, UUID(org_id), branch_id, valuation_basis)
    return _result(db, await svc.overview_report(session, UUID(org_id), start, end,
                                        currency.upper()))
