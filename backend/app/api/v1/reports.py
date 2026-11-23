from fastapi import APIRouter, Depends
from uuid import UUID
from datetime import date

from ...core.database import get_db
from ...api.deps import get_current_org_id, get_branch_scope, require_permission
from ...api.responses import ok
from ...domain.services.m5_service import HRService
from ...infrastructure.repositories.sql_alchemy_m5_repository import (
    SQLDepartmentRepo,
    SQLPositionRepo,
    SQLEmployeeRepo,
    SQLAttendanceRepo,
    SQLLeaveRepo,
    SQLPayrollRepo,
)

router = APIRouter(tags=["Reports"])


def _svc(db):
    return HRService(
        SQLDepartmentRepo(db),
        SQLPositionRepo(db),
        SQLEmployeeRepo(db),
        SQLAttendanceRepo(db),
        SQLLeaveRepo(db),
        SQLPayrollRepo(db),
    )


@router.get("/reports/kpi", summary="Dashboard KPIs")
async def kpi(
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("reports", "read")),
):
    return ok(await _svc(db).kpi(UUID(org)))


@router.get("/reports/sales", summary="Sales report")
async def sales_report(
    from_date: date,
    to_date: date,
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("reports", "read")),
):
    return ok(await _svc(db).sales_report(UUID(org), from_date, to_date))


@router.get("/reports/inventory", summary="Inventory report")
async def inventory_report(
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("reports", "read")),
    scope=Depends(get_branch_scope),
):
    from ...domain.services.report_scope import ReportSession
    session = ReportSession(db, scope.branch_ids if scope.all_mode else [scope.branch_id])
    return ok(await _svc(session).inventory_report(UUID(org)))
