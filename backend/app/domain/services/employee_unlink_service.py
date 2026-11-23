"""Revoke an employment/company relationship without deleting HR ledgers."""
import json
from datetime import datetime, timezone
from uuid import UUID, uuid4

from fastapi import HTTPException
from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from ..entities.auth_entities import Organization, User
from ..entities.branch_entities import BranchInvitation, BranchMember
from ..entities.employee_workspace_entities import EmployeeInvitation, EmployeeWorkspace
from ..entities.hr_entities import Employee
from ..entities.notification_entities import AppNotification
from .branch_access_service import is_owner


async def unlink_employee(db: AsyncSession, employee_id: UUID, actor_id: UUID, *, deletion: bool = False) -> dict:
    employee = (await db.execute(select(Employee).where(
        Employee.id == employee_id, Employee.is_deleted.is_(False)))).scalar_one_or_none()
    actor = (await db.execute(select(User).where(User.id == actor_id))).scalar_one_or_none()
    if employee is None or actor is None:
        raise HTTPException(404, detail='ملف الموظف غير موجود')
    ws = (await db.execute(select(EmployeeWorkspace).where(
        EmployeeWorkspace.employee_id == employee_id))).scalar_one_or_none()
    merchant = is_owner(actor, employee.organization_id)
    if ws is None or (not merchant and ws.linked_user_id != actor_id):
        raise HTTPException(404, detail='ما عندك ارتباط بهذا المتجر')
    if ws.linked_user_id is None:
        return {'organization_id': str(employee.organization_id), 'already_unlinked': True}
    target_id = ws.linked_user_id
    target = (await db.execute(select(User).where(User.id == target_id))).scalar_one()
    if is_owner(target, employee.organization_id):
        raise HTTPException(409, detail='لا يمكن إلغاء ملكية التاجر بهذه العملية')

    member = (await db.execute(select(BranchMember).where(
        BranchMember.organization_id == employee.organization_id,
        BranchMember.user_id == target_id).with_for_update())).scalar_one_or_none()
    ws = (await db.execute(select(EmployeeWorkspace).where(
        EmployeeWorkspace.employee_id == employee_id).with_for_update()
        .execution_options(populate_existing=True))).scalar_one()
    if ws.linked_user_id is None:
        return {'organization_id': str(employee.organization_id), 'already_unlinked': True}
    if ws.linked_user_id != target_id:
        raise HTTPException(409, detail='تغير ارتباط الموظف، حدّث الصفحة وحاول مرة ثانية')
    if member is None:
        member = BranchMember(organization_id=employee.organization_id, user_id=target_id)
        db.add(member)
    # Retain a tombstone: deleting it could re-enable legacy same-org access.
    member.status = 'revoked'
    member.branch_ids = '[]'
    member.all_branches = False
    member.can_transfer = False
    member.permissions = '{}'
    member.per_branch = '{}'
    member.updated_at = datetime.now(timezone.utc)
    member.scope_valid_after = member.updated_at

    workspaces = (await db.execute(select(EmployeeWorkspace).where(
        EmployeeWorkspace.organization_id == employee.organization_id,
        EmployeeWorkspace.linked_user_id == target_id))).scalars().all()
    for workspace in workspaces:
        workspace.linked_user_id = None
        workspace.last_seen_at = None
        workspace.active_organization_id = None
        workspace.branch_ids = '[]'
        try:
            keys = json.loads(workspace.permissions or '{}')
        except (TypeError, ValueError):
            keys = {}
        workspace.permissions = json.dumps({key: False for key in keys})
    # Remove received cards; invalidate old pending accept links too.
    await db.execute(delete(EmployeeInvitation).where(
        EmployeeInvitation.organization_id == employee.organization_id,
        EmployeeInvitation.invited_user_id == target_id))
    await db.execute(update(BranchInvitation).where(
        BranchInvitation.organization_id == employee.organization_id,
        BranchInvitation.invited_user_id == target_id,
        BranchInvitation.status.in_(['pending', 'accepted']),
    ).values(status='revoked', responded_at=datetime.now(timezone.utc)))

    org = (await db.execute(select(Organization).where(
        Organization.id == employee.organization_id))).scalar_one()
    if merchant:
        recipients = [target]
        title = 'تم حذف ملفك لدى المتجر' if deletion else 'تم إلغاء ربطك بالمتجر'
        message = (f'حذف التاجر ملفك لدى متجر {org.name} وألغى الربط. لم يعد بإمكانك دخول فروعه أو إدارتها.'
                   if deletion else f'ألغى التاجر ربطك بمتجر {org.name}. لم يعد بإمكانك دخول فروعه أو إدارتها.')
    else:
        recipients = (await db.execute(select(User).where(
            User.organization_id == employee.organization_id,
            User.role == 'owner', User.status == 'active'))).scalars().all()
        title = 'الموظف ألغى ارتباطه بالمتجر'
        message = f'ألغى {employee.full_name} ارتباطه بمتجر {org.name}. تم إيقاف وصوله لجميع فروعك.'
    event = uuid4().hex
    for recipient in recipients:
        db.add(AppNotification(
            organization_id=recipient.organization_id or employee.organization_id,
            user_id=recipient.id, type='warning', is_system=True, domain='main',
            title=title, message=message, action='open_screen',
            action_payload='notifications', route='/notifications',
            event_id=f'employee_unlink:{event}',
        ))
    await db.flush()
    return {'organization_id': str(employee.organization_id), 'already_unlinked': False,
            'recipient_ids': [str(u.id) for u in recipients], 'title': title, 'message': message}
