"""Auth v2 API (/api/v1/auth2) — see docs/AUTH_PLAN.md "API contract v2".

Phone + password accounts, WhatsApp-first OTP (SMS fallback by rule),
device-bound keys (ECDSA P-256 proofs over server nonces), trusted devices,
primary-device approvals, Google / Apple sign-in, phone change, password
reset, recovery (48 h primary claim), account deletion, admin metrics.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any, Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_session_id, get_current_user_uuid, require_platform_admin
from app.core.config import settings
from app.core.database import get_db
from app.core.logging import get_logger
from app.core.rate_limiter import RateLimiter
from app.core.security import (
    burn_password_check,
    hash_password,
    hash_refresh_token,
    password_needs_rehash,
    verify_password,
)
from app.domain.entities.auth2_entities import (
    AuthIdentity,
    OtpChallenge,
    OtpDelivery,
    PrimaryTransfer,
)
from app.domain.entities.auth_entities import User, UserSession
from app.domain.services import auth2_service as a2
from app.domain.services import device_proof, social_auth
from app.domain.services.auth2_service import AuthError
from app.domain.services.auth_service import AuthService, SessionLimitReached
from app.domain.services.otp import costs, engine, providers
from app.domain.services.otp.engine import OtpError
from app.domain.services.otp.secrets_box import (
    decrypt,
    decrypt_json,
    encrypt,
    mask_e164,
    phone_hash,
)
from app.infrastructure.repositories.sql_alchemy_auth_repository import (
    SQLAlchemyOrganizationRepository,
    SQLAlchemyPendingRegistrationRepository,
    SQLAlchemyRoleRepository,
    SQLAlchemySessionRepository,
    SQLAlchemyUserRepository,
)

router = APIRouter()
logger = get_logger("auth2_api")

VERIFICATION_TTL = 600
SOCIAL_SESSION_TTL = 900

_password_limiter = RateLimiter(
    requests=max(settings.AUTH_PASSWORD_MAX_FAILURES_PER_15MIN, 1),
    window_seconds=900, key_prefix="rl_auth2_pw")


def _svc(db: AsyncSession) -> AuthService:
    return AuthService(
        org_repo=SQLAlchemyOrganizationRepository(db),
        user_repo=SQLAlchemyUserRepository(db),
        session_repo=SQLAlchemySessionRepository(db),
        role_repo=SQLAlchemyRoleRepository(db),
        pending_repo=SQLAlchemyPendingRegistrationRepository(db),
    )


def _raise(err: Exception):
    if isinstance(err, (AuthError, OtpError)):
        raise HTTPException(status_code=err.status, detail=err.detail())
    raise err


def _ip(request: Request) -> Optional[str]:
    fwd = request.headers.get("X-Forwarded-For")
    if fwd:
        return fwd.split(",")[0].strip()[:64] or None
    return request.client.host[:64] if request.client else None


def _locale(request: Request, body_locale: Optional[str] = None) -> str:
    return a2.locale_of(body_locale, request.headers.get("X-App-Language")
                        or request.headers.get("Accept-Language"))


async def _location_hint(ip: Optional[str]) -> Optional[str]:
    try:
        from app.api.v1 import auth as legacy

        geo = await legacy._geo_lookup(ip)
    except Exception:  # noqa: BLE001
        return None
    parts = [p for p in (geo.get("city"), geo.get("country")) if p]
    return ", ".join(parts) or None


# ── Request bodies ──
class DeviceIn(BaseModel):
    id: str
    public_key: str
    name: Optional[str] = None
    model: Optional[str] = None
    os: Optional[str] = None
    os_version: Optional[str] = None
    app_version: Optional[str] = None


class NonceIn(BaseModel):
    device_id: str


class RegisterStartIn(BaseModel):
    full_name: str
    phone_e164: str
    password: str
    password_confirm: Optional[str] = None
    device: DeviceIn
    idempotency_key: Optional[str] = Field(default=None, max_length=100)
    locale: Optional[str] = None


class ChallengeIn(BaseModel):
    challenge_id: str


class ResendIn(BaseModel):
    challenge_id: str
    channel: Optional[str] = None


class VerifyIn(BaseModel):
    challenge_id: str
    code: str
    nonce: Optional[str] = None
    signature: Optional[str] = None


class LoginIn(BaseModel):
    phone_e164: str
    password: str
    device: DeviceIn
    nonce: Optional[str] = None
    signature: Optional[str] = None
    locale: Optional[str] = None


class LoginVerifyStartIn(BaseModel):
    verification_id: str
    channel: str


class SocialIn(BaseModel):
    provider: str
    id_token: str
    authorization_code: Optional[str] = None
    nonce: Optional[str] = None
    # Apple: raw string whose SHA-256 hex is the token's nonce claim (when
    # absent, the device nonce itself is expected there).
    raw_nonce: Optional[str] = Field(default=None, max_length=200)
    full_name: Optional[str] = None
    device: DeviceIn
    signature: Optional[str] = None
    locale: Optional[str] = None


class SocialPhoneStartIn(BaseModel):
    social_session: str
    phone_e164: str
    idempotency_key: Optional[str] = Field(default=None, max_length=100)
    full_name: Optional[str] = None
    locale: Optional[str] = None


class SocialLinkIn(BaseModel):
    provider: str
    id_token: str
    authorization_code: Optional[str] = None
    nonce: Optional[str] = None
    raw_nonce: Optional[str] = Field(default=None, max_length=200)


class RefreshIn(BaseModel):
    refresh_token: str
    device_id: str
    nonce: Optional[str] = None
    signature: Optional[str] = None


class ProofIn(BaseModel):
    nonce: Optional[str] = None
    signature: Optional[str] = None


class RenameIn(BaseModel):
    name: str = Field(default="", max_length=100)


class PhoneChangeStartIn(BaseModel):
    new_phone_e164: str
    password: Optional[str] = None
    nonce: Optional[str] = None
    signature: Optional[str] = None
    idempotency_key: Optional[str] = Field(default=None, max_length=100)
    locale: Optional[str] = None


class PhoneChangeVerifyIn(BaseModel):
    challenge_id: str
    code: str


class ForgotIn(BaseModel):
    phone_e164: str
    device: Optional[DeviceIn] = None
    idempotency_key: Optional[str] = Field(default=None, max_length=100)
    locale: Optional[str] = None


class ResetIn(BaseModel):
    challenge_id: str
    code: str
    new_password: str


class AccountDeleteIn(BaseModel):
    password: Optional[str] = None
    nonce: Optional[str] = None
    signature: Optional[str] = None


class BudgetIn(BaseModel):
    daily_usd: Optional[float] = Field(default=None, ge=0, le=10000)
    monthly_usd: Optional[float] = Field(default=None, ge=0, le=100000)


class BudgetsIn(BaseModel):
    sms: Optional[BudgetIn] = None
    whatsapp: Optional[BudgetIn] = None
    global_: Optional[BudgetIn] = Field(default=None, alias="global")


# ── Shared helpers ──
def _start_view(view: dict) -> dict:
    return {k: view[k] for k in ("challenge_id", "channel", "status", "resend_after",
                                 "expires_in", "can_request_sms")}


async def _otp_started(db: AsyncSession, ch: OtpChallenge) -> dict:
    view = await engine.status_view(db, ch)
    await db.commit()
    engine.kick(ch.id)
    return _start_view(view)


async def _issue(db: AsyncSession, request: Request, user: User, dev) -> dict:
    """Tokens + session for a trusted device (3-device cap enforced)."""
    from app.api.v1.auth import _client_info

    info = _client_info(request)
    svc = _svc(db)
    try:
        resp = await svc._generate_auth_response(
            user, device_name=dev.custom_name or dev.name or info["device_name"],
            ip_address=info["ip_address"], user_agent=info["user_agent"],
            device_model=dev.model or info["device_model"],
            os_version=" ".join(x for x in (dev.os, dev.os_version) if x) or info["os_version"],
            fingerprint=dev.device_id,
        )
    except SessionLimitReached as exc:
        raise AuthError("device_limit", 409, extra={"limit": exc.limit})
    now = a2.utcnow()
    user.last_login_at = now
    dev.last_seen = now
    await a2.sync_session_primary(db, user.id)
    out = resp.model_dump()
    out["device"] = {"device_id": dev.device_id, "is_primary": bool(dev.is_primary),
                     "trusted": a2.device_is_trusted(dev)}
    return out


async def _proof(db: AsyncSession, *, public_key: str, device_id: str, purpose: str,
                 nonce: Optional[str], signature: Optional[str]) -> None:
    if not await device_proof.check_proof(db, public_key_b64=public_key, device_id=device_id,
                                          purpose=purpose, nonce=nonce, signature=signature):
        raise AuthError("invalid_device_proof", 401)


async def _caller(db: AsyncSession, request: Request, user_id: UUID,
                  sid: Optional[UUID], *, require_trusted: bool = True):
    """The calling device: X-Device-Id must match the session's device."""
    device_id = (request.headers.get("X-Device-Id") or "").strip()
    if not device_id or sid is None:
        raise AuthError("device_not_trusted", 403)
    session = await db.get(UserSession, sid)
    if session is None or session.user_id != user_id or session.fingerprint != device_id:
        raise AuthError("device_not_trusted", 403)
    dev = await a2.get_device(db, user_id, device_id)
    if require_trusted and not a2.device_is_trusted(dev):
        raise AuthError("device_revoked" if dev and dev.revoked_at else "device_not_trusted", 403)
    return dev


