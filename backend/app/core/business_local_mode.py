"""Whole-organization local Business mode (QA rollout).

For an invited QA owner, every active branch of the organization — the main
branch, existing branches and branches born later on a device — is a device
ledger branch. Business data lives on the devices; the server issues the
branch-scope token and carries operations between devices through the
Business relay, nothing more.

This replaces, for these accounts, the earlier per-branch registration fence
(two slots, non-default, "legacy empty" branches only).
"""

from __future__ import annotations

import json
import os
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core import qa_directory
from app.domain.entities.sale_entities import Branch


# On by default for the QA rollout; "0" restores the per-branch fence.
ENABLED = os.getenv("FYONA_QA_LOCAL_ALL_BRANCHES", "1") != "0"


def _granted_account(user) -> bool:
    """The managed QA launcher's pinned ledger account (private env only)."""
    if not qa_directory.INVITES or os.getenv("FYONA_QA_REMOTE") != "1":
        return False
    try:
        grants = json.loads(os.getenv("FYONA_QA_EXISTING_LEDGER_GRANTS", "{}"))
    except ValueError:
        return False
    return isinstance(grants, dict) and any(
        isinstance(g, dict)
        and g.get("account") == str(user.id)
        and g.get("organization") == str(user.organization_id)
        for g in grants.values()
    )


def enabled_for(user) -> bool:
    return (
        ENABLED
        and bool(qa_directory.INVITES)
        and getattr(user, "role", None) == "owner"
        and getattr(user, "status", "active") == "active"
        and (getattr(user, "email", None) in qa_directory.INVITES
             or _granted_account(user))
    )


async def whole_organization(db: AsyncSession, user, branch) -> bool:
    return (
        enabled_for(user)
        and user.organization_id == branch.organization_id
        and bool(branch.is_active)
        and not bool(branch.is_archived)
    )


async def branch_names(db: AsyncSession, org_id: UUID) -> dict[str, str]:
    """Every active branch of the organization, for transfers between them."""
    rows = (await db.execute(select(Branch.id, Branch.name).where(
        Branch.organization_id == org_id,
        Branch.is_active.is_(True),
        Branch.is_archived.is_(False),
    ).order_by(Branch.created_at))).all()
    return {str(branch_id): name for branch_id, name in rows}


async def organization_enabled(db: AsyncSession, org_id: UUID) -> bool:
    """The organization's Business lives on devices (its owner is enabled)."""
    from app.domain.entities.auth_entities import User

    owners = (await db.execute(select(User).where(
        User.organization_id == org_id, User.role == "owner",
        User.status == "active",
    ))).scalars().all()
    return any(enabled_for(owner) for owner in owners)


async def member_branches(db: AsyncSession, user, org_id: UUID) -> list[str] | None:
    """Branches an active employee (branch member) may work in, or None."""
    from sqlalchemy import text

    if not await db.scalar(text(
        "SELECT to_regclass('public.branch_members') IS NOT NULL"
    )):
        return None
    row = (await db.execute(text("""
        SELECT m.branch_ids, m.all_branches FROM public.branch_members m
        WHERE m.user_id = :user AND m.organization_id = :org AND m.status = 'active'
    """), {"user": user.id, "org": org_id})).first()
    if row is None:
        return None
    names = await branch_names(db, org_id)
    if row.all_branches:
        return list(names)
    try:
        allowed = {str(b) for b in json.loads(row.branch_ids or "[]")}
    except ValueError:
        return []
    return [b for b in names if b in allowed]


async def member_scope(db: AsyncSession, user, branch) -> dict[str, str] | None:
    """For an employee of a local-mode organization: the branches (id→name)
    their device works in, when [branch] is one of them; otherwise None."""
    if user.organization_id == branch.organization_id:
        return None
    if not branch.is_active or branch.is_archived:
        return None
    if not await organization_enabled(db, branch.organization_id):
        return None
    allowed = await member_branches(db, user, branch.organization_id)
    if not allowed or str(branch.id) not in allowed:
        return None
    names = await branch_names(db, branch.organization_id)
    return {b: names[b] for b in allowed if b in names}
