"""Dedicated, scope-bound transport for the QA Business party projection."""
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_branch_scope, get_current_org_id, get_current_session_id, get_current_user_uuid
from app.api.responses import ok
from app.core import qa_business_ledger, qa_directory
from app.core.database import get_db
from app.domain.entities.sale_entities import Branch
from app.domain.services import merchant_link_service as links
from app.domain.services import qa_business_party_sharing as shares
from app.domain.services.branch_service import decode_scope_token

from .merchant_links import _need_party_perm, _push_after_commit
from .qa_business_session import lock_live_user

router = APIRouter(prefix="/business/party-sharing", tags=["Business Party Sharing (QA)"])
PartyKind = Literal["customer", "supplier"]


class Contact(BaseModel):
    model_config = ConfigDict(extra="forbid")
    phone: str | None = Field(default=None, max_length=30)
    code: str | None = Field(default=None, max_length=6)
    country: str | None = Field(default=None, min_length=2, max_length=2)


class Lookup(Contact):
    kind: PartyKind


async def writer(
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    scope=Depends(get_branch_scope),
    token: str | None = Header(default=None, alias="X-Branch-Token"),
    db: AsyncSession = Depends(get_db),
    session_id: UUID | None = Depends(get_current_session_id),
):
    if not qa_directory.INVITES:
        raise HTTPException(404, "المشاركة غير متاحة")
    claims = decode_scope_token(token) or {}
    if scope.branch_id is None or scope.all_mode or claims.get("mode") != "branch" \
            or claims.get("qa_directory") is not True \
            or claims.get("qa_business_ledger") is not True \
            or claims.get("sub") != str(user_id) or claims.get("org") != org_id \
             or claims.get("branch") != str(scope.branch_id):
        raise HTTPException(403, "المشاركة تتطلب الفرع والجهاز المصرّح لهما")
    if not await shares.available(db):
        raise HTTPException(404, "المشاركة غير متاحة")
    user = await lock_live_user(db, user_id, session_id)
    branch = await db.get(Branch, scope.branch_id, with_for_update={"read": True}, populate_existing=True)
    if not user or not branch \
            or not await qa_business_ledger.registered_owner(db, user, branch):
        raise HTTPException(403, "المشاركة تتطلب الفرع والجهاز المصرّح لهما")
    return UUID(org_id), scope.branch_id, user_id, session_id


@router.post("/lookup")
async def lookup(data: Lookup, scope=Depends(writer), db: AsyncSession = Depends(get_db)):
    _, _, actor, _ = scope
    await _need_party_perm(db, actor, data.kind, "update")
    try:
        target = await links.lookup_user(db, data.phone, data.code, data.country)
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    if target is None or target.id == actor or target.status != "active":
        return ok({"found": False})
    via = "phone" if (data.phone or "").strip() else "code"
    value = (data.phone if via == "phone" else data.code).strip()
    return ok({"found": True, "name": target.full_name,
               "avatar": target.photo_url or target.avatar,
               "matched_by": via, via: value, "contact": {"via": via, "value": value}})


@router.post("/{kind}/{party_key}/invite")
async def invite(kind: PartyKind, party_key: UUID, data: Contact,
                 scope=Depends(writer), db: AsyncSession = Depends(get_db)):
    org, branch, actor, session_id = scope
    await _need_party_perm(db, actor, kind, "update")
    try:
        result = await shares.invite(db, org, branch, actor, session_id, kind, party_key,
                                     data.phone, data.code, data.country)
    except shares.PublisherChanged as exc:
        raise HTTPException(409, str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    push = result.pop("_push", None)
    await db.commit()
    await _push_after_commit(db, org, push)
    return ok(result)


@router.get("/{kind}/{party_key}")
async def status(kind: PartyKind, party_key: UUID,
                 scope=Depends(writer), db: AsyncSession = Depends(get_db)):
    org, branch, actor, _ = scope
    await _need_party_perm(db, actor, kind, "read")
    return ok(await shares.status(db, org, branch, kind, party_key))


@router.put("/{kind}/{party_key}/snapshot")
async def publish(kind: PartyKind, party_key: UUID, data: shares.ShareSnapshot,
                  scope=Depends(writer), db: AsyncSession = Depends(get_db)):
    org, branch, actor, session_id = scope
    await _need_party_perm(db, actor, kind, "update")
    try:
        result = await shares.publish(db, org, branch, session_id, kind, party_key, data)
    except (shares.StalePublication, shares.PublisherChanged) as exc:
        raise HTTPException(409, str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc
    await db.commit()
    return ok(result)


@router.delete("/{kind}/{party_key}")
async def revoke(kind: PartyKind, party_key: UUID,
                 scope=Depends(writer), db: AsyncSession = Depends(get_db)):
    org, branch, actor, _ = scope
    await _need_party_perm(db, actor, kind, "delete")
    result = await shares.revoke(db, org, branch, kind, party_key)
    await db.commit()
    return ok(result)
