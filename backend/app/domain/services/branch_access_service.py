"""Branch membership, invitations, and effective branch access.

Owners keep full access to their own company. Any other FYONA user gets access
ONLY through an accepted invitation, with explicit server-validated
permissions. Personal data and the user's own organization are untouched.
"""

import json
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Iterable, List, Optional
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.branch_entities import (
    BranchInvitation, BranchMember,
)
from app.domain.entities.notification_entities import AppNotification
from app.domain.entities.sale_entities import Branch
from app.domain.services import branch_service

INVITE_TTL = timedelta(days=14)

# Minimal operational read access after acceptance. No financial/admin write
# is ever granted automatically, and transfer rights stay OFF until the owner
# grants them explicitly.
DEFAULT_MEMBER_PERMISSIONS: Dict[str, Dict[str, bool]] = {
    "customers": {"create": False, "read": True, "update": False, "delete": False},
    "suppliers": {"create": False, "read": True, "update": False, "delete": False},
    "products": {"create": False, "read": True, "update": False, "delete": False},
    "inventory": {"create": False, "read": True, "update": False, "delete": False},
    "invoices": {"create": False, "read": True, "update": False, "delete": False},
    "banking": {"create": False, "read": True, "update": False, "delete": False},
    "reports": {"create": False, "read": True, "update": False, "delete": False},
    "debts": {"create": False, "read": True, "update": False, "delete": False},
    "reconciliation": {"create": False, "read": True, "update": False, "delete": False},
    "inventory_cost": {"create": False, "read": True, "update": False, "delete": False},
    "notifications": {"create": False, "read": True, "update": True, "delete": False},
    "payments": {"create": False, "read": True, "update": False, "delete": False},
    "expenses": {"create": False, "read": True, "update": False, "delete": False},
    "cheques": {"create": False, "read": True, "update": False, "delete": False},
    "accounts": {"create": False, "read": True, "update": False, "delete": False},
    "accounting": {"create": False, "read": True, "update": False, "delete": False},
}


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _expired(value: Optional[datetime]) -> bool:
    """Timezone-safe comparison (SQLite may return naive datetimes)."""
    if value is None:
        return False
    v = value
    if v.tzinfo is None:
        v = v.replace(tzinfo=timezone.utc)
    return v < _now()


def _ids(raw: str) -> List[UUID]:
    try:
        values = json.loads(raw or "[]")
        return [UUID(str(v)) for v in values if v]
    except Exception:
        return []


def _permissions(raw: str) -> Dict[str, Any]:
    try:
        value = json.loads(raw or "{}")
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}


async def _active_branch_ids(db: AsyncSession, org_id: UUID) -> List[UUID]:
    rows = (await db.execute(select(Branch.id).where(
        Branch.organization_id == org_id,
        Branch.is_archived.is_(False),
        Branch.is_active.is_(True),
    ).order_by(Branch.is_default.desc(), Branch.created_at.asc()))).scalars().all()
    return list(rows)


def is_owner(user: User, org_id: UUID) -> bool:
    return ((user.role or "").lower() == "owner" or bool(user.is_platform_admin)) \
        and str(user.organization_id) == str(org_id)


async def _lock_member_company(db: AsyncSession, org_id: UUID) -> None:
    await branch_service._lock_registry(db, org_id)
    if db.get_bind().dialect.name == 'postgresql':
        from sqlalchemy import text
        # Also serialize Original membership/invitation writers on installations
        # without the optional sync schema. No persistent tables/config changes.
        await db.execute(text("SELECT pg_advisory_xact_lock(hashtextextended(:company,0))"),
                         {'company': 'fyona:branch-members:' + str(org_id)})


async def get_member(db: AsyncSession, org_id: UUID,
                     user_id: UUID) -> Optional[BranchMember]:
    return (await db.execute(select(BranchMember).where(
        BranchMember.organization_id == org_id,
        BranchMember.user_id == user_id,
        BranchMember.status == "active",
    ))).scalar_one_or_none()


