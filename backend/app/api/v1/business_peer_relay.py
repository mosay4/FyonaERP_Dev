"""Peer relay endpoints (merchant ↔ linked customer/supplier).

See app.domain.services.business_peer_relay.
"""

from typing import Any, Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user_uuid
from app.core.database import get_db
from app.domain.services import business_peer_relay as peer

router = APIRouter()
_installed = False


def ok(data):
    return {"success": True, "message": "تم", "data": data}


class _Device(BaseModel):
    model_config = ConfigDict(extra="forbid")
    device_id: UUID


class Notify(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str = Field(max_length=300)
    message: str = Field(max_length=1000)
    route: str = Field(max_length=200)
    event_id: str = Field(max_length=200)


class PushBody(_Device):
    id: UUID
    link_id: UUID
    kind: str = Field(pattern=r"^(debt_snapshot|chat|chat_receipt)$")
    payload: Any
    # The same notification texts the app already uses; sent only once.
    notify: Optional[Notify] = None


class SelfPushBody(_Device):
    id: UUID
    kind: str = Field(pattern=r"^(account_types|account_types_request)$")
    payload: dict


class AckBody(_Device):
    ids: list[UUID] = Field(min_length=1, max_length=200)


async def _conn(db: AsyncSession):
    global _installed
    conn = await db.connection()
    if not _installed:
        await peer.install(conn)
        _installed = True
    return conn


@router.post("/register", summary="تسجيل الجهاز لاستلام عمليات الأطراف المرتبطة")
async def register(body: _Device, user_id: UUID = Depends(get_current_user_uuid),
                   db: AsyncSession = Depends(get_db)):
    try:
        await peer.register(await _conn(db), user=user_id, device=body.device_id)
    except peer.PeerDenied as exc:
        raise HTTPException(403, "غير مصرح") from exc
    await db.commit()
    return ok({})


@router.post("/push", summary="تسليم عملية لطرف مرتبط")
async def push(body: PushBody, user_id: UUID = Depends(get_current_user_uuid),
               db: AsyncSession = Depends(get_db)):
    try:
        result = await peer.push(await _conn(db), user=user_id, device=body.device_id,
                                 link_id=body.link_id, kind=body.kind,
                                 op_id=body.id, payload=body.payload)
    except peer.PeerDenied as exc:
        raise HTTPException(403, "غير مصرح") from exc
    except ValueError as exc:
        raise HTTPException(422, "حمولة غير صالحة") from exc
    created = []
    if body.notify is not None and not result["duplicate"]:
        from app.domain.services import debt_notification_service as dn
        created = await dn.emit(
            db, result["link"]["merchant_org_id"], body.notify.event_id,
            [UUID(r) for r in result["recipients"]],
            title=body.notify.title, message=body.notify.message,
            route=body.notify.route,
        )
    await db.commit()
    if created:
        from app.domain.services import debt_notification_service as dn
        await dn.push_event(
            db, result["link"]["merchant_org_id"], body.notify.event_id,
            [UUID(r) for r in result["recipients"]],
            title=body.notify.title, message=body.notify.message,
            route=body.notify.route,
        )
    return ok({"id": result["id"]})


@router.post("/pull", summary="العمليات الموجّهة لهذا الجهاز")
async def pull(body: _Device, user_id: UUID = Depends(get_current_user_uuid),
               db: AsyncSession = Depends(get_db)):
    try:
        items = await peer.pull(await _conn(db), user=user_id, device=body.device_id)
    except peer.PeerDenied as exc:
        raise HTTPException(403, "غير مصرح") from exc
    await db.commit()
    return ok({"items": items})


@router.post("/ack", summary="إقرار الحفظ على الجهاز")
async def ack(body: AckBody, user_id: UUID = Depends(get_current_user_uuid),
              db: AsyncSession = Depends(get_db)):
    try:
        gone = await peer.ack(await _conn(db), user=user_id, device=body.device_id,
                              ids=body.ids)
    except peer.PeerDenied as exc:
        raise HTTPException(403, "غير مصرح") from exc
    await db.commit()
    return ok({"deleted": gone})


@router.post("/self-push", summary="تسليم حالة صغيرة لأجهزة المستخدم الأخرى (تُحذف بعد الاستلام)")
async def self_push(body: SelfPushBody, user_id: UUID = Depends(get_current_user_uuid),
                    db: AsyncSession = Depends(get_db)):
    try:
        result = await peer.push_self(await _conn(db), user=user_id, device=body.device_id,
                                      kind=body.kind, op_id=body.id, payload=body.payload)
    except peer.PeerDenied as exc:
        raise HTTPException(403, "غير مصرح") from exc
    except ValueError as exc:
        raise HTTPException(422, "حمولة غير صالحة") from exc
    await db.commit()
    return ok({"id": result["id"], "destinations": result["destinations"]})
