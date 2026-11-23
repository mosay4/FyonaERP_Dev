from fastapi import APIRouter, Depends, HTTPException
from typing import Optional
from uuid import UUID
from datetime import date

from ...core.database import get_db
from ...api.deps import get_current_org_id, get_current_user_uuid, require_permission
from ...api.responses import ok, created, no_content, ok_paginated
from ...domain.models.m5_models import (
    DepartmentCreate, PositionCreate, EmployeeCreate, EmployeeUpdate,
    AttendanceCreate, LeaveCreate, LeaveAction, PayrollCreate,
)
from ...domain.services.m5_service import HRService
from ...infrastructure.repositories.sql_alchemy_m5_repository import (
    SQLDepartmentRepo,
    SQLPositionRepo,
    SQLEmployeeRepo,
    SQLAttendanceRepo,
    SQLLeaveRepo,
    SQLPayrollRepo,
)

router = APIRouter(tags=["HR"])


def _svc(db):
    return HRService(
        SQLDepartmentRepo(db),
        SQLPositionRepo(db),
        SQLEmployeeRepo(db),
        SQLAttendanceRepo(db),
        SQLLeaveRepo(db),
        SQLPayrollRepo(db),
    )


# ═══ Departments ═══
@router.post("/hr/departments", summary="Create department", status_code=201)
async def create_dept(
    data: DepartmentCreate,
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "create")),
):
    return created(await _svc(db).create_dept(UUID(org), data))


@router.get("/hr/departments", summary="List departments")
async def list_depts(
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "read")),
):
    return ok(await _svc(db).list_depts(UUID(org)))


# ═══ Positions ═══
@router.post("/hr/positions", summary="Create position", status_code=201)
async def create_pos(
    data: PositionCreate,
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "create")),
):
    return created(await _svc(db).create_pos(UUID(org), data))


@router.get("/hr/positions", summary="List positions")
async def list_positions(
    dept_id: Optional[UUID] = None,
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "read")),
):
    return ok(await _svc(db).list_positions(UUID(org), dept_id))


# ═══ Employees ═══
@router.post("/hr/employees", summary="Create employee", status_code=201)
async def create_emp(
    data: EmployeeCreate,
    org=Depends(get_current_org_id),
    uid=Depends(get_current_user_uuid),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "create")),
):
    try:
        return created(await _svc(db).create_emp(UUID(org), uid, data))
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.get("/hr/employees", summary="List employees")
async def list_emps(
    search: Optional[str] = None,
    dept_id: Optional[UUID] = None,
    status: Optional[str] = None,
    page: int = 1,
    per_page: int = 20,
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "read")),
):
    items, total = await _svc(db).list_emps(
        UUID(org), search, dept_id, status, page, per_page
    )
    return ok_paginated([i.model_dump() for i in items], total, page, per_page)


@router.get("/hr/employees/{eid}", summary="Get employee")
async def get_emp(
    eid: UUID,
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "read")),
):
    try:
        return ok(await _svc(db).get_emp(eid, UUID(org)))
    except ValueError as e:
        raise HTTPException(404, str(e))


@router.put("/hr/employees/{eid}", summary="Update employee")
async def update_emp(
    eid: UUID,
    data: EmployeeUpdate,
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "update")),
):
    try:
        return ok(await _svc(db).update_emp(eid, UUID(org), data), "تم التحديث")
    except ValueError as e:
        raise HTTPException(404, str(e))


@router.delete("/hr/employees/{eid}", summary="Delete employee")
async def delete_emp(
    eid: UUID,
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "delete")),
):
    try:
        await _svc(db).delete_emp(eid, UUID(org))
        return no_content("تم الحذف")
    except ValueError as e:
        raise HTTPException(404, str(e))


# ═══ Attendance ═══
@router.post("/hr/attendance", summary="Record attendance", status_code=201)
async def create_att(
    data: AttendanceCreate,
    org=Depends(get_current_org_id),
    uid=Depends(get_current_user_uuid),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "create")),
):
    return created(await _svc(db).create_attendance(UUID(org), uid, data))


@router.get("/hr/attendance", summary="List attendance")
async def list_att(
    emp_id: Optional[UUID] = None,
    from_date: Optional[date] = None,
    to_date: Optional[date] = None,
    page: int = 1,
    per_page: int = 20,
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "read")),
):
    items, total = await _svc(db).list_attendance(
        UUID(org), emp_id, from_date, to_date, page, per_page
    )
    return ok_paginated([i.model_dump() for i in items], total, page, per_page)


# ═══ Leaves ═══
@router.post("/hr/leaves", summary="Request leave", status_code=201)
async def create_leave(
    data: LeaveCreate,
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "create")),
):
    return created(await _svc(db).create_leave(UUID(org), data))


@router.get("/hr/leaves", summary="List leaves")
async def list_leaves(
    emp_id: Optional[UUID] = None,
    status: Optional[str] = None,
    page: int = 1,
    per_page: int = 20,
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "read")),
):
    items, total = await _svc(db).list_leaves(UUID(org), emp_id, status, page, per_page)
    return ok_paginated([i.model_dump() for i in items], total, page, per_page)


@router.post("/hr/leaves/{lid}/action", summary="Approve or reject leave")
async def leave_action(
    lid: UUID,
    data: LeaveAction,
    org=Depends(get_current_org_id),
    uid=Depends(get_current_user_uuid),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "update")),
):
    try:
        if data.action == "approve":
            return ok(await _svc(db).approve_leave(lid, UUID(org), uid), "تمت الموافقة")
        else:
            return ok(await _svc(db).reject_leave(lid, UUID(org), uid), "تم الرفض")
    except ValueError as e:
        raise HTTPException(400, str(e))


# ═══ Payroll ═══
@router.post("/hr/payroll", summary="Create payroll for a month", status_code=201)
async def create_payroll(
    data: PayrollCreate,
    org=Depends(get_current_org_id),
    uid=Depends(get_current_user_uuid),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "create")),
):
    return created(await _svc(db).create_payroll(UUID(org), uid, data))


@router.get("/hr/payroll", summary="List payrolls")
async def list_payrolls(
    page: int = 1,
    per_page: int = 20,
    org=Depends(get_current_org_id),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "read")),
):
    items, total = await _svc(db).list_payrolls(UUID(org), page, per_page)
    return ok_paginated([i.model_dump() for i in items], total, page, per_page)


@router.post("/hr/payroll/{pid}/process", summary="Process payroll")
async def process_payroll(
    pid: UUID,
    org=Depends(get_current_org_id),
    uid=Depends(get_current_user_uuid),
    db=Depends(get_db),
    _=Depends(require_permission("hr", "update")),
):
    try:
        return ok(await _svc(db).process_payroll(pid, UUID(org), uid), "تمت المعالجة")
    except ValueError as e:
        raise HTTPException(400, str(e))
