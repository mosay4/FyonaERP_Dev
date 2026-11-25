"""Personal relay endpoints: carry one user's device operations, keep nothing.

See app.domain.services.personal_relay for the contract.
"""

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_session_id, get_current_user_uuid
from app.core.database import get_db
from app.domain.services import personal_relay as relay

router = APIRouter()


def ok(data):
    return {"success": True, "message": "تم", "data": data}


class _Body(BaseModel):
    model_config = ConfigDict(extra="forbid")
    replica_id: UUID


class PushItem(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: UUID
    kind: str = Field(default="ops", pattern=r"^ops$")
    payload: Any


class PushBody(_Body):
    items: list[PushItem] = Field(min_length=1, max_length=relay.MAX_BATCH)


class AckBody(_Body):
    ids: list[UUID] = Field(min_length=1, max_length=relay.MAX_BATCH)


class PullBody(_Body):
    # Long poll: hold the request up to this many seconds until something
    # arrives, so another device's change shows up within a second or two.
    wait: int = Field(default=0, ge=0, le=25)
    limit: int = Field(default=relay.MAX_BATCH, ge=1, le=relay.MAX_BATCH)


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


def _denied() -> HTTPException:
    return HTTPException(403, "غير مصرح")


def _invalid() -> HTTPException:
    return HTTPException(422, "حمولة غير صالحة")


@router.post("/register", summary="ربط قاعدة البيانات الشخصية للجهاز بالحساب")
async def register(body: _Body, user_id: UUID = Depends(get_current_user_uuid),
                   session_id: UUID | None = Depends(get_current_session_id),
                   db: AsyncSession = Depends(get_db)):
    try:
        data = await relay.register(await _ready(db), user=user_id,
                                    session=session_id,
                                    replica_id=body.replica_id)
    except relay.RelayAccessDenied as exc:
        raise _denied() from exc
    await db.commit()
    return ok(data)


@router.post("/push", summary="تسليم عمليات الجهاز إلى محطة العبور")
async def push(body: PushBody, user_id: UUID = Depends(get_current_user_uuid),
               db: AsyncSession = Depends(get_db)):
    try:
        data = await relay.push(
            await _ready(db), user=user_id, replica_id=body.replica_id,
            items=[item.model_dump() for item in body.items],
        )
    except relay.RelayAccessDenied as exc:
        raise _denied() from exc
    except relay.RelayInvalid as exc:
        raise _invalid() from exc
    await db.commit()
    return ok({"items": data})


@router.post("/pull", summary="العمليات الموجّهة لهذا الجهاز")
async def pull(body: PullBody, user_id: UUID = Depends(get_current_user_uuid),
               db: AsyncSession = Depends(get_db)):
    import asyncio

    deadline = asyncio.get_running_loop().time() + body.wait
    while True:
        try:
            data = await relay.pull(await _ready(db), user=user_id,
                                    replica_id=body.replica_id,
                                    limit=body.limit)
        except relay.RelayAccessDenied as exc:
            raise _denied() from exc
        await db.commit()
        if (data["items"] or data["resync_required"]
                or asyncio.get_running_loop().time() >= deadline):
            return ok(data)
        await asyncio.sleep(1)


@router.post("/ack", summary="إقرار الحفظ المحلي")
async def ack(body: AckBody, user_id: UUID = Depends(get_current_user_uuid),
              db: AsyncSession = Depends(get_db)):
    try:
        purged = await relay.ack(await _ready(db), user=user_id,
                                 replica_id=body.replica_id, op_ids=body.ids)
    except relay.RelayAccessDenied as exc:
        raise _denied() from exc
    await db.commit()
    return ok({"purged": purged})


@router.post("/snapshot/request", summary="طلب نسخة كاملة من جهاز آخر")
async def snapshot_request(body: _Body,
                           user_id: UUID = Depends(get_current_user_uuid),
                           db: AsyncSession = Depends(get_db)):
    try:
        data = await relay.request_snapshot(await _ready(db), user=user_id,
                                            replica_id=body.replica_id)
    except relay.RelayAccessDenied as exc:
        raise _denied() from exc
    await db.commit()
    return ok(data)


@router.post("/snapshot/serve", summary="تسليم نسخة كاملة لجهاز ينتظرها")
async def snapshot_serve(body: SnapshotBody,
                         user_id: UUID = Depends(get_current_user_uuid),
                         db: AsyncSession = Depends(get_db)):
    try:
        sent = await relay.serve_snapshot(
            await _ready(db), user=user_id, replica_id=body.replica_id,
            target=body.target, payload=body.payload)
    except relay.RelayAccessDenied as exc:
        raise _denied() from exc
    except relay.RelayInvalid as exc:
        raise _invalid() from exc
    await db.commit()
    return ok({"sent": sent})


@router.post("/snapshot/applied", summary="اكتمل استلام النسخة الكاملة")
async def snapshot_applied(body: _Body,
                           user_id: UUID = Depends(get_current_user_uuid),
                           db: AsyncSession = Depends(get_db)):
    try:
        await relay.snapshot_applied(await _ready(db), user=user_id,
                                     replica_id=body.replica_id)
    except relay.RelayAccessDenied as exc:
        raise _denied() from exc
    await db.commit()
    return ok({})


@router.post("/retire", summary="إيقاف هذا الجهاز عن استلام العمليات")
async def retire(body: _Body, user_id: UUID = Depends(get_current_user_uuid),
                 db: AsyncSession = Depends(get_db)):
    try:
        await relay.retire(await _ready(db), user=user_id,
                           replica_id=body.replica_id)
    except relay.RelayAccessDenied as exc:
        raise _denied() from exc
    await db.commit()
    return ok({})


@router.get("/replicas", summary="أجهزتي المرتبطة بمحطة العبور الشخصية")
async def replicas(user_id: UUID = Depends(get_current_user_uuid),
                   db: AsyncSession = Depends(get_db)):
    data = await relay.my_replicas(await _ready(db), user=user_id)
    await db.commit()
    return ok({"items": data})
