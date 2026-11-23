import json
from uuid import uuid4
from unittest.mock import AsyncMock

import pytest
from fastapi import FastAPI, HTTPException
from httpx import ASGITransport, AsyncClient
from starlette.requests import Request

from tests.unit.test_notifications_visibility import pg_url, db  # noqa: F401
from tests.unit.test_employee_finance import seed, payload
from app.api.deps import BranchScopeContext, get_current_org_id, get_current_user_uuid, get_branch_scope
from app.core.database import get_db
from app.api.v1 import employees as api, business
from app.domain.entities.auth_entities import Organization
from app.domain.entities.employee_workspace_entities import EmployeeInvitation, EmployeeWorkspace
from app.domain.entities.branch_entities import BranchMember
from app.domain.entities.hr_entities import Employee
from app.domain.services import employee_access_policy, falcon_service


def request():
    return Request({'type': 'http', 'method': 'POST', 'path': '/', 'headers': [],
                    'scheme': 'http', 'server': ('test', 80)})


@pytest.mark.asyncio
@pytest.mark.parametrize('kind', ['linked', 'pending', 'phone', 'code'])
async def test_duplicate_lookup_and_create_invite_reject_without_insert(db, monkeypatch, kind):
    org, owner, target, employee, branches, _ = await seed(db)
    code = str(123450 + ['linked', 'pending', 'phone', 'code'].index(kind))
    target.public_code = code; target.phone = '+966501234567'
    ws = await api._workspace(db, employee.id, org.id)
    if kind != 'linked': ws.linked_user_id = None
    if kind == 'pending':
        db.add(EmployeeInvitation(organization_id=org.id, employee_id=employee.id,
            invited_user_id=target.id, invited_by=owner.id, permissions='{}'))
    if kind == 'phone': employee.phone = '٠٠٩٦٦ ٥٠١٢٣٤٥٦٧'
    if kind == 'code': employee.employee_code = code
    await db.commit()
    monkeypatch.setattr(api, '_user_by_code', AsyncMock(return_value=target))
    flags = payload(await api.lookup_user(code, str(org.id), owner.id, db))
    key = {'linked': 'already_employee', 'pending': 'pending_invitation',
           'phone': 'existing_employee', 'code': 'existing_employee'}[kind]
    assert flags[key] is True
    scope = BranchScopeContext(branches[0].id, False, [branches[0].id])
    expected = {'linked': api.LINKED_CONFLICT, 'pending': api.PENDING_CONFLICT,
                'phone': api.FILE_CONFLICT, 'code': api.FILE_CONFLICT}[kind]
    other = Employee(organization_id=org.id, employee_code=uuid4().hex[:10], full_name='Other')
    db.add(other); await db.commit()
    for operation in [
        lambda: api.create_employee(api.EmployeeCreateBody(full_name='Duplicate', link_code=code),
            request(), str(org.id), owner.id, db, scope),
        lambda: api.invite_employee(other.id, api.InviteBody(code=code),
            request(), str(org.id), owner.id, db, scope),
    ]:
        with pytest.raises(HTTPException) as error:
            await operation()
        assert error.value.status_code == 409 and error.value.detail == expected
    assert len((await db.execute(api.select(Employee).where(Employee.organization_id == org.id))).scalars().all()) == 2


@pytest.mark.asyncio
async def test_other_merchant_identity_is_independent(db):
    org, owner, target, employee, branches, _ = await seed(db)
    other = Organization(id=uuid4(), name='Independent', slug=uuid4().hex)
    db.add(other); await db.commit()
    flags = await api._duplicate_flags(db, other.id, target, '123456')
    assert not any(flags[k] for k in ('already_employee', 'pending_invitation', 'existing_employee'))
    await api._check_duplicate(db, other.id, target, '123456', owner.id)


@pytest.mark.asyncio
async def test_invite_defaults_to_concrete_branch_and_all_mode_lists_assignments(db, monkeypatch):
    org, owner, target, employee, branches, _ = await seed(db)
    ws = await api._workspace(db, employee.id, org.id)
    ws.linked_user_id = None; await db.commit()
    monkeypatch.setattr(api, '_user_by_code', AsyncMock(return_value=target))
    monkeypatch.setattr(api, '_push_invitation', AsyncMock())
    scope = BranchScopeContext(branches[1].id, False, [branches[1].id])
    result = payload(await api.invite_employee(employee.id, api.InviteBody(code='123456'),
        request(), str(org.id), owner.id, db, scope))
    assert result['branch_ids'] == [str(branches[1].id)]
    all_scope = BranchScopeContext(None, True, [b.id for b in branches])
    listed = payload(await api.list_employees(str(org.id), owner.id, db, all_scope))['employees']
    assert len(listed) == 1 and listed[0]['managed_branches'][0]['id'] == str(branches[1].id)


@pytest.mark.asyncio
async def test_employee_lists_use_live_member_branches_and_default_new_files(db):
    org, owner, target, employee, branches, _ = await seed(db)
    main, second = branches[:2]
    member = BranchMember(organization_id=org.id, user_id=target.id, status='active',
        branch_ids=json.dumps([str(second.id)]), all_branches=False, permissions='{}')
    db.add(member); await db.commit()
    scopes = [BranchScopeContext(b.id, False, [b.id]) for b in (main, second)]
    assert payload(await api.list_employees(str(org.id), owner.id, db, scopes[0]))['employees'] == []
    listed = payload(await api.list_employees(str(org.id), owner.id, db, scopes[1]))['employees']
    assert [e['id'] for e in listed] == [str(employee.id)]
    assert listed[0]['branch_ids'] == [str(second.id)]
    result = payload(await api.create_employee(api.EmployeeCreateBody(full_name='New staff'),
        request(), str(org.id), owner.id, db, scopes[1]))
    assert result['employee']['branch_ids'] == [str(second.id)]
    member.all_branches = True; await db.commit()
    assert len(payload(await api.list_employees(str(org.id), owner.id, db, scopes[0]))['employees']) == 1
    ws = await api._workspace(db, employee.id, org.id)
    ws.linked_user_id = None; ws.branch_ids = None; await db.commit()
    assert len(payload(await api.list_employees(str(org.id), owner.id, db, scopes[0]))['employees']) == 1
    assert len(payload(await api.list_employees(str(org.id), owner.id, db, scopes[1]))['employees']) == 1


@pytest.mark.asyncio
@pytest.mark.parametrize('endpoint', ['analyze', 'chat'])
async def test_falcon_routes_reject_false_and_allow_reenabled(db, monkeypatch, endpoint):
    org, owner, target, employee, branches, _ = await seed(db)
    app = FastAPI(); app.include_router(business.router)
    app.dependency_overrides[get_db] = lambda: db
    app.dependency_overrides[get_current_org_id] = lambda: str(org.id)
    app.dependency_overrides[get_current_user_uuid] = lambda: target.id
    app.dependency_overrides[get_branch_scope] = lambda: BranchScopeContext(branches[0].id, False, [branches[0].id])
    policy = {'inventory': True, 'falcon': False}
    monkeypatch.setattr(employee_access_policy, 'member_policy', AsyncMock(side_effect=lambda *args: policy))
    service = AsyncMock(return_value={'answer': 'ok'})
    monkeypatch.setattr(falcon_service, endpoint, service)
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        body = {'scope': 'inventory', 'question': 'Inventory?'}
        denied = await client.post(f'/inventory/falcon/{endpoint}', json=body)
        assert denied.status_code == 403
        service.assert_not_awaited()
        policy['falcon'] = True
        accepted = await client.post(f'/inventory/falcon/{endpoint}', json=body)
        assert accepted.status_code == 200
