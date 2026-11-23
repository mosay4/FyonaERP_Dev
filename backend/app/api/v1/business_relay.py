"""Business relay endpoints: carry device operations, keep nothing.

See app.domain.services.business_relay for the contract.
"""

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import (
    get_current_org_id,
    get_current_session_id,
    get_current_user_uuid,
)
from app.core.database import get_db
from app.domain.services import business_relay as relay

router = APIRouter()


def ok(data):
    return {"success": True, "message": "تم", "data": data}


class _Body(BaseModel):
    model_config = ConfigDict(extra="forbid")
    replica_id: UUID


class PushItem(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: UUID
    branch_id: UUID | None = None
    kind: str = Field(default="ops", pattern=r"^ops$")
    payload: Any


class PushBody(_Body):
    items: list[PushItem] = Field(min_length=1, max_length=relay.MAX_BATCH)


class AckBody(_Body):
    ids: list[UUID] = Field(min_length=1, max_length=relay.MAX_BATCH)


class SnapshotBody(_Body):
    target: UUID
    payload: Any


_installed = False


async def _ready(db: AsyncSession):
    global _installed
    conn = await db.connection()
    if not _installed:
        await relay.install(conn)
        _installed = True
    return conn


def _denied(exc: Exception) -> HTTPException:
    return HTTPException(403, "غير مصرح")


@router.post("/register", summary="ربط قاعدة بيانات الجهاز بالحساب")
async def register(body: _Body, org_id: str = Depends(get_current_org_id),
                   user_id: UUID = Depends(get_current_user_uuid),
                   session_id: UUID | None = Depends(get_current_session_id),
                   db: AsyncSession = Depends(get_db)):
    try:
        data = await relay.register(await _ready(db), org=UUID(org_id),
                                    user=user_id, session=session_id,
                                    replica_id=body.replica_id)
    except relay.RelayAccessDenied as exc:
        raise _denied(exc) from exc
    await db.commit()
    return ok(data)


@router.post("/push", summary="تسليم عمليات الجهاز إلى محطة العبور")
async def push(body: PushBody, org_id: str = Depends(get_current_org_id),
               user_id: UUID = Depends(get_current_user_uuid),
               db: AsyncSession = Depends(get_db)):
    try:
        data = await relay.push(
            await _ready(db), org=UUID(org_id), user=user_id,
            replica_id=body.replica_id,
            items=[item.model_dump() for item in body.items],
        )
    except relay.RelayAccessDenied as exc:
        raise _denied(exc) from exc
    except relay.RelayInvalid as exc:
        raise HTTPException(422, "حمولة غير صالحة") from exc
    await db.commit()
    return ok({"items": data})


@router.post("/pull", summary="العمليات الموجّهة لهذا الجهاز")
async def pull(body: _Body, org_id: str = Depends(get_current_org_id),
               user_id: UUID = Depends(get_current_user_uuid),
               db: AsyncSession = Depends(get_db)):
    try:
        data = await relay.pull(await _ready(db), org=UUID(org_id),
                                user=user_id, replica_id=body.replica_id)
    except relay.RelayAccessDenied as exc:
        raise _denied(exc) from exc
    await db.commit()
    return ok(data)


@router.post("/ack", summary="إقرار الحفظ المحلي")
async def ack(body: AckBody, org_id: str = Depends(get_current_org_id),
              user_id: UUID = Depends(get_current_user_uuid),
              db: AsyncSession = Depends(get_db)):
    try:
        purged = await relay.ack(await _ready(db), org=UUID(org_id),
                                 user=user_id, replica_id=body.replica_id,
                                 op_ids=body.ids)
    except relay.RelayAccessDenied as exc:
        raise _denied(exc) from exc
    await db.commit()
    return ok({"purged": purged})


@router.post("/snapshot/request", summary="طلب نسخة كاملة من جهاز آخر")
async def snapshot_request(body: _Body, org_id: str = Depends(get_current_org_id),
                           user_id: UUID = Depends(get_current_user_uuid),
                           db: AsyncSession = Depends(get_db)):
    try:
        data = await relay.request_snapshot(await _ready(db), org=UUID(org_id),
                                            user=user_id,
                                            replica_id=body.replica_id)
    except relay.RelayAccessDenied as exc:
        raise _denied(exc) from exc
    await db.commit()
    return ok(data)


@router.post("/snapshot/serve", summary="تسليم نسخة كاملة لجهاز ينتظرها")
async def snapshot_serve(body: SnapshotBody,
                         org_id: str = Depends(get_current_org_id),
                         user_id: UUID = Depends(get_current_user_uuid),
                         db: AsyncSession = Depends(get_db)):
    try:
        sent = await relay.serve_snapshot(
            await _ready(db), org=UUID(org_id), user=user_id,
            replica_id=body.replica_id, target=body.target,
            payload=body.payload)
    except relay.RelayAccessDenied as exc:
        raise _denied(exc) from exc
    except relay.RelayInvalid as exc:
        raise HTTPException(422, "حمولة غير صالحة") from exc
    await db.commit()
    return ok({"sent": sent})


@router.post("/snapshot/applied", summary="اكتمل استلام النسخة الكاملة")
async def snapshot_applied(body: _Body, org_id: str = Depends(get_current_org_id),
                           user_id: UUID = Depends(get_current_user_uuid),
                           db: AsyncSession = Depends(get_db)):
    try:
        await relay.snapshot_applied(await _ready(db), org=UUID(org_id),
                                     user=user_id, replica_id=body.replica_id)
    except relay.RelayAccessDenied as exc:
        raise _denied(exc) from exc
    await db.commit()
    return ok({})
