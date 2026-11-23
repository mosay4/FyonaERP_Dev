"""Employee workspace for merchant-managed staff.

Extends the existing HR employee file without changing its historical rows.
"""
import base64
import io
import json
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Dict, List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import AliasChoices, BaseModel, Field
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from ...api.deps import get_current_org_id, get_current_user_uuid, get_branch_scope
from ...api.responses import created, no_content, ok
from ...core.database import get_db
from ...domain.entities.auth_entities import Organization, User
from ...domain.entities.branch_entities import BranchMember
from ...domain.entities.finance_entities import BankAccount
from ...domain.entities.sale_entities import Branch
from ...domain.entities.hr_entities import Employee
from ...domain.entities.employee_workspace_entities import (
    EmployeeWorkspace, EmployeeInvitation, EmployeeSalaryPayment, EmployeeDebt)
from ...domain.services import branch_access_service as access
from ...domain.services.push_service import notify_user
from ...domain.services.employment_notification_service import save_employment_event
from ...domain.services.employee_receipt_service import identity_snapshot, salary_receipt, debt_receipt

router = APIRouter(prefix="/employees", tags=["Employees"])
UTC = timezone.utc

TOP_KEYS = ['dashboard', 'ai', 'reports', 'reconciliation', 'banks', 'sales',
            'purchases', 'returns', 'invoices', 'inventory', 'customers',
            'suppliers', 'debts', 'employees', 'branches', 'suggestions',
            'notifications', 'chat', 'transfers']
CHILD_KEYS = {
    'banks': ['add_delete', 'transfer', 'details', 'balances'],
    'sales': ['create', 'view', 'delete', 'returns'],
    'purchases': ['create', 'view', 'delete', 'returns'],
    'inventory': ['add', 'edit', 'delete', 'count', 'transfer'],
    'customers': ['add', 'edit', 'delete', 'details'],
    'suppliers': ['add', 'edit', 'delete', 'details'],
    'debts': ['add', 'settle', 'details'],
    'reports': ['view', 'export'],
    'reconciliation': ['bank', 'inventory', 'equalize'],
    'employees': ['view', 'manage', 'salary', 'debts'],
    'branches': ['view', 'transfer', 'manage'],
}


def default_permissions() -> Dict[str, bool]:
    from ...domain.services.employee_access_policy import GROUPS
    result = {key: True for key in GROUPS}
    for parent, children in GROUPS.items():
        for child in children:
            result[f'{parent}.{child}'] = True
    return result


def _perm(raw: str | None) -> Dict[str, bool]:
    base = default_permissions()
    try:
        loaded = json.loads(raw or '{}')
        if isinstance(loaded, dict):
            base.update({str(k): v is True for k, v in loaded.items()
                         if str(k) in base})
    except Exception:
        pass
    return base


def _owner(user: User, org_id: uuid.UUID) -> bool:
    return ((user.role or '').lower() == 'owner' or bool(user.is_platform_admin)) \
        and str(user.organization_id) == str(org_id)


async def _owner_check(db: AsyncSession, org_id: str, user_id: uuid.UUID) -> User:
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    if user is None:
        raise HTTPException(401, detail='المستخدم غير موجود')
    if not _owner(user, uuid.UUID(str(org_id))):
        raise HTTPException(403, detail='إدارة الموظفين متاحة للتاجر فقط')
    return user


def _employee_dict(e: Employee, ws: EmployeeWorkspace | None,
                   user: User | None = None) -> Dict:
    from ...domain.services.employee_presence_service import is_online
    return {
        'id': str(e.id), 'full_name': e.full_name,
        'employee_code': e.employee_code, 'email': e.email, 'phone': e.phone,
        'salary': float(e.salary or 0),
        'salary_currency': (ws.salary_currency if ws else 'SAR'),
        'photo_url': (ws.photo_url if ws else None),
        'status': (ws.linked_user_id and 'linked') if ws and ws.linked_user_id
                  else 'unlinked',
        'linked_user_id': str(ws.linked_user_id) if ws and ws.linked_user_id else None,
        'permissions': _perm(ws.permissions if ws else '{}'),
        'branch_ids': json.loads(ws.branch_ids) if ws and ws.branch_ids is not None else None,
        'notes': e.notes, 'created_at': e.created_at.isoformat() if e.created_at else None,
        'online': is_online(ws),
        'user_name': user.full_name if user else None,
        'user_code': user.public_code if user else None,
        'user_avatar': user.photo_url if user else None,
    }


async def _workspace(db: AsyncSession, employee_id: uuid.UUID,
                     org_id: uuid.UUID) -> EmployeeWorkspace | None:
    return (await db.execute(select(EmployeeWorkspace).where(
        EmployeeWorkspace.employee_id == employee_id,
        EmployeeWorkspace.organization_id == org_id))).scalar_one_or_none()


async def _workspace_get_or_create(db: AsyncSession, employee: Employee) -> EmployeeWorkspace:
    ws = await _workspace(db, employee.id, employee.organization_id)
    if ws is None:
        ws = EmployeeWorkspace(employee_id=employee.id,
            organization_id=employee.organization_id, salary_currency='SAR',
            permissions=json.dumps(default_permissions()))
        db.add(ws)
        await db.flush()
    return ws


def _save_photo(raw: str | None) -> str | None:
    if not raw:
        return None
    try:
        value = raw.split(',', 1)[-1]
        data = base64.b64decode(value)
        if len(data) > 3 * 1024 * 1024:
            raise ValueError('حجم الصورة أكبر من 3MB')
        from PIL import Image
        image = Image.open(io.BytesIO(data)).convert('RGB')
        image.thumbnail((512, 512))
        out = io.BytesIO()
        image.save(out, format='JPEG', quality=86, optimize=True)
        return 'data:image/jpeg;base64,' + base64.b64encode(out.getvalue()).decode()
    except Exception as e:
        raise HTTPException(400, detail=f'صورة غير صالحة: {e}')


