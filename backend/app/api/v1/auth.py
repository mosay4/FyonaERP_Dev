from fastapi import APIRouter, Depends, HTTPException, status, Request, UploadFile, File
from sqlalchemy.ext.asyncio import AsyncSession
from datetime import datetime, timezone
from typing import Optional
from uuid import UUID

from app.core.database import get_db
from app.core.logging import get_logger
from app.core.config import settings
from app.core.rate_limiter import RateLimiter
from app.domain.models.auth_models import (
    FirebaseAuthRequest,
    RefreshRequest,
    AuthResponse,
    UserResponse,
    UserUpdateRequest,
    PhoneUpdateRequest,
    TokenResponse,
    RegisterRequest,
    VerifyRegistrationRequest,
    LoginRequest,
    ForgotPasswordRequest,
    VerifyOtpRequest,
    ResetPasswordRequest,
    ChangePasswordRequest,
    OtpSentResponse,
    ResetTokenResponse,
    EmailChangeVerifyRequest,
)
from app.domain.services.auth_service import AuthService
from app.infrastructure.repositories.sql_alchemy_auth_repository import (
    SQLAlchemyOrganizationRepository,
    SQLAlchemyUserRepository,
    SQLAlchemySessionRepository,
    SQLAlchemyRoleRepository,
    SQLAlchemyPendingRegistrationRepository,
)
from app.api.deps import get_current_user_uuid, get_current_session_id

router = APIRouter(tags=["Auth"])
logger = get_logger("auth_api")

# Phone add/update is the most abuse-prone account field: a tight dedicated
# per-user cap sits in front of the global auth middleware limits.
_phone_rate_limiter = RateLimiter(
    requests=max(settings.PHONE_UPDATE_RATE_LIMIT_PER_MINUTE, 1),
    window_seconds=60,
    key_prefix="rl_phone",
)


def _get_auth_service(db: AsyncSession) -> AuthService:
    return AuthService(
        org_repo=SQLAlchemyOrganizationRepository(db),
        user_repo=SQLAlchemyUserRepository(db),
        session_repo=SQLAlchemySessionRepository(db),
        role_repo=SQLAlchemyRoleRepository(db),
        pending_repo=SQLAlchemyPendingRegistrationRepository(db),
    )


def _client_info(request: Request) -> dict:
    ua = request.headers.get("User-Agent")
    if ua and len(ua) > 200:
        ua = ua[:200]
    # Behind nginx/docker the peer is the proxy: prefer X-Forwarded-For.
    ip = None
    fwd = request.headers.get("X-Forwarded-For")
    if fwd:
        ip = fwd.split(",")[0].strip() or None
    if not ip and request.client:
        ip = request.client.host
    device_name = (
        request.headers.get("X-Device-Name")
        or request.headers.get("X-Device-Model")
        or "تطبيق موبايل"
    )
    return {
        "device_name": device_name,
        "device_model": request.headers.get("X-Device-Model"),
        "os_version": request.headers.get("X-Device-OS"),
        "fingerprint": request.headers.get("X-Device-Fingerprint"),
        "ip_address": ip,
        "user_agent": ua,
    }


def _is_routable_ip(ip: Optional[str]) -> bool:
    if not ip:
        return False
    ip = ip.strip()
    if ip.startswith("127.") or ip == "::1":
        return False
    if ip.startswith("10.") or ip.startswith("192.168."):
        return False
    if ip.startswith("172."):
        try:
            second = int(ip.split(".")[1])
            if 16 <= second <= 31:
                return False
        except (ValueError, IndexError):
            return False
    if ":" in ip and (ip.startswith("fc") or ip.startswith("fd")):
        return False
    return True