async def _needs_verification(db: AsyncSession, user: User, dev_payload: dict,
                              method: str) -> JSONResponse:
    trusted = [d for d in await a2.trusted_devices(db, user.id)
               if d.device_id != dev_payload["id"]]
    prim = next((d for d in trusted if d.is_primary), None)
    options = (["device"] if trusted else []) + ["whatsapp"]
    token = a2.make_token("login_verif", {"sub": str(user.id), "dev": dev_payload,
                                          "method": method}, VERIFICATION_TTL)
    return JSONResponse(status_code=202, content={
        "needs_verification": True,
        "verification_id": token,
        "options": options,
        "primary_device": ({"name": prim.custom_name or prim.name, "model": prim.model}
                           if prim else None),
        "expires_in": VERIFICATION_TTL,
    })


async def _ensure_slot(db: AsyncSession, user: User, device_id: str) -> None:
    try:
        await _svc(db).ensure_session_slot(user.id, device_id)
    except SessionLimitReached as exc:
        raise AuthError("device_limit", 409, extra={"limit": exc.limit})


# ── Device nonce ──
@router.post("/device/nonce")
async def device_nonce(body: NonceIn, db: AsyncSession = Depends(get_db)):
    if not device_proof.valid_device_id(body.device_id):
        _raise(AuthError("invalid_device"))
    nonce, ttl = await device_proof.issue_nonce(db, body.device_id)
    return {"nonce": nonce, "expires_in": ttl}


# ── Registration ──
@router.post("/register/start")
async def register_start(body: RegisterStartIn, request: Request,
                         db: AsyncSession = Depends(get_db)):
    try:
        name = a2.check_name(body.full_name)
        a2.check_password_policy(body.password)
        if body.password_confirm is not None and body.password_confirm != body.password:
            raise AuthError("weak_password", extra={"reason": "mismatch"})
        info = a2.normalize(body.phone_e164)
        dev = a2.parse_device(body.device.model_dump())
        if await a2.phone_in_use(db, info.e164):
            raise AuthError("phone_taken", 409, extra={"hint": "login"})
        payload = {"kind": "register", "full_name": name,
                   "password_hash": hash_password(body.password), "device": dev}
        ch = await engine.start(
            db, purpose="signup", phone_e164=info.e164, locale=_locale(request, body.locale),
            ip=_ip(request), device_id=dev["id"], idempotency_key=body.idempotency_key,
            payload=payload, country=info.country)
        return await _otp_started(db, ch)
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/otp/status")
async def otp_status(body: ChallengeIn, db: AsyncSession = Depends(get_db)):
    ch = await engine.get(db, body.challenge_id)
    if ch is None:
        _raise(OtpError("otp_not_found", 404))
    return await engine.status_view(db, ch)