async def _user_by_code(db: AsyncSession, code: str) -> User | None:
    from ...core.phone_lookup import ascii_digits, phone_lookup_keys
    code = (code or '').strip()
    if not code:
        return None
    if '*' in code or any(ch.isalpha() for ch in code): return None
    normalized = ascii_digits(code)
    found = (await db.execute(select(User).where(User.public_code == normalized,
        User.status == 'active'))).scalar_one_or_none() if len(normalized) == 6 else None
    if found is not None:
        return found
    full, national = phone_lookup_keys(code)
    if full is None: return None
    exact = (await db.execute(select(User).where(User.phone_lookup_digits == full,
        User.status == 'active').limit(2))).scalars().all()
    if len(exact) == 1: return exact[0]
    if len(exact) > 1:
        raise HTTPException(409, detail='رقم الهاتف مربوط بأكثر من حساب، استخدم الرقم المميز')
    # National lookup is allowed only if unambiguous. Country-prefixed input
    # must not silently match an unrelated account in another country.
    if code.startswith('+') or normalized.startswith('00') or len(normalized) > 10: return None
    matches = (await db.execute(select(User).where(User.phone_national_digits == national,
        User.status == 'active').limit(2))).scalars().all()
    if len(matches) == 1: return matches[0]
    if len(matches) > 1:
        raise HTTPException(409, detail='يوجد أكثر من حساب بهذا الرقم المحلي؛ اكتب رمز الدولة أو الرقم المميز')
    return None


async def _validate_employee_branches(db: AsyncSession, org: uuid.UUID,
                                      branch_ids: Optional[List[uuid.UUID]]) -> Optional[str]:
    if branch_ids is None:
        return None  # Legacy invitations retain their existing scope.
    selected = set(branch_ids)
    if not selected:
        raise HTTPException(400, detail='اختر فرعاً واحداً على الأقل للموظف')
    allowed = set((await db.execute(select(Branch.id).where(
        Branch.organization_id == org, Branch.is_active.is_(True),
        Branch.is_archived.is_(False), Branch.id.in_(selected)))).scalars().all())
    if allowed != selected:
        raise HTTPException(400, detail='الفروع المختارة غير متاحة في مشروعك')
    return json.dumps(sorted(str(x) for x in selected))


LINKED_CONFLICT = 'هذا الموظف مضاف عندك من قبل، ما ينفع تضيفه مرتين'
PENDING_CONFLICT = 'عندك طلب توظيف لهذا الموظف لسه ما رد. انتظر موافقته أو رفضه، واطلب منه يوافق على الطلب السابق'
FILE_CONFLICT = 'عندك ملف موظف بنفس رقم الهاتف أو الرقم المميز؛ افتح الملف الموجود واربطه بدل إضافة موظف جديد'


async def _lock_employee_org(db, org):
    # Serialize identity checks and inserts, including requests for different HR
    # files pointing at the same account. Other merchants use independent locks.
    await db.execute(select(Organization.id).where(Organization.id == org).with_for_update())


async def _duplicate_flags(db, org, target, code, exclude_employee_id=None):
    linked = (await db.execute(select(Employee).join(EmployeeWorkspace,
        EmployeeWorkspace.employee_id == Employee.id).where(
        Employee.organization_id == org, Employee.is_deleted.is_(False),
        EmployeeWorkspace.organization_id == org,
        EmployeeWorkspace.linked_user_id == target.id).limit(1))).scalars().first()
    pending = (await db.execute(select(EmployeeInvitation).where(
        EmployeeInvitation.organization_id == org,
        EmployeeInvitation.invited_user_id == target.id,
        EmployeeInvitation.status == 'pending').limit(1))).scalars().first()
    from ...core.phone_lookup import ascii_digits, phone_lookup_keys
    phone = phone_lookup_keys(target.phone)
    target_code = ascii_digits(target.public_code)
    rows = (await db.execute(select(Employee).outerjoin(EmployeeWorkspace,
        EmployeeWorkspace.employee_id == Employee.id).where(
        Employee.organization_id == org, Employee.is_deleted.is_(False),
        EmployeeWorkspace.linked_user_id.is_(None)))).scalars().all()
    existing = None
    for employee in rows:
        if employee.id == exclude_employee_id:
            continue
        stored = phone_lookup_keys(employee.phone)
        same_phone = bool(phone[0] and stored[0] and (phone[0] == stored[0] or
            (phone[1] == stored[1] and (phone[0] == phone[1] or stored[0] == stored[1]))))
        if same_phone or (target_code and ascii_digits(employee.employee_code) == target_code):
            existing = employee
            break
    return {'already_employee': linked is not None,
        'employee_name': linked.full_name if linked else None,
        'pending_invitation': pending is not None,
        'invitation_id': str(pending.id) if pending else None,
        'existing_employee': existing is not None,
        'existing_employee_id': str(existing.id) if existing else None,
        'existing_employee_name': existing.full_name if existing else None}


async def _check_duplicate(db, org, target, code, actor, exclude_employee_id=None):
    if target.id == actor:
        raise HTTPException(400, detail='لا يمكن ربط حساب التاجر كموظف')
    flags = await _duplicate_flags(db, org, target, code, exclude_employee_id)
    for key, message in [('already_employee', LINKED_CONFLICT),
                         ('pending_invitation', PENDING_CONFLICT),
                         ('existing_employee', FILE_CONFLICT)]:
        if flags[key]:
            raise HTTPException(409, detail=message)


def _employee_branch_ids(workspace, member, branches):
    if workspace and workspace.linked_user_id:
        if member is None or member.status != 'active':
            return []
        if member.all_branches:
            return [str(b.id) for b in branches]
        ids = json.loads(member.branch_ids) if member.branch_ids is not None else None
    else:
        ids = json.loads(workspace.branch_ids) if workspace and workspace.branch_ids is not None else None
    return ids if ids is not None else [str(b.id) for b in branches if b.is_default]


class EmployeeCreateBody(BaseModel):
    full_name: str = Field(min_length=2, max_length=200)
    employee_code: Optional[str] = Field(default=None, max_length=50)
    salary: Decimal = Decimal('0')
    salary_currency: str = Field(default='SAR', max_length=20)
    phone: Optional[str] = Field(default=None, max_length=50)
    photo_base64: Optional[str] = None
    notes: Optional[str] = None
    link_code: Optional[str] = None
    permissions: Optional[Dict[str, bool]] = None
    branch_ids: Optional[List[uuid.UUID]] = None