async def _geo_lookup(ip: Optional[str]) -> dict:
    """Country/region/city for a public IP (best-effort, never blocks).

    Uses the free ip-api.com endpoint with a tight timeout; private/local
    IPs and any failure yield empty fields. Login requires internet
    anyway, so this adds no new connectivity assumption.
    """
    empty: dict = {"country": None, "region": None, "city": None}
    if not _is_routable_ip(ip):
        return empty
    try:
        import httpx

        async with httpx.AsyncClient(timeout=1.5) as client:
            r = await client.get(
                f"http://ip-api.com/json/{ip}",
                params={"fields": "status,country,regionName,city"},
            )
            if r.status_code != 200:
                return empty
            data = r.json()
            if not isinstance(data, dict) or data.get("status") != "success":
                return empty
            return {
                "country": data.get("country"),
                "region": data.get("regionName"),
                "city": data.get("city"),
            }
    except Exception:
        return empty


@router.post("/register", response_model=OtpSentResponse)
async def register(request: RegisterRequest, db: AsyncSession = Depends(get_db)):
    service = _get_auth_service(db)
    try:
        data = await service.register(
            full_name=request.full_name,
            email=request.email,
            password=request.password,
            phone=request.phone,
            organization_name=request.organization_name,
            preferred_usage_mode=request.preferred_usage_mode,
        )
        return OtpSentResponse(**data)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post("/verify-registration", response_model=AuthResponse)
async def verify_registration(
    request: VerifyRegistrationRequest, db: AsyncSession = Depends(get_db)
):
    service = _get_auth_service(db)
    try:
        return await service.verify_registration(
            email=request.email, otp=request.otp
        )
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post("/resend-otp", response_model=OtpSentResponse)
async def resend_otp(
    request: ForgotPasswordRequest, db: AsyncSession = Depends(get_db)
):
    service = _get_auth_service(db)
    try:
        data = await service.resend_registration_otp(request.email)
        return OtpSentResponse(**data)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post("/login", response_model=AuthResponse)
async def login(
    request: LoginRequest,
    http_request: Request,
    db: AsyncSession = Depends(get_db),
):
    service = _get_auth_service(db)
    info = _client_info(http_request)
    try:
        # Check session count before login to detect new device
        from sqlalchemy import select, func
        from app.domain.entities.auth_entities import UserSession
        user = await service._user_repo.get_by_email(request.email.lower())
        prev_count = 0
        if user:
            r = await db.execute(
                select(func.count()).select_from(UserSession).where(
                    UserSession.user_id == user.id, UserSession.is_active.is_(True)
                )
            )
            prev_count = r.scalar() or 0

        # Best-effort geo enrichment for the new session row (fast timeout,
        # never blocks login on failure).
        geo = await _geo_lookup(info["ip_address"])

        result = await service.login(
            email=request.email,
            password=request.password,
            device_name=info["device_name"],
            ip_address=info["ip_address"],
            user_agent=info["user_agent"],
            device_model=info["device_model"],
            os_version=info["os_version"],
            fingerprint=info["fingerprint"],
            country=geo["country"],
            region=geo["region"],
            city=geo["city"],
        )

        # If there were previous active sessions, this is a new device → push notification
        if prev_count > 0 and user:
            from app.domain.services.push_service import notify_user
            await notify_user(
                db,
                user_id=user.id,
                title="تنبيه أمني 🔒",
                body=f"تم تسجيل الدخول إلى حسابك من جهاز جديد ({info['device_name']})",
                action="open_screen",
                action_payload="sessions",
            )

        return result
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(e))


@router.post("/forgot-password", response_model=OtpSentResponse)
async def forgot_password(
    request: ForgotPasswordRequest, db: AsyncSession = Depends(get_db)
):
    service = _get_auth_service(db)
    try:
        data = await service.forgot_password(request.email, purpose=request.purpose)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
    return OtpSentResponse(**data)


@router.post("/verify-otp", response_model=ResetTokenResponse)
async def verify_otp(
    request: VerifyOtpRequest, db: AsyncSession = Depends(get_db)
):
    service = _get_auth_service(db)
    try:
        reset_token = await service.verify_otp(
            email=request.email, otp=request.otp, purpose=request.purpose
        )
        return ResetTokenResponse(reset_token=reset_token, expires_in_seconds=600)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post("/reset-password", response_model=AuthResponse)