def scope_is_current(member: BranchMember, scope: Optional[dict]) -> bool:
    if not scope or member.scope_valid_after is None:
        return True
    cutoff = member.scope_valid_after
    if cutoff.tzinfo is None:
        cutoff = cutoff.replace(tzinfo=timezone.utc)
    try:
        return float(scope.get('issued_at', scope.get('iat', 0))) > cutoff.timestamp()
    except (TypeError, ValueError):
        return False


async def has_company_access(db: AsyncSession, org_id: UUID, user_id: UUID,
                             scope: Optional[dict] = None) -> bool:
    """A revoked membership is explicit denial, never a legacy-access fallback."""
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    if user is None:
        return False
    if is_owner(user, org_id):
        return True
    member = (await db.execute(select(BranchMember).where(
        BranchMember.organization_id == org_id,
        BranchMember.user_id == user_id))).scalar_one_or_none()
    if member is not None:
        return member.status == 'active' and scope_is_current(member, scope)
    return str(user.organization_id) == str(org_id)


async def effective_branch_ids(db: AsyncSession, org_id: UUID,
                               user_id: UUID) -> List[UUID]:
    user = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    if user is None:
        return []
    active = await _active_branch_ids(db, org_id)
    if is_owner(user, org_id):
        return active
    member = await get_member(db, org_id, user_id)
    if member is None:
        if not await has_company_access(db, org_id, user_id):
            return []
        # Legacy same-company staff keep their existing access. Cross-company
        # users are ONLY admitted through an accepted membership.
        if str(user.organization_id) == str(org_id):
            return active
        return []
    if member.all_branches:
        return active
    allowed = set(_ids(member.branch_ids))
    return [b for b in active if b in allowed]


async def can_access_branch(db: AsyncSession, org_id: UUID, user_id: UUID,
                            branch_id: UUID) -> bool:
    return branch_id in set(await effective_branch_ids(db, org_id, user_id))


async def can_view_all(db: AsyncSession, org_id: UUID, user_id: UUID) -> bool:
    user = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    if user is None:
        return False
    if is_owner(user, org_id):
        return True
    member = await get_member(db, org_id, user_id)
    return bool(member and (member.all_branches or
        len(await effective_branch_ids(db, org_id, user_id)) > 1))


def intersect_scope_ids(scope: dict, allowed_ids: List[UUID]) -> List[UUID]:
    """A signed snapshot may shrink after revocation, never expand after a grant."""
    if 'branch_ids' not in scope:
        return allowed_ids  # Legacy owner/all-branch tokens.
    raw = scope['branch_ids']
    if not isinstance(raw, list):
        return []
    selected = {str(value) for value in raw}
    return [value for value in allowed_ids if str(value) in selected]


async def can_transfer(db: AsyncSession, org_id: UUID, user_id: UUID,
                       from_branch_id: UUID, to_branch_id: UUID) -> bool:
    user = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    if user is None:
        return False
    if is_owner(user, org_id):
        return True
    member = await get_member(db, org_id, user_id)
    if member is None:
        return False
    permissions = _permissions(member.permissions)
    if any(isinstance(value, bool) for value in permissions.values()):
        from .employee_access_policy import allowed
        if not allowed(permissions, 'branches.transfer'):
            return False
    elif not member.can_transfer:
        return False
    allowed = set(await effective_branch_ids(db, org_id, user_id))
    return from_branch_id in allowed and to_branch_id in allowed


async def branch_recipients(db: AsyncSession, org_id: UUID,
                            branch_id: UUID) -> List[UUID]:
    """Active users who may see this branch: the owner + accepted members."""
    owner_ids = (await db.execute(select(User.id).where(
        User.organization_id == org_id,
        User.status == "active",
        User.role == "owner",
    ))).scalars().all()
    members = (await db.execute(select(BranchMember).where(
        BranchMember.organization_id == org_id,
        BranchMember.status == "active",
    ))).scalars().all()
    out: List[UUID] = list(owner_ids)
    for m in members:
        if m.all_branches or branch_id in set(_ids(m.branch_ids)):
            out.append(m.user_id)
    return list(dict.fromkeys(out))