class EmployeeUpdateBody(BaseModel):
    full_name: Optional[str] = None
    employee_code: Optional[str] = None
    salary: Optional[Decimal] = None
    salary_currency: Optional[str] = None
    phone: Optional[str] = None
    photo_base64: Optional[str] = None
    notes: Optional[str] = None
    permissions: Optional[Dict[str, bool]] = None
    branch_ids: Optional[List[uuid.UUID]] = None


class InviteBody(BaseModel):
    code: str
    permissions: Optional[Dict[str, bool]] = None
    branch_ids: Optional[List[uuid.UUID]] = None


class RespondBody(BaseModel):
    accept: bool


class SalaryBody(BaseModel):
    idempotency_key: Optional[str] = Field(default=None, min_length=8, max_length=120)
    amount: Decimal = Field(gt=0, max_digits=12, decimal_places=2, allow_inf_nan=False)
    currency: str = 'SAR'
    payment_currency: Optional[str] = None
    exchange_rate: Optional[Decimal] = Field(default=None, validation_alias=AliasChoices('exchange_rate', 'fx_rate'), gt=0, max_digits=24, decimal_places=12, allow_inf_nan=False)
    notes: Optional[str] = None
    bank_account_id: Optional[uuid.UUID] = None
    branch_id: Optional[uuid.UUID] = None


class DebtBody(BaseModel):
    debt_id: Optional[uuid.UUID] = Field(default=None, validation_alias=AliasChoices('debt_id', 'source_debt_id'))
    idempotency_key: Optional[str] = Field(default=None, min_length=8, max_length=120)
    direction: str = Field(pattern='^(employee_owes|employer_owes)$')
    kind: str = Field(default='charge', pattern='^(charge|settlement)$')
    amount: Decimal = Field(gt=0, max_digits=12, decimal_places=2, allow_inf_nan=False)
    currency: str = 'SAR'
    payment_currency: Optional[str] = None
    exchange_rate: Optional[Decimal] = Field(default=None, validation_alias=AliasChoices('exchange_rate', 'fx_rate'), gt=0, max_digits=24, decimal_places=12, allow_inf_nan=False)
    notes: Optional[str] = None
    bank_account_id: Optional[uuid.UUID] = None
    branch_id: Optional[uuid.UUID] = None


@router.get('', summary='List employees')
async def list_employees(org_id: str = Depends(get_current_org_id),
                         user_id: uuid.UUID = Depends(get_current_user_uuid),
                         db: AsyncSession = Depends(get_db),
                         scope=Depends(get_branch_scope)):
    await _owner_check(db, org_id, user_id)
    org = uuid.UUID(str(org_id))
    rows = (await db.execute(select(Employee, EmployeeWorkspace, User)
        .outerjoin(EmployeeWorkspace, EmployeeWorkspace.employee_id == Employee.id)
        .outerjoin(User, User.id == EmployeeWorkspace.linked_user_id)
        .where(Employee.organization_id == org, Employee.is_deleted.is_(False))
        .order_by(Employee.created_at.desc()))).all()
    from ...domain.services.branch_service import branch_dict
    branches = (await db.execute(select(Branch).where(Branch.organization_id == org,
        Branch.is_active.is_(True), Branch.is_archived.is_(False)).order_by(Branch.is_default.desc(), Branch.name))).scalars().all()
    members = {member.user_id: member for member in (await db.execute(select(BranchMember).where(
        BranchMember.organization_id == org,
        BranchMember.user_id.in_([ws.linked_user_id for _, ws, _ in rows if ws and ws.linked_user_id])
    ))).scalars().all()}
    result = []
    for employee, workspace, user in rows:
        entry = _employee_dict(employee, workspace, user)
        ids = _employee_branch_ids(workspace,
            members.get(workspace.linked_user_id) if workspace else None, branches)
        assigned = set(ids)
        permitted = {str(b) for b in scope.branch_ids} if scope.all_mode else {str(scope.branch_id)}
        if not assigned.intersection(permitted):
            continue
        entry['branch_ids'] = ids
        entry['managed_branches'] = [branch_dict(branch) for branch in branches
            if str(branch.id) in assigned]
        result.append(entry)
    return ok({'employees': result})


@router.get('/lookup', summary='Find user by public code')
async def lookup_user(code: str = Query(min_length=4),
                      org_id: str = Depends(get_current_org_id),
                      user_id: uuid.UUID = Depends(get_current_user_uuid),
                      db: AsyncSession = Depends(get_db)):
    await _owner_check(db, org_id, user_id)
    target = await _user_by_code(db, code)
    if target is None:
        raise HTTPException(404, detail='ما لقينا حساب بهذا الرقم. تأكد من رقم الهاتف مع رمز الدولة أو الرقم المميز')
    if str(target.id) == str(user_id):
        raise HTTPException(400, detail='لا يمكن ربط حساب التاجر كموظف')
    from ...core.phone_lookup import ascii_digits
    by_code = str(target.public_code or '') == ascii_digits(code)
    flags = await _duplicate_flags(db, uuid.UUID(str(org_id)), target, code)
    return ok({**flags, 'user': {'id': str(target.id), 'name': target.full_name,
        **flags,
        'photo_url': target.photo_url,
        'match_type': 'code' if by_code else 'phone',
        'public_code': target.public_code if by_code else None,
        'phone': target.phone if not by_code else None}})