async def reset_password(
    request: ResetPasswordRequest, db: AsyncSession = Depends(get_db)
):
    service = _get_auth_service(db)
    try:
        return await service.reset_password(
            reset_token=request.reset_token, new_password=request.new_password
        )
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post("/change-password")
async def change_password(
    request: ChangePasswordRequest,
    http_request: Request,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    service = _get_auth_service(db)
    info = _client_info(http_request)
    try:
        await service.change_password(
            user_id=user_id,
            current_password=request.current_password,
            new_password=request.new_password,
            device_name=info["device_name"],
        )
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
    return {
        "success": True,
        "message": "تم تغيير كلمة المرور، يرجى تسجيل الدخول من جديد",
        "logout_all": True,
    }


@router.post("/email-change-otp")
async def email_change_otp(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    """Send a verification code to the user's CURRENT (old) email.

    The new email is supplied later (at verify time), so the user must prove
    ownership of the inbox currently attached to the account before the email
    can be changed.
    """
    service = _get_auth_service(db)
    user = await service.get_user_by_id(user_id)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated"
        )
    try:
        data = await service.request_email_change(user)
        return OtpSentResponse(
            expires_in_seconds=data["expires_in_seconds"],
            cooldown_seconds=data["cooldown_seconds"],
        )
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post("/email-change-verify")
async def email_change_verify(
    request: EmailChangeVerifyRequest,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    """Verify the OTP sent to the OLD email and apply a new email address."""
    service = _get_auth_service(db)
    user = await service.get_user_by_id(user_id)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated"
        )
    try:
        return await service.verify_email_change(user, request.otp, request.new_email)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post("/firebase", response_model=AuthResponse)
async def firebase_login(request: FirebaseAuthRequest, http_request: Request, db: AsyncSession = Depends(get_db)):
    service = _get_auth_service(db)
    info = _client_info(http_request)
    geo = await _geo_lookup(info["ip_address"])
    try:
        # Check session count before login to detect new device
        from sqlalchemy import select, func
        from app.domain.entities.auth_entities import UserSession, User
        # For Firebase login, we need to find the user first
        # login_with_firebase resolves the user internally, so we check after
        result = await service.login_with_firebase(
            request.id_token, google_id_token=request.google_id_token,
            device_name=info["device_name"],
            ip_address=info["ip_address"],
            user_agent=info["user_agent"],
            device_model=info["device_model"],
            os_version=info["os_version"],
            fingerprint=info["fingerprint"],
            country=geo["country"],
            region=geo["region"],
            city=geo["city"],
        )
        # After successful login, check if there are multiple sessions
        r = await db.execute(
            select(func.count()).select_from(UserSession).where(
                UserSession.user_id == UUID(str(result.user.id)),
                UserSession.is_active.is_(True)
            )
        )
        session_count = r.scalar() or 0
        if session_count > 1:
            from app.domain.services.push_service import notify_user
            await notify_user(
                db,
                user_id=UUID(str(result.user.id)),
                title="تنبيه أمني 🔒",
                body="تم تسجيل الدخول إلى حسابك من جهاز جديد",
                action="open_screen",
                action_payload="sessions",
            )
        return result
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(e))