def branch_of_invitation_dict(inv: BranchInvitation,
                              branch: Optional[Branch] = None,
                              org: Optional[Organization] = None,
                              user: Optional[User] = None) -> Dict[str, Any]:
    return {
        "id": str(inv.id),
        "organization_id": str(inv.organization_id),
        "organization_name": org.name if org else None,
        "branch_id": str(inv.branch_id),
        "branch_name": branch.name if branch else None,
        "invited_user_id": str(inv.invited_user_id),
        "invited_user_name": user.full_name if user else None,
        "invited_by": str(inv.invited_by) if inv.invited_by else None,
        "status": inv.status,
        "identifier_type": inv.identifier_type,
        "identifier": inv.identifier,
        "can_transfer": bool(inv.can_transfer),
        "created_at": inv.created_at.isoformat() if inv.created_at else None,
        "expires_at": inv.expires_at.isoformat() if inv.expires_at else None,
        "responded_at": inv.responded_at.isoformat() if inv.responded_at else None,
    }


async def invite(
    db: AsyncSession, org_id: UUID, actor: User, branch_id: UUID,
    phone: Optional[str] = None, code: Optional[str] = None,
    can_transfer: bool = False,
) -> Dict[str, Any]:
    await require_member_owner(db, org_id, actor, message="إرسال الدعوات متاح للمالك فقط")
    branch = (await db.execute(select(Branch).where(
        Branch.id == branch_id, Branch.organization_id == org_id,
        Branch.is_archived.is_(False), Branch.is_active.is_(True),
    ))).scalar_one_or_none()
    if branch is None:
        raise ValueError("الفرع غير موجود أو غير نشط")
    from app.domain.services.merchant_link_service import lookup_user
    target = await lookup_user(db, phone, code)
    if target is None:
        raise ValueError("لا يوجد مستخدم بهذا الرقم أو الرمز")
    if target.status and target.status != "active":
        raise ValueError("حساب المستخدم غير نشط")
    if is_owner(target, org_id):
        raise ValueError("هذا المستخدم مالك الشركة ولديه وصول كامل")
    existing_member = await get_member(db, org_id, target.id)
    if existing_member and (existing_member.all_branches or
                            branch_id in set(_ids(existing_member.branch_ids))):
        raise ValueError("المستخدم مرتبط بهذا الفرع بالفعل")
    pending = (await db.execute(select(BranchInvitation).where(
        BranchInvitation.organization_id == org_id,
        BranchInvitation.branch_id == branch_id,
        BranchInvitation.invited_user_id == target.id,
        BranchInvitation.status == "pending",
    ))).scalar_one_or_none()
    if pending:
        raise ValueError("توجد دعوة معلقة بالفعل لهذا المستخدم على الفرع")
    ident_type = "phone" if (phone or "").strip() else "code"
    inv = BranchInvitation(
        organization_id=org_id, branch_id=branch_id,
        invited_user_id=target.id, invited_by=actor.id,
        identifier_type=ident_type,
        identifier=(phone or code or "").strip(),
        status="pending", can_transfer=can_transfer,
        permissions=json.dumps(DEFAULT_MEMBER_PERMISSIONS, ensure_ascii=False),
        created_at=_now(), expires_at=_now() + INVITE_TTL,
    )
    db.add(inv)
    await db.flush()
    event_id = f"branch_invite:{inv.id}"
    route = f"/branches/invitations?invite={inv.id}"
    from app.domain.entities.notification_entities import AppNotification as N
    db.add(N(
        organization_id=org_id, user_id=target.id, type="info",
        title="دعوة فرع جديد", message=(
            f"{actor.full_name} يدعوك للانضمام إلى فرع {branch.name}"
            f" في {await _org_name(db, org_id)}"),
        action="open_screen", action_payload=json.dumps(
            {"invitation_id": str(inv.id), "branch_id": str(branch_id),
             "organization_id": str(org_id)}, ensure_ascii=False),
        route=route, event_id=event_id, domain="main",
    ))
    return {
        "invitation": branch_of_invitation_dict(inv, branch, user=target),
        "target_user_id": str(target.id),
        "event_id": event_id,
        "route": route,
        "title": "دعوة فرع جديد",
        "message": (
            f"{actor.full_name} يدعوك للانضمام إلى فرع {branch.name}"
            f" في {await _org_name(db, org_id)}"),
    }