@router.post('', status_code=201, summary='Create employee')
async def create_employee(data: EmployeeCreateBody, request: Request,
                          org_id: str = Depends(get_current_org_id),
                          user_id: uuid.UUID = Depends(get_current_user_uuid),
                          db: AsyncSession = Depends(get_db),
                          scope=Depends(get_branch_scope)):
    await _owner_check(db, org_id, user_id)
    org = uuid.UUID(str(org_id))
    await _lock_employee_org(db, org)
    branch_scope = await _validate_employee_branches(db, org,
        data.branch_ids if data.branch_ids is not None or scope.all_mode else [scope.branch_id])
    target = None
    if data.link_code:
        target = await _user_by_code(db, data.link_code)
        if target is None:
            raise HTTPException(404, detail='ما لقينا حساب برقم الهاتف أو الرقم المميز المدخل')
        await _check_duplicate(db, org, target, data.link_code, user_id)
    code = (data.employee_code or '').strip() or f"EMP-{uuid.uuid4().hex[:6].upper()}"
    if await db.scalar(select(Employee.id).where(
            Employee.organization_id == org, Employee.employee_code == code,
            Employee.is_deleted.is_(False))):
        raise HTTPException(409, detail='رقم الموظف مستخدم مسبقاً')
    employee = Employee(organization_id=org, employee_code=code,
        full_name=data.full_name.strip(), salary=data.salary,
        phone=(data.phone or '').strip() or None, notes=data.notes, created_by=user_id, status='active')
    db.add(employee)
    await db.flush()
    ws = EmployeeWorkspace(employee_id=employee.id, organization_id=org,
        salary_currency=(data.salary_currency or 'SAR').upper(),
        permissions=json.dumps(_perm(json.dumps(data.permissions or {}))),
        branch_ids=branch_scope,
        photo_url=_save_photo(data.photo_base64))
    db.add(ws)
    invitation = None
    if target is not None:
        invitation = await _create_invitation(db, org, employee, target, user_id,
                                               ws.permissions, ws.branch_ids)
    await db.commit()
    if invitation is not None:
        await _push_invitation(db, invitation, base_url=str(request.base_url))
    return created({'employee': _employee_dict(employee, ws),
                    'invitation': _invite_dict(invitation) if invitation else None},
                   'تم إنشاء الموظف')


@router.put('/{employee_id}', summary='Update employee')
async def update_employee(employee_id: uuid.UUID, data: EmployeeUpdateBody,
                          org_id: str = Depends(get_current_org_id),
                          user_id: uuid.UUID = Depends(get_current_user_uuid),
                          db: AsyncSession = Depends(get_db)):
    await _owner_check(db, org_id, user_id)
    org = uuid.UUID(str(org_id))
    employee = (await db.execute(select(Employee).where(
        Employee.id == employee_id, Employee.organization_id == org,
        Employee.is_deleted.is_(False)).with_for_update())).scalar_one_or_none()
    if employee is None:
        raise HTTPException(404, detail='الموظف غير موجود')
    branch_scope = await _validate_employee_branches(db, org, data.branch_ids)
    if data.full_name is not None: employee.full_name = data.full_name.strip()
    if data.employee_code is not None:
        new_code = data.employee_code.strip()
        if new_code and new_code != employee.employee_code:
            if await db.scalar(select(Employee.id).where(
                    Employee.organization_id == org, Employee.employee_code == new_code,
                    Employee.id != employee.id, Employee.is_deleted.is_(False))):
                raise HTTPException(409, detail='رقم الموظف مستخدم مسبقاً')
            employee.employee_code = new_code
    if data.salary is not None: employee.salary = data.salary
    if data.phone is not None: employee.phone = data.phone.strip() or None
    if data.notes is not None: employee.notes = data.notes
    ws = await _workspace_get_or_create(db, employee)
    if data.salary_currency: ws.salary_currency = data.salary_currency.upper()
    if data.photo_base64 is not None:
        ws.photo_url = _save_photo(data.photo_base64)
    if data.permissions is not None:
        ws.permissions = json.dumps(_perm(json.dumps({**_perm(ws.permissions), **data.permissions})))
    if data.branch_ids is not None:
        ws.branch_ids = branch_scope
    if ws.linked_user_id:
        member = (await db.execute(select(BranchMember).where(
            BranchMember.organization_id == org,
            BranchMember.user_id == ws.linked_user_id))).scalar_one_or_none()
        if member is not None:
            member.permissions = ws.permissions
            member.all_branches = ws.branch_ids is None
            member.branch_ids = ws.branch_ids or '[]'
    await db.commit()
    target = (await db.execute(select(User).where(User.id == ws.linked_user_id))).scalar_one_or_none() if ws.linked_user_id else None
    return ok(_employee_dict(employee, ws, target), 'تم تحديث الموظف')


@router.post('/{employee_id}/invite', summary='Invite/link employee account')
async def invite_employee(employee_id: uuid.UUID, data: InviteBody, request: Request,
                          org_id: str = Depends(get_current_org_id),
                          user_id: uuid.UUID = Depends(get_current_user_uuid),
                          db: AsyncSession = Depends(get_db),
                          scope=Depends(get_branch_scope)):
    await _owner_check(db, org_id, user_id)
    org = uuid.UUID(str(org_id))
    await _lock_employee_org(db, org)
    employee = (await db.execute(select(Employee).where(
        Employee.id == employee_id, Employee.organization_id == org,
        Employee.is_deleted.is_(False)))).scalar_one_or_none()
    if employee is None:
        raise HTTPException(404, detail='الموظف غير موجود')
    branch_scope = await _validate_employee_branches(db, org,
        data.branch_ids if data.branch_ids is not None or scope.all_mode else [scope.branch_id])
    target = await _user_by_code(db, data.code)
    if target is None:
        raise HTTPException(404, detail='ما لقينا حساب برقم الهاتف أو الرقم المميز المدخل')
    await _check_duplicate(db, org, target, data.code, user_id, employee.id)
    ws = await _workspace_get_or_create(db, employee)
    if ws.linked_user_id:
        raise HTTPException(409, detail=LINKED_CONFLICT)
    if data.permissions:
        ws.permissions = json.dumps(_perm(json.dumps({**_perm(ws.permissions), **data.permissions})))
    ws.branch_ids = branch_scope
    invitation = await _create_invitation(db, org, employee, target, user_id,
                                          ws.permissions, ws.branch_ids)
    await db.commit()
    await _push_invitation(db, invitation, base_url=str(request.base_url))
    return ok(_invite_dict(invitation), 'تم إرسال طلب التوظيف')


def _invite_dict(inv: EmployeeInvitation) -> Dict:
    return {'id': str(inv.id), 'employee_id': str(inv.employee_id),
            'status': inv.status, 'created_at': inv.created_at.isoformat() if inv.created_at else None,
            'permissions': _perm(inv.permissions),
            'branch_ids': json.loads(inv.branch_ids) if inv.branch_ids is not None else None}