@router.post("/refresh", response_model=TokenResponse)
async def refresh(request: RefreshRequest, db: AsyncSession = Depends(get_db)):
    service = _get_auth_service(db)
    try:
        return await service.refresh_token(request.refresh_token)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(e))


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(
    request: Request,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    service = _get_auth_service(db)
    refresh_token = request.headers.get("X-Refresh-Token")
    await service.logout(user_id, refresh_token)
    from ...domain.services.employee_presence_service import set_presence
    await set_presence(db, user_id)


@router.get("/me", response_model=UserResponse)
async def get_me(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    service = _get_auth_service(db)
    user = await service.get_user_by_id(user_id)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="المستخدم غير موجود"
        )
    org = await service._org_repo.get_by_id(user.organization_id)
    return await service.get_user_response(user, org)


@router.put("/me", response_model=UserResponse)
async def update_me(
    request: UserUpdateRequest,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    service = _get_auth_service(db)
    try:
        _payload = request.model_dump(exclude_none=True)
        _org_name = _payload.pop("organization_name", None)
        from sqlalchemy import select as _select0
        from app.domain.entities.auth_entities import User as _User0
        _old_name = (await db.execute(
            _select0(_User0.full_name).where(_User0.id == user_id)
        )).scalar_one_or_none()
        user = await service.update_user(user_id, _payload)
        org = await service._org_repo.get_by_id(user.organization_id)
        _old_org_name = getattr(org, "name", None)
        # Business profile rename also renames the shop (org) so customers,
        # invites, notifications and chat all show the new name.
        if _org_name is not None and org is not None and (org_name := str(_org_name).strip()):
            if (getattr(user, "role", "") or "").lower() in ("owner", "admin", "manager"):
                org.name = org_name
                # Existing UNREAD invite notifications embed the old shop
                # name in their text — rewrite them so the tray/center match.
                try:
                    from app.domain.entities.notification_entities import (
                        AppNotification as _AppNotif)
                    from app.domain.services.merchant_link_service import (
                        _clean_shop_name as _clean)
                    _new_shop = _clean(org.name, user.full_name)
                    _old_shop = _clean(_old_org_name, user.full_name)
                    if _old_shop and _new_shop and _old_shop != _new_shop:
                        _rows = (await db.execute(_select0(_AppNotif).where(
                            _AppNotif.organization_id == user.organization_id,
                            _AppNotif.event_id.like('merchant_invite:%'),
                            _AppNotif.is_read.is_(False),
                        ))).scalars().all()
                        for _r in _rows:
                            _r.message = (_r.message or "").replace(
                                f"التاجر {_old_shop}",
                                f"التاجر {_new_shop}")
                except Exception:
                    pass
        return await service.get_user_response(user, org)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post("/me/phone", response_model=UserResponse)
async def update_my_phone(
    request: PhoneUpdateRequest,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    """Add or replace the caller's phone number.

    The number is validated with libphonenumber (never a hand-rolled regex),
    normalized to E.164, de-duplicated across the platform, and stored with its
    metadata (country, calling code, line type, carrier where known). Only the
    masked number is ever returned — full numbers are never echoed back.
    """
    await _phone_rate_limiter.check(str(user_id))
    service = _get_auth_service(db)
    try:
        user = await service.update_user_phone(
            user_id, request.phone, country=request.country
        )
        org = await service._org_repo.get_by_id(user.organization_id)
        logger.info(
            "phone_updated",
            user_id=str(user_id),
            country=user.phone_country,
            type=user.phone_type,
        )
        return await service.get_user_response(user, org)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.get("/sessions")
async def get_sessions(
    request: Request,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    service = _get_auth_service(db)
    current_refresh = request.headers.get("X-Refresh-Token")
    sessions = await service.get_active_sessions(user_id, current_refresh)
    return sessions


@router.post("/sessions/logout")
async def logout_session(
    request: Request,
    user_id: UUID = Depends(get_current_user_uuid),
    caller_sid: Optional[UUID] = Depends(get_current_session_id),
    db: AsyncSession = Depends(get_db),
):
    body = await request.json()
    session_id = body.get("session_id")
    service = _get_auth_service(db)
    if session_id:
        # Management operations require an identifiable caller session:
        # legacy tokens without sid cannot manage other sessions.
        if caller_sid is None:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="فقط الجهاز الرئيسي يمكنه إدارة الجلسات",
            )
        try:
            await service.revoke_session(
                user_id, UUID(str(session_id)), caller_session_id=caller_sid)
        except PermissionError as e:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN, detail=str(e)
            )
        except ValueError as e:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST, detail=str(e)
            )
    return {"success": True, "message": "تم تسجيل الخروج من الجلسة"}


@router.put("/sessions/{session_id}/name")
async def update_session_name(
    session_id: UUID,
    request: Request,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    body = await request.json()
    custom_name = body.get("custom_name", "")
    service = _get_auth_service(db)
    try:
        await service.update_session_custom_name(user_id, session_id, custom_name)
    except ValueError as e:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail=str(e)
        )
    return {"success": True, "message": "تم تحديث اسم الجهاز"}


@router.post("/sessions/logout-all")
async def logout_all_sessions(
    request: Request,
    user_id: UUID = Depends(get_current_user_uuid),
    caller_sid: Optional[UUID] = Depends(get_current_session_id),
    db: AsyncSession = Depends(get_db),
):
    try:
        body = await request.json()
    except Exception:
        body = {}
    exclude_session_id = body.get("exclude_session_id") or (
        str(caller_sid) if caller_sid else None
    )
    service = _get_auth_service(db)
    # Logout-all is a primary-only administrative operation. Without an
    # identifiable caller session it is denied outright (no legacy bypass).
    if caller_sid is None:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="فقط الجهاز الرئيسي يمكنه تسجيل خروج باقي الأجهزة",
        )
    # Only the primary device may wipe other sessions. The caller always
    # keeps its own session (self-logout happens via /sessions/logout).
    caller = await service._session_repo.get(caller_sid)
    if not caller or caller.user_id != user_id or not caller.is_primary:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="فقط الجهاز الرئيسي يمكنه تسجيل خروج باقي الأجهزة",
        )
    # Deactivate every other active session. The caller's own session is
    # always excluded (it defaults to the caller above); the primary row
    # can only ever be the caller's own here, so a sweep can never wipe it.
    # (Legacy path with no resolvable caller keeps the old safeguard below.)
    sessions = await service._session_repo.list_active_for_user(user_id)
    for s in sessions:
        if exclude_session_id and str(s.id) == str(exclude_session_id):
            continue
        if s.is_primary and not exclude_session_id:
            continue  # Don't deactivate primary if no exclude specified
        await service._session_repo.deactivate(s.id)
    # Invalidate old access tokens
    user = await service._user_repo.get_by_id(user_id)
    if user:
        user.tokens_valid_after = datetime.now(timezone.utc)
        await service._user_repo.update(user)
    return {"success": True, "message": "تم تسجيل الخروج من جميع الأجهزة الأخرى"}


