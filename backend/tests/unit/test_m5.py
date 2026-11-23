import pytest
from uuid import uuid4
from datetime import datetime, timezone, date
from unittest.mock import AsyncMock, MagicMock
from decimal import Decimal
from app.domain.models.m5_models import (
    DepartmentCreate,
    PositionCreate,
    EmployeeCreate,
)
from app.domain.services.m5_service import HRService
from app.domain.entities.hr_entities import Employee, Department, Position


@pytest.fixture
def org_id():
    return uuid4()


@pytest.fixture
def user_id():
    return uuid4()


@pytest.fixture
def svc():
    return HRService(
        AsyncMock(), AsyncMock(), AsyncMock(), AsyncMock(), AsyncMock(), AsyncMock()
    )


def mock_emp(org_id, **kw):
    e = MagicMock(spec=Employee)
    e.id = uuid4()
    e.organization_id = org_id
    e.employee_code = "EMP001"
    e.full_name = "test"
    e.email = None
    e.phone = None
    e.department_id = None
    e.department = None
    e.position_id = None
    e.position = None
    e.hire_date = date.today()
    e.salary = Decimal("5000")
    e.status = "active"
    e.id_number = None
    e.gender = None
    e.date_of_birth = None
    e.address = None
    e.emergency_contact = None
    e.emergency_phone = None
    e.bank_name = None
    e.bank_account = None
    e.iban = None
    e.notes = None
    e.created_at = datetime.now(timezone.utc)
    e.updated_at = datetime.now(timezone.utc)
    for k, v in kw.items():
        setattr(e, k, v)
    return e


class TestHRService:
    async def test_create_dept(self, svc, org_id):
        d = MagicMock(spec=Department)
        d.id = uuid4()
        d.organization_id = org_id
        d.name = "IT"
        d.name_ar = None
        d.description = None
        d.is_active = True
        d.created_at = datetime.now(timezone.utc)
        svc._d.create.return_value = d
        r = await svc.create_dept(org_id, DepartmentCreate(name="IT"))
        assert r.name == "IT"

    async def test_create_pos(self, svc, org_id):
        p = MagicMock(spec=Position)
        p.id = uuid4()
        p.organization_id = org_id
        p.title = "Manager"
        p.title_ar = None
        p.description = None
        p.department_id = None
        p.department = None
        p.is_active = True
        p.created_at = datetime.now(timezone.utc)
        svc._p.create.return_value = p
        r = await svc.create_pos(org_id, PositionCreate(title="Manager"))
        assert r.title == "Manager"

    async def test_create_emp(self, svc, org_id, user_id):
        emp = mock_emp(org_id)
        svc._e.create.return_value = emp
        svc._e.get_by_id.return_value = emp
        data = EmployeeCreate(employee_code="E001", full_name="Test")
        r = await svc.create_emp(org_id, user_id, data)
        assert r is not None

    async def test_get_emp_not_found(self, svc, org_id):
        svc._e.get_by_id.return_value = None
        with pytest.raises(ValueError):
            await svc.get_emp(uuid4(), org_id)

    async def test_list_emps(self, svc, org_id):
        svc._e.list.return_value = ([], 0)
        items, total = await svc.list_emps(org_id)
        assert total == 0