@router.post("/otp/resend")
async def otp_resend(body: ResendIn, db: AsyncSession = Depends(get_db)):
    ch = await engine.get(db, body.challenge_id, lock=True)
    if ch is None:
        _raise(OtpError("otp_not_found", 404))
    try:
        has_trusted = False
        if ch.purpose == "new_device" and ch.user_id:
            has_trusted = any(d.device_id != ch.device_id
                              for d in await a2.trusted_devices(db, ch.user_id))
        if body.channel == "sms" and ch.purpose == "new_device":
            raise OtpError("sms_not_allowed", 409)
        ch = await engine.resend(db, ch, body.channel, has_trusted_device=has_trusted)
        return await _otp_started(db, ch)
    except (AuthError, OtpError) as err:
        _raise(err)


async def _peek_payload(db: AsyncSession, challenge_id: str, purpose: str, kind: str):
    ch = await engine.get(db, challenge_id)
    if ch is None or ch.purpose != purpose:
        raise OtpError("otp_not_found", 404)
    payload = decrypt_json(ch.payload_enc)
    if ch.status in engine.TERMINAL or not payload or payload.get("kind") != kind:
        if ch.status == "verified":
            raise OtpError("otp_already_used", 409)
        if ch.status in ("expired", "locked"):
            raise OtpError(f"otp_{ch.status}", 410 if ch.status == "expired" else 423)
        raise OtpError("otp_not_found", 404)
    return ch, payload


@router.post("/register/verify")
async def register_verify(body: VerifyIn, request: Request, db: AsyncSession = Depends(get_db)):
    try:
        _ch, payload = await _peek_payload(db, body.challenge_id, "signup", "register")
        dev = payload["device"]
        await _proof(db, public_key=dev["public_key"], device_id=dev["id"],
                     purpose="register_verify", nonce=body.nonce, signature=body.signature)
        ch, payload, phone = await engine.verify(db, body.challenge_id, body.code,
                                                 purposes={"signup"})
        info = a2.normalize(phone)
        if await a2.phone_in_use(db, info.e164):
            raise AuthError("phone_taken", 409, extra={"hint": "login"})
        try:
            user = await a2.create_account(
                db, _svc(db), full_name=payload["full_name"], info=info,
                password_hash=payload["password_hash"], locale=ch.locale, auth_provider="phone")
        except IntegrityError:
            raise AuthError("phone_taken", 409, extra={"hint": "login"})
        device = await a2.trust_device(db, user.id, dev, ip=_ip(request))
        return await _issue(db, request, user, device)
    except (AuthError, OtpError) as err:
        _raise(err)


# ── Login ──
@router.post("/login")
async def login(body: LoginIn, request: Request, db: AsyncSession = Depends(get_db)):
    try:
        info = a2.normalize(body.phone_e164)
        dev = a2.parse_device(body.device.model_dump())
        try:
            await _password_limiter.check(phone_hash(info.e164))
        except HTTPException:
            raise AuthError("invalid_credentials", 429, retry_after=900)
        user = await a2.user_by_phone(db, info.e164)
        if user is None:
            burn_password_check(body.password)
            raise AuthError("invalid_credentials", 401)
        if not verify_password(body.password, user.password_hash):
            raise AuthError("invalid_credentials", 401)
        if user.status != "active":
            raise AuthError("account_inactive", 403)
        if password_needs_rehash(user.password_hash):
            user.password_hash = hash_password(body.password)
        await _ensure_slot(db, user, dev["id"])
        existing = await a2.get_device(db, user.id, dev["id"])
        if (a2.device_is_trusted(existing) and existing.key_fingerprint == dev["key_fp"]
                and body.signature and await device_proof.check_proof(
                    db, public_key_b64=existing.public_key, device_id=dev["id"],
                    purpose="login", nonce=body.nonce, signature=body.signature)):
            for field in ("name", "model", "os", "os_version", "app_version"):
                if dev.get(field):
                    setattr(existing, field, dev[field])
            existing.last_ip = _ip(request)
            return await _issue(db, request, user, existing)
        logger.info("auth2_login_needs_verification", user_id=str(user.id))
        return await _needs_verification(db, user, dev, "password")
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/login/verify/start")
async def login_verify_start(body: LoginVerifyStartIn, request: Request,
                             db: AsyncSession = Depends(get_db)):
    try:
        tok = a2.read_token("login_verif", body.verification_id)
        user = await db.get(User, UUID(tok["sub"]))
        if user is None or user.status != "active" or not user.phone_e164:
            raise AuthError("verification_expired", 401)
        dev = tok["dev"]
        if body.channel not in ("device", "whatsapp"):
            raise (OtpError("sms_not_allowed", 409) if body.channel == "sms"
                   else OtpError("channel_not_allowed"))
        if body.channel == "device":
            others = [d for d in await a2.trusted_devices(db, user.id) if d.device_id != dev["id"]]
            if not others:
                raise OtpError("channel_not_allowed")
        ip = _ip(request)
        context = {"device": {k: dev.get(k) for k in ("name", "model", "os", "os_version")},
                   "location_hint": await _location_hint(ip)}
        ch = await engine.start(
            db, purpose="new_device", phone_e164=user.phone_e164, channel=body.channel,
            locale=user.preferred_language or "ar", user_id=user.id, ip=ip,
            device_id=dev["id"], idempotency_key=f"lv:{tok['jti']}:{body.channel}",
            payload={"kind": "login", "device": dev, "user_id": str(user.id),
                     "method": tok.get("method")},
            context=context, country=user.phone_country)
        return await _otp_started(db, ch)
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/login/verify")
async def login_verify(body: VerifyIn, request: Request, db: AsyncSession = Depends(get_db)):
    try:
        _ch, payload = await _peek_payload(db, body.challenge_id, "new_device", "login")
        dev = payload["device"]
        await _proof(db, public_key=dev["public_key"], device_id=dev["id"],
                     purpose="login_verify", nonce=body.nonce, signature=body.signature)
        ch, payload, _phone = await engine.verify(db, body.challenge_id, body.code,
                                                  purposes={"new_device"})
        user = await db.get(User, UUID(payload["user_id"]))
        if user is None or user.status != "active":
            raise AuthError("account_inactive", 403)
        await _ensure_slot(db, user, dev["id"])
        device = await a2.trust_device(db, user.id, dev, ip=_ip(request))
        result = await _issue(db, request, user, device)
        await _notify_user(db, user.id, "تسجيل دخول من جهاز جديد",
                           f"تم توثيق جهاز جديد على حسابك ({device.name or device.model or ''}).")
        return result
    except (AuthError, OtpError) as err:
        _raise(err)