@router.post("/me/avatar")
async def upload_my_avatar(
    file: UploadFile = File(...),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    """Upload the profile picture (JPEG/PNG, max 2 MB).

    Stored via the unified storage backend (local disk / MinIO-S3) under
    ``avatars/{user_id}.jpg`` and served back through the authenticated
    ``GET /uploads/...`` files endpoint, so every device fetches the same
    picture (see DELETE below to remove).
    """
    import io

    from PIL import Image

    from app.core.storage import unified_upload

    service = _get_auth_service(db)
    raw = await file.read()
    if not raw or len(raw) > 2 * 1024 * 1024:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="الصورة غير صالحة أو تتجاوز 2 ميجابايت",
        )
    try:
        img = Image.open(io.BytesIO(raw))
        img.verify()
        img = Image.open(io.BytesIO(raw))
        if img.mode in ("RGBA", "LA", "P"):
            bg = Image.new("RGB", img.size, (255, 255, 255))
            bg.paste(img, mask=img.split()[-1] if img.mode in ("RGBA", "LA") else None)
            img = bg
        else:
            img = img.convert("RGB")
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="ملف الصورة غير صالح",
        )
    out = io.BytesIO()
    img.save(out, format="JPEG", quality=88)
    # Unified backend (MinIO/S3 in prod, local disk otherwise). If the
    # configured remote backend is unreachable (e.g. local dev without
    # MinIO), fall back to local disk so avatars keep working — the files
    # endpoint reads local disk first anyway.
    #
    # The public URL carries a `?v=` timestamp: every upload changes the
    # URL, so other devices (and HTTP caches) always fetch the NEW
    # picture instead of trusting a stale identical path.
    from datetime import datetime as _dt, timezone as _tz

    version = int(_dt.now(_tz.utc).timestamp())
    try:
        from app.core.storage import unified_upload

        rel_path = await unified_upload(
            "avatars", f"{user_id}.jpg", out.getvalue(), "image/jpeg"
        )
    except Exception:
        from app.core.paths import UPLOAD_ROOT
        from app.core.storage import LocalStorage

        rel_path = await LocalStorage(UPLOAD_ROOT).upload(
            f"avatars/{user_id}.jpg", io.BytesIO(out.getvalue()), "image/jpeg"
        )
    user = await service._user_repo.get_by_id(user_id)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="المستخدم غير موجود"
        )
    user.avatar = f"uploads/{rel_path}?v={version}"
    await service._user_repo.update(user)
    await db.commit()
    from app.api.responses import ok as _ok

    # Wake the user's OTHER devices so they fetch the new picture without
    # waiting for a profile open (silent data event; best-effort, never
    # blocks this response).
    try:
        from app.domain.services.push_service import notify_avatar_updated

        await notify_avatar_updated(db, user_id=user_id, avatar=user.avatar)
    except Exception:
        pass
    return _ok(data={"avatar": user.avatar}, message="تم تحديث الصورة الشخصية")