async def _create_invitation(db: AsyncSession, org: uuid.UUID, employee: Employee,
                             target: User, actor: uuid.UUID,
                             permissions: str, branch_ids: str | None = None) -> EmployeeInvitation:
    existing = (await db.execute(select(EmployeeInvitation).where(
        EmployeeInvitation.employee_id == employee.id,
        EmployeeInvitation.invited_user_id == target.id,
        EmployeeInvitation.status == 'pending'))).scalar_one_or_none()
    if existing:
        existing.permissions = permissions
        existing.branch_ids = branch_ids
        invitation = existing
    else:
        invitation = EmployeeInvitation(organization_id=org, employee_id=employee.id,
            invited_user_id=target.id, invited_by=actor, permissions=permissions,
            branch_ids=branch_ids)
        db.add(invitation)
    await db.flush()
    from ...domain.services.merchant_identity_service import business_identity
    identity = await business_identity(db, org)
    org_name = identity['name']
    await save_employment_event(db, recipient_id=target.id,
        event_id=f'employee_invite:{invitation.id}', title=f'طلب توظيف من {org_name}',
        body=f'يدعوك متجر {org_name} للانضمام إلى فريقه. افتح الطلب وشوف بيانات التاجر قبل الموافقة.',
        route=f'/job-requests?invite={invitation.id}', image_url=identity['photo_url'])
    return invitation


async def _push_invitation(db: AsyncSession, invitation: EmployeeInvitation, base_url: str | None = None) -> None:
    from ...domain.services.merchant_identity_service import business_identity
    from urllib.parse import urljoin
    identity = await business_identity(db, invitation.organization_id)
    org_name = identity['name']
    image = identity['photo_url']
    if base_url and image and not image.startswith('data:'): image = urljoin(base_url, image)
    await notify_user(db, user_id=invitation.invited_user_id, title=f'طلب توظيف من {org_name}',
        body=f'يدعوك متجر {org_name} للانضمام إلى فريقه. افتح الطلب وشوف بيانات التاجر قبل الموافقة.',
        action='open_screen', action_payload=f'/job-requests?invite={invitation.id}', image_url=image)


async def _invitation_view(db: AsyncSession, inv: EmployeeInvitation,
                           emp: Employee, ws: EmployeeWorkspace | None,
                           org: Organization) -> Dict:
    merchant = await db.get(User, inv.invited_by) if inv.invited_by else None
    if merchant is None:
        merchant = (await db.execute(select(User).where(User.organization_id == org.id,
            User.role == 'owner').order_by(User.created_at.asc()))).scalars().first()
    active_branches = (await db.execute(select(Branch).where(
        Branch.organization_id == org.id, Branch.is_active.is_(True),
        Branch.is_archived.is_(False)).order_by(Branch.is_default.desc(), Branch.name))).scalars().all()
    main = next((b for b in active_branches if b.is_default), None)
    from ...domain.services.merchant_identity_service import business_identity
    identity = await business_identity(db, org.id)
    allowed = []
    if inv.status == 'accepted':
        allowed_ids = set(await access.effective_branch_ids(db, org.id, inv.invited_user_id))
        allowed = [{'id': str(b.id), 'name': b.name, 'image': b.image}
                   for b in active_branches if b.id in allowed_ids]
    return {**_invite_dict(inv), 'employee': (
            _employee_dict(emp, ws) if inv.status == 'accepted'
            else {'id': str(emp.id), 'full_name': emp.full_name}),
        'organization': {'id': str(org.id), 'name': identity['name'],
                         'photo_url': identity['photo_url']},
        'merchant': {'id': str(merchant.id) if merchant else None,
                     'name': identity['name'],
                     'phone': identity['phone'] or (merchant.phone if merchant else None),
                     'photo_url': identity['photo_url']},
        'branches': allowed,
        'salary': float(emp.salary or 0),
        'salary_currency': ws.salary_currency if ws else 'SAR'}


@router.get('/invitations/me', summary='My employment requests')
async def my_invitations(user_id: uuid.UUID = Depends(get_current_user_uuid),
                         db: AsyncSession = Depends(get_db)):
    rows = (await db.execute(select(EmployeeInvitation, Employee, EmployeeWorkspace, Organization)
        .join(Employee, Employee.id == EmployeeInvitation.employee_id)
        .outerjoin(EmployeeWorkspace, EmployeeWorkspace.employee_id == Employee.id)
        .join(Organization, Organization.id == EmployeeInvitation.organization_id)
        .where(EmployeeInvitation.invited_user_id == user_id,
               EmployeeInvitation.status.in_(['pending', 'accepted']))
        .order_by(EmployeeInvitation.created_at.desc()))).all()
    out = []
    for inv, emp, ws, org in rows:
        if emp.is_deleted or emp.organization_id != org.id or (ws is not None and (
                ws.organization_id != org.id or ws.linked_user_id not in (None, user_id))):
            continue
        if inv.status == 'accepted' and (ws is None or ws.linked_user_id != user_id
                or await access.get_member(db, org.id, user_id) is None):
            continue
        out.append(await _invitation_view(db, inv, emp, ws, org))
    return ok({'invitations': out})


@router.get('/invitations/{invitation_id}', summary='Open my exact employment invitation')
async def invitation_detail(invitation_id: uuid.UUID,
                             user_id: uuid.UUID = Depends(get_current_user_uuid),
                             db: AsyncSession = Depends(get_db)):
    inv = (await db.execute(select(EmployeeInvitation).where(
        EmployeeInvitation.id == invitation_id, EmployeeInvitation.invited_user_id == user_id,
        EmployeeInvitation.status.in_(['pending', 'accepted'])))).scalar_one_or_none()
    if inv is None:
        raise HTTPException(404, detail='طلب التوظيف غير موجود أو تم إلغاء الربط')
    emp = await db.get(Employee, inv.employee_id)
    ws = await db.get(EmployeeWorkspace, inv.employee_id)
    if emp is None or emp.is_deleted or emp.organization_id != inv.organization_id or (
            ws is not None and (ws.organization_id != inv.organization_id or
                                ws.linked_user_id not in (None, user_id))) or (inv.status == 'accepted' and (
            ws is None or ws.linked_user_id != user_id or
            await access.get_member(db, inv.organization_id, user_id) is None)):
        raise HTTPException(404, detail='طلب التوظيف غير موجود أو تم إلغاء الربط')
    org = await db.get(Organization, inv.organization_id)
    return ok(await _invitation_view(db, inv, emp, ws, org))