async def _notify_user(db: AsyncSession, user_id: UUID, title: str, body: str) -> None:
    try:
        from app.domain.services.push_service import notify_user

        await notify_user(db, user_id=user_id, title=title, body=body,
                          action="open_screen", action_payload="security_devices")
    except Exception:  # noqa: BLE001 - notifications never fail the flow
        pass


# ── Social ──
async def _verify_social(provider: str, id_token: str, nonce: Optional[str]):
    try:
        if provider == "google":
            return await social_auth.verify_google(id_token, nonce)
        if provider == "apple":
            return await social_auth.verify_apple(id_token, nonce)
    except social_auth.SocialTokenError as exc:
        raise AuthError(exc.code, 503 if exc.code == "jwks_unavailable" else 401)
    raise AuthError("provider_not_supported")


@router.post("/social")
async def social(body: SocialIn, request: Request, db: AsyncSession = Depends(get_db)):
    try:
        dev = a2.parse_device(body.device.model_dump())
        if body.nonce and not await device_proof.consume_nonce(db, body.nonce, dev["id"]):
            raise AuthError("invalid_nonce", 401)
        ident = await _verify_social(body.provider, body.id_token, body.raw_nonce or body.nonce)
        row = (await db.execute(select(AuthIdentity).where(
            AuthIdentity.provider == ident.provider,
            AuthIdentity.subject == ident.subject))).scalar_one_or_none()
        if row is not None:
            user = await db.get(User, row.user_id)
            if user is None or user.status != "active":
                raise AuthError("account_inactive", 403)
            row.last_login_at = a2.utcnow()
            if ident.provider == "apple" and body.authorization_code and not row.refresh_token_enc:
                rt = await social_auth.apple_exchange_code(body.authorization_code)
                if rt:
                    row.refresh_token_enc = encrypt(rt)
            await _ensure_slot(db, user, dev["id"])
            existing = await a2.get_device(db, user.id, dev["id"])
            if (a2.device_is_trusted(existing) and existing.key_fingerprint == dev["key_fp"]
                    and body.signature and device_proof.verify_signature(
                        existing.public_key, body.nonce or "", dev["id"], "social",
                        body.signature)):
                return await _issue(db, request, user, existing)
            return await _needs_verification(db, user, dev, ident.provider)
        name = None
        if body.full_name:
            try:
                name = a2.check_name(body.full_name)
            except AuthError:
                name = None
        name = name or (ident.name and " ".join(ident.name.split())[:200]) or None
        rt_enc = None
        if ident.provider == "apple" and body.authorization_code:
            rt = await social_auth.apple_exchange_code(body.authorization_code)
            rt_enc = encrypt(rt) if rt else None
        session = a2.make_token("social_session", {
            "provider": ident.provider, "subject": ident.subject, "email": ident.email,
            "email_verified": ident.email_verified, "private": ident.is_private_email,
            "name": name, "rt": rt_enc, "dev": dev,
        }, SOCIAL_SESSION_TTL)
        return {"needs_phone": True, "social_session": session, "name_required": not name,
                "expires_in": SOCIAL_SESSION_TTL}
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/social/phone/start")
async def social_phone_start(body: SocialPhoneStartIn, request: Request,
                             db: AsyncSession = Depends(get_db)):
    try:
        tok = a2.read_token("social_session", body.social_session)
        name = tok.get("name")
        if body.full_name:
            name = a2.check_name(body.full_name)
        if not name:
            raise AuthError("invalid_name")
        info = a2.normalize(body.phone_e164)
        if await a2.phone_in_use(db, info.e164):
            raise AuthError("phone_taken", 409, extra={"hint": "login_then_link"})
        linked = (await db.execute(select(AuthIdentity.id).where(
            AuthIdentity.provider == tok["provider"],
            AuthIdentity.subject == tok["subject"]))).first()
        if linked:
            raise AuthError("identity_linked", 409)
        payload = {"kind": "social", "full_name": name, "device": tok["dev"],
                   "identity": {k: tok.get(k) for k in ("provider", "subject", "email",
                                                        "email_verified", "private", "rt")}}
        ch = await engine.start(
            db, purpose="signup", phone_e164=info.e164, locale=_locale(request, body.locale),
            ip=_ip(request), device_id=tok["dev"]["id"], idempotency_key=body.idempotency_key,
            payload=payload, country=info.country)
        return await _otp_started(db, ch)
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/social/phone/verify")
async def social_phone_verify(body: VerifyIn, request: Request, db: AsyncSession = Depends(get_db)):
    try:
        _ch, payload = await _peek_payload(db, body.challenge_id, "signup", "social")
        dev = payload["device"]
        await _proof(db, public_key=dev["public_key"], device_id=dev["id"],
                     purpose="social_phone_verify", nonce=body.nonce, signature=body.signature)
        ch, payload, phone = await engine.verify(db, body.challenge_id, body.code,
                                                 purposes={"signup"})
        info = a2.normalize(phone)
        if await a2.phone_in_use(db, info.e164):
            raise AuthError("phone_taken", 409, extra={"hint": "login_then_link"})
        ident = payload["identity"]
        try:
            user = await a2.create_account(
                db, _svc(db), full_name=payload["full_name"], info=info, password_hash=None,
                locale=ch.locale, auth_provider=ident["provider"], email=ident.get("email"),
                email_verified=bool(ident.get("email_verified")))
            db.add(AuthIdentity(user_id=user.id, provider=ident["provider"],
                                subject=ident["subject"], email=ident.get("email"),
                                email_verified=bool(ident.get("email_verified")),
                                is_private_email=bool(ident.get("private")),
                                refresh_token_enc=ident.get("rt"), last_login_at=a2.utcnow()))
            await db.flush()
        except IntegrityError:
            raise AuthError("identity_linked", 409)
        device = await a2.trust_device(db, user.id, dev, ip=_ip(request))
        return await _issue(db, request, user, device)
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/social/link")
async def social_link(body: SocialLinkIn, request: Request,
                      user_id: UUID = Depends(get_current_user_uuid),
                      sid: Optional[UUID] = Depends(get_current_session_id),
                      db: AsyncSession = Depends(get_db)):
    """Link Google/Apple to the signed-in (phone-verified) account from a
    trusted device."""
    try:
        caller = await _caller(db, request, user_id, sid)
        if body.nonce and not await device_proof.consume_nonce(db, body.nonce, caller.device_id):
            raise AuthError("invalid_nonce", 401)
        user = await db.get(User, user_id)
        if user is None or not user.phone_e164:
            raise AuthError("reauth_required", 403)
        ident = await _verify_social(body.provider, body.id_token, body.raw_nonce or body.nonce)
        exists = (await db.execute(select(AuthIdentity).where(
            AuthIdentity.provider == ident.provider,
            AuthIdentity.subject == ident.subject))).scalar_one_or_none()
        if exists is not None:
            if exists.user_id != user_id:
                raise AuthError("identity_linked", 409)
            return {"linked": True, "provider": ident.provider}
        rt = None
        if ident.provider == "apple" and body.authorization_code:
            rt = await social_auth.apple_exchange_code(body.authorization_code)
        db.add(AuthIdentity(user_id=user_id, provider=ident.provider, subject=ident.subject,
                            email=ident.email, email_verified=ident.email_verified,
                            is_private_email=ident.is_private_email,
                            refresh_token_enc=encrypt(rt) if rt else None))
        try:
            await db.flush()
        except IntegrityError:
            raise AuthError("identity_linked", 409)
        return {"linked": True, "provider": ident.provider}
    except (AuthError, OtpError) as err:
        _raise(err)


