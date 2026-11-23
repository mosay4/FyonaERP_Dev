"""Private, branch-scoped delivery of an employee's own device receipts."""
import json
from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_session_id, get_current_user_uuid
from app.api.responses import ok
from app.core.database import get_db
from app.domain.entities.auth_entities import Organization, UserSession
from app.domain.entities.sale_entities import Branch
from app.domain.services import branch_access_service as access
from app.domain.services import qa_employee_finance as finance
from app.domain.services.branch_service import decode_scope_token
from app.domain.services.merchant_subscription_service import (
    owner_subscription_fields, require_merchant_subscription,
)
from .employees import _employee_dict
from .qa_business_session import lock_live_user

router = APIRouter(prefix="/business/employee-finance", tags=["Employee Finance (QA)"])


def _deny():
    return HTTPException(403, "العملية غير متاحة أو تم إلغاء الارتباط")


async def _scope(db, token, actor, session):
    if not await finance.available(db):
        raise HTTPException(404, "العملية غير متاحة")
    claims = decode_scope_token(token) or {}
    if claims.get("mode") != "branch" or claims.get("sub") != str(actor):
        raise _deny()
    try:
        branch_id, org_id = UUID(claims["branch"]), UUID(claims["org"])
    except (KeyError, ValueError, TypeError, AttributeError):
        raise _deny() from None
    user = await lock_live_user(db, actor, session)
    if user is None:
        raise _deny()
    branch = await db.get(Branch, branch_id, with_for_update={"read": True}, populate_existing=True)
    if branch is None or branch.organization_id != org_id:
        raise _deny()
    owner = await finance.registered_account(db, branch)
    if owner is None:
        raise _deny()
    organization = await db.get(Organization, org_id, with_for_update={"read": True}, populate_existing=True)
    require_merchant_subscription(organization)
    return branch, organization, owner, claims


async def owner_scope(
    token: str | None = Header(default=None, alias="X-Branch-Token"),
    actor: UUID = Depends(get_current_user_uuid),
    session: UUID | None = Depends(get_current_session_id),
    db: AsyncSession = Depends(get_db),
):
    branch, _, owner, claims = await _scope(db, token, actor, session)
    if actor != owner or claims.get("qa_directory") is not True \
            or claims.get("qa_business_ledger") is not True:
        raise _deny()
    return branch, session


async def _publisher(db, branch_id, session, *, bind=False):
    if bind:
        # No session rotation or takeover by a second owner device in this
        # trial. A separately verified recovery can change that later.
        await db.execute(text(f"""
            INSERT INTO {finance.PUBLISHERS} (branch_id, session_id) VALUES (:branch, :session)
            ON CONFLICT (branch_id) DO NOTHING
        """), {"branch": branch_id, "session": session})
    pinned = await db.scalar(text(f"""
        SELECT session_id FROM {finance.PUBLISHERS} WHERE branch_id = :branch
        {"FOR UPDATE" if bind else ""}
    """), {"branch": branch_id})
    if pinned is not None and pinned != session:
        raise _deny()


@router.get("/owner")
async def targets(scope=Depends(owner_scope), db: AsyncSession = Depends(get_db)):
    branch, session = scope
    await _publisher(db, branch.id, session)
    previous = dict((await db.execute(text(f"""
        SELECT employee_id, version FROM {finance.SNAPSHOTS} WHERE branch_id = :branch
    """), {"branch": branch.id})).all())
    return ok({"targets": [
        {"employee_id": str(employee.id), "grant_revision": revision,
         "version": previous.get(employee.id, 0)}
        for employee, _, _, revision, _ in await finance.recipients(db, branch)
    ]})


