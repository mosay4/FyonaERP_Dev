"""Presence belongs to a live, explicitly selected merchant workspace only."""
from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import HTTPException
from sqlalchemy import select

from ..entities.employee_workspace_entities import EmployeeWorkspace
from ..entities.hr_entities import Employee
from . import branch_access_service as access

STALE_AFTER = timedelta(seconds=60)


def is_online(workspace, now=None):
    if (workspace is None or not workspace.linked_user_id or
            workspace.active_organization_id != workspace.organization_id or
            workspace.last_seen_at is None):
        return False
    seen = workspace.last_seen_at
    if seen.tzinfo is None:
        seen = seen.replace(tzinfo=timezone.utc)
    age = (now or datetime.now(timezone.utc)) - seen
    return timedelta(0) <= age < STALE_AFTER


async def set_presence(db, user_id, scope=None, online=False):
    rows = (await db.execute(select(EmployeeWorkspace).where(
        EmployeeWorkspace.linked_user_id == user_id))).scalars().all()
    active = None
    if online and scope:
        if str(scope.get('sub')) != str(user_id):
            raise HTTPException(403, detail='Invalid branch scope')
        try:
            org = UUID(str(scope['org']))
        except (KeyError, ValueError, TypeError):
            raise HTTPException(403, detail='Invalid branch scope')
        member = await access.get_member(db, org, user_id)
        if member is None or not access.scope_is_current(member, scope):
            raise HTTPException(403, detail={'code': 'employee_workspace_revoked',
                'message': 'تم إلغاء ارتباطك بالمتجر'})
        allowed_ids = {str(value) for value in await access.effective_branch_ids(db, org, user_id)}
        valid_branch = bool(allowed_ids) if scope.get('mode') == 'all' else str(scope.get('branch')) in allowed_ids
        if valid_branch:
            for workspace in rows:
                if workspace.organization_id != org:
                    continue
                employee = await db.get(Employee, workspace.employee_id)
                if employee and not employee.is_deleted and employee.organization_id == org:
                    active = workspace
                    break
    for workspace in rows:
        workspace.last_seen_at = datetime.now(timezone.utc) if workspace is active else None
        workspace.active_organization_id = workspace.organization_id if workspace is active else None
    await db.commit()
    return active is not None