# ── Refresh (device-bound) ──
@router.post("/refresh")
async def refresh(body: RefreshIn, request: Request, db: AsyncSession = Depends(get_db)):
    try:
        session = (await db.execute(select(UserSession).where(
            UserSession.refresh_token == hash_refresh_token(body.refresh_token)))).scalar_one_or_none()
        if session is None or not session.is_active:
            raise AuthError("verification_expired", 401)
        if session.fingerprint != body.device_id:
            raise AuthError("device_not_trusted", 401)
        dev = await a2.get_device(db, session.user_id, body.device_id)
        if not a2.device_is_trusted(dev):
            raise AuthError("device_revoked", 401)
        await _proof(db, public_key=dev.public_key, device_id=dev.device_id, purpose="refresh",
                     nonce=body.nonce, signature=body.signature)
        from app.api.v1.auth import _client_info

        info = _client_info(request)
        try:
            tokens = await _svc(db).refresh_token(body.refresh_token,
                                                  ip_address=info["ip_address"],
                                                  user_agent=info["user_agent"])
        except ValueError:
            raise AuthError("verification_expired", 401)
        dev.last_seen = a2.utcnow()
        dev.last_ip = info["ip_address"]
        out = tokens.model_dump()
        out["device"] = {"device_id": dev.device_id, "is_primary": bool(dev.is_primary),
                         "trusted": True}
        return out
    except (AuthError, OtpError) as err:
        _raise(err)


# ── Primary-device approvals ──
async def _approval(db: AsyncSession, user_id: UUID, approval_id: str) -> OtpChallenge:
    ch = await engine.get(db, approval_id, lock=True)
    if (ch is None or ch.user_id != user_id or ch.purpose != "new_device"
            or ch.channel != "device" or ch.status in engine.TERMINAL
            or ch.status_reason == "denied"):
        raise AuthError("approval_not_found", 404)
    if engine._aw(ch.expires_at) <= engine.utcnow():
        raise AuthError("approval_not_found", 404)
    return ch


@router.get("/approvals/pending")
async def approvals_pending(request: Request, user_id: UUID = Depends(get_current_user_uuid),
                            sid: Optional[UUID] = Depends(get_current_session_id),
                            db: AsyncSession = Depends(get_db)):
    try:
        caller = await _caller(db, request, user_id, sid)
        now = engine.utcnow()
        rows = (await db.execute(select(OtpChallenge).where(
            OtpChallenge.user_id == user_id, OtpChallenge.purpose == "new_device",
            OtpChallenge.channel == "device",
            OtpChallenge.status.in_(("queued", "sent", "delivered")),
            OtpChallenge.expires_at > now).order_by(OtpChallenge.created_at.desc()))).scalars().all()
        out = []
        for ch in rows:
            if ch.status_reason == "denied" or ch.device_id == caller.device_id:
                continue
            ctx = ch.context or {}
            out.append({
                "approval_id": str(ch.id),
                "device": ctx.get("device") or {},
                "location_hint": ctx.get("location_hint"),
                "created_at": engine._aw(ch.created_at).isoformat(),
                "expires_at": engine._aw(ch.expires_at).isoformat(),
            })
        return out
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/approvals/{approval_id}/code")
async def approval_code(approval_id: str, body: ProofIn, request: Request,
                        user_id: UUID = Depends(get_current_user_uuid),
                        sid: Optional[UUID] = Depends(get_current_session_id),
                        db: AsyncSession = Depends(get_db)):
    try:
        caller = await _caller(db, request, user_id, sid)
        await _proof(db, public_key=caller.public_key, device_id=caller.device_id,
                     purpose="approval_code", nonce=body.nonce, signature=body.signature)
        ch = await _approval(db, user_id, approval_id)
        if ch.device_id == caller.device_id:
            raise AuthError("approval_not_found", 404)
        code = engine.reveal_code(ch)
        if not code:
            raise AuthError("approval_not_found", 404)
        if ch.status in ("queued", "sent"):
            ch.status = "delivered"
        await engine._event(db, ch.id, "code_fetched", "device")
        logger.info("auth2_approval_code_fetched", user_id=str(user_id))
        return {"code": code, "expires_at": engine._aw(ch.expires_at).isoformat()}
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/approvals/{approval_id}/deny")
async def approval_deny(approval_id: str, request: Request,
                        user_id: UUID = Depends(get_current_user_uuid),
                        sid: Optional[UUID] = Depends(get_current_session_id),
                        db: AsyncSession = Depends(get_db)):
    try:
        await _caller(db, request, user_id, sid)
        ch = await _approval(db, user_id, approval_id)
        await engine.deny(db, ch)
        return {"ok": True}
    except (AuthError, OtpError) as err:
        _raise(err)


