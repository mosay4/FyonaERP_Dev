"""Chat service — one isolated conversation per accepted MerchantLink.

Direction is determined by the SIDE the caller is using ('merchant' or
'personal'), never by the user id alone: the same account can be both sides
(e.g. testing with one account), and a message sent from Personal must appear
on the right in Personal and on the left in Business.
"""

from datetime import datetime, timedelta, timezone
import json
import re
from typing import Any, Dict, List, Optional
from uuid import UUID

from sqlalchemy import func, select, update, tuple_
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.business_entities import Customer, Supplier
from app.domain.entities.chat_entities import ChatMessage, ChatPresence
from app.domain.entities.invoice_entities import Invoice
from app.domain.entities.merchant_entities import MerchantLink
from app.core.redis import cache_get, cache_set, get_redis, _REDIS_ERRORS

ONLINE_WINDOW = timedelta(seconds=45)
EDIT_WINDOW = timedelta(minutes=30)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _aware(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is None:
        return None
    return dt if dt.tzinfo is not None else dt.replace(tzinfo=timezone.utc)


async def _link_for_participant(
    db: AsyncSession, user_id: UUID, link_id: UUID
) -> MerchantLink:
    link = (
        await db.execute(select(MerchantLink).where(MerchantLink.id == link_id).execution_options(populate_existing=True))
    ).scalar_one_or_none()
    if link is None or link.status != "accepted":
        raise ValueError("المحادثة غير متاحة — الحساب غير مرتبط")
    if user_id not in (link.external_user_id, link.invited_by):
        raise ValueError("غير مصرح بهذه المحادثة")
    return link


def _require_side(link: MerchantLink, user_id: UUID, side: Optional[str]) -> str:
    if side not in ("merchant", "personal"):
        raise ValueError("جهة المحادثة غير محددة")
    if side == "merchant" and user_id != link.invited_by:
        raise ValueError("غير مصرح بهذه الجهة")
    if side == "personal" and user_id != link.external_user_id:
        raise ValueError("غير مصرح بهذه الجهة")
    return side


async def _touch(db: AsyncSession, user_id: UUID) -> None:
    row = (
        await db.execute(
            select(ChatPresence).where(ChatPresence.user_id == user_id)
        )
    ).scalar_one_or_none()
    if row is None:
        db.add(ChatPresence(user_id=user_id, last_seen_at=_now()))
    else:
        row.last_seen_at = _now()
    await db.flush()


async def touch_presence(db: AsyncSession, user_id: UUID) -> None:
    """App-wide heartbeat: while the app is open the user is «online»."""
    await _touch(db, user_id)


def _active_key(org_id: UUID, user_id: UUID) -> str:
    return f"chat:active:{org_id}:{user_id}"


async def set_active_conversation(
    db: AsyncSession, user_id: UUID, link_id: UUID, *, active: bool = True, side: Optional[str] = None,
) -> None:
    link = await _link_for_participant(db, user_id, link_id)
    key = _active_key(link.merchant_org_id, user_id)
    if side is not None: _require_side(link, user_id, side)
    if active:
        await cache_set(key, json.dumps({"conversation_id": str(link.id),
                                        "seen_at": _now().timestamp(), 'side': side}), expire=30)
    else:
        # A late leave from another conversation must not clear the new one.
        try:
            redis = await get_redis()
            await redis.eval(
                "local raw = redis.call('get', KEYS[1]); "
                "if not raw then return 0 end; "
                "local ok, value = pcall(cjson.decode, raw); "
                "if ok and type(value) == 'table' and "
                "value.conversation_id == ARGV[1] then "
                "return redis.call('del', KEYS[1]) else return 0 end",
                1, key, str(link.id))
        except _REDIS_ERRORS:
            pass  # TTL is the backstop; Redis failure defaults to notifying.


async def _online(db: AsyncSession, user_id: Optional[UUID]) -> bool:
    if not user_id:
        return False
    seen = (
        await db.execute(
            select(ChatPresence.last_seen_at).where(
                ChatPresence.user_id == user_id)
        )
    ).scalar_one_or_none()
    seen = _aware(seen)
    if seen is None:
        return False
    return _now() - seen <= ONLINE_WINDOW


async def _shop(db: AsyncSession, org_id: UUID) -> Dict[str, Any]:
    org = (
        await db.execute(
            select(Organization).where(Organization.id == org_id)
        )
    ).scalar_one_or_none()
    name = org.name if org else None
    owner = (
        await db.execute(
            select(User).where(
                User.organization_id == org_id, User.role == "owner").limit(1)
        )
    ).scalar_one_or_none()
    clean = (name or "").strip()
    clean = re.sub(r"\s*'s\s+organization\s*$", "", clean, flags=re.I).strip()
    if not clean or clean.lower() == "organization":
        clean = ((owner.full_name if owner else None) or "").strip() or "متجر"
    # Business identity: the BUSINESS (org) picture wins, then the owner's.
    return {"name": clean,
            "avatar": (org.avatar if org and org.avatar else
                       (owner.avatar if owner else None))}


async def _party_name(db: AsyncSession, link) -> str:
    """The merchant's OWN name for the party (never the personal real name)."""
    try:
        if link.party_kind == "customer":
            q = select(Customer.name).where(Customer.id == link.party_id)
        else:
            q = select(Supplier.name).where(Supplier.id == link.party_id)
        return ((await db.execute(q)).scalar_one_or_none() or "").strip()
    except Exception:
        return ""


async def _user(db: AsyncSession, user_id: Optional[UUID]) -> Dict[str, Any]:
    if not user_id:
        return {"name": "", "avatar": None}
    u = (
        await db.execute(select(User).where(User.id == user_id))
    ).scalar_one_or_none()
    return {"name": u.full_name if u else "",
            "avatar": u.avatar if u else None}


async def conversation_info(
    db: AsyncSession, user_id: UUID, link_id: UUID,
    side: Optional[str] = None,
) -> Dict[str, Any]:
    link = await _link_for_participant(db, user_id, link_id)
    if side is None:
        # Backward-compatible inference (only when the account is one side).
        if user_id == link.invited_by and user_id != link.external_user_id:
            side = "merchant"
        else:
            side = "personal"
    side = _require_side(link, user_id, side)
    await _touch(db, user_id)
    is_merchant = side == "merchant"
    other_id = link.external_user_id if is_merchant else link.invited_by
    if is_merchant:
        other = await _user(db, other_id)
        # Merchant's chat: the party name they chose + the REAL user avatar.
        other_name = (await _party_name(db, link)) or link.display_name or other["name"]
        other_avatar = other["avatar"]
    else:
        shop = await _shop(db, link.merchant_org_id)
        other_name = shop["name"]
        other_avatar = shop["avatar"]
    unread = (
        await db.execute(
            select(func.count()).select_from(ChatMessage).where(
                ChatMessage.link_id == link.id,
                ChatMessage.recipient_user_id == user_id,
                ChatMessage.read_at.is_(None),
                ChatMessage.deleted_at.is_(None),
            )
        )
    ).scalar_one()
    return {
        "link_id": str(link.id),
        "side": side,
        "is_merchant": is_merchant,
        "other_name": other_name,
        "other_avatar": other_avatar,
        "online": await _online(db, other_id),
        "unread": int(unread or 0),
        "party_kind": link.party_kind,
        "edit_window_minutes": int(EDIT_WINDOW.total_seconds() // 60),
    }


def _media_count(m: ChatMessage) -> int:
    if not m.media:
        return 0
    try:
        parsed = json.loads(m.media)
        return len(parsed) if isinstance(parsed, list) else 0
    except Exception:
        return 0


def _reply_summary(m: ChatMessage, side: str, numbers: Dict[str, str]) -> Dict[str, Any]:
    return {
        "id": str(m.id),
        "mine": m.sender_side == side,
        "kind": m.kind,
        "text": m.text,
        "file_name": m.file_name,
        "duration_ms": m.duration_ms,
        "media_count": _media_count(m),
        "invoice_number": ((numbers.get(str(m.invoice_id)) or m.file_name)
                           if m.invoice_id else None),
        "deleted": m.deleted_at is not None,
    }


def _msg_dict(m: ChatMessage, side: str, numbers: Dict[str, str],
              replies: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    mine = (m.sender_side == side)
    base = {
        "id": str(m.id),
        "mine": mine,
        "client_id": m.client_id,
        "client_message_id": m.client_id,
        "idempotency_key": m.client_id,
        "kind": m.kind,
        "edited": m.edited_at is not None,
        "deleted": m.deleted_at is not None,
        "delivered": m.delivered_at is not None,
        "read": m.read_at is not None,
        "created_at": m.created_at.isoformat() if m.created_at else None,
        "edited_at": m.edited_at.isoformat() if m.edited_at else None,
        "reply": (replies or {}).get(str(m.reply_to_id))
        if m.reply_to_id else None,
    }
    if m.deleted_at is not None:
        base.update({"text": None, "media_url": None,
                     "media": [], "media_count": 0,
                     "invoice_id": None, "invoice_number": None})
        return base
    media_list = []
    if m.media:
        try:
            parsed = json.loads(m.media)
            if isinstance(parsed, list):
                media_list = parsed
        except Exception:
            media_list = []
    base.update({
        "text": m.text,
        "media_url": m.media_path,
        "media": media_list,
        "media_count": len(media_list),
        "file_name": m.file_name,
        "duration_ms": m.duration_ms,
        "invoice_id": str(m.invoice_id) if m.invoice_id else None,
        "invoice_number": ((numbers.get(str(m.invoice_id)) or m.file_name)
                           if m.invoice_id else None),
    })
    return base


async def _numbers(db: AsyncSession, msgs: List[ChatMessage]) -> Dict[str, str]:
    ids = [m.invoice_id for m in msgs if m.invoice_id]
    if not ids:
        return {}
    rows = (
        await db.execute(
            select(Invoice.id, Invoice.invoice_number).where(Invoice.id.in_(ids))
        )
    ).all()
    return {str(i): n for i, n in rows}


async def list_messages(
    db: AsyncSession, user_id: UUID, link_id: UUID,
    side: Optional[str] = None, after_id: Optional[UUID] = None,
    limit: int = 40, before_id: Optional[UUID] = None,
    around_id: Optional[UUID] = None,
) -> Dict[str, Any]:
    link = await _link_for_participant(db, user_id, link_id)
    if side is None:
        side = ("merchant" if user_id == link.invited_by
                and user_id != link.external_user_id else "personal")
    side = _require_side(link, user_id, side)
    await _touch(db, user_id)
    limit = max(1, min(limit, 100))
    if sum(value is not None for value in (after_id, before_id, around_id)) > 1:
        raise ValueError("استخدم مؤشرًا واحدًا فقط")
    stmt = select(ChatMessage).where(ChatMessage.link_id == link.id)
    cursor = after_id or before_id or around_id
    if cursor is not None:
        anchor = (
            await db.execute(
                select(ChatMessage.created_at, ChatMessage.id).where(
                    ChatMessage.id == cursor, ChatMessage.link_id == link.id)
            )
        ).one_or_none()
        if anchor is None:
            raise ValueError("مؤشر الرسائل غير صالح")
        position = tuple_(ChatMessage.created_at, ChatMessage.id)
        stmt = stmt.where(position > tuple_(*anchor) if after_id else (
            position <= tuple_(*anchor) if around_id else position < tuple_(*anchor)))
    order = (ChatMessage.created_at.asc(), ChatMessage.id.asc()) if after_id else (
        ChatMessage.created_at.desc(), ChatMessage.id.desc())
    rows = (
        await db.execute(
            stmt.order_by(*order).limit(limit + 1)
        )
    ).scalars().all()
    has_more = len(rows) > limit
    rows = list(rows[:limit])
    if not after_id:
        rows.reverse()
    await db.execute(
        update(ChatMessage).where(
            ChatMessage.link_id == link.id,
            ChatMessage.id.in_([m.id for m in rows]),
            ChatMessage.recipient_user_id == user_id,
            ChatMessage.delivered_at.is_(None),
            ChatMessage.deleted_at.is_(None),
        ).values(delivered_at=_now())
    )
    numbers = await _numbers(db, rows)
    reply_ids = [m.reply_to_id for m in rows if m.reply_to_id]
    replies: Dict[str, Any] = {}
    if reply_ids:
        rrows = (
            await db.execute(
                select(ChatMessage).where(ChatMessage.id.in_(reply_ids),
                                          ChatMessage.link_id == link.id)
            )
        ).scalars().all()
        rnumbers = await _numbers(db, rrows)
        for rm in rrows:
            replies[str(rm.id)] = _reply_summary(rm, side, rnumbers)
    await db.flush()
    result = {"messages": [
        _msg_dict(m, side, numbers, replies) for m in rows],
        "has_more": has_more}
    await purge_delivered(db, link.id)
    return result


_CLOUD_DROPS: set = set()  # keeps the background deletions alive
_CLOUD_REF = re.compile(r"^fyc:([0-9a-f-]{36})/([0-9a-f]{64})")


def cloud_media_keys(link_id: UUID, media_path: Optional[str], media: Optional[str]) -> List[str]:
    """R2 keys of the encrypted attachments a message refers to (``fyc:``
    references of THIS chat only; anything else is ignored)."""
    refs: List[str] = [media_path or ""]
    try:
        for it in json.loads(media or "[]") or []:
            if isinstance(it, dict):
                refs += [str(it.get("url") or ""), str(it.get("thumbnail") or "")]
    except (ValueError, TypeError):
        pass
    keys = []
    for ref in refs:
        m = _CLOUD_REF.match(ref.strip())
        if m and UUID(m.group(1)) == link_id:
            keys.append(f"t/c_{link_id.hex}/m/{m.group(2)}")
    return keys


async def _drop_cloud_media(keys: List[str]) -> None:
    """Best effort: an attachment leaves Cloudflare with its message."""
    from app.core import r2
    try:
        cfg = r2.R2Config.from_env()
    except Exception:  # noqa: BLE001 — storage not configured (tests/dev)
        return
    for key in keys:
        try:
            await r2.delete(cfg, key)
        except Exception:  # noqa: BLE001 — retried by no one; logged by r2
            pass


async def purge_delivered(db: AsyncSession, link_id: UUID) -> None:
    """Both devices keep the conversation. The server forgets a message once
    it was read (after a short grace so the sender's device sees the read
    tick), and anything never delivered after 90 days. Its encrypted
    attachments are removed from Cloudflare R2 at the same time."""
    import asyncio
    from datetime import timedelta
    from sqlalchemy import delete, or_
    now = _now()
    gone = or_(ChatMessage.read_at < now - timedelta(minutes=10),
               ChatMessage.created_at < now - timedelta(days=90))
    rows = (await db.execute(select(ChatMessage.media_path, ChatMessage.media).where(
        ChatMessage.link_id == link_id, gone))).all()
    keys = [k for path, media in rows for k in cloud_media_keys(link_id, path, media)]
    await db.execute(delete(ChatMessage).where(ChatMessage.link_id == link_id, gone))
    if keys:
        task = asyncio.get_running_loop().create_task(_drop_cloud_media(keys))
        _CLOUD_DROPS.add(task)
        task.add_done_callback(_CLOUD_DROPS.discard)


async def mark_read(
    db: AsyncSession, user_id: UUID, link_id: UUID
) -> Dict[str, Any]:
    link = await _link_for_participant(db, user_id, link_id)
    await _touch(db, user_id)
    now = _now()
    res = await db.execute(
        update(ChatMessage).where(
            ChatMessage.link_id == link.id,
            ChatMessage.recipient_user_id == user_id,
            ChatMessage.read_at.is_(None),
            ChatMessage.deleted_at.is_(None),
        ).values(read_at=now, delivered_at=func.coalesce(
            ChatMessage.delivered_at, now))
    )
    await db.flush()
    try:
        from app.domain.services import debt_notification_service as dn
        await dn.mark_chat_read(db, user_id, link.id)
    except Exception:  # noqa: BLE001 — read receipts must never fail
        pass
    return {"read": int(res.rowcount or 0)}


async def _invoice_for_link(
    db: AsyncSession, link: MerchantLink, invoice_id: UUID
) -> Invoice:
    col = (Invoice.customer_id if link.party_kind == "customer"
           else Invoice.supplier_id)
    inv = (
        await db.execute(
            select(Invoice).where(
                Invoice.id == invoice_id,
                Invoice.organization_id == link.merchant_org_id,
                col == link.party_id,
                Invoice.is_deleted.is_(False),
            )
        )
    ).scalar_one_or_none()
    if inv is None:
        raise ValueError("الفاتورة غير مرتبطة بهذه المحادثة")
    return inv


async def send_message(
    db: AsyncSession, user_id: UUID, link_id: UUID,
    *, side: Optional[str], kind: str, text: Optional[str] = None,
    media_path: Optional[str] = None, file_name: Optional[str] = None,
    media: Optional[List[Dict[str, Any]]] = None,
    duration_ms: Optional[int] = None,
    invoice_id: Optional[UUID] = None,
    reply_to_id: Optional[UUID] = None,
    client_id: Optional[str] = None,
    client_message_id: Optional[str] = None,
    idempotency_key: Optional[str] = None,
) -> Dict[str, Any]:
    keys = {key for key in (client_id, client_message_id, idempotency_key) if key}
    if len(keys) > 1:
        raise ValueError("Conflicting client message identifiers")
    client_id = client_message_id or client_id or idempotency_key or None
    link = await _link_for_participant(db, user_id, link_id)
    side = _require_side(link, user_id, side)
    kind = (kind or "text").strip().lower()
    if kind not in ("text", "image", "video", "voice", "invoice", "file",
                    "album"):
        raise ValueError("نوع الرسالة غير مدعوم")
    if kind == "text" and not (text or "").strip():
        raise ValueError("اكتب رسالة")
    if kind == "album" and not media:
        raise ValueError("لا توجد وسائط")
    if kind in ("image", "video", "voice", "file") and not media_path:
        raise ValueError("الملف غير موجود")
    if client_id:
        existing = (
            await db.execute(
                select(ChatMessage).where(
                    ChatMessage.sender_user_id == user_id,
                    ChatMessage.client_id == client_id,
                )
            )
        ).scalar_one_or_none()
        if existing is not None:
            if existing.link_id != link.id or existing.sender_side != side:
                raise ValueError("معرف الرسالة مستخدم في محادثة أخرى")
            return {"message": _msg_dict(existing, side, await _numbers(db, [existing])),
                    "duplicate": True}
    reply_msg = None
    if reply_to_id is not None:
        reply_msg = (
            await db.execute(
                select(ChatMessage).where(
                    ChatMessage.id == reply_to_id,
                    ChatMessage.link_id == link.id,
                )
            )
        ).scalar_one_or_none()
        if reply_msg is None:
            raise ValueError("الرسالة المردود عليها غير موجودة")
    inv = None
    if kind == "invoice":
        if invoice_id is None:
            raise ValueError("اختر فاتورة")
        try:
            inv = await _invoice_for_link(db, link, invoice_id)
        except ValueError:
            # A device-ledger business: its invoices live on the devices. The
            # message carries the shared invoice id and its number.
            from ...core import business_local_mode
            if not (file_name and await business_local_mode.organization_enabled(
                    db, link.merchant_org_id)):
                raise
    recipient = (link.invited_by if side == "personal"
                 else link.external_user_id)
    if recipient is None:
        raise ValueError("الطرف الآخر غير مرتبط")
    m = ChatMessage(
        link_id=link.id, merchant_org_id=link.merchant_org_id,
        sender_user_id=user_id, recipient_user_id=recipient,
        sender_side=side, kind=kind,
        text=(text or "").strip() or None,
        media_path=media_path, file_name=file_name,
        media=json.dumps(media, ensure_ascii=False) if media else None,
        duration_ms=duration_ms,
        invoice_id=invoice_id, reply_to_id=reply_to_id,
        client_id=client_id,
    )
    try:
        async with db.begin_nested():
            db.add(m)
            await db.flush()
    except IntegrityError:
        if not client_id:
            raise
        existing = (await db.execute(select(ChatMessage).where(
            ChatMessage.sender_user_id == user_id,
            ChatMessage.client_id == client_id))).scalar_one_or_none()
        if existing is None:
            raise
        if existing.link_id != link.id or existing.sender_side != side:
            raise ValueError("معرف الرسالة مستخدم في محادثة أخرى")
        return {"message": _msg_dict(existing, side, await _numbers(db, [existing])),
                "duplicate": True}
    await _touch(db, user_id)
    await db.flush()
    if side == "merchant":
        sender_name = (await _shop(db, link.merchant_org_id))["name"]
    else:
        # Personal -> merchant: notify with the merchant's own party name.
        sender_name = ((await _party_name(db, link)) or link.display_name
                       or (await _user(db, user_id))["name"])
    _replies = ({str(reply_msg.id): _reply_summary(reply_msg, side, {})}
                if reply_msg is not None else None)
    return {"message": _msg_dict(
                m, side,
                {str(inv.id): inv.invoice_number} if inv is not None else {},
                _replies),
            "recipient_user_id": str(recipient),
            "merchant_org_id": str(link.merchant_org_id),
            "is_personal_recipient": side == "merchant",
            "sender_name": sender_name,
            "recipient_online": await _online(db, recipient),
            "sender_side": side}


async def _owned_message(
    db: AsyncSession, user_id: UUID, link_id: UUID, message_id: UUID
) -> ChatMessage:
    link = await _link_for_participant(db, user_id, link_id)
    m = (
        await db.execute(
            select(ChatMessage).where(
                ChatMessage.id == message_id,
                ChatMessage.link_id == link.id,
            )
        )
    ).scalar_one_or_none()
    if m is None or m.deleted_at is not None:
        raise ValueError("الرسالة غير موجودة")
    if m.sender_user_id != user_id:
        raise ValueError("يمكنك تعديل/حذف رسائلك فقط")
    created = _aware(m.created_at)
    if created is None or _now() - created > EDIT_WINDOW:
        raise ValueError("انتهت مدة التعديل (30 دقيقة)")
    return m


async def edit_message(
    db: AsyncSession, user_id: UUID, link_id: UUID, message_id: UUID,
    text: str,
) -> Dict[str, Any]:
    m = await _owned_message(db, user_id, link_id, message_id)
    if m.kind == "text" and not (text or "").strip():
        raise ValueError("اكتب نص الرسالة")
    m.text = (text or "").strip() or None
    m.edited_at = _now()
    await db.flush()
    side = m.sender_side or "personal"
    numbers = await _numbers(db, [m])
    return {"message": _msg_dict(m, side, numbers)}


async def delete_message(
    db: AsyncSession, user_id: UUID, link_id: UUID, message_id: UUID
) -> Dict[str, Any]:
    m = await _owned_message(db, user_id, link_id, message_id)
    m.deleted_at = _now()
    await db.flush()
    return {"deleted": True, "id": str(m.id)}


async def recipient_in_conversation(org_id, recipient_user_id, link_id, side):
    active = await cache_get(_active_key(org_id, recipient_user_id))
    try: active = json.loads(active) if active else None
    except (TypeError, ValueError): active = None
    if not isinstance(active, dict) or active.get('conversation_id') != str(link_id): return False
    seen = active.get('seen_at')
    return (active.get('side') in (None, side) and isinstance(seen, (int, float))
            and 0 <= _now().timestamp() - seen < 30)


async def deliver_chat_push(db, org_id, link_id, recipient_user_id, is_personal_recipient, push):
    side = 'personal' if is_personal_recipient else 'merchant'
    link = await db.get(MerchantLink, link_id)
    if link is None or link.status != 'accepted': return
    if await recipient_in_conversation(org_id, recipient_user_id, link_id, side): return
    from .debt_notification_service import push_event
    await push_event(db, org_id, push['event_id'], push['recipients'],
        title=push['title'], message=push['message'], route=push['route'])


async def deliver_chat_push_detached(org_id, link_id, recipient_user_id, is_personal_recipient, push):
    from ...core.database import async_session_factory
    try:
        async with async_session_factory() as session:
            await deliver_chat_push(session, org_id, link_id, recipient_user_id, is_personal_recipient, push)
            await session.commit()
    except Exception as exc:
        import logging
        logging.getLogger('chat.push').warning('chat_delivery_failed type=%s', type(exc).__name__)


async def notify_new_message(
    db: AsyncSession, *, org_id: UUID, message_id: UUID,
    recipient_user_id: UUID, is_personal_recipient: bool,
    sender_name: str, preview: str, link_id: UUID,
    sender_user_id: UUID | None = None,
) -> Optional[Dict[str, Any]]:
    """Emit the in-app notification (outbox) + return the push payload. The
    router sends the push AFTER commit."""
    side = 'personal' if is_personal_recipient else 'merchant'
    if await recipient_in_conversation(org_id, recipient_user_id, link_id, side): return None
    from app.domain.services import debt_notification_service as dn
    route = (f"/personal/chat?link={link_id}&msg={message_id}"
             if is_personal_recipient
             else f"/debts/chat?link={link_id}&msg={message_id}")
    title = sender_name or "رسالة جديدة"
    event_id = f"chat:{message_id}"
    await dn.emit(db, org_id, event_id, [recipient_user_id],
                  title=title, message=preview, route=route,
                  notif_type="chat_message",
                  payload={"link_id": str(link_id), "message_id": str(message_id),
                           "category": "chat",
                           "to_side": "personal" if is_personal_recipient else "merchant",
                           "sender_user_id": str(sender_user_id) if sender_user_id else None})
    return {"event_id": event_id, "recipients": [recipient_user_id],
            "title": title, "message": preview, "route": route}


async def list_invoices_for_chat(
    db: AsyncSession, user_id: UUID, link_id: UUID, q: Optional[str] = None,
    limit: int = 50,
) -> List[Dict[str, Any]]:
    link = await _link_for_participant(db, user_id, link_id)
    col = (Invoice.customer_id if link.party_kind == "customer"
           else Invoice.supplier_id)
    stmt = select(Invoice).where(
        Invoice.organization_id == link.merchant_org_id,
        col == link.party_id,
        Invoice.is_deleted.is_(False),
        Invoice.status.notin_(["draft", "cancelled"]),
    )
    if q and q.strip():
        stmt = stmt.where(Invoice.invoice_number.ilike(f"%{q.strip()}%"))
    rows = (
        await db.execute(
            stmt.order_by(Invoice.invoice_date.desc()).limit(limit)
        )
    ).scalars().all()
    return [
        {"id": str(i.id), "number": i.invoice_number,
         "date": i.invoice_date.isoformat() if i.invoice_date else None,
         "currency": i.currency, "total": str(i.total or 0),
         "remaining": str(i.balance or 0)}
        for i in rows
    ]
