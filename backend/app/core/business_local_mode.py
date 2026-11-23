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

import os
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core import qa_directory
from app.domain.entities.sale_entities import Branch


# On by default for the QA rollout; "0" restores the per-branch fence.
ENABLED = os.getenv("FYONA_QA_LOCAL_ALL_BRANCHES", "1") != "0"


def enabled_for(user) -> bool:
    return (
        ENABLED
        and bool(qa_directory.INVITES)
        and getattr(user, "email", None) in qa_directory.INVITES
        and getattr(user, "role", None) == "owner"
        and getattr(user, "status", "active") == "active"
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