@router.post('/invitations/{invitation_id}/respond', summary='Respond to employment request')
async def respond_invitation(invitation_id: uuid.UUID, data: RespondBody,
                             user_id: uuid.UUID = Depends(get_current_user_uuid),
                             db: AsyncSession = Depends(get_db)):
    inv = (await db.execute(select(EmployeeInvitation).where(
        EmployeeInvitation.id == invitation_id,
        EmployeeInvitation.invited_user_id == user_id,
        EmployeeInvitation.status == 'pending'))).scalar_one_or_none()
    if inv is None:
        raise HTTPException(404, detail='طلب التوظيف غير موجود')
    # Lock the relationship before invitations/workspaces, the same order as
    # unlink. Re-read the invitation after waiting so a deleted pending request
    # can never resurrect a relationship that was just revoked.
    member = (await db.execute(select(BranchMember).where(
        BranchMember.organization_id == inv.organization_id,
        BranchMember.user_id == user_id).with_for_update())).scalar_one_or_none()
    inv = (await db.execute(select(EmployeeInvitation).where(
        EmployeeInvitation.id == invitation_id,
        EmployeeInvitation.invited_user_id == user_id,
        EmployeeInvitation.status == 'pending').with_for_update()
        .execution_options(populate_existing=True))).scalar_one_or_none()
    if inv is None:
        raise HTTPException(404, detail='طلب التوظيف غير موجود')
    if not data.accept:
        inv.status = 'rejected'; inv.responded_at = datetime.now(UTC)
        event = await _response_event(db, inv, accepted=False)
        await db.commit()
        if event:
            await notify_user(db, user_id=event.user_id, title=event.title,
                body=event.message, action='open_screen', action_payload=event.route)
        return ok(_invite_dict(inv), 'تم رفض طلب التوظيف')
    employee = (await db.execute(select(Employee).where(Employee.id == inv.employee_id,
        Employee.organization_id == inv.organization_id,
        Employee.is_deleted.is_(False)))).scalar_one_or_none()
    if employee is None:
        raise HTTPException(404, detail='طلب التوظيف غير موجود')
    ws = await _workspace_get_or_create(db, employee)
    if ws.linked_user_id not in (None, user_id):
        raise HTTPException(409, detail='هذا الملف مرتبط بحساب آخر')
    ws.linked_user_id = user_id
    ws.permissions = inv.permissions
    ws.branch_ids = inv.branch_ids
    if inv.branch_ids is not None:
        await _validate_employee_branches(db, inv.organization_id,
            [uuid.UUID(x) for x in json.loads(inv.branch_ids)])
    inv.status = 'accepted'; inv.responded_at = datetime.now(UTC)
    perms = _perm(inv.permissions)
    rooted = {
        'organization_name': (await db.execute(select(Organization.name).where(
            Organization.id == inv.organization_id))).scalar_one_or_none(),
        'employee_name': employee.full_name,
    }
    if member is None:
        member = BranchMember(organization_id=inv.organization_id, user_id=user_id,
            branch_ids=inv.branch_ids or '[]', all_branches=inv.branch_ids is None, permissions=json.dumps(perms),
            status='active', invited_by=inv.invited_by)
        db.add(member)
    else:
        member.all_branches = inv.branch_ids is None
        member.branch_ids = inv.branch_ids or '[]'
        member.permissions = json.dumps(perms)
        member.status = 'active'
    event = await _response_event(db, inv, accepted=True)
    await db.commit()
    if event:
        await notify_user(db, user_id=event.user_id, title=event.title,
            body=event.message, action='open_screen', action_payload=event.route)
    organization = await db.get(Organization, inv.organization_id)
    return ok({**(await _invitation_view(db, inv, employee, ws, organization)), **rooted},
              'تم قبول طلب التوظيف')


async def _response_event(db: AsyncSession, inv: EmployeeInvitation, accepted: bool):
    if not inv.invited_by:
        return None
    employee_name = await db.scalar(select(Employee.full_name).where(Employee.id == inv.employee_id))
    return await save_employment_event(db, recipient_id=inv.invited_by,
        event_id=f'employee_response:{inv.id}',
        title='تم قبول طلب التوظيف' if accepted else 'تم رفض طلب التوظيف',
        body=f'{employee_name} ' + ('وافق على طلبك وأصبح مرتبطاً بمتجرك.' if accepted else 'ما وافق على طلب التوظيف.'),
        route=f'/employees/detail?id={inv.employee_id}')


@router.delete('/{employee_id}', summary='Delete employee')
async def delete_employee(employee_id: uuid.UUID,
                          org_id: str = Depends(get_current_org_id),
                          user_id: uuid.UUID = Depends(get_current_user_uuid),
                          db: AsyncSession = Depends(get_db)):
    await _owner_check(db, org_id, user_id)
    employee = (await db.execute(select(Employee).where(
        Employee.id == employee_id, Employee.organization_id == uuid.UUID(str(org_id)),
        Employee.is_deleted.is_(False)))).scalar_one_or_none()
    if employee is None:
        raise HTTPException(404, detail='الموظف غير موجود')
    ws = await _workspace(db, employee.id, employee.organization_id)
    result = None
    # Repair a partially unlinked legacy relationship before deleting its last
    # HR reference, otherwise an accepted invite can leave live branch access.
    if ws and ws.linked_user_id is None:
        accepted_user = (await db.execute(select(EmployeeInvitation.invited_user_id).where(
            EmployeeInvitation.employee_id == employee.id,
            EmployeeInvitation.status == 'accepted').order_by(
            EmployeeInvitation.created_at.desc()).limit(1))).scalar_one_or_none()
        if accepted_user is not None:
            other_link = await db.scalar(select(EmployeeWorkspace.employee_id).where(
                EmployeeWorkspace.organization_id == employee.organization_id,
                EmployeeWorkspace.linked_user_id == accepted_user,
                EmployeeWorkspace.employee_id != employee.id).limit(1))
            if other_link is None:
                ws.linked_user_id = accepted_user
    if ws and ws.linked_user_id:
        from ...domain.services.employee_unlink_service import unlink_employee
        result = await unlink_employee(db, employee.id, user_id, deletion=True)
    from sqlalchemy import delete
    for model in (EmployeeInvitation, EmployeeSalaryPayment, EmployeeDebt, EmployeeWorkspace):
        await db.execute(delete(model).where(model.employee_id == employee.id))
    await db.delete(employee)
    await db.commit()
    if result:
        for recipient in result.get('recipient_ids', []):
            await notify_user(db, user_id=uuid.UUID(recipient), title=result['title'],
                body=result['message'], action='open_screen', action_payload='notifications')
    return no_content('تم حذف الموظف')