@router.post("/me/organization/avatar")
async def upload_my_org_avatar(
    file: UploadFile = File(...),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    """Business-profile picture (separate from the personal avatar)."""
    import io
    from datetime import datetime as _dt, timezone as _tz

    from PIL import Image

    from app.core.storage import unified_upload

    service = _get_auth_service(db)
    user = await service._user_repo.get_by_id(user_id)
    if not user:
        raise HTTPException(status_code=404, detail="المستخدم غير موجود")
    if (user.role or "").lower() not in ("owner", "admin", "manager"):
        raise HTTPException(status_code=403,
                            detail="ليست لديك صلاحية تعديل صورة المتجر")
    org = await service._org_repo.get_by_id(user.organization_id)
    if not org:
        raise HTTPException(status_code=404, detail="المتجر غير موجود")
    raw = await file.read()
    if not raw or len(raw) > 2 * 1024 * 1024:
        raise HTTPException(
            status_code=400,
            detail="الصورة غير صالحة أو تتجاوز 2 ميجابايت")
    try:
        img = Image.open(io.BytesIO(raw))
        img.verify()
        img = Image.open(io.BytesIO(raw))
        if img.mode in ("RGBA", "LA", "P"):
            bg = Image.new("RGB", img.size, (255, 255, 255))
            bg.paste(img, mask=img.split()[-1]
                     if img.mode in ("RGBA", "LA") else None)
            img = bg
        else:
            img = img.convert("RGB")
    except Exception:
        raise HTTPException(status_code=400, detail="ملف الصورة غير صالح")
    out = io.BytesIO()
    img.save(out, format="JPEG", quality=88)
    version = int(_dt.now(_tz.utc).timestamp())
    try:
        rel_path = await unified_upload(
            "org_avatars", f"{org.id}.jpg", out.getvalue(), "image/jpeg")
    except Exception:
        from app.core.paths import UPLOAD_ROOT
        from app.core.storage import LocalStorage

        rel_path = await LocalStorage(UPLOAD_ROOT).upload(
            f"org_avatars/{org.id}.jpg", io.BytesIO(out.getvalue()),
            "image/jpeg")
    org.avatar = f"uploads/{rel_path}?v={version}"
    await db.commit()
    from app.api.responses import ok as _ok

    return _ok(data={"avatar": org.avatar},
               message="تم تحديث صورة المتجر")


@router.delete("/me/avatar")
async def delete_my_avatar(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    """Remove the profile picture everywhere (storage + user row)."""
    from app.core.storage import unified_delete

    service = _get_auth_service(db)
    try:
        await unified_delete(f"avatars/{user_id}.jpg")
    except Exception:
        try:
            from app.core.paths import UPLOAD_ROOT
            from app.core.storage import LocalStorage

            await LocalStorage(UPLOAD_ROOT).delete(f"avatars/{user_id}.jpg")
        except Exception:
            pass
    user = await service._user_repo.get_by_id(user_id)
    if user:
        user.avatar = None
        await service._user_repo.update(user)
        await db.commit()
    from app.api.responses import ok as _ok

    return _ok(message="تم حذف الصورة الشخصية")
