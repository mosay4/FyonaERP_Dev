"""Business branch registry: main-branch guarantees, create/rename/archive,
and the branch context resolver used by business APIs.

The main branch is identified by `is_default` (stable), NOT by its name; it can
be renamed but never archived. Archived branches keep all their data.
"""
import re
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional
from uuid import UUID

from jose import ExpiredSignatureError, jwt

from app.core.config import settings

from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.sale_entities import Branch
from app.domain.entities.auth_entities import User


async def require_owner(db: AsyncSession, user_id: UUID, org_id: str) -> User:
    """Original management authority, shared by HTTP and immutable commands."""
    from fastapi import HTTPException
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    if user is None or str(user.organization_id) != str(org_id):
        raise HTTPException(status_code=403, detail="غير مصرح")
    if (user.role or "").lower() != "owner" and not user.is_platform_admin:
        raise HTTPException(status_code=403, detail="إدارة الفروع متاحة للمالك فقط")
    return user


async def _lock_registry(db: AsyncSession, org_id: UUID):
    if db.get_bind().dialect.name == "postgresql":
        await db.execute(
            text("SELECT pg_advisory_xact_lock(hashtextextended(:key, 0))"),
            {"key": f"business-branches:{org_id}"},
        )


def clean_branch_name(value: Optional[str]) -> str:
    name = re.sub(r"\s*'s\s+organization\s*$", "", (value or "").strip(),
                  flags=re.I).strip()
    return name[:200]


async def main_branch(db: AsyncSession, org_id: UUID) -> Branch:
    """The org's main branch (created on demand with the business name)."""
    from app.domain.services.sale_service import get_or_create_default_branch
    return await get_or_create_default_branch(db, org_id)


async def list_branches(
    db: AsyncSession, org_id: UUID, include_archived: bool = False
) -> List[Branch]:
    q = select(Branch).where(Branch.organization_id == org_id)
    if not include_archived:
        q = q.where(Branch.is_archived.is_(False))
    q = q.order_by(Branch.is_default.desc(), Branch.created_at.asc())
    return list((await db.execute(q)).scalars().all())


async def _name_taken(db: AsyncSession, org_id: UUID, name: str,
                      exclude: Optional[UUID] = None) -> bool:
    q = select(Branch.id).where(
        Branch.organization_id == org_id, Branch.name == name)
    if exclude is not None:
        q = q.where(Branch.id != exclude)
    return (await db.execute(q.limit(1))).scalar_one_or_none() is not None


async def create_branch(db: AsyncSession, org_id: UUID, name: str, *,
                        branch_id: Optional[UUID] = None) -> Branch:
    await _lock_registry(db, org_id)
    clean = clean_branch_name(name)
    if len(clean) < 2:
        raise ValueError("اسم الفرع يجب أن يكون حرفين على الأقل")
    if await _name_taken(db, org_id, clean):
        raise ValueError("يوجد فرع بهذا الاسم بالفعل")
    await main_branch(db, org_id)  # guarantee a main exists first
    branch = Branch(organization_id=org_id, name=clean, is_default=False)
    if branch_id is not None:
        branch.id = branch_id
    db.add(branch)
    await db.flush()
    return branch


async def rename_branch(db: AsyncSession, org_id: UUID, branch_id: UUID,
                        name: str) -> Branch:
    await _lock_registry(db, org_id)
    clean = clean_branch_name(name)
    if len(clean) < 2:
        raise ValueError("اسم الفرع يجب أن يكون حرفين على الأقل")
    branch = await _get(db, org_id, branch_id, include_archived=True)
    if await _name_taken(db, org_id, clean, exclude=branch.id):
        raise ValueError("يوجد فرع بهذا الاسم بالفعل")
    branch.name = clean
    await db.flush()
    return branch


async def archive_branch(db: AsyncSession, org_id: UUID,
                         branch_id: UUID) -> Branch:
    await _lock_registry(db, org_id)
    branch = await _get(db, org_id, branch_id, include_archived=True)
    if branch.is_default:
        raise ValueError("الفرع الرئيسي لا يمكن تعطيله أو أرشفته")
    if branch.is_archived:
        return branch
    from datetime import datetime, timezone
    branch.is_archived = True
    branch.is_active = False
    branch.archived_at = datetime.now(timezone.utc)
    await db.flush()
    return branch


async def reactivate_branch(db: AsyncSession, org_id: UUID,
                            branch_id: UUID) -> Branch:
    await _lock_registry(db, org_id)
    branch = await _get(db, org_id, branch_id, include_archived=True)
    if not branch.is_archived:
        return branch
    branch.is_archived = False
    branch.is_active = True
    branch.archived_at = None
    await db.flush()
    return branch


