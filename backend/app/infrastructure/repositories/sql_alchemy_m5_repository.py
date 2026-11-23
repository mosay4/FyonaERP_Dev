from datetime import datetime, timezone
from sqlalchemy import select, func, or_, update
from sqlalchemy.ext.asyncio import AsyncSession
from app.domain.entities.hr_entities import (
    Department,
    Position,
    Employee,
    Attendance,
    Leave,
    Payroll,
)
from app.domain.repositories.m5_repository import (
    DepartmentRepository,
    PositionRepository,
    EmployeeRepository,
    AttendanceRepository,
    LeaveRepository,
    PayrollRepository,
)


class SQLDepartmentRepo(DepartmentRepository):
    def __init__(self, s: AsyncSession):
        self._s = s

    async def create(self, d):
        self._s.add(d)
        await self._s.flush()
        return d

    async def get_by_id(self, id, org_id):
        r = await self._s.execute(
            select(Department).where(
                Department.id == id, Department.organization_id == org_id
            )
        )
        return r.unique().scalar_one_or_none()

    async def update(self, d):
        self._s.add(d)
        await self._s.flush()
        return d

    async def list(self, org_id):
        r = await self._s.execute(
            select(Department)
            .where(Department.organization_id == org_id)
            .order_by(Department.name)
        )
        return list(r.unique().scalars().all())


class SQLPositionRepo(PositionRepository):
    def __init__(self, s: AsyncSession):
        self._s = s

    async def create(self, p):
        self._s.add(p)
        await self._s.flush()
        return p

    async def get_by_id(self, id, org_id):
        r = await self._s.execute(
            select(Position).where(
                Position.id == id, Position.organization_id == org_id
            )
        )
        return r.unique().scalar_one_or_none()

    async def update(self, p):
        self._s.add(p)
        await self._s.flush()
        return p

    async def list(self, org_id, dept_id=None):
        q = select(Position).where(Position.organization_id == org_id)
        if dept_id:
            q = q.where(Position.department_id == dept_id)
        r = await self._s.execute(q.order_by(Position.title))
        return list(r.unique().scalars().all())


class SQLEmployeeRepo(EmployeeRepository):
    def __init__(self, s: AsyncSession):
        self._s = s

    async def create(self, e):
        self._s.add(e)
        await self._s.flush()
        return e

    async def get_by_id(self, id, org_id):
        r = await self._s.execute(
            select(Employee).where(
                Employee.id == id,
                Employee.organization_id == org_id,
                ~Employee.is_deleted,
            )
        )
        return r.unique().scalar_one_or_none()

    async def update(self, e):
        self._s.add(e)
        await self._s.flush()
        return e

    async def soft_delete(self, id, org_id):
        await self._s.execute(
            update(Employee)
            .where(Employee.id == id, Employee.organization_id == org_id)
            .values(is_deleted=True, deleted_at=datetime.now(timezone.utc))
        )
        await self._s.flush()

    async def list(
        self, org_id, search=None, dept_id=None, status=None, page=1, per_page=20
    ):
        q = select(Employee).where(
            Employee.organization_id == org_id, ~Employee.is_deleted
        )
        cq = select(func.count(Employee.id)).where(
            Employee.organization_id == org_id, ~Employee.is_deleted
        )
        if search:
            f = or_(
                Employee.full_name.ilike(f"%{search}%"),
                Employee.employee_code.ilike(f"%{search}%"),
                Employee.email.ilike(f"%{search}%"),
            )
            q, cq = q.where(f), cq.where(f)
        if dept_id:
            q, cq = q.where(Employee.department_id == dept_id), cq.where(
                Employee.department_id == dept_id
            )
        if status:
            q, cq = q.where(Employee.status == status), cq.where(
                Employee.status == status
            )
        total = (await self._s.execute(cq)).scalar() or 0
        r = await self._s.execute(
            q.order_by(Employee.full_name).offset((page - 1) * per_page).limit(per_page)
        )
        return list(r.unique().scalars().all()), total

    async def count(self, org_id, status=None):
        q = select(func.count(Employee.id)).where(
            Employee.organization_id == org_id, ~Employee.is_deleted
        )
        if status:
            q = q.where(Employee.status == status)
        return (await self._s.execute(q)).scalar() or 0