@router.put("/owner/{employee_id}")
async def publish(employee_id: UUID, body: finance.Publication,
                  scope=Depends(owner_scope), db: AsyncSession = Depends(get_db)):
    branch, session = scope
    target = next((row for row in await finance.recipients(db, branch)
                   if row[0].id == employee_id), None)
    if target is None or target[3] != body.grant_revision:
        raise _deny()
    _, _, member, revision, _ = target
    await _publisher(db, branch.id, session, bind=True)
    previous = await finance.snapshot(db, branch.id, employee_id)
    if previous and previous["recipient_id"] != member.user_id:
        # Reassigning a file to a new account cannot hand it the old holder's
        # receipts automatically. A deliberate migration is a separate job.
        raise _deny()
    records = body.records()
    if previous and previous["records"] == records and previous["grant_revision"] == revision:
        # Exact retry (including a lost response) has the same version.
        return ok({"version": previous["version"]})
    version = previous["version"] if previous else 0
    new_by_id = {row["id"]: row for row in records}
    if body.expected_version != version or (previous and any(
        new_by_id.get(row["id"]) != row for row in previous["records"]
    )):
        raise HTTPException(409, "العملية غير متاحة")
    await db.execute(text(f"""
        INSERT INTO {finance.SNAPSHOTS}
          (branch_id, employee_id, recipient_id, grant_revision, version, records)
        VALUES (:branch, :employee, :recipient, :revision, :version, CAST(:records AS jsonb))
        ON CONFLICT (branch_id, employee_id) DO UPDATE SET
          recipient_id = EXCLUDED.recipient_id, grant_revision = EXCLUDED.grant_revision,
          version = EXCLUDED.version, records = EXCLUDED.records
    """), {"branch": branch.id, "employee": employee_id, "recipient": member.user_id,
           "revision": revision, "version": version + 1, "records": json.dumps(records)})
    await db.commit()
    return ok({"version": version + 1})


@router.get("/me")
async def self_finance(
    token: str | None = Header(default=None, alias="X-Branch-Token"),
    actor: UUID = Depends(get_current_user_uuid),
    session: UUID | None = Depends(get_current_session_id),
    db: AsyncSession = Depends(get_db),
):
    branch, organization, owner, claims = await _scope(db, token, actor, session)
    grant = claims.get("qa_employee_finance")
    if actor == owner or not isinstance(grant, dict):
        raise _deny()
    rows = await finance.recipients(db, branch, user_id=actor)
    if len(rows) != 1:
        raise _deny()
    employee, workspace, member, revision, invite = rows[0]
    if grant != {"employee_id": str(employee.id), "revision": revision} \
            or not access.scope_is_current(member, claims):
        raise _deny()
    profile = _employee_dict(employee, workspace)
    profile["permissions"] = access._permissions(member.permissions)
    profile["branch_ids"] = [str(branch.id)]
    profile.pop("notes", None)
    published = await finance.snapshot(db, branch.id, employee.id)
    records = (published["records"] if published and published["recipient_id"] == actor
               and published["grant_revision"] == revision else None)
    now = datetime.now(timezone.utc)
    session_end = await db.scalar(select(UserSession.expires_at).where(UserSession.id == session))
    expiry = min(datetime.fromtimestamp(claims["exp"], timezone.utc), now + timedelta(hours=12), session_end)
    end = owner_subscription_fields(organization)["owner_subscription_end_date"]
    if end:
        subscription_end = datetime.fromisoformat(end)
        expiry = min(expiry, subscription_end.replace(tzinfo=subscription_end.tzinfo or timezone.utc))
    if expiry <= now:
        raise _deny()
    company = {"id": str(organization.id), "name": organization.name}
    response = ok({
        "account_id": str(actor), "session_id": str(session), "branch_id": str(branch.id),
        "organization_id": str(organization.id), "employee_id": str(employee.id),
        "grant_revision": revision, "expires_at": expiry.isoformat(),
        "profile": {"employee": profile, "organization": company},
        "employment": {
            "id": str(invite), "status": "accepted", "employee_id": str(employee.id),
            "organization": company,
            "employee": {"id": str(employee.id), "full_name": employee.full_name},
            "branch_ids": [str(branch.id)], "branches": [{"id": str(branch.id), "name": branch.name}],
        },
        "finance": None if records is None else finance.finance_view(records, employee, organization, branch),
    })
    response.headers["Cache-Control"] = "no-store"
    return response