@router.post('/{employee_id}/unlink', summary='End employment workspace access from either party')
async def unlink_workspace(employee_id: uuid.UUID,
                           user_id: uuid.UUID = Depends(get_current_user_uuid),
                           db: AsyncSession = Depends(get_db)):
    from ...domain.services.employee_unlink_service import unlink_employee
    result = await unlink_employee(db, employee_id, user_id)
    await db.commit()
    for recipient in result.pop('recipient_ids', []):
        await notify_user(db, user_id=uuid.UUID(recipient),
            title=result['title'], body=result['message'],
            action='open_screen', action_payload='notifications')
    return ok(result, 'تم إلغاء الربط وإيقاف الوصول')


@router.get('/{employee_id}/salary', summary='Salary ledger')
async def salary_ledger(employee_id: uuid.UUID,
                        org_id: str = Depends(get_current_org_id),
                        user_id: uuid.UUID = Depends(get_current_user_uuid),
                        db: AsyncSession = Depends(get_db)):
    await _owner_check(db, org_id, user_id)
    organization = await db.get(Organization, uuid.UUID(str(org_id)))
    employee = (await db.execute(select(Employee).where(Employee.id == employee_id,
        Employee.organization_id == organization.id, Employee.is_deleted.is_(False)))).scalar_one_or_none()
    if employee is None:
        raise HTTPException(404, detail='الموظف غير موجود')
    rows = (await db.execute(select(EmployeeSalaryPayment).where(
        EmployeeSalaryPayment.employee_id == employee_id,
        EmployeeSalaryPayment.organization_id == uuid.UUID(str(org_id)))
        .order_by(EmployeeSalaryPayment.paid_at.desc()))).scalars().all()
    ws = await _workspace(db, employee.id, employee.organization_id)
    base_currency = ws.salary_currency if ws else 'SAR'
    from ...domain.services.employee_finance_service import paid_salary_base
    paid_base = paid_salary_base(rows, base_currency)
    return ok({'organization_name': organization.name,
               'base_salary': str(employee.salary or 0), 'base_currency': base_currency,
               'remaining_salary': str(Decimal(str(employee.salary or 0)) - paid_base) if paid_base is not None else None,
               'requires_historical_rate': paid_base is None,
               'payments': [salary_receipt(p, employee, organization) for p in rows]})


@router.post('/{employee_id}/salary', status_code=201, summary='Pay salary')
async def pay_salary(employee_id: uuid.UUID, data: SalaryBody,
                     org_id: str = Depends(get_current_org_id),
                     user_id: uuid.UUID = Depends(get_current_user_uuid),
                     db: AsyncSession = Depends(get_db), scope=Depends(get_branch_scope)):
    await _owner_check(db, org_id, user_id)
    org = uuid.UUID(str(org_id))
    employee = (await db.execute(select(Employee).where(
        Employee.id == employee_id, Employee.organization_id == org,
        Employee.is_deleted.is_(False)).with_for_update())).scalar_one_or_none()
    if employee is None:
        raise HTTPException(404, detail='ما لقينا هذا الموظف')
    from ...domain.services.employee_finance_service import record_finance
    p, organization = await record_finance(db, employee, org, user_id, data,
        scope.branch_ids if scope.all_mode else await access.effective_branch_ids(db, org, user_id), salary=True)
    return created(salary_receipt(p, employee, organization),
                   'تم صرف الراتب وإنشاء الفاتورة')
@router.get('/{employee_id}/debts', summary='Employee debt ledger')
async def debt_ledger(employee_id: uuid.UUID,
                      org_id: str = Depends(get_current_org_id),
                      user_id: uuid.UUID = Depends(get_current_user_uuid),
                      db: AsyncSession = Depends(get_db)):
    await _owner_check(db, org_id, user_id)
    organization = await db.get(Organization, uuid.UUID(str(org_id)))
    employee = (await db.execute(select(Employee).where(Employee.id == employee_id,
        Employee.organization_id == organization.id, Employee.is_deleted.is_(False)))).scalar_one_or_none()
    if employee is None:
        raise HTTPException(404, detail='الموظف غير موجود')
    rows = (await db.execute(select(EmployeeDebt).where(
        EmployeeDebt.employee_id == employee_id,
        EmployeeDebt.organization_id == uuid.UUID(str(org_id)))
        .order_by(EmployeeDebt.created_at.desc()))).scalars().all()
    totals: Dict[str, Decimal] = {}
    for d in rows:
        sign = Decimal(1) if d.direction == 'employee_owes' else Decimal(-1)
        if d.kind == 'settlement': sign *= Decimal(-1)
        totals[d.currency] = totals.get(d.currency, Decimal(0)) + sign * (d.amount or 0)
    from ...domain.services.employee_finance_service import outstanding_debts
    remaining = outstanding_debts(rows)
    return ok({'organization_name': organization.name,
        'debts': [{**debt_receipt(d, employee, organization),
                   **({'outstanding_amount': str(remaining.get(str(d.id), Decimal(0)))} if d.kind == 'charge' else {})}
                  for d in rows],
        'balances': {k: float(v) for k, v in totals.items()}})