async def _org_name(db: AsyncSession, org_id: UUID) -> str:
    name = (await db.execute(select(Organization.name).where(
        Organization.id == org_id))).scalar_one_or_none()
    return (name or "شركة").strip()


async def incoming_invitations(db: AsyncSession,
                               user_id: UUID) -> List[Dict[str, Any]]:
    rows = (await db.execute(select(BranchInvitation).where(
        BranchInvitation.invited_user_id == user_id,
        BranchInvitation.status == "pending",
    ).order_by(BranchInvitation.created_at.desc()))).scalars().all()
    out = []
    for inv in rows:
        if _expired(inv.expires_at):
            inv.status = "expired"
            continue
        branch = (await db.execute(select(Branch).where(
            Branch.id == inv.branch_id))).scalar_one_or_none()
        org = (await db.execute(select(Organization).where(
            Organization.id == inv.organization_id))).scalar_one_or_none()
        inviter = (await db.execute(select(User).where(
            User.id == inv.invited_by))).scalar_one_or_none() if inv.invited_by else None
        item = branch_of_invitation_dict(inv, branch, org, inviter)
        out.append(item)
    return out


async def respond(db: AsyncSession, user_id: UUID, invitation_id: UUID,
                   accept: bool) -> Dict[str, Any]:
    company = await db.scalar(select(BranchInvitation.organization_id).where(
        BranchInvitation.id == invitation_id, BranchInvitation.invited_user_id == user_id))
    if company is None:
        raise ValueError("الدعوة غير موجودة")
    # Acceptance changes a membership and must take the SAME company head before
    # invitation/member rows as owner updates and immutable sync commands.
    await _lock_member_company(db, company)
    inv = (await db.execute(select(BranchInvitation).where(
        BranchInvitation.id == invitation_id,
        BranchInvitation.invited_user_id == user_id,
    ).with_for_update().execution_options(populate_existing=True))).scalar_one_or_none()
    if inv is None:
        raise ValueError("الدعوة غير موجودة")
    if inv.status != "pending":
        raise ValueError("تمت معالجة هذه الدعوة مسبقًا")
    if _expired(inv.expires_at):
        inv.status = "expired"
        raise ValueError("انتهت صلاحية الدعوة")
    branch = (await db.execute(select(Branch).where(
        Branch.id == inv.branch_id,
        Branch.organization_id == inv.organization_id))).scalar_one_or_none()
    if branch is None or branch.is_archived or not branch.is_active:
        raise ValueError("الفرع لم يعد متاحًا")
    inv.status = "accepted" if accept else "rejected"
    inv.responded_at = _now()
    if accept:
        member = (await db.execute(select(BranchMember).where(
            BranchMember.organization_id == inv.organization_id,
            BranchMember.user_id == user_id,
        ).with_for_update().execution_options(populate_existing=True))).scalar_one_or_none()
        if member is None:
            member = BranchMember(
                organization_id=inv.organization_id, user_id=user_id,
                branch_ids=json.dumps([str(inv.branch_id)]),
                permissions=inv.permissions or json.dumps(
                    DEFAULT_MEMBER_PERMISSIONS, ensure_ascii=False),
                per_branch="{}", all_branches=False,
                can_transfer=bool(inv.can_transfer),
                status="active", invited_by=inv.invited_by, created_at=_now(),
            )
            db.add(member)
        else:
            ids = _ids(member.branch_ids)
            if inv.branch_id not in ids:
                ids.append(inv.branch_id)
            member.branch_ids = json.dumps([str(x) for x in ids])
            member.status = "active"
            member.can_transfer = bool(member.can_transfer or inv.can_transfer)
        await db.flush()
    push = await _notify_owner_response(db, inv, user_id, accepted=accept,
                                       branch_name=(branch.name if branch else ""))
    return {"status": inv.status, "invitation_id": str(inv.id), "_push": push}


