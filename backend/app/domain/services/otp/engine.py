"""Persisted OTP state machine.

Statuses (``otp_challenges.status``)::

    queued ──send ok──▶ sent ──webhook──▶ delivered ──▶ read
      │  ╲                │ deadline (25 s, no receipt) / permanent failure
      │   ╲temp error     ▼
      │    ╰─retry(2s,4s) fallback_sms ──callback──▶ delivered
      ▼                   │
    failed ◀──────────────╯ (no fallback allowed / SMS failed)
    any live ──▶ verified | expired (5 min) | locked (5 wrong codes)

Rules
* WhatsApp first. SMS only for signup / phone_change / password_reset,
  NEVER for new_device, at most once per challenge (compare-and-set on
  ``sms_sent`` + partial unique index on otp_deliveries), and only when
  WhatsApp failed permanently or no delivery receipt arrived before the
  deadline. Never once WhatsApp reported delivered/read.
* Channel ``device`` (new_device): data push to the user's trusted devices;
  the code is fetched over the authenticated device channel.
* Codes: 6 digits, HMAC-SHA256 bound to the challenge id, single use,
  TTL 5 min, 5 wrong attempts → locked. Resend cool-downs 30/60/120 s,
  max 3 resends; caps per phone / IP / device / account (hour + day).
* All transitions are persisted; the worker resumes due actions after a
  restart (``next_action_at``).
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Iterable, Optional
from uuid import UUID, uuid4

from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.logging import get_logger
from app.domain.entities.auth2_entities import OtpChallenge, OtpDelivery, OtpEvent

from . import costs, providers
from .secrets_box import (
    code_hmac,
    code_matches,
    decrypt,
    decrypt_json,
    encrypt,
    encrypt_json,
    mask_e164,
    new_code,
    phone_hash,
    sign_token,
)

logger = get_logger("otp_engine")

PURPOSES = frozenset({"signup", "phone_change", "new_device", "password_reset"})
SMS_PURPOSES = frozenset({"signup", "phone_change", "password_reset"})
CHANNELS = frozenset({"whatsapp", "sms", "device"})
TERMINAL = frozenset({"verified", "expired", "locked"})
DELIVERED = frozenset({"delivered", "read"})
_WA_RANK = {"accepted": 1, "sent": 2, "delivered": 3, "read": 4}

MESSAGES = {
    "otp_rate_limited": ("تجاوزت عدد المحاولات المسموح. حاول لاحقاً",
                         "Too many attempts. Please try again later."),
    "otp_cooldown": ("انتظر قليلاً قبل طلب رمز جديد", "Please wait before requesting a new code."),
    "otp_resend_limit": ("تجاوزت عدد مرات إعادة الإرسال", "Resend limit reached."),
    "otp_unavailable": ("خدمة إرسال الرموز غير متاحة حالياً. حاول لاحقاً",
                        "Code delivery is unavailable right now. Please try later."),
    "otp_not_found": ("طلب التحقق غير موجود", "Verification request not found."),
    "otp_expired": ("انتهت صلاحية الرمز. اطلب رمزاً جديداً", "The code expired. Request a new one."),
    "otp_locked": ("تم قفل الرمز بعد محاولات خاطئة كثيرة. اطلب رمزاً جديداً",
                   "Too many wrong codes. Request a new one."),
    "otp_invalid_code": ("رمز التحقق غير صحيح", "Incorrect code."),
    "otp_already_used": ("تم استخدام هذا الرمز بالفعل", "This code was already used."),
    "otp_denied": ("تم رفض محاولة تسجيل الدخول من الجهاز الرئيسي",
                   "The sign-in attempt was denied on the primary device."),
    "sms_not_allowed": ("الإرسال عبر رسالة SMS غير متاح لهذا الطلب الآن",
                        "SMS is not available for this request right now."),
    "channel_not_allowed": ("طريقة الإرسال غير متاحة لهذا الطلب",
                            "This delivery method is not available for this request."),
    "idempotency_conflict": ("مفتاح الطلب مستخدم لطلب آخر",
                             "The idempotency key belongs to another request."),
}


class OtpError(Exception):
    def __init__(self, code: str, status: int = 400, retry_after: Optional[int] = None,
                 extra: Optional[dict] = None):
        self.code = code
        self.status = status
        self.retry_after = retry_after
        self.extra = extra or {}
        super().__init__(code)

    def detail(self) -> dict:
        ar, en = MESSAGES.get(self.code, (self.code, self.code))
        d = {"code": self.code, "message_ar": ar, "message_en": en}
        if self.retry_after is not None:
            d["retry_after"] = int(self.retry_after)
        d.update(self.extra)
        return d


# ── Injection points (tests) ──
def utcnow() -> datetime:
    return datetime.now(timezone.utc)


session_factory: Optional[Callable[[], Any]] = None
kick_enabled = True
_tasks: set = set()


def _factory():
    if session_factory is not None:
        return session_factory()
    from app.core.database import async_session_factory
    return async_session_factory()


def _aw(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is not None and dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def _pair(raw: str, default: tuple[int, int]) -> tuple[int, int]:
    try:
        a, b = (int(x) for x in str(raw).split(","))
        return a, b
    except (ValueError, TypeError):
        return default


def cooldowns() -> list[int]:
    try:
        vals = [int(x) for x in settings.AUTH_OTP_RESEND_COOLDOWNS.split(",") if x.strip()]
        return vals or [30, 60, 120]
    except ValueError:
        return [30, 60, 120]


def webhook_receipts_enabled() -> bool:
    # Only the explicit secret of the Meta app the WABA is subscribed to.
    # META_APP_SECRET may belong to another app: its receipts never arrive.
    return bool(settings.META_WEBHOOK_APP_SECRET)


# Last time a correctly signed WhatsApp status receipt reached us (process
# memory only). Proof that receipts flow; never persisted.
_last_receipt_at: Optional[datetime] = None
RECEIPT_HEALTH_WINDOW = timedelta(hours=6)


def note_receipt(now: Optional[datetime] = None) -> None:
    global _last_receipt_at
    _last_receipt_at = now or utcnow()


def receipts_recently_seen(now: datetime) -> bool:
    return _last_receipt_at is not None and now - _last_receipt_at <= RECEIPT_HEALTH_WINDOW


def auto_fallback_active() -> bool:
    return bool(settings.AUTH_OTP_AUTO_SMS_FALLBACK) and webhook_receipts_enabled()


async def _event(db: AsyncSession, ch_id, kind: str, channel: Optional[str] = None,
                 detail: Optional[str] = None) -> None:
    db.add(OtpEvent(challenge_id=ch_id, kind=kind, channel=channel,
                    detail=(detail or None) and str(detail)[:200]))


def _wipe(ch: OtpChallenge) -> None:
    ch.code_enc = None
    ch.target_enc = None
    ch.next_action_at = None


def _expire_if_due(ch: OtpChallenge, now: datetime) -> bool:
    if ch.status not in TERMINAL and _aw(ch.expires_at) <= now:
        ch.status = "expired"
        _wipe(ch)
        ch.payload_enc = None
        return True
    return False


# ── Caps ──
async def _check_caps(db: AsyncSession, *, phone_h: Optional[str], ip: Optional[str],
                      device_id: Optional[str], user_id: Optional[UUID],
                      now: datetime) -> None:
    checks = (
        (OtpDelivery.phone_hash, phone_h, _pair(settings.AUTH_OTP_CAP_PHONE, (5, 10))),
        (OtpDelivery.ip, ip, _pair(settings.AUTH_OTP_CAP_IP, (10, 30))),
        (OtpDelivery.device_id, device_id, _pair(settings.AUTH_OTP_CAP_DEVICE, (6, 15))),
        (OtpDelivery.user_id, user_id, _pair(settings.AUTH_OTP_CAP_ACCOUNT, (6, 15))),
    )
    for column, value, (hourly, daily) in checks:
        if value is None:
            continue
        for window, cap in ((timedelta(hours=1), hourly), (timedelta(days=1), daily)):
            since = now - window
            count, oldest = (await db.execute(
                select(func.count(), func.min(OtpDelivery.created_at)).where(
                    column == value, OtpDelivery.created_at >= since)
            )).one()
            if (count or 0) >= cap:
                retry = 60
                if oldest is not None:
                    retry = max(int((_aw(oldest) + window - now).total_seconds()), 1)
                raise OtpError("otp_rate_limited", 429, retry_after=retry)


def _new_delivery(ch: OtpChallenge, channel: str) -> OtpDelivery:
    provider = providers.get(channel) if channel != "device" else None
    return OtpDelivery(
        id=uuid4(), challenge_id=ch.id, channel=channel,
        provider=(provider.name if provider else "fyona_device"),
        status="queued", cost_usd=0, purpose=ch.purpose, phone_hash=ch.phone_hash,
        ip=ch.ip, device_id=ch.device_id, user_id=ch.user_id, country=ch.country,
    )


# ── Public API ──
async def start(
    db: AsyncSession,
    *,
    purpose: str,
    phone_e164: Optional[str],
    channel: str = "whatsapp",
    locale: str = "ar",
    user_id: Optional[UUID] = None,
    ip: Optional[str] = None,
    device_id: Optional[str] = None,
    idempotency_key: Optional[str] = None,
    payload: Optional[dict] = None,
    context: Optional[dict] = None,
    country: Optional[str] = None,
) -> OtpChallenge:
    if purpose not in PURPOSES or channel not in CHANNELS:
        raise OtpError("channel_not_allowed")
    if channel == "sms":
        # A challenge always starts on WhatsApp (or the device channel).
        raise OtpError("sms_not_allowed")
    if channel == "device" and purpose != "new_device":
        raise OtpError("channel_not_allowed")
    now = utcnow()
    ph = phone_hash(phone_e164)
    if idempotency_key:
        existing = (await db.execute(select(OtpChallenge).where(
            OtpChallenge.idempotency_key == idempotency_key))).scalar_one_or_none()
        if existing is not None:
            if existing.purpose != purpose or existing.phone_hash != ph or (
                    existing.user_id is not None and user_id is not None
                    and existing.user_id != user_id):
                raise OtpError("idempotency_conflict", 409)
            return existing
    await _check_caps(db, phone_h=ph, ip=ip, device_id=device_id, user_id=user_id, now=now)
    if channel == "whatsapp":
        provider = providers.get("whatsapp")
        if provider is None or not provider.configured():
            if not (purpose in SMS_PURPOSES and _sms_possible()):
                raise OtpError("otp_unavailable", 503)
        elif not await costs.allowed(db, "whatsapp", country, now):
            raise OtpError("otp_unavailable", 503)
    ch_id = uuid4()
    code = new_code()
    ch = OtpChallenge(
        id=ch_id, purpose=purpose, user_id=user_id, phone_hash=ph,
        target_enc=encrypt(phone_e164) if phone_e164 else None,
        country=(country or None), locale=("en" if (locale or "").lower().startswith("en") else "ar"),
        code_hmac=code_hmac(str(ch_id), code), code_enc=encrypt(code),
        attempts=0, max_attempts=settings.AUTH_OTP_MAX_ATTEMPTS,
        status="queued", channel=channel, resend_count=0,
        next_action_at=now, expires_at=now + timedelta(seconds=settings.AUTH_OTP_TTL_SECONDS),
        idempotency_key=idempotency_key or None, ip=ip, device_id=device_id,
        payload_enc=encrypt_json(payload) if payload is not None else None,
        context=context or None, created_at=now, updated_at=now,
    )
    db.add(ch)
    await db.flush()
    delivery = _new_delivery(ch, channel)
    delivery.created_at = now
    db.add(delivery)
    ch.current_delivery_id = delivery.id
    await _event(db, ch.id, "created", channel, purpose)
    try:
        await db.flush()
    except IntegrityError:
        # Concurrent request with the same idempotency key won the insert.
        await db.rollback()
        existing = (await db.execute(select(OtpChallenge).where(
            OtpChallenge.idempotency_key == idempotency_key))).scalar_one_or_none()
        if existing is None:
            raise
        return existing
    logger.info("otp_started", purpose=purpose, channel=channel, to=mask_e164(phone_e164))
    return ch


def _sms_possible() -> bool:
    p = providers.get("sms")
    return bool(p and p.configured())


async def get(db: AsyncSession, challenge_id, *, lock: bool = False) -> Optional[OtpChallenge]:
    try:
        cid = UUID(str(challenge_id))
    except (ValueError, TypeError):
        return None
    q = select(OtpChallenge).where(OtpChallenge.id == cid)
    if lock and db.get_bind().dialect.name == "postgresql":
        q = q.with_for_update()
    return (await db.execute(q)).scalar_one_or_none()


def resend_after(ch: OtpChallenge, now: datetime) -> int:
    if ch.status in TERMINAL:
        return 0
    cds = cooldowns()
    cd = cds[min(ch.resend_count, len(cds) - 1)]
    base = _aw(ch.last_sent_at) or _aw(ch.created_at) or now
    return max(int((base + timedelta(seconds=cd) - now).total_seconds() + 0.999), 0)


async def can_request_sms(db: AsyncSession, ch: OtpChallenge, now: Optional[datetime] = None) -> bool:
    now = now or utcnow()
    if ch.purpose not in SMS_PURPOSES or ch.sms_sent or ch.status in TERMINAL:
        return False
    if ch.status_reason in ("denied", "whatsapp_setup") or _aw(ch.expires_at) <= now:
        return False
    if ch.channel == "sms" or ch.wa_status in DELIVERED or ch.status in DELIVERED:
        return False
    wa_failed = ch.wa_status == "failed" or ch.status == "failed"
    deadline = _aw(ch.delivery_deadline_at)
    timed_out = deadline is not None and now >= deadline
    if not (wa_failed or timed_out):
        return False
    if not _sms_possible():
        return False
    return await costs.allowed(db, "sms", ch.country, now)


async def status_view(db: AsyncSession, ch: OtpChallenge) -> dict:
    now = utcnow()
    if _expire_if_due(ch, now):
        await db.flush()
    return {
        "challenge_id": str(ch.id),
        "status": ch.status,
        "channel": ch.channel,
        "can_request_sms": await can_request_sms(db, ch, now),
        "resend_after": resend_after(ch, now),
        "expires_in": max(int((_aw(ch.expires_at) - now).total_seconds()), 0)
        if ch.status not in TERMINAL else 0,
        "attempts_left": max(ch.max_attempts - ch.attempts, 0),
    }


async def resend(db: AsyncSession, ch: OtpChallenge, channel: Optional[str] = None,
                 *, has_trusted_device: bool = False) -> OtpChallenge:
    now = utcnow()
    if _expire_if_due(ch, now):
        await db.commit()
        raise OtpError("otp_expired", 410)
    if ch.status in TERMINAL:
        raise OtpError("otp_already_used" if ch.status == "verified" else f"otp_{ch.status}", 409)
    if ch.status_reason == "denied":
        raise OtpError("otp_denied", 403)
    channel = channel or ("whatsapp" if ch.channel == "sms" else ch.channel)
    if channel not in CHANNELS:
        raise OtpError("channel_not_allowed")
    if channel == "sms":
        if not await can_request_sms(db, ch, now):
            raise OtpError("sms_not_allowed", 409)
        await _check_caps(db, phone_h=ch.phone_hash, ip=ch.ip, device_id=ch.device_id,
                          user_id=ch.user_id, now=now)
        ch.status = "fallback_sms"
        ch.status_reason = "user_requested"
        ch.channel = "sms"
        ch.next_action_at = now
        await _event(db, ch.id, "sms_requested", "sms")
        await db.flush()
        return ch
    if channel == "device" and (ch.purpose != "new_device" or not has_trusted_device):
        raise OtpError("channel_not_allowed")
    wait = resend_after(ch, now)
    if wait > 0:
        raise OtpError("otp_cooldown", 429, retry_after=wait)
    if ch.resend_count >= settings.AUTH_OTP_MAX_RESENDS:
        raise OtpError("otp_resend_limit", 429)
    await _check_caps(db, phone_h=ch.phone_hash, ip=ch.ip, device_id=ch.device_id,
                      user_id=ch.user_id, now=now)
    if channel == "whatsapp":
        provider = providers.get("whatsapp")
        if provider is None or not provider.configured() or not await costs.allowed(
                db, "whatsapp", ch.country, now):
            raise OtpError("otp_unavailable", 503)
    # Fresh code: the previous one dies (single use).
    code = new_code()
    ch.code_hmac = code_hmac(str(ch.id), code)
    ch.code_enc = encrypt(code)
    ch.resend_count += 1
    ch.channel = channel
    ch.status = "queued"
    ch.status_reason = None
    ch.wa_message_id = None
    ch.wa_status = None
    ch.wa_error_code = None
    ch.wa_attempts = 0
    ch.delivery_deadline_at = None
    ch.last_sent_at = now
    ch.next_action_at = now
    # A fresh code gets a fresh TTL (bounded by the resend limit).
    ch.expires_at = now + timedelta(seconds=settings.AUTH_OTP_TTL_SECONDS)
    delivery = _new_delivery(ch, channel)
    delivery.created_at = now
    db.add(delivery)
    ch.current_delivery_id = delivery.id
    await _event(db, ch.id, "resend", channel)
    await db.flush()
    return ch


async def verify(db: AsyncSession, challenge_id, code: str, *,
                 purposes: Iterable[str]) -> tuple[OtpChallenge, Optional[dict], Optional[str]]:
    """Check a code. Wrong codes are COMMITTED (attempts survive the error).

    Returns (challenge, payload, phone_e164) — the challenge is marked
    verified in the caller's transaction (consumed together with the
    account change it authorizes).
    """
    ch = await get(db, challenge_id, lock=True)
    if ch is None or ch.purpose not in set(purposes):
        raise OtpError("otp_not_found", 404)
    now = utcnow()
    if _expire_if_due(ch, now):
        await db.commit()
        raise OtpError("otp_expired", 410)
    if ch.status == "verified":
        raise OtpError("otp_already_used", 409)
    if ch.status == "locked":
        raise OtpError("otp_locked", 423)
    if ch.status == "expired":
        raise OtpError("otp_expired", 410)
    if ch.status_reason == "denied":
        raise OtpError("otp_denied", 403)
    clean = "".join(c for c in (code or "") if c.isdigit())
    if len(clean) != 6 or not code_matches(str(ch.id), clean, ch.code_hmac):
        ch.attempts += 1
        left = max(ch.max_attempts - ch.attempts, 0)
        if left == 0:
            ch.status = "locked"
            _wipe(ch)
            ch.payload_enc = None
            await _event(db, ch.id, "locked")
            await db.commit()
            raise OtpError("otp_locked", 423)
        await _event(db, ch.id, "wrong_code")
        await db.commit()
        raise OtpError("otp_invalid_code", 400, extra={"attempts_left": left})
    payload = decrypt_json(ch.payload_enc)
    phone = decrypt(ch.target_enc)
    ch.status = "verified"
    ch.verified_at = now
    ch.consumed_at = now
    _wipe(ch)
    ch.payload_enc = None
    await _event(db, ch.id, "verified", ch.channel)
    await db.flush()
    return ch, payload, phone


async def deny(db: AsyncSession, ch: OtpChallenge) -> None:
    if ch.status in TERMINAL:
        return
    ch.status = "failed"
    ch.status_reason = "denied"
    _wipe(ch)
    ch.payload_enc = None
    await _event(db, ch.id, "denied", ch.channel)
    await db.flush()


def reveal_code(ch: OtpChallenge) -> Optional[str]:
    """Plain code for the authenticated device channel (approvals only)."""
    if ch.purpose != "new_device" or ch.channel != "device" or ch.status in TERMINAL:
        return None
    return decrypt(ch.code_enc)


# ── Background processing ──
def kick(challenge_id) -> None:
    """Process now (after the caller committed). Restart-safe: if this task
    dies, the worker picks the due action up from ``next_action_at``."""
    if not kick_enabled:
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    task = loop.create_task(process(challenge_id))
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)


async def process(challenge_id) -> None:
    try:
        async with _factory() as db:
            await _process(db, challenge_id)
    except Exception as exc:  # noqa: BLE001 - never crash the worker
        logger.warning("otp_process_failed", error=type(exc).__name__)


async def _lock_for_processing(db: AsyncSession, challenge_id) -> Optional[OtpChallenge]:
    q = select(OtpChallenge).where(OtpChallenge.id == UUID(str(challenge_id)))
    if db.get_bind().dialect.name == "postgresql":
        q = q.with_for_update(skip_locked=True)
    return (await db.execute(q)).scalar_one_or_none()


async def _process(db: AsyncSession, challenge_id) -> None:
    ch = await _lock_for_processing(db, challenge_id)
    if ch is None:
        return
    now = utcnow()
    if _expire_if_due(ch, now):
        await _event(db, ch.id, "expired")
        await db.commit()
        return
    if ch.status in TERMINAL or ch.status_reason == "denied":
        ch.next_action_at = None
        await db.commit()
        return
    due = _aw(ch.next_action_at)
    if due is None or due > now:
        await db.commit()
        return
    if ch.status == "queued":
        if ch.channel == "device":
            await _dispatch_device(db, ch, now)
        elif ch.channel == "whatsapp":
            await _dispatch_whatsapp(db, ch, now)
        await db.commit()
        if ch.status == "fallback_sms" and not ch.sms_sent:
            await _send_sms(db, ch.id)
        return
    if ch.status == "fallback_sms" and not ch.sms_sent:
        await db.commit()
        await _send_sms(db, ch.id)
        return
    if ch.status == "sent" and ch.channel == "whatsapp":
        # Deadline reached without a delivery receipt.
        ch.next_action_at = None
        # Cost guard: a silent timeout only means "not delivered" when receipts
        # are proven to flow (one arrived for this message, or recently for
        # another). Otherwise no automatic SMS: the user can ask for one.
        receipts_proven = (ch.wa_status not in (None, "accepted")
                           or receipts_recently_seen(now))
        if (ch.purpose in SMS_PURPOSES and auto_fallback_active() and receipts_proven
                and ch.wa_status not in DELIVERED and await can_request_sms(db, ch, now)):
            ch.status = "fallback_sms"
            ch.status_reason = "whatsapp_timeout"
            ch.channel = "sms"
            await _event(db, ch.id, "fallback_timeout", "sms")
            await db.commit()
            await _send_sms(db, ch.id)
            return
        await db.commit()
        return
    ch.next_action_at = None
    await db.commit()


async def _current_delivery(db: AsyncSession, ch: OtpChallenge, channel: str) -> OtpDelivery:
    d = await db.get(OtpDelivery, ch.current_delivery_id) if ch.current_delivery_id else None
    if d is None or d.channel != channel:
        d = _new_delivery(ch, channel)
        db.add(d)
        ch.current_delivery_id = d.id
    return d


async def _dispatch_whatsapp(db: AsyncSession, ch: OtpChallenge, now: datetime) -> None:
    provider = providers.get("whatsapp")
    d = await _current_delivery(db, ch, "whatsapp")
    phone = decrypt(ch.target_enc)
    code = decrypt(ch.code_enc)
    ch.wa_attempts += 1
    if provider is None or not provider.configured() or not phone or not code:
        result = providers.SendResult(ok=False, error_code="not_configured", permanent=True)
    elif not await costs.allowed(db, "whatsapp", ch.country, now):
        result = providers.SendResult(ok=False, error_code="budget_exceeded", permanent=True)
    else:
        result = await provider.send_code(to_e164=phone, code=code, locale=ch.locale)
    now = utcnow()
    if result.ok:
        d.status = "accepted"
        d.provider_message_id = result.message_id
        d.cost_usd = result.cost_usd if result.cost_usd is not None else costs.estimate(
            "whatsapp", ch.country)
        ch.wa_message_id = result.message_id
        ch.wa_status = "accepted"
        ch.status = "sent"
        ch.last_sent_at = now
        ch.delivery_deadline_at = now + timedelta(seconds=settings.AUTH_OTP_DELIVERY_DEADLINE_SECONDS)
        ch.next_action_at = (ch.delivery_deadline_at
                             if ch.purpose in SMS_PURPOSES and auto_fallback_active() else None)
        await _event(db, ch.id, "wa_accepted", "whatsapp")
        return
    d.error_code = result.error_code
    d.error_title = result.error_title
    window_end = (_aw(ch.created_at) or now) + timedelta(
        seconds=settings.AUTH_OTP_DELIVERY_DEADLINE_SECONDS)
    backoff = timedelta(seconds=2 * ch.wa_attempts)
    if (not result.permanent and ch.wa_attempts < settings.AUTH_OTP_WHATSAPP_MAX_ATTEMPTS
            and now + backoff < window_end):
        ch.next_action_at = now + backoff
        ch.wa_error_code = result.error_code
        await _event(db, ch.id, "wa_retry", "whatsapp", result.error_code)
        return
    d.status = "failed"
    await _whatsapp_failed(db, ch, result.error_code, now)


async def _whatsapp_failed(db: AsyncSession, ch: OtpChallenge, error_code: Optional[str],
                           now: datetime) -> None:
    ch.wa_status = "failed"
    ch.wa_error_code = error_code
    ch.next_action_at = None
    await _event(db, ch.id, "wa_failed", "whatsapp", error_code)
    if ch.status in TERMINAL or ch.sms_sent or ch.channel == "sms":
        return  # SMS already under way: a late WhatsApp failure changes nothing
    ch.status = "failed"
    if not providers.sms_fallback_allowed(error_code):
        # Our WhatsApp setup is broken (template / token / account): no SMS,
        # automatic or requested, so a Meta misconfiguration costs nothing.
        ch.status_reason = "whatsapp_setup"
        logger.warning("otp_whatsapp_setup_error", code=error_code)
        await _event(db, ch.id, "wa_setup_error", "whatsapp", error_code)
        return
    ch.status_reason = "whatsapp_failed"
    if ch.purpose in SMS_PURPOSES and await can_request_sms(db, ch, now):
        ch.status = "fallback_sms"
        ch.status_reason = "whatsapp_failed"
        ch.channel = "sms"
        ch.next_action_at = now
        await _event(db, ch.id, "fallback_failure", "sms", error_code)


def sms_callback_url(delivery_id) -> Optional[str]:
    base = (settings.API_BASE_URL or "").rstrip("/")
    if not base.startswith("https://"):
        return None
    token = f"{delivery_id}.{sign_token('smsto', str(delivery_id))}"
    return f"{base}{settings.API_PREFIX}/webhooks/smsto/{token}"


async def _send_sms(db: AsyncSession, challenge_id) -> None:
    """At most ONE SMS per challenge, enforced twice at the DB level."""
    now = utcnow()
    claimed = await db.execute(
        update(OtpChallenge)
        .where(OtpChallenge.id == challenge_id, OtpChallenge.sms_sent.is_(False),
               OtpChallenge.purpose.in_(tuple(SMS_PURPOSES)))
        .values(sms_sent=True, next_action_at=None, updated_at=now)
    )
    if (claimed.rowcount or 0) != 1:
        await db.rollback()
        return
    ch = (await db.execute(select(OtpChallenge).where(
        OtpChallenge.id == challenge_id))).scalar_one()
    await db.refresh(ch)
    provider = providers.get("sms")
    d = _new_delivery(ch, "sms")
    d.status = "sending"
    d.created_at = now
    db.add(d)
    ch.current_delivery_id = d.id
    try:
        await db.commit()  # claim is durable BEFORE the provider call
    except IntegrityError:
        await db.rollback()
        logger.warning("otp_sms_duplicate_blocked")
        return
    phone = decrypt(ch.target_enc)
    code = decrypt(ch.code_enc)
    if ch.status in TERMINAL or not phone or not code or provider is None:
        result = providers.SendResult(ok=False, error_code="not_sendable", permanent=True)
    elif not await costs.allowed(db, "sms", ch.country, now):
        result = providers.SendResult(ok=False, error_code="budget_exceeded", permanent=True)
    else:
        result = await provider.send_code(to_e164=phone, code=code, locale=ch.locale,
                                          callback_url=sms_callback_url(d.id))
    now = utcnow()
    if result.ok:
        d.status = "accepted"
        d.provider_message_id = result.message_id
        d.cost_usd = result.cost_usd if result.cost_usd is not None else costs.estimate(
            "sms", ch.country)
        ch.sms_message_id = result.message_id
        ch.sms_status = "accepted"
        ch.last_sent_at = now
        if ch.status not in TERMINAL:
            ch.status = "fallback_sms"
        await _event(db, ch.id, "sms_accepted", "sms")
    else:
        d.status = "failed"
        d.error_code = result.error_code
        d.error_title = result.error_title
        ch.sms_status = "failed"
        if ch.status not in TERMINAL:
            ch.status = "failed"
            ch.status_reason = "sms_failed"
        await _event(db, ch.id, "sms_failed", "sms", result.error_code)
    await db.commit()


async def _dispatch_device(db: AsyncSession, ch: OtpChallenge, now: datetime) -> None:
    d = await _current_delivery(db, ch, "device")
    try:
        from .device_channel import notify_approval

        await notify_approval(db, ch)
    except Exception as exc:  # noqa: BLE001 - the in-app row is best-effort too
        logger.warning("otp_device_push_failed", error=type(exc).__name__)
    d.status = "sent"
    ch.status = "sent"
    ch.last_sent_at = now
    ch.next_action_at = None
    await _event(db, ch.id, "device_notified", "device")


# ── Delivery receipts ──
async def _first_receipt(db: AsyncSession, key: str, kind: str, channel: str,
                         detail: Optional[str]) -> bool:
    """Record a webhook receipt once (unique dedupe_key). False = duplicate."""
    key = key[:200]
    row = OtpEvent(kind=kind, channel=channel, dedupe_key=key,
                   detail=(detail or None) and str(detail)[:200])
    if db.get_bind().dialect.name == "postgresql":
        try:
            async with db.begin_nested():
                db.add(row)
                await db.flush()
            return True
        except IntegrityError:
            return False
    exists = (await db.execute(select(OtpEvent.id).where(OtpEvent.dedupe_key == key))).first()
    if exists:
        return False
    db.add(row)
    await db.flush()
    return True


async def apply_whatsapp_status(db: AsyncSession, *, message_id: str, status: str,
                                error_code: Optional[str] = None,
                                event_key: Optional[str] = None) -> Optional[UUID]:
    """Idempotent. Returns the challenge id when it needs processing."""
    status = (status or "").lower()
    if status not in ("sent", "delivered", "read", "failed"):
        return None
    key = event_key or f"wa:{message_id}:{status}"
    if not await _first_receipt(db, key, f"wa_webhook_{status}", "whatsapp", error_code):
        return None  # duplicate receipt
    d = (await db.execute(select(OtpDelivery).where(
        OtpDelivery.provider_message_id == message_id,
        OtpDelivery.channel == "whatsapp"))).scalar_one_or_none()
    if d is None:
        return None
    ch = await get(db, d.challenge_id, lock=True)
    if ch is None:
        return None
    if status == "failed":
        if d.status not in DELIVERED:
            d.status = "failed"
            d.error_code = error_code
        if ch.wa_message_id != message_id or ch.wa_status in DELIVERED:
            return None
        now = utcnow()
        if _expire_if_due(ch, now) or ch.status in TERMINAL:
            return None
        await _whatsapp_failed(db, ch, error_code, now)
        return ch.id if ch.status == "fallback_sms" else None
    if _WA_RANK.get(status, 0) > _WA_RANK.get(d.status, 0):
        d.status = status
    if ch.wa_message_id == message_id and _WA_RANK.get(status, 0) > _WA_RANK.get(ch.wa_status or "", 0):
        ch.wa_status = status
        if (status in DELIVERED and ch.status in ("sent", "queued", "fallback_sms", "failed")
                and ch.status_reason != "denied"):
            ch.status = status
            ch.next_action_at = None
        elif status == "read" and ch.status == "delivered":
            ch.status = "read"
    return None


SMS_DELIVERED = frozenset({"delivered", "delivrd", "success", "succeeded", "completed"})
SMS_FAILED = frozenset({"failed", "undelivered", "undeliv", "rejected", "expired", "error",
                        "unknown_error", "invalid", "blocked"})


async def apply_sms_status(db: AsyncSession, *, delivery_id, status: str,
                           error_code: Optional[str] = None) -> None:
    norm = (status or "").strip().lower().replace(" ", "_")
    key = f"sms:{delivery_id}:{norm}"
    if not await _first_receipt(db, key, f"sms_webhook_{norm[:20]}", "sms", error_code):
        return
    d = await db.get(OtpDelivery, UUID(str(delivery_id)))
    if d is None or d.channel != "sms":
        return
    ch = await get(db, d.challenge_id, lock=True)
    if norm in SMS_DELIVERED:
        d.status = "delivered"
        if ch is not None:
            ch.sms_status = "delivered"
            if ch.status in ("fallback_sms", "failed") and ch.status_reason != "denied":
                ch.status = "delivered"
    elif norm in SMS_FAILED:
        if d.status != "delivered":
            d.status = "failed"
            d.error_code = error_code or norm
        if ch is not None and ch.status == "fallback_sms":
            ch.sms_status = "failed"
            ch.status = "failed"
            ch.status_reason = "sms_failed"
    elif norm in ("sent", "queued", "accepted", "enroute", "scheduled", "pending"):
        if d.status in ("queued", "sending", "accepted"):
            d.status = "sent"


# ── Worker tick ──
async def run_due(limit: int = 25) -> int:
    """Process due actions + expire stale live challenges. Returns count."""
    now = utcnow()
    async with _factory() as db:
        ids = (await db.execute(
            select(OtpChallenge.id).where(
                OtpChallenge.next_action_at.is_not(None),
                OtpChallenge.next_action_at <= now,
                OtpChallenge.status.not_in(tuple(TERMINAL)),
            ).order_by(OtpChallenge.next_action_at).limit(limit)
        )).scalars().all()
        stale = (await db.execute(
            select(OtpChallenge).where(
                OtpChallenge.status.not_in(tuple(TERMINAL)),
                OtpChallenge.expires_at < now,
            ).limit(200)
        )).scalars().all()
        for ch in stale:
            _expire_if_due(ch, now)
        await db.commit()
    for cid in ids:
        await process(cid)
    return len(ids)