# ── Devices ──
@router.get("/devices")
async def devices(request: Request, user_id: UUID = Depends(get_current_user_uuid),
                  sid: Optional[UUID] = Depends(get_current_session_id),
                  db: AsyncSession = Depends(get_db)):
    try:
        caller = await _caller(db, request, user_id, sid, require_trusted=False)
        from app.domain.entities.auth2_entities import AuthDevice

        rows = (await db.execute(select(AuthDevice).where(AuthDevice.user_id == user_id)
                                 .order_by(AuthDevice.created_at))).scalars().all()
        rows = sorted(rows, key=lambda d: (not d.is_primary, d.revoked_at is not None))
        pending = await _pending_transfer(db, user_id)
        out = []
        for d in rows:
            view = a2.device_view(d, caller.device_id if caller else None)
            view["primary_claim_until"] = (engine._aw(pending.apply_at).isoformat()
                                           if pending and pending.to_device_id == d.device_id
                                           else None)
            out.append(view)
        return out
    except (AuthError, OtpError) as err:
        _raise(err)


async def _target(db: AsyncSession, user_id: UUID, device_id: str):
    dev = await a2.get_device(db, user_id, device_id)
    if dev is None:
        raise AuthError("device_not_found", 404)
    return dev


@router.post("/devices/{device_id}/revoke")
async def device_revoke(device_id: str, request: Request,
                        user_id: UUID = Depends(get_current_user_uuid),
                        sid: Optional[UUID] = Depends(get_current_session_id),
                        db: AsyncSession = Depends(get_db)):
    try:
        caller = await _caller(db, request, user_id, sid)
        target = await _target(db, user_id, device_id)
        if target.is_primary:
            raise AuthError("cannot_revoke_primary", 409)
        if target.device_id != caller.device_id and not caller.is_primary:
            raise AuthError("not_primary", 403)
        killed = await a2.revoke_device(db, target)
        from app.api.v1.auth import _retire_relay_devices

        await _retire_relay_devices(db, killed)
        return {"ok": True, "device": a2.device_view(target, caller.device_id)}
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/devices/{device_id}/rename")
async def device_rename(device_id: str, body: RenameIn, request: Request,
                        user_id: UUID = Depends(get_current_user_uuid),
                        sid: Optional[UUID] = Depends(get_current_session_id),
                        db: AsyncSession = Depends(get_db)):
    try:
        caller = await _caller(db, request, user_id, sid)
        target = await _target(db, user_id, device_id)
        if target.device_id != caller.device_id and not caller.is_primary:
            raise AuthError("not_primary", 403)
        name = " ".join((body.name or "").split())[:60] or None
        target.custom_name = name
        sessions = (await db.execute(select(UserSession).where(
            UserSession.user_id == user_id, UserSession.fingerprint == device_id,
            UserSession.is_active.is_(True)))).scalars().all()
        for s in sessions:
            s.custom_name = name
        return a2.device_view(target, caller.device_id)
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/devices/{device_id}/make-primary")
async def device_make_primary(device_id: str, body: ProofIn, request: Request,
                              user_id: UUID = Depends(get_current_user_uuid),
                              sid: Optional[UUID] = Depends(get_current_session_id),
                              db: AsyncSession = Depends(get_db)):
    try:
        caller = await _caller(db, request, user_id, sid)
        if not caller.is_primary:
            raise AuthError("not_primary", 403)
        await _proof(db, public_key=caller.public_key, device_id=caller.device_id,
                     purpose="make_primary", nonce=body.nonce, signature=body.signature)
        target = await _target(db, user_id, device_id)
        if not a2.device_is_trusted(target):
            raise AuthError("device_not_trusted", 409)
        if target.is_primary:
            raise AuthError("already_primary", 409)
        await a2.set_primary(db, user_id, target)
        await _cancel_transfers(db, user_id, by=caller.device_id)
        return {"ok": True, "primary_device_id": target.device_id}
    except (AuthError, OtpError) as err:
        _raise(err)


async def _cancel_transfers(db: AsyncSession, user_id: UUID, by: str) -> int:
    rows = (await db.execute(select(PrimaryTransfer).where(
        PrimaryTransfer.user_id == user_id, PrimaryTransfer.status == "pending"))).scalars().all()
    for t in rows:
        t.status = "cancelled"
        t.resolved_at = a2.utcnow()
        t.resolved_by = by
    return len(rows)


def _transfer_view(t: Optional[PrimaryTransfer]) -> Optional[dict]:
    if t is None:
        return None
    return {"transfer_id": str(t.id), "from_device_id": t.from_device_id,
            "to_device_id": t.to_device_id, "status": t.status,
            "apply_at": engine._aw(t.apply_at).isoformat(),
            "created_at": engine._aw(t.created_at).isoformat() if t.created_at else None}


async def _pending_transfer(db: AsyncSession, user_id: UUID) -> Optional[PrimaryTransfer]:
    return (await db.execute(select(PrimaryTransfer).where(
        PrimaryTransfer.user_id == user_id, PrimaryTransfer.status == "pending")
        .order_by(PrimaryTransfer.created_at.desc()))).scalars().first()


