"""Opt-in QA relay for replicas admitted after a reconciled cash checkpoint."""

import json
import os
from hashlib import sha256
from uuid import UUID

from fastapi import APIRouter, Body, Depends, Header, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import (
    get_current_org_id, get_current_session_id, get_current_user_uuid,
)
from app.api.responses import ok
from app.core import qa_business_ledger, qa_directory
from app.core.database import get_db
from app.domain.entities.auth_entities import Organization, User, UserSession
from app.domain.entities.branch_entities import BranchMember
from app.domain.entities.sale_entities import Branch
from app.domain.services import branch_access_service, employee_access_policy
from app.domain.services import local_business_cash as cash
from app.domain.services import qa_cash_admission as admission
from app.domain.services.branch_service import decode_scope_token
from app.domain.services.local_business_cash_wire import CashAction, apply_message
from app.domain.services.merchant_subscription_service import require_merchant_subscription
from .qa_business_session import SESSION_STATE, lock_live_user, session_disabled

router = APIRouter(prefix="/business/cash-relay", tags=["Business Cash Relay (QA)"])


def relay_enabled() -> bool:
    return bool(qa_directory.INVITES) and os.getenv("FYONA_QA_CASH_RELAY") == "1"


def _deny():
    return HTTPException(403, detail="مزامنة النقد غير متاحة لهذا الفرع أو الجهاز")


def _member_permissions(member, branch_id):
    if not member or member.status != "active":
        return None
    try:
        branches = json.loads(member.branch_ids)
        permissions = json.loads(member.permissions)
    except (ValueError, TypeError):
        return None
    if not member.all_branches and (
        not isinstance(branches, list) or str(branch_id) not in branches
    ):
        return None
    if not isinstance(permissions, dict) or not all(
        employee_access_policy.allowed(permissions, permission)
        for permission in ("banks.details", "banks.balances")
    ):
        return None
    return permissions


def _membership_revision(member) -> str:
    # A permission/membership edit requires a new reconciled admission. Old
    # credentials cannot join a later grant even if the old map is restored.
    fields = [str(member.id), str(member.updated_at), str(member.scope_valid_after),
              member.branch_ids, member.all_branches, member.permissions]
    return sha256(json.dumps(fields, separators=(",", ":")).encode()).hexdigest()


async def _live_access(db, scope, user_id, session_id, claims):
    org_id, branch_id = scope.workspace_id, scope.branch_id
    # Lock the verified session, branch and employee membership against a
    # concurrent revocation while applying/reading this authority transaction.
    user = await lock_live_user(db, user_id, session_id)
    branch = await db.get(Branch, branch_id, with_for_update={"read": True}, populate_existing=True)
    if not user or not branch or branch.organization_id != org_id \
            or branch.is_default or not branch.is_active or branch.is_archived:
        raise _deny()
    require_merchant_subscription(await db.get(Organization, org_id, populate_existing=True))
    owner = await db.scalar(text(f"""
        SELECT u.id
        FROM {qa_business_ledger.SCOPE_TABLE} ledger
        JOIN public.fyona_qa_directory_scope directory
          USING (organization_id, account_id, branch_id)
        JOIN public.users u ON u.id = ledger.account_id AND u.organization_id = ledger.organization_id
        WHERE ledger.organization_id = :org AND ledger.branch_id = :branch
          AND u.status = 'active' AND u.role = 'owner'
          AND u.email = ANY(CAST(:owners AS text[]))
        FOR SHARE OF ledger, directory, u
    """), {"org": org_id, "branch": branch_id, "owners": sorted(qa_directory.INVITES)})
    if owner is None:
        raise _deny()
    if owner == user_id:
        if claims.get("qa_directory") is not True or claims.get("qa_business_ledger") is not True:
            raise _deny()
        return owner, cash.CashReplica(user_id, session_id), True, True, True
    # Neither access to this tenant nor a merchant link is membership.
    member = await db.scalar(select(BranchMember).where(
        BranchMember.organization_id == org_id, BranchMember.user_id == user_id,
    ).with_for_update(read=True).execution_options(populate_existing=True))
    permissions = _member_permissions(member, branch_id)
    if permissions is None or not branch_access_service.scope_is_current(member, claims):
        raise _deny()
    return (owner, cash.CashReplica(user_id, session_id, _membership_revision(member)),
            employee_access_policy.allowed(permissions, "expenses"),
            employee_access_policy.allowed(permissions, "transactions"),
            all(employee_access_policy.allowed(permissions, permission)
                for permission in ("reconciliation.bank", "reconciliation.equalize")))


async def _stale_sessions(db, scope, owner, replicas):
    # Same transaction as decisions/acknowledgments. Never reads or purges
    # another branch. A device that is simply offline is not retired.
    if not replicas:
        return []
    actor_ids = {r["actor_id"] for r in replicas}
    sessions = {r.id: r for r in (await db.execute(select(*SESSION_STATE).where(
        UserSession.id.in_({r["session_id"] for r in replicas}),
    ))).all()}
    users = {r.id: r for r in (await db.execute(select(User.id, User.status, User.tokens_valid_after).where(
        User.id.in_(actor_ids),
    ))).all()}
    members = {r.user_id: r for r in (await db.scalars(select(BranchMember).where(
        BranchMember.organization_id == scope.workspace_id, BranchMember.user_id.in_(actor_ids - {owner}),
    ).execution_options(populate_existing=True))).all()}
    stale = []
    for r in replicas:
        actor, session = r["actor_id"], r["session_id"]
        if session_disabled(sessions.get(session), users.get(actor), actor):
            stale.append(session)
        elif actor != owner:
            member = members.get(actor)
            if _member_permissions(member, scope.branch_id) is None \
                    or r["membership_revision"] != _membership_revision(member):
                stale.append(session)
    return stale


