"""Startup self-healing for system-role baseline permissions.

Org roles are seeded once at org creation. When the baseline
(ROLE_PERMISSIONS) gains new resources, existing orgs would silently lose
access to endpoints that are now permission-gated. This routine idempotently
upserts any missing baseline permission rows for all existing system roles,
without touching rows that were customised by an admin.
"""

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.auth_entities import Role, RolePermission
from app.domain.services.auth_service import ROLE_PERMISSIONS

ACTIONS = ("create", "read", "update", "delete")


async def ensure_system_role_permissions(db: AsyncSession) -> int:
    """Add missing baseline RolePermission rows for every system role.

    Returns the number of permission rows inserted.
    """
    added = 0
    roles = (
        await db.execute(select(Role).where(Role.is_system.is_(True)))
    ).scalars().all()

    for role in roles:
        baseline = ROLE_PERMISSIONS.get(role.name)
        if not baseline:
            continue

        existing_rows = (
            await db.execute(
                select(RolePermission).where(RolePermission.role_id == role.id)
            )
        ).scalars().all()
        existing_resources = {rp.resource for rp in existing_rows}

        for resource, actions in baseline.items():
            if resource in existing_resources:
                continue
            db.add(
                RolePermission(
                    role_id=role.id,
                    resource=resource,
                    can_create="create" in actions,
                    can_read="read" in actions,
                    can_update="update" in actions,
                    can_delete="delete" in actions,
                )
            )
            added += 1

    if added:
        await db.commit()
    return added