@router.get("/devices/claim-primary")
async def claim_primary_status(request: Request, user_id: UUID = Depends(get_current_user_uuid),
                               sid: Optional[UUID] = Depends(get_current_session_id),
                               db: AsyncSession = Depends(get_db)):
    try:
        await _caller(db, request, user_id, sid)
        return {"pending": _transfer_view(await _pending_transfer(db, user_id))}
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/devices/claim-primary")
async def claim_primary(request: Request, user_id: UUID = Depends(get_current_user_uuid),
                        sid: Optional[UUID] = Depends(get_current_session_id),
                        db: AsyncSession = Depends(get_db)):
    try:
        caller = await _caller(db, request, user_id, sid)
        if caller.is_primary:
            raise AuthError("already_primary", 409)
        pending = await _pending_transfer(db, user_id)
        if pending is not None and pending.to_device_id == caller.device_id:
            return {"pending": _transfer_view(pending),
                    "applies_at": engine._aw(pending.apply_at).isoformat()}
        if pending is not None:
            await _cancel_transfers(db, user_id, by=caller.device_id)
        prim = await a2.primary_device(db, user_id)
        now = a2.utcnow()
        t = PrimaryTransfer(user_id=user_id, from_device_id=prim.device_id if prim else None,
                            to_device_id=caller.device_id, status="pending", created_at=now,
                            apply_at=now + timedelta(hours=settings.AUTH_PRIMARY_TRANSFER_HOURS))
        db.add(t)
        await db.flush()
        await _notify_user(db, user_id, "طلب نقل الجهاز الرئيسي",
                           "طلب جهاز آخر أن يصبح الجهاز الرئيسي لحسابك. "
                           "إذا لم تكن أنت، ألغِ الطلب من إعدادات الأجهزة.")
        return {"pending": _transfer_view(t), "applies_at": engine._aw(t.apply_at).isoformat()}
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/devices/claim-primary/cancel")
async def claim_primary_cancel(request: Request, user_id: UUID = Depends(get_current_user_uuid),
                               sid: Optional[UUID] = Depends(get_current_session_id),
                               db: AsyncSession = Depends(get_db)):
    try:
        caller = await _caller(db, request, user_id, sid)
        pending = await _pending_transfer(db, user_id)
        if pending is None:
            raise AuthError("transfer_not_found", 404)
        if not caller.is_primary and pending.to_device_id != caller.device_id:
            raise AuthError("not_primary", 403)
        await _cancel_transfers(db, user_id, by=caller.device_id)
        return {"ok": True}
    except (AuthError, OtpError) as err:
        _raise(err)


# ── Phone change ──
class ReauthIn(BaseModel):
    password: str = Field(min_length=1, max_length=200)


@router.post("/reauth")
async def reauth(body: ReauthIn, request: Request,
                 user_id: UUID = Depends(get_current_user_uuid),
                 sid: Optional[UUID] = Depends(get_current_session_id),
                 db: AsyncSession = Depends(get_db)):
    """Confirms the account password from a trusted device (app-lock PIN
    reset). No message is sent and nothing is changed."""
    try:
        await _caller(db, request, user_id, sid)
        try:
            await _password_limiter.check(f"reauth:{user_id}")
        except HTTPException:
            raise AuthError("invalid_credentials", 429, retry_after=900)
        user = await db.get(User, user_id)
        if user is None or not user.password_hash:
            raise AuthError("password_not_set", 409)
        if not verify_password(body.password, user.password_hash):
            raise AuthError("invalid_credentials", 401)
        return {"success": True, "data": {"ok": True}}
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/phone/change/start")
async def phone_change_start(body: PhoneChangeStartIn, request: Request,
                             user_id: UUID = Depends(get_current_user_uuid),
                             sid: Optional[UUID] = Depends(get_current_session_id),
                             db: AsyncSession = Depends(get_db)):
    try:
        caller = await _caller(db, request, user_id, sid)
        user = await db.get(User, user_id)
        reauth = False
        if body.password:
            if not verify_password(body.password, user.password_hash):
                raise AuthError("invalid_credentials", 401)
            reauth = True
        if body.signature:
            await _proof(db, public_key=caller.public_key, device_id=caller.device_id,
                         purpose="phone_change", nonce=body.nonce, signature=body.signature)
            reauth = True
        if not reauth:
            raise AuthError("reauth_required", 401)
        info = a2.normalize(body.new_phone_e164)
        if user.phone_e164 == info.e164:
            raise AuthError("same_phone", 409)
        if await a2.phone_in_use(db, info.e164, except_user=user_id):
            raise AuthError("phone_taken", 409)
        ch = await engine.start(
            db, purpose="phone_change", phone_e164=info.e164,
            locale=_locale(request, body.locale or user.preferred_language), user_id=user_id,
            ip=_ip(request), device_id=caller.device_id, idempotency_key=body.idempotency_key,
            payload={"kind": "phone_change", "user_id": str(user_id)}, country=info.country)
        return await _otp_started(db, ch)
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/phone/change/verify")
async def phone_change_verify(body: PhoneChangeVerifyIn, request: Request,
                              user_id: UUID = Depends(get_current_user_uuid),
                              sid: Optional[UUID] = Depends(get_current_session_id),
                              db: AsyncSession = Depends(get_db)):
    try:
        await _caller(db, request, user_id, sid)
        _ch, payload = await _peek_payload(db, body.challenge_id, "phone_change", "phone_change")
        if payload.get("user_id") != str(user_id):
            raise OtpError("otp_not_found", 404)
        ch, payload, phone = await engine.verify(db, body.challenge_id, body.code,
                                                 purposes={"phone_change"})
        info = a2.normalize(phone)
        if await a2.phone_in_use(db, info.e164, except_user=user_id):
            raise AuthError("phone_taken", 409)
        user = await db.get(User, user_id)
        old = user.phone_e164
        a2.apply_verified_phone(user, info, a2.utcnow())
        await a2.release_unverified_phone(db, info.e164, user_id)
        try:
            await db.flush()
        except IntegrityError:
            raise AuthError("phone_taken", 409)
        logger.info("auth2_phone_changed", user_id=str(user_id), old=mask_e164(old),
                    new=mask_e164(info.e164))
        await _notify_user(db, user_id, "تم تغيير رقم الهاتف",
                           "تم تغيير رقم الهاتف المرتبط بحسابك. إذا لم تكن أنت، تواصل مع الدعم فوراً.")
        svc = _svc(db)
        org = await svc._org_repo.get_by_id(user.organization_id)
        return {"user": (await svc.get_user_response(user, org)).model_dump()}
    except (AuthError, OtpError) as err:
        _raise(err)


# ── Password reset ──
@router.post("/password/forgot")
async def password_forgot(body: ForgotIn, request: Request, db: AsyncSession = Depends(get_db)):
    try:
        info = a2.normalize(body.phone_e164)
        device_id = None
        if body.device is not None:
            device_id = a2.parse_device(body.device.model_dump())["id"]
        user = await a2.user_by_phone(db, info.e164)
        if user is None or user.status != "active":
            raise AuthError("account_not_found", 404)
        ch = await engine.start(
            db, purpose="password_reset", phone_e164=info.e164,
            locale=_locale(request, body.locale or user.preferred_language), user_id=user.id,
            ip=_ip(request), device_id=device_id, idempotency_key=body.idempotency_key,
            payload={"kind": "password_reset", "user_id": str(user.id)}, country=info.country)
        return await _otp_started(db, ch)
    except (AuthError, OtpError) as err:
        _raise(err)