class PreparedCash(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: UUID
    account_id: UUID
    digest: str = Field(pattern=r"^[a-f0-9]{64}$")
    # Sent only by the device that counted the till.
    currency: str | None = Field(default=None, pattern=r"^[A-Z]{3}(_[A-Z]{3})?$")
    balance_minor: int | None = Field(default=None, ge=0)
    check_ref: str | None = Field(default=None, pattern=r"^RCN-[0-9]{8}-[A-F0-9]{8}$")


async def _link_scope(
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    session_id: UUID | None = Depends(get_current_session_id),
    token: str | None = Header(default=None, alias="X-Branch-Token"),
    expected_session: UUID | None = Header(default=None, alias="X-Business-Replica-Session"),
    db: AsyncSession = Depends(get_db),
):
    if not relay_enabled() or not admission.enabled():
        raise HTTPException(404, "مزامنة النقد غير متاحة")
    claims = decode_scope_token(token) or {}
    if (session_id is None or session_id != expected_session or claims.get("mode") != "branch"
            or claims.get("sub") != str(user_id) or claims.get("org") != org_id
            or claims.get("qa_writer_session") != str(session_id)
            or claims.get("qa_cash_link") is None):
        raise _deny()
    try:
        scope = cash.CashScope(UUID(org_id), UUID(claims["branch"]))
        plan = UUID(claims["qa_cash_link"])
    except (KeyError, ValueError, TypeError, AttributeError):
        raise _deny() from None
    owner, replica, *_ = await _live_access(db, scope, user_id, session_id, claims)
    if user_id != owner:
        raise _deny()
    return scope, replica, plan


@router.get("/link")
async def read_link(scope=Depends(_link_scope), db: AsyncSession = Depends(get_db)):
    cash_scope, replica, plan = scope
    frame = await admission.read_plan(await db.connection(), cash_scope, replica)
    if frame is None or frame["id"] != str(plan):
        raise _deny()
    await db.commit()
    response = ok(frame)
    response.headers["Cache-Control"] = "no-store"
    return response


@router.post("/link/prepared")
async def prepare_link(body: PreparedCash, scope=Depends(_link_scope),
                       db: AsyncSession = Depends(get_db)):
    cash_scope, replica, plan = scope
    if body.id != plan:
        raise _deny()
    try:
        frame = await admission.prepared(
            await db.connection(), cash_scope, replica, plan=plan,
            account_id=body.account_id, digest=body.digest,
            currency=body.currency, balance_minor=body.balance_minor,
            check_ref=body.check_ref,
        )
    except cash.CashAccessDenied as exc:
        raise _deny() from exc
    await db.commit()
    return ok(frame)


@router.post("/v{version}/{action}")
async def relay(
    version: int,
    action: CashAction,
    body: dict = Body(...),
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    session_id: UUID | None = Depends(get_current_session_id),
    token: str | None = Header(default=None, alias="X-Branch-Token"),
    expected_session: UUID | None = Header(default=None, alias="X-Business-Replica-Session"),
    db: AsyncSession = Depends(get_db),
):
    if not relay_enabled() or version not in (2, 3):
        raise HTTPException(404, "مزامنة النقد غير متاحة")
    claims = decode_scope_token(token) or {}
    if session_id is None or expected_session != session_id \
            or claims.get("mode") != "branch" or claims.get("sub") != str(user_id) \
            or claims.get("org") != org_id:
        raise _deny()
    try:
        scope = cash.CashScope(UUID(org_id), UUID(claims.get("branch", "")))
    except (ValueError, TypeError, AttributeError):
        raise _deny() from None
    if db.get_bind().dialect.name != "postgresql" or not await db.scalar(text("""
        SELECT to_regclass('public.local_cash_replicas') IS NOT NULL
           AND to_regclass('public.fyona_qa_business_ledger_scope') IS NOT NULL
           AND to_regclass('public.fyona_qa_directory_scope') IS NOT NULL
    """)):
        raise HTTPException(404, "مزامنة النقد غير متاحة")
    owner, replica, can_withdraw, can_reference, can_equalize = await _live_access(
        db, scope, user_id, session_id, claims,
    )
    try:
        frame = await apply_message(
            await db.connection(), scope, replica, action, body, live_can_withdraw=can_withdraw,
            live_can_reference=can_reference, version=version, live_can_equalize=can_equalize,
            stale_destinations=lambda rows: _stale_sessions(db, scope, owner, rows),
        )
    except ValueError as exc:
        raise HTTPException(422, "طلب مزامنة غير صالح") from exc
    except cash.CashAccessDenied as exc:
        raise _deny() from exc
    except cash.CashReplayConflict as exc:
        raise HTTPException(409, "معرّف العملية سبق استخدامه") from exc
    # No successful delivery/receipt before database commit, even when the
    # application dependency uses commit-on-yield.
    await db.commit()
    return ok(frame)