async def _get(db: AsyncSession, org_id: UUID, branch_id: UUID,
               include_archived: bool = False) -> Branch:
    branch = (await db.execute(select(Branch).where(
        Branch.id == branch_id, Branch.organization_id == org_id
    ))).scalar_one_or_none()
    if branch is None:
        raise ValueError("الفرع غير موجود")
    if branch.is_archived and not include_archived:
        raise ValueError("الفرع مؤرشف ولا يمكن الوصول إليه")
    return branch


async def resolve_branch_for_context(
    db: AsyncSession, org_id: UUID, branch_id: Optional[UUID]
) -> Branch:
    """Active branch for read/write APIs. Archived branches are rejected."""
    if branch_id is None:
        return await main_branch(db, org_id)
    branch = await _get(db, org_id, branch_id)
    if not branch.is_active:
        raise ValueError("الفرع غير نشط")
    return branch


def branch_dict(branch: Branch) -> Dict[str, Any]:
    return {
        "id": str(branch.id),
        "name": branch.name,
        "image": branch.image,
        "image_version": branch.updated_at.isoformat() if branch.updated_at else None,
        "is_default": bool(branch.is_default),
        "is_active": bool(branch.is_active),
        "is_archived": bool(branch.is_archived),
        "archived_at": branch.archived_at.isoformat() if branch.archived_at else None,
        "created_at": branch.created_at.isoformat() if branch.created_at else None,
    }

# ── Server-issued branch scope token ────────────────────────────────
# Branch selection is NOT trusted from a plain header: the app exchanges it
# for a signed, short-lived token that binds user + org + branch (or the
# permitted-all snapshot). New all tokens retain exact branch IDs.
BRANCH_SCOPE_TTL = timedelta(hours=12)


def issue_scope_token(user_id: UUID, org_id: UUID,
                      branch_id: Optional[UUID], all_mode: bool,
                      branch_ids: Optional[List[UUID]] = None,
                      *, qa_directory: bool = False,
                      qa_business_ledger: bool = False,
                      qa_employee_finance: Optional[Dict[str, str]] = None,
                      qa_transfer_branches: Optional[Dict[str, str]] = None,
                      qa_writer_session: Optional[UUID] = None,
                      qa_cash_link: Optional[UUID] = None,
                      qa_member: bool = False) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "typ": "branch_scope",
        "sub": str(user_id),
        "org": str(org_id),
        "branch": str(branch_id) if branch_id else None,
        "mode": "all" if all_mode else "branch",
        "iat": now,
        "issued_at": now.timestamp(),
        "exp": now + BRANCH_SCOPE_TTL,
    }
    if all_mode and branch_ids is not None:
        payload['branch_ids'] = list(dict.fromkeys(str(b) for b in branch_ids))
        payload['write_scope'] = 'read_only'
    if qa_directory and branch_id is not None and not all_mode:
        payload['qa_directory'] = True
    # The directory claim never grants the ledger; this separate claim is the
    # one-time device-writer enrollment of a branch whose legacy ledger is
    # empty and whose old writer is fenced.
    if qa_business_ledger and branch_id is not None and not all_mode:
        payload['qa_business_ledger'] = True
        if qa_member:
            # The device works in its employer's organization.
            payload['qa_member'] = True
        if qa_writer_session is not None:
            payload['qa_writer_session'] = str(qa_writer_session)
            payload['qa_transfer_branches'] = qa_transfer_branches or {}
        if qa_cash_link is not None and qa_directory:
            payload['qa_cash_link'] = str(qa_cash_link)
    if qa_employee_finance and not qa_directory and not qa_business_ledger \
            and branch_id is not None and not all_mode:
        payload['qa_employee_finance'] = qa_employee_finance
    return jwt.encode(payload, settings.JWT_SECRET_KEY,
                      algorithm=settings.JWT_ALGORITHM)


def decode_scope_token(token: Optional[str]) -> Optional[dict]:
    if not token:
        return None
    try:
        payload = jwt.decode(token, settings.JWT_SECRET_KEY,
                             algorithms=[settings.JWT_ALGORITHM])
    except Exception:
        return None
    if payload.get("typ") != "branch_scope":
        return None
    return payload

def scope_token_state(token: Optional[str]) -> str:
    """Distinguish a genuinely EXPIRED (validly signed) scope token from an
    invalid/tampered one. Only the former may be auto-refreshed."""
    if not token:
        return "missing"
    try:
        payload = jwt.decode(token, settings.JWT_SECRET_KEY,
                             algorithms=[settings.JWT_ALGORITHM])
    except ExpiredSignatureError:
        return "expired"
    except Exception:
        return "invalid"
    if payload.get("typ") != "branch_scope":
        return "invalid"
    return "valid"