async def _notify_owner_response(db: AsyncSession, inv: BranchInvitation,
                                 user_id: UUID, accepted: bool,
                                 branch_name: str):
    if not inv.invited_by:
        return
    actor_name = (await db.execute(select(User.full_name).where(
        User.id == user_id))).scalar_one_or_none() or "مستخدم"
    event_id = f"branch_invite_response:{inv.id}"
    from app.domain.services.invitation_response_service import emit
    return await emit(db,
        org_id=inv.organization_id, inviter_id=inv.invited_by,
        message=(f"{actor_name} {'قبل' if accepted else 'رفض'} دعوة فرع "
                 f"{branch_name}"),
        route=f"/branches/invitations?invite={inv.id}",
        event_id=event_id,
    )


async def revoke_invitation(db: AsyncSession, org_id: UUID, actor: User,
                             invitation_id: UUID) -> None:
    await require_member_owner(db, org_id, actor, message="سحب الدعوات متاح للمالك فقط")
    inv = (await db.execute(select(BranchInvitation).where(
        BranchInvitation.id == invitation_id,
        BranchInvitation.organization_id == org_id,
    ).with_for_update().execution_options(populate_existing=True))).scalar_one_or_none()
    if inv is None:
        raise ValueError("الدعوة غير موجودة")
    if inv.status == "pending":
        inv.status = "revoked"
        inv.responded_at = _now()


async def list_invitations(db: AsyncSession, org_id: UUID,
                           actor: User) -> List[Dict[str, Any]]:
    if not is_owner(actor, org_id):
        raise ValueError("عرض دعوات الفرع متاح للمالك فقط")
    rows = (await db.execute(select(BranchInvitation).where(
        BranchInvitation.organization_id == org_id,
    ).order_by(BranchInvitation.created_at.desc()))).scalars().all()
    out = []
    for inv in rows:
        branch = (await db.execute(select(Branch).where(
            Branch.id == inv.branch_id))).scalar_one_or_none()
        user = (await db.execute(select(User).where(
            User.id == inv.invited_user_id))).scalar_one_or_none()
        out.append(branch_of_invitation_dict(inv, branch, user=user))
    return out


async def list_members(db: AsyncSession, org_id: UUID,
                        actor: User) -> List[Dict[str, Any]]:
    await require_member_owner(db, org_id, actor, message="عرض أعضاء الفروع متاح للمالك فقط")
    rows = (await db.execute(select(BranchMember).where(
        BranchMember.organization_id == org_id,
    ).order_by(BranchMember.created_at.asc()))).scalars().all()
    active = await _active_branch_ids(db, org_id)
    branch_names = dict((await db.execute(select(Branch.id, Branch.name).where(
        Branch.organization_id == org_id))).all())
    out = []
    for m in rows:
        user = (await db.execute(select(User).where(
            User.id == m.user_id))).scalar_one_or_none()
        ids = active if m.all_branches else [
            b for b in _ids(m.branch_ids) if b in set(active)]
        out.append({
            "id": str(m.id), "user_id": str(m.user_id),
            "name": user.full_name if user else None,
            "phone": user.phone if user else None,
            "code": user.public_code if user else None,
            "status": m.status,
            "branch_ids": [str(b) for b in ids],
            "branch_names": [branch_names.get(b) for b in ids],
            "all_branches": bool(m.all_branches),
            "can_transfer": bool(m.can_transfer),
            "permissions": _permissions(m.permissions),
            "created_at": m.created_at.isoformat() if m.created_at else None,
        })
    return out


async def require_member_owner(db: AsyncSession, org_id: UUID, actor: User, *,
        message="تعديل أعضاء الفروع متاح للمالك فقط") -> User:
    """Share the authority's company-before-user/member lock order online too."""
    await _lock_member_company(db, org_id)
    current = (await db.execute(select(User).where(User.id == actor.id)
        .with_for_update().execution_options(populate_existing=True))).scalar_one_or_none()
    if current is None or current.status != 'active' or not is_owner(current, org_id):
        raise ValueError(message)
    return current


