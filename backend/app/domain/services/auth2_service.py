"""Auth v2 building blocks: phone accounts, trusted devices, sessions.

Sessions stay the round-14 ``user_sessions`` rows (3-device cap, sid in the
access token, refresh rotation); the session ``fingerprint`` is the device
id so one install always reuses its own slot, and the session primary flag
mirrors the device primary.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Optional
from uuid import UUID, uuid4

from jose import JWTError, jwt
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.logging import get_logger
from app.core.phone_validation import PhoneInfo, normalize_phone
from app.domain.entities.auth2_entities import AuthDevice, PrimaryTransfer
from app.domain.entities.auth_entities import Organization, User, UserSession
from app.domain.services.device_proof import normalize_public_key, valid_device_id

logger = get_logger("auth2")

PLACEHOLDER_DOMAIN = "phone.fyona.invalid"

MESSAGES = {
    "invalid_phone": ("رقم الهاتف غير صالح", "Invalid phone number."),
    "invalid_credentials": ("رقم الهاتف أو كلمة المرور غير صحيحة",
                            "Incorrect phone number or password."),
    "account_inactive": ("الحساب غير نشط. يرجى التواصل مع الدعم",
                         "This account is inactive. Please contact support."),
    "account_not_found": ("لا يوجد حساب مسجل بهذا الرقم", "No account is registered with this number."),
    "phone_taken": ("رقم الهاتف مسجل لحساب آخر. سجّل الدخول بكلمة المرور ثم اربط الحساب",
                    "This number belongs to another account. Sign in with your password, then link."),
    "same_phone": ("هذا هو رقمك الحالي", "This is already your number."),
    "weak_password": ("كلمة المرور يجب أن تكون 8 أحرف على الأقل",
                      "The password must be at least 8 characters."),
    "invalid_name": ("الاسم الكامل يجب أن يكون حرفين على الأقل",
                     "The full name must be at least 2 characters."),
    "invalid_device": ("بيانات الجهاز غير صالحة", "Invalid device data."),
    "invalid_device_proof": ("تعذر التحقق من هوية الجهاز. أعد المحاولة",
                             "Device verification failed. Please retry."),
    "device_not_trusted": ("هذا الجهاز غير موثوق", "This device is not trusted."),
    "device_revoked": ("تم إلغاء ثقة هذا الجهاز. سجّل الدخول من جديد",
                       "This device was revoked. Please sign in again."),
    "device_limit": ("وصلت إلى الحد الأقصى للأجهزة على هذا الحساب. سجّل الخروج من أحد أجهزتك",
                     "Device limit reached. Sign out of one of your devices first."),
    "verification_expired": ("انتهت صلاحية طلب التحقق. سجّل الدخول من جديد",
                             "The verification request expired. Please sign in again."),
    "invalid_social_token": ("تعذر التحقق من تسجيل الدخول الخارجي", "Social sign-in could not be verified."),
    "social_token_expired": ("انتهت صلاحية تسجيل الدخول الخارجي. أعد المحاولة",
                             "The social sign-in expired. Please retry."),
    "social_nonce_mismatch": ("تعذر التحقق من تسجيل الدخول الخارجي", "Social sign-in could not be verified."),
    "jwks_unavailable": ("خدمة التحقق غير متاحة حالياً. حاول لاحقاً",
                         "Verification service unavailable. Please try later."),
    "invalid_nonce": ("انتهت صلاحية طلب التحقق من الجهاز. أعد المحاولة",
                      "The device challenge expired. Please retry."),
    "identity_linked": ("هذا الحساب الخارجي مرتبط بحساب آخر", "This social account is linked to another account."),
    "provider_not_supported": ("طريقة الدخول غير مدعومة", "Sign-in method not supported."),
    "not_primary": ("هذا الإجراء متاح من الجهاز الرئيسي فقط", "Only the primary device can do this."),
    "cannot_revoke_primary": ("لا يمكن إلغاء الجهاز الرئيسي. انقل صفة الرئيسي أولاً",
                              "The primary device cannot be revoked. Transfer primary first."),
    "device_not_found": ("الجهاز غير موجود", "Device not found."),
    "approval_not_found": ("طلب الموافقة غير موجود أو انتهى", "Approval request not found or expired."),
    "transfer_not_found": ("لا يوجد طلب نقل قيد الانتظار", "No pending transfer."),
    "reauth_required": ("أدخل كلمة المرور أو أكد هويتك من جهاز موثوق",
                        "Enter your password or confirm from a trusted device."),
    "already_primary": ("هذا الجهاز هو الرئيسي بالفعل", "This device is already primary."),
    "gone": ("هذه الطريقة لم تعد مدعومة. حدّث التطبيق", "This method is no longer supported. Update the app."),
}


class AuthError(Exception):
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


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _aw(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is not None and dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def is_placeholder_email(email: Optional[str]) -> bool:
    return bool(email) and email.lower().endswith(".fyona.invalid")


def placeholder_email(user_id: UUID) -> str:
    return f"u-{user_id.hex}@{PLACEHOLDER_DOMAIN}"


def normalize(phone: Optional[str]) -> PhoneInfo:
    try:
        return normalize_phone(phone or "")
    except ValueError as exc:
        raise AuthError("invalid_phone") from exc


def check_password_policy(password: Optional[str]) -> str:
    if not password or len(password) < 8 or len(password) > 128:
        raise AuthError("weak_password")
    return password


def check_name(name: Optional[str]) -> str:
    clean = " ".join((name or "").split())
    if len(clean) < 2 or len(clean) > 200:
        raise AuthError("invalid_name")
    return clean


def parse_device(raw: Optional[dict]) -> dict:
    """Validated device payload: {id, public_key, key_fp, name, model, ...}."""
    if not isinstance(raw, dict):
        raise AuthError("invalid_device")
    device_id = str(raw.get("id") or raw.get("device_id") or "").strip()
    if not valid_device_id(device_id):
        raise AuthError("invalid_device")
    try:
        pk, fp = normalize_public_key(str(raw.get("public_key") or ""))
    except ValueError as exc:
        raise AuthError("invalid_device") from exc

    def s(key: str, n: int) -> Optional[str]:
        value = raw.get(key)
        if value is None:
            return None
        value = " ".join(str(value).split())[:n]
        return value or None

    return {"id": device_id, "public_key": pk, "key_fp": fp, "name": s("name", 100),
            "model": s("model", 100), "os": s("os", 30), "os_version": s("os_version", 50),
            "app_version": s("app_version", 40)}


def locale_of(request_locale: Optional[str], accept: Optional[str]) -> str:
    raw = (request_locale or accept or "ar").strip().lower()
    return "en" if raw.startswith("en") else "ar"


# ── Signed short-lived tokens (verification_id / social_session) ──
def make_token(kind: str, data: dict, ttl_seconds: int) -> str:
    now = utcnow()
    payload = {**data, "type": kind, "iat": now, "exp": now + timedelta(seconds=ttl_seconds),
               "jti": uuid4().hex}
    return jwt.encode(payload, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM)


def read_token(kind: str, token: Optional[str]) -> dict:
    try:
        payload = jwt.decode(token or "", settings.JWT_SECRET_KEY,
                             algorithms=[settings.JWT_ALGORITHM])
    except JWTError as exc:
        raise AuthError("verification_expired", 401) from exc
    if payload.get("type") != kind:
        raise AuthError("verification_expired", 401)
    return payload


# ── Users ──
async def user_by_phone(db: AsyncSession, e164: str) -> Optional[User]:
    return (await db.execute(select(User).where(User.phone_e164 == e164))).scalar_one_or_none()


async def phone_in_use(db: AsyncSession, e164: str, except_user: Optional[UUID] = None) -> bool:
    """Only a VERIFIED phone owns a number."""
    q = select(User.id).where(User.phone_e164 == e164)
    if except_user is not None:
        q = q.where(User.id != except_user)
    return (await db.execute(q.limit(1))).first() is not None


async def release_unverified_phone(db: AsyncSession, e164: str, owner: UUID) -> None:
    """A verified owner wins over stale unverified copies (legacy column)."""
    await db.execute(update(User).where(
        User.phone == e164, User.id != owner, User.phone_e164.is_(None)).values(phone=None))


def apply_verified_phone(user: User, info: PhoneInfo, now: datetime) -> None:
    user.phone_e164 = info.e164
    user.phone = info.e164
    user.phone_country = info.country
    user.phone_calling_code = info.country_code
    user.phone_type = info.number_type
    user.phone_carrier = info.carrier
    user.phone_verified_at = now
    if user.phone_added_at is None:
        user.phone_added_at = now
    user.phone_updated_at = now


async def create_account(db: AsyncSession, auth_service, *, full_name: str, info: PhoneInfo,
                         password_hash: Optional[str], locale: str, auth_provider: str,
                         email: Optional[str] = None, email_verified: bool = False) -> User:
    now = utcnow()
    user_id = uuid4()
    base_slug = "".join(c for c in full_name.lower().replace(" ", "-") if c.isalnum() or c == "-")
    org = Organization(name=f"منظمة {full_name}", slug=f"{base_slug or 'u'}-{uuid4().hex[:8]}")
    db.add(org)
    await db.flush()
    use_email = None
    if email:
        clash = (await db.execute(select(User.id).where(User.email == email.lower()))).first()
        use_email = None if clash else email.lower()
    user = User(id=user_id, organization_id=org.id, full_name=full_name,
                email=use_email or placeholder_email(user_id), password_hash=password_hash,
                auth_provider=auth_provider, role="owner",
                email_verified=bool(use_email and email_verified),
                preferred_language=locale, preferred_usage_mode="personal", status="active")
    apply_verified_phone(user, info, now)
    await release_unverified_phone(db, info.e164, user_id)
    db.add(user)
    await db.flush()
    await auth_service._create_default_roles(org)
    logger.info("auth2_account_created", user_id=str(user_id), provider=auth_provider)
    return user


# ── Devices ──
async def get_device(db: AsyncSession, user_id: UUID, device_id: str) -> Optional[AuthDevice]:
    return (await db.execute(select(AuthDevice).where(
        AuthDevice.user_id == user_id, AuthDevice.device_id == device_id))).scalar_one_or_none()


def device_is_trusted(dev: Optional[AuthDevice]) -> bool:
    return bool(dev and dev.trusted and dev.revoked_at is None)


async def trusted_devices(db: AsyncSession, user_id: UUID) -> list[AuthDevice]:
    return list((await db.execute(select(AuthDevice).where(
        AuthDevice.user_id == user_id, AuthDevice.trusted.is_(True),
        AuthDevice.revoked_at.is_(None)))).scalars().all())


async def primary_device(db: AsyncSession, user_id: UUID) -> Optional[AuthDevice]:
    return (await db.execute(select(AuthDevice).where(
        AuthDevice.user_id == user_id, AuthDevice.is_primary.is_(True)))).scalar_one_or_none()


async def trust_device(db: AsyncSession, user_id: UUID, dev_payload: dict, *,
                       ip: Optional[str], make_primary_if_none: bool = True) -> AuthDevice:
    now = utcnow()
    dev = await get_device(db, user_id, dev_payload["id"])
    if dev is None:
        dev = AuthDevice(user_id=user_id, device_id=dev_payload["id"], created_at=now)
        db.add(dev)
    dev.public_key = dev_payload["public_key"]
    dev.key_fingerprint = dev_payload["key_fp"]
    for field in ("name", "model", "os", "os_version", "app_version"):
        if dev_payload.get(field):
            setattr(dev, field, dev_payload[field])
    dev.trusted = True
    dev.trusted_at = now
    dev.revoked_at = None
    dev.last_seen = now
    dev.last_ip = ip
    await db.flush()
    if make_primary_if_none:
        current = await primary_device(db, user_id)
        if current is None or not device_is_trusted(current):
            await set_primary(db, user_id, dev)
    return dev


async def set_primary(db: AsyncSession, user_id: UUID, dev: AuthDevice) -> None:
    await db.execute(update(AuthDevice).where(
        AuthDevice.user_id == user_id, AuthDevice.id != dev.id).values(is_primary=False))
    await db.flush()
    dev.is_primary = True
    await db.flush()
    await sync_session_primary(db, user_id)


async def sync_session_primary(db: AsyncSession, user_id: UUID) -> None:
    prim = await primary_device(db, user_id)
    if prim is None:
        return
    rows = list((await db.execute(select(UserSession).where(
        UserSession.user_id == user_id, UserSession.is_active.is_(True)))).scalars().all())
    target = next((s for s in rows if s.fingerprint == prim.device_id), None)
    if target is None:
        return
    for s in rows:
        if s.is_primary and s.id != target.id:
            s.is_primary = False
    await db.flush()
    if not target.is_primary:
        target.is_primary = True
        await db.flush()


async def kill_device_sessions(db: AsyncSession, user_id: UUID, device_id: str) -> list[UUID]:
    rows = list((await db.execute(select(UserSession).where(
        UserSession.user_id == user_id, UserSession.fingerprint == device_id,
        UserSession.is_active.is_(True)))).scalars().all())
    for s in rows:
        s.is_active = False
        s.is_primary = False
    await db.flush()
    return [s.id for s in rows]


async def revoke_device(db: AsyncSession, dev: AuthDevice) -> list[UUID]:
    now = utcnow()
    dev.trusted = False
    dev.revoked_at = now
    dev.is_primary = False
    await db.flush()
    killed = await kill_device_sessions(db, dev.user_id, dev.device_id)
    await db.execute(update(PrimaryTransfer).where(
        PrimaryTransfer.user_id == dev.user_id, PrimaryTransfer.status == "pending",
        PrimaryTransfer.to_device_id == dev.device_id,
    ).values(status="cancelled", resolved_at=now, resolved_by="revoked"))
    logger.info("auth2_device_revoked", user_id=str(dev.user_id))
    return killed


def device_view(dev: AuthDevice, current_device_id: Optional[str] = None) -> dict:
    return {
        "device_id": dev.device_id,
        "name": dev.custom_name or dev.name,
        "model": dev.model,
        "os": dev.os,
        "os_version": dev.os_version,
        "app_version": dev.app_version,
        "is_primary": bool(dev.is_primary),
        "trusted": device_is_trusted(dev),
        "revoked": dev.revoked_at is not None,
        "last_seen": _aw(dev.last_seen).isoformat() if dev.last_seen else None,
        "created_at": _aw(dev.created_at).isoformat() if dev.created_at else None,
        "current": bool(current_device_id and dev.device_id == current_device_id),
    }


# ── Primary transfers (recovery) ──
async def apply_due_primary_transfers(db: Optional[AsyncSession] = None) -> int:
    from app.domain.services.otp import engine as _engine

    async def _run(session: AsyncSession) -> int:
        now = utcnow()
        rows = list((await session.execute(select(PrimaryTransfer).where(
            PrimaryTransfer.status == "pending", PrimaryTransfer.apply_at <= now))).scalars().all())
        done = 0
        for t in rows:
            dev = await get_device(session, t.user_id, t.to_device_id)
            if device_is_trusted(dev):
                await set_primary(session, t.user_id, dev)
                t.status = "applied"
                done += 1
            else:
                t.status = "cancelled"
                t.resolved_by = "target_untrusted"
            t.resolved_at = now
        await session.commit()
        return done

    if db is not None:
        return await _run(db)
    async with _engine._factory() as session:
        return await _run(session)
