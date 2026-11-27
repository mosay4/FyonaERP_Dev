"""Chat endpoints (merchant ↔ linked customer/supplier).

Authorization is per `MerchantLink`: only the link's personal user
(`external_user_id`) and the merchant user who invited them (`invited_by`) can
read/write. Conversations are fully isolated per link.
"""

import uuid as _uuid
from typing import List, Optional
from uuid import UUID

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, Query, Request, BackgroundTasks
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from ...api.deps import get_current_user_uuid
from ...api.responses import ok
from ...core.database import get_db
from ...domain.services import chat_service as svc

router = APIRouter(tags=["Chat"])


class ConversationPresence(BaseModel):
    side: Optional[str] = None
    conversation_id: Optional[UUID] = None
    active: bool = True


# IMPORTANT: declared BEFORE /chat/{link_id} so it is not captured as a link id.
@router.post("/chat/presence", summary="نبضة حضور (داخل التطبيق)")
async def presence_beat(
    data: Optional[ConversationPresence] = None,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        await svc.touch_presence(db, user_id)
        if data and data.conversation_id:
            await svc.set_active_conversation(
                db, user_id, data.conversation_id, active=data.active, side=data.side)
    except ValueError as e:
        raise HTTPException(status_code=403, detail=str(e))
    await db.commit()
    return ok({"online": True})


class MediaItem(BaseModel):
    url: str
    kind: str
    file_name: Optional[str] = None


class SendMessage(BaseModel):
    kind: str = "text"
    side: Optional[str] = None  # merchant | personal
    text: Optional[str] = None
    media_path: Optional[str] = None
    media: Optional[List[MediaItem]] = None
    duration_ms: Optional[int] = None
    file_name: Optional[str] = None
    invoice_id: Optional[UUID] = None
    reply_to_id: Optional[UUID] = None
    client_id: Optional[str] = Field(default=None, max_length=80)
    client_message_id: Optional[str] = Field(default=None, max_length=80)
    idempotency_key: Optional[str] = Field(default=None, max_length=80)


class EditMessage(BaseModel):
    text: Optional[str] = None


@router.get("/chat/{link_id}", summary="بيانات المحادثة")
async def conversation(
    link_id: UUID,
    side: Optional[str] = None,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        data = await svc.conversation_info(db, user_id, link_id, side)
        await db.commit()
        return ok(data)
    except ValueError as e:
        raise HTTPException(status_code=403, detail=str(e))


@router.get("/chat/{link_id}/messages", summary="رسائل المحادثة")
async def messages(
    link_id: UUID,
    after: Optional[UUID] = None,
    before: Optional[UUID] = None,
    around: Optional[UUID] = None,
    limit: int = Query(default=40, ge=1, le=100),
    side: Optional[str] = None,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        data = await svc.list_messages(
            db, user_id, link_id, side=side, after_id=after,
            before_id=before, around_id=around, limit=limit)
        await db.commit()
        return ok(data)
    except ValueError as e:
        raise HTTPException(status_code=403, detail=str(e))


@router.post("/chat/{link_id}/messages", summary="إرسال رسالة")
async def send(
    link_id: UUID,
    data: SendMessage,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    background_tasks: BackgroundTasks = None,
):
    try:
        res = await svc.send_message(
            db, user_id, link_id, side=data.side, kind=data.kind,
            text=data.text, media_path=data.media_path,
            file_name=data.file_name,
            media=([m.model_dump() for m in data.media]
                   if data.media else None),
            duration_ms=data.duration_ms,
            invoice_id=data.invoice_id, reply_to_id=data.reply_to_id,
            client_id=data.client_id, client_message_id=data.client_message_id,
            idempotency_key=data.idempotency_key)
        push = None
        # notify_new_message suppresses both outbox and push for a fresh,
        # authorized active-conversation heartbeat. Duplicates never notify.
        if not res.get("duplicate"):
            caption = (data.text or "").strip()
            if len(caption) > 80:
                caption = caption[:80] + "…"
            if data.kind == "text":
                preview = caption
            elif data.kind == "image":
                preview = ("📷 " + caption) if caption else "📷 صورة"
            elif data.kind == "video":
                preview = ("🎬 " + caption) if caption else "🎬 فيديو"
            elif data.kind == "voice":
                preview = "🎙 رسالة صوتية"
            elif data.kind == "file":
                preview = "📎 " + (data.file_name or "ملف")
            elif data.kind == "album":
                preview = f"📷 {len(data.media or [])} صور/فيديو"
            elif data.kind == "invoice":
                preview = "🧾 فاتورة " + (
                    res.get("message", {}).get("invoice_number") or "")
            else:
                preview = caption or "رسالة"
            push = await svc.notify_new_message(
                db, org_id=UUID(res["merchant_org_id"]),
                message_id=UUID(res["message"]["id"]),
                recipient_user_id=UUID(res["recipient_user_id"]),
                is_personal_recipient=res["is_personal_recipient"],
                sender_name=res.get("sender_name", ""),
                sender_user_id=user_id,
                preview=preview, link_id=link_id)
        await db.commit()
        if not res.get('duplicate'):
            from ...domain.services.chat_live_service import chat_live_hub
            await chat_live_hub.publish(link_id)
        if push:
            args = (UUID(res['merchant_org_id']), link_id, UUID(res['recipient_user_id']), res['is_personal_recipient'], push)
            if background_tasks is not None:
                background_tasks.add_task(svc.deliver_chat_push_detached, *args)
            else:
                await svc.deliver_chat_push(db, *args)
        return ok(res)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.get('/chat/{link_id}/updates', summary='Wait briefly for new authorized messages')
async def live_messages(link_id: UUID, request: Request, after: Optional[UUID] = None,
                        side: Optional[str] = None, limit: int = Query(40, ge=1, le=100),
                        user_id: UUID = Depends(get_current_user_uuid), db: AsyncSession = Depends(get_db)):
    from ...domain.services.chat_live_service import wait_messages
    try:
        result = await wait_messages(db, user_id, link_id, side=side, after_id=after, limit=limit)
        supplied = request.headers.get('Authorization', '')
        if not supplied.startswith('Bearer '): raise HTTPException(401, detail='Not authenticated')
        await get_current_user_uuid(credentials=HTTPAuthorizationCredentials(scheme='Bearer', credentials=supplied[7:]),
                                    request=request, db=db)
        await db.commit()
        return ok(result)
    except ValueError as exc:
        raise HTTPException(403, detail=str(exc))


@router.patch("/chat/{link_id}/messages/{message_id}",
             summary="تعديل رسالة (خلال 30 دقيقة)")
async def edit_message(
    link_id: UUID,
    message_id: UUID,
    data: EditMessage,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        res = await svc.edit_message(
            db, user_id, link_id, message_id, data.text or "")
        await db.commit()
        return ok(res)
    except ValueError as e:
        raise HTTPException(status_code=403, detail=str(e))


@router.delete("/chat/{link_id}/messages/{message_id}",
               summary="حذف رسالة لدى الجميع (خلال 30 دقيقة)")
async def delete_message(
    link_id: UUID,
    message_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        res = await svc.delete_message(db, user_id, link_id, message_id)
        await db.commit()
        return ok(res)
    except ValueError as e:
        raise HTTPException(status_code=403, detail=str(e))


@router.post("/chat/{link_id}/read", summary="تعليم الرسائل كمقروءة")
async def read(
    link_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        data = await svc.mark_read(db, user_id, link_id)
        await db.commit()
        return ok(data)
    except ValueError as e:
        raise HTTPException(status_code=403, detail=str(e))


@router.get("/chat/{link_id}/invoices", summary="فواتير الطرفين لتبادلها")
async def chat_invoices(
    link_id: UUID,
    q: Optional[str] = None,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        return ok(await svc.list_invoices_for_chat(db, user_id, link_id, q))
    except ValueError as e:
        raise HTTPException(status_code=403, detail=str(e))


@router.post("/chat/{link_id}/media", summary="رفع صورة/تسجيل صوتي (قديم)")
async def upload_media(
    link_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
):
    """Retired: the server no longer stores chat files. The app encrypts an
    attachment on the device and sends it to the chat's private Cloudflare
    R2 space through /storage/upload-url (section "chat"); the message then
    carries its ``fyc:`` reference."""
    raise HTTPException(status_code=410, detail={
        "code": "chat_media_moved",
        "message": "حدّث التطبيق لإرسال المرفقات",
    })