async def update_member(db: AsyncSession, org_id: UUID, actor: User,
                        member_id: UUID, *, branch_ids: Optional[List[UUID]] = None,
                        all_branches: Optional[bool] = None,
                        can_transfer: Optional[bool] = None,
                        permissions: Optional[Dict[str, Any]] = None,
                        status: Optional[str] = None) -> Dict[str, Any]:
    await require_member_owner(db, org_id, actor)
    member = (await db.execute(select(BranchMember).where(
        BranchMember.id == member_id,
        BranchMember.organization_id == org_id,
    ).with_for_update().execution_options(populate_existing=True))).scalar_one_or_none()
    if member is None:
        raise ValueError("العضوية غير موجودة")
    active = set(await _active_branch_ids(db, org_id))
    if branch_ids is not None:
        wanted = [b for b in branch_ids if b in active]
        member.branch_ids = json.dumps([str(b) for b in wanted])
    if all_branches is not None:
        member.all_branches = bool(all_branches)
    if can_transfer is not None:
        member.can_transfer = bool(can_transfer)
    if permissions is not None:
        member.permissions = json.dumps(permissions, ensure_ascii=False)
    if status in ("active", "revoked"):
        member.status = status
        if status == 'revoked':
            # Old signed scope tokens and outstanding invitations must not
            # reactivate a deliberately disconnected member after a re-grant.
            member.scope_valid_after = _now()
            pending = (await db.execute(select(BranchInvitation).where(
                BranchInvitation.organization_id == org_id,
                BranchInvitation.invited_user_id == member.user_id,
                BranchInvitation.status == 'pending')
                .order_by(BranchInvitation.id).with_for_update()
                .execution_options(populate_existing=True))).scalars().all()
            for invitation in pending:
                invitation.status = 'revoked'
                invitation.responded_at = _now()
    await db.flush()
    return {"id": str(member.id), "status": member.status}


async def access_summary(db: AsyncSession, user_id: UUID) -> Dict[str, Any]:
    """Every company/branch this user may enter, including their own."""
    user = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    if user is None:
        return {"companies": []}
    companies: Dict[str, Dict[str, Any]] = {}

    async def add_company(org_id: UUID, role: str, can_transfer_flag: bool,
                          member: Optional[BranchMember] = None) -> None:
        org = (await db.execute(select(Organization).where(
            Organization.id == org_id))).scalar_one_or_none()
        if org is None:
            return
        branches = (await db.execute(select(Branch).where(
            Branch.organization_id == org_id,
            Branch.is_archived.is_(False),
            Branch.is_active.is_(True),
        ).order_by(Branch.is_default.desc(), Branch.created_at.asc()))).scalars().all()
        if member is not None and not member.all_branches:
            allowed = set(_ids(member.branch_ids))
            branches = [b for b in branches if b.id in allowed]
        entry = companies.setdefault(str(org_id), {
            "organization_id": str(org_id), "organization_name": org.name,
            "role": role, "can_transfer": can_transfer_flag,
            "all_branches": bool(member.all_branches) if member else role == "owner",
            "branches": [],
        })
        from .merchant_subscription_service import owner_subscription_fields
        entry.update(owner_subscription_fields(org))
        for b in branches:
            branch = branch_service.branch_dict(b)
            if b.is_default and not branch['image']:
                branch['image'] = org.avatar
                branch['image_version'] = org.updated_at.isoformat() if org.updated_at else branch['image_version']
            entry["branches"].append(branch)
        if member is not None:
            entry["permissions"] = _permissions(member.permissions)

    if user.organization_id:
        own_role = "owner" if (user.role or "").lower() == "owner" else "member"
        own_member = None
        if own_role != "owner":
            own_member = await get_member(db, user.organization_id, user_id)
        if own_role == "owner" or own_member is not None:
            await add_company(
                user.organization_id, own_role,
                bool(own_member.can_transfer) if own_member else True,
                own_member)

    members = (await db.execute(select(BranchMember).where(
        BranchMember.user_id == user_id,
        BranchMember.status == "active",
    ))).scalars().all()
    for m in members:
        if str(m.organization_id) == str(user.organization_id):
            continue
        await add_company(m.organization_id, "member", bool(m.can_transfer), m)
    return {"companies": list(companies.values())}