@router.post("/password/reset")
async def password_reset(body: ResetIn, db: AsyncSession = Depends(get_db)):
    try:
        a2.check_password_policy(body.new_password)
        _ch, payload = await _peek_payload(db, body.challenge_id, "password_reset",
                                           "password_reset")
        ch, payload, _phone = await engine.verify(db, body.challenge_id, body.code,
                                                  purposes={"password_reset"})
        user = await db.get(User, UUID(payload["user_id"]))
        if user is None or user.status != "active":
            raise AuthError("account_not_found", 404)
        now = a2.utcnow()
        user.password_hash = hash_password(body.new_password)
        user.tokens_valid_after = now
        await _svc(db)._session_repo.deactivate_all_for_user(user.id)
        await _notify_user(db, user.id, "تم تغيير كلمة المرور",
                           "تم تعيين كلمة مرور جديدة لحسابك وتسجيل الخروج من جميع الأجهزة.")
        return {"ok": True, "message_ar": "تم تعيين كلمة المرور. سجّل الدخول من جديد",
                "message_en": "Password updated. Please sign in again."}
    except (AuthError, OtpError) as err:
        _raise(err)


# ── Account deletion (App Store: revokes Sign in with Apple tokens) ──
@router.post("/account/delete")
async def account_delete(body: AccountDeleteIn, request: Request,
                         user_id: UUID = Depends(get_current_user_uuid),
                         sid: Optional[UUID] = Depends(get_current_session_id),
                         db: AsyncSession = Depends(get_db)):
    try:
        caller = await _caller(db, request, user_id, sid)
        user = await db.get(User, user_id)
        await _proof(db, public_key=caller.public_key, device_id=caller.device_id,
                     purpose="account_delete", nonce=body.nonce, signature=body.signature)
        if user.password_hash and not verify_password(body.password or "", user.password_hash):
            raise AuthError("invalid_credentials", 401)
        identities = (await db.execute(select(AuthIdentity).where(
            AuthIdentity.user_id == user_id))).scalars().all()
        apple_revoked = 0
        for ident in identities:
            if ident.provider == "apple" and ident.refresh_token_enc:
                rt = decrypt(ident.refresh_token_enc)
                if rt and await social_auth.apple_revoke(rt):
                    apple_revoked += 1
            await db.delete(ident)
        from app.domain.entities.auth2_entities import AuthDevice

        devs = (await db.execute(select(AuthDevice).where(
            AuthDevice.user_id == user_id))).scalars().all()
        for d in devs:
            await db.delete(d)
        now = a2.utcnow()
        await _svc(db)._session_repo.deactivate_all_for_user(user_id)
        user.status = "deleted"
        user.phone_e164 = None
        user.phone = None
        user.phone_verified_at = None
        user.password_hash = None
        user.email = f"deleted-{user_id.hex}@deleted.fyona.invalid"
        user.tokens_valid_after = now
        logger.info("auth2_account_deleted", user_id=str(user_id), apple_revoked=apple_revoked)
        return {"ok": True}
    except (AuthError, OtpError) as err:
        _raise(err)


# ── Admin ──
@router.get("/admin/otp-metrics")
async def admin_otp_metrics(days: int = Query(1, ge=1, le=31),
                            _: bool = Depends(require_platform_admin),
                            db: AsyncSession = Depends(get_db)):
    since = engine.utcnow() - timedelta(days=days)

    async def grouped(*cols, model=OtpChallenge, where=()):
        q = select(*cols, func.count()).select_from(model).where(model.created_at >= since, *where)
        rows = (await db.execute(q.group_by(*cols))).all()
        return rows

    by_status = {s: n for s, n in await grouped(OtpChallenge.status)}
    by_purpose = {p: n for p, n in await grouped(OtpChallenge.purpose)}
    deliveries: dict[str, dict] = {}
    for ch_, st, n in await grouped(OtpDelivery.channel, OtpDelivery.status, model=OtpDelivery):
        deliveries.setdefault(ch_, {})[st] = n
    failures = [{"channel": c, "error_code": e, "count": n} for c, e, n in sorted(
        await grouped(OtpDelivery.channel, OtpDelivery.error_code, model=OtpDelivery,
                      where=(OtpDelivery.error_code.is_not(None),)),
        key=lambda r: -r[2])[:15]]
    wa = deliveries.get("whatsapp", {})
    wa_accepted = sum(v for k, v in wa.items() if k in ("accepted", "sent", "delivered", "read"))
    wa_delivered = wa.get("delivered", 0) + wa.get("read", 0)
    total_sends = sum(sum(v.values()) for v in deliveries.values())
    sms_sends = sum(deliveries.get("sms", {}).values())
    return {
        "window_days": days,
        "challenges": {"by_status": by_status, "by_purpose": by_purpose,
                       "total": sum(by_status.values())},
        "deliveries": deliveries,
        "whatsapp_delivery_rate": round(wa_delivered / wa_accepted, 4) if wa_accepted else None,
        "sms_share": round(sms_sends / total_sends, 4) if total_sends else None,
        "failure_reasons": failures,
        "spend": await costs.spend_summary(db),
        "config": {
            "whatsapp_configured": bool(providers.get("whatsapp")
                                        and providers.get("whatsapp").configured()),
            "sms_configured": bool(providers.get("sms") and providers.get("sms").configured()),
            "webhook_receipts": engine.webhook_receipts_enabled(),
            "auto_sms_fallback": engine.auto_fallback_active(),
            "delivery_deadline_seconds": settings.AUTH_OTP_DELIVERY_DEADLINE_SECONDS,
            "apple_configured": social_auth.apple_configured(),
        },
    }


@router.put("/admin/otp-budgets")
async def admin_otp_budgets(body: BudgetsIn, user_id: UUID = Depends(get_current_user_uuid),
                            _: bool = Depends(require_platform_admin),
                            db: AsyncSession = Depends(get_db)):
    for channel, value in (("sms", body.sms), ("whatsapp", body.whatsapp),
                           ("global", body.global_)):
        if value is not None:
            await costs.set_budget(db, channel, daily_usd=value.daily_usd,
                                   monthly_usd=value.monthly_usd, by=user_id)
    return {"budgets": await costs.budgets(db)}