class SQLAttendanceRepo(AttendanceRepository):
    def __init__(self, s: AsyncSession):
        self._s = s

    async def create(self, a):
        self._s.add(a)
        await self._s.flush()
        return a

    async def update(self, a):
        self._s.add(a)
        await self._s.flush()
        return a

    async def list(
        self, org_id, emp_id=None, from_date=None, to_date=None, page=1, per_page=20
    ):
        from app.domain.entities.hr_entities import Employee as Emp

        q = (
            select(Attendance)
            .join(Emp, Attendance.employee_id == Emp.id)
            .where(Emp.organization_id == org_id)
        )
        cq = (
            select(func.count(Attendance.id))
            .join(Emp, Attendance.employee_id == Emp.id)
            .where(Emp.organization_id == org_id)
        )
        if emp_id:
            q, cq = q.where(Attendance.employee_id == emp_id), cq.where(
                Attendance.employee_id == emp_id
            )
        if from_date:
            q, cq = q.where(Attendance.date >= from_date), cq.where(
                Attendance.date >= from_date
            )
        if to_date:
            q, cq = q.where(Attendance.date <= to_date), cq.where(
                Attendance.date <= to_date
            )
        total = (await self._s.execute(cq)).scalar() or 0
        r = await self._s.execute(
            q.order_by(Attendance.date.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        return list(r.unique().scalars().all()), total


class SQLLeaveRepo(LeaveRepository):
    def __init__(self, s: AsyncSession):
        self._s = s

    async def create(self, l):
        self._s.add(l)
        await self._s.flush()
        return l

    async def get_by_id(self, id, org_id):
        from app.domain.entities.hr_entities import Employee as Emp

        r = await self._s.execute(
            select(Leave)
            .join(Emp, Leave.employee_id == Emp.id)
            .where(Leave.id == id, Emp.organization_id == org_id)
        )
        return r.unique().scalar_one_or_none()

    async def update(self, l):
        self._s.add(l)
        await self._s.flush()
        return l

    async def list(self, org_id, emp_id=None, status=None, page=1, per_page=20):
        from app.domain.entities.hr_entities import Employee as Emp

        q = (
            select(Leave)
            .join(Emp, Leave.employee_id == Emp.id)
            .where(Emp.organization_id == org_id)
        )
        cq = (
            select(func.count(Leave.id))
            .join(Emp, Leave.employee_id == Emp.id)
            .where(Emp.organization_id == org_id)
        )
        if emp_id:
            q, cq = q.where(Leave.employee_id == emp_id), cq.where(
                Leave.employee_id == emp_id
            )
        if status:
            q, cq = q.where(Leave.status == status), cq.where(Leave.status == status)
        total = (await self._s.execute(cq)).scalar() or 0
        r = await self._s.execute(
            q.order_by(Leave.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        return list(r.unique().scalars().all()), total

    async def count_pending(self, org_id):
        from app.domain.entities.hr_entities import Employee as Emp

        r = await self._s.execute(
            select(func.count(Leave.id))
            .join(Emp, Leave.employee_id == Emp.id)
            .where(Emp.organization_id == org_id, Leave.status == "pending")
        )
        return r.scalar() or 0


class SQLPayrollRepo(PayrollRepository):
    def __init__(self, s: AsyncSession):
        self._s = s

    async def create(self, p):
        self._s.add(p)
        await self._s.flush()
        return p

    async def get_by_id(self, id, org_id):
        r = await self._s.execute(
            select(Payroll).where(Payroll.id == id, Payroll.organization_id == org_id)
        )
        return r.unique().scalar_one_or_none()

    async def update(self, p):
        self._s.add(p)
        await self._s.flush()
        return p

    async def list(self, org_id, page=1, per_page=20):
        q = select(Payroll).where(Payroll.organization_id == org_id)
        total = (
            await self._s.execute(
                select(func.count(Payroll.id)).where(Payroll.organization_id == org_id)
            )
        ).scalar() or 0
        r = await self._s.execute(
            q.order_by(Payroll.year.desc(), Payroll.month.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        return list(r.unique().scalars().all()), total