@router.post('/{employee_id}/debts', status_code=201, summary='Add/settle employee debt')
async def add_debt(employee_id: uuid.UUID, data: DebtBody,
                   org_id: str = Depends(get_current_org_id),
                   user_id: uuid.UUID = Depends(get_current_user_uuid),
                    db: AsyncSession = Depends(get_db), scope=Depends(get_branch_scope)):
    await _owner_check(db, org_id, user_id)
    employee = (await db.execute(select(Employee).where(
        Employee.id == employee_id, Employee.organization_id == uuid.UUID(str(org_id)),
        Employee.is_deleted.is_(False)).with_for_update())).scalar_one_or_none()
    if employee is None: raise HTTPException(404, detail='الموظف غير موجود')
    org = uuid.UUID(str(org_id))
    from ...domain.services.employee_finance_service import record_finance
    d, organization = await record_finance(db, employee, org, user_id, data,
        scope.branch_ids if scope.all_mode else await access.effective_branch_ids(db, org, user_id), salary=False)
    return created(debt_receipt(d, employee, organization), 'تم تسجيل الدين')


@router.get('/me/finance', summary='My salary and debt ledger')
async def employee_finance(employee_id: Optional[uuid.UUID] = Query(default=None),
                           user_id: uuid.UUID = Depends(get_current_user_uuid),
                           db: AsyncSession = Depends(get_db), request: Request = None):
    if request is not None:
        from ...domain.services import qa_employee_finance
        from ...domain.services.branch_service import decode_scope_token
        token = request.headers.get('X-Branch-Token')
        if token and qa_employee_finance.enabled():
            claims = decode_scope_token(token) or {}
            grant = claims.get('qa_employee_finance')
            if claims.get('sub') == str(user_id) and isinstance(grant, dict) and (
                employee_id is None or str(employee_id) == grant.get('employee_id')
            ):
                # An older client selecting the device branch must not show
                # an incomplete connected history as the whole current view.
                raise HTTPException(409, detail={
                    'code': 'employee_finance_device_scope',
                    'message': 'الراتب ودين الموظف لهذا الفرع غير متاحين في المسار المتصل.',
                })
    query = select(EmployeeWorkspace).where(EmployeeWorkspace.linked_user_id == user_id)
    if employee_id is not None:
        query = query.where(EmployeeWorkspace.employee_id == employee_id)
    workspaces = (await db.execute(query)).scalars().all()
    valid = []
    for workspace in workspaces:
        employee = await db.get(Employee, workspace.employee_id)
        if employee and not employee.is_deleted and employee.organization_id == workspace.organization_id and await access.get_member(db, workspace.organization_id, user_id):
            valid.append((workspace, employee))
    if not valid:
        if employee_id is not None:
            raise HTTPException(404, detail='ما عندك ارتباط بهذا المتجر')
        return ok({'salary': [], 'debts': [], 'balances': {}})
    if len(valid) > 1:
        raise HTTPException(409, detail='اختر المتجر أولاً لعرض رواتبه وديونه')
    ws, employee = valid[0]
    organization = await db.get(Organization, ws.organization_id)
    salary = (await db.execute(select(EmployeeSalaryPayment).where(
        EmployeeSalaryPayment.employee_id == ws.employee_id,
        EmployeeSalaryPayment.organization_id == ws.organization_id).order_by(
        EmployeeSalaryPayment.paid_at.desc()))).scalars().all()
    debts = (await db.execute(select(EmployeeDebt).where(
        EmployeeDebt.employee_id == ws.employee_id,
        EmployeeDebt.organization_id == ws.organization_id).order_by(
        EmployeeDebt.created_at.desc()))).scalars().all()
    totals: Dict[str, Decimal] = {}
    for d in debts:
        sign = Decimal(1) if d.direction == 'employee_owes' else Decimal(-1)
        if d.kind == 'settlement': sign *= Decimal(-1)
        totals[d.currency] = totals.get(d.currency, Decimal(0)) + sign * (d.amount or 0)
    return ok({'employee_id': str(employee.id), 'organization_id': str(organization.id),
        'salary': [salary_receipt(x, employee, organization) for x in salary],
        'debts': [debt_receipt(x, employee, organization) for x in debts],
        'balances': {k: float(v) for k, v in totals.items()}})


@router.post('/me/heartbeat', summary='Employee app presence')
async def heartbeat(request: Request, user_id: uuid.UUID = Depends(get_current_user_uuid),
                     db: AsyncSession = Depends(get_db), online: bool = Query(default=True)):
    from ...domain.services.branch_service import decode_scope_token
    from ...domain.services.employee_presence_service import set_presence
    scope = decode_scope_token(request.headers.get('X-Branch-Token'))
    return ok({'online': await set_presence(db, user_id, scope, online)})


@router.get('/me/profile', summary='My employee profile in manager workspace')
async def employee_me(organization_id: Optional[uuid.UUID] = Query(default=None),
                      user_id: uuid.UUID = Depends(get_current_user_uuid),
                      db: AsyncSession = Depends(get_db)):
    query = select(EmployeeWorkspace).where(EmployeeWorkspace.linked_user_id == user_id)
    if organization_id is not None:
        if not await access.get_member(db, organization_id, user_id):
            raise HTTPException(404, detail='ما عندك ارتباط بهذا المتجر')
        query = query.where(EmployeeWorkspace.organization_id == organization_id)
    ws = (await db.execute(query)).scalars().first()
    if ws is None:
        if organization_id is not None:
            raise HTTPException(404, detail='ما عندك ارتباط بهذا المتجر')
        return ok({'employee': None})
    employee = (await db.execute(select(Employee).where(Employee.id == ws.employee_id))).scalar_one_or_none()
    if organization_id is not None and (employee is None or employee.is_deleted or
            employee.organization_id != organization_id):
        raise HTTPException(404, detail='الموظف غير موجود')
    org = (await db.execute(select(Organization).where(Organization.id == ws.organization_id))).scalar_one_or_none()
    return ok({'employee': _employee_dict(employee, ws) if employee else None,
               'organization': {'id': str(ws.organization_id), 'name': org.name if org else ''}})
