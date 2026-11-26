import re
from typing import Optional
from uuid import UUID, uuid4
from datetime import datetime, timedelta, timezone

from app.domain.entities.auth_entities import (
    Organization,
    User,
    UserSession,
    Role,
    RolePermission,
    PendingRegistration,
)
from app.domain.repositories.auth_repository import (
    OrganizationRepository,
    UserRepository,
    SessionRepository,
    RoleRepository,
    PendingRegistrationRepository,
)
from app.domain.models.auth_models import (
    AuthResponse,
    UserResponse,
    TokenResponse,
)
from app.core.security import (
    create_access_token,
    create_refresh_token,
    decode_token,
    hash_refresh_token,
    hash_password,
    password_needs_rehash,
    verify_password,
    create_reset_token,
    decode_reset_token,
)
from app.core.config import settings
from app.core.logging import get_logger
from app.core import otp_service
from app.core import email_service
from app.core import email_templates
from app.core.phone_validation import normalize_phone, is_valid_phone, mask_phone
from app.domain.services.admin_permissions import (
    admin_permission_codes,
    all_admin_permission_codes,
)
from app.core import firebase as firebase_auth

logger = get_logger("auth_service")


class SessionLimitReached(ValueError):
    """A new device tried to sign in while the account already has the
    maximum number of live sessions (settings.MAX_ACTIVE_SESSIONS)."""

    def __init__(self, limit: int):
        self.limit = limit
        super().__init__(
            f"وصلت إلى الحد الأقصى للأجهزة ({limit} أجهزة) على هذا الحساب. "
            "سجّل الخروج من أحد أجهزتك من «الأمان والخصوصية ← الجلسات والأجهزة» ثم حاول مجدداً، "
            "أو أعد تعيين كلمة المرور لتسجيل الخروج من كل الأجهزة."
        )


def session_limit() -> int:
    return max(int(getattr(settings, "MAX_ACTIVE_SESSIONS", 3) or 3), 1)


_APP_UA = re.compile(r"FyonaERP/(?P<ver>[^\s(]+)(?:\s*\((?P<plat>[^)]*)\))?")


def parse_app_agent(user_agent: Optional[str]) -> tuple[Optional[str], Optional[str]]:
    """(app_version, platform) the app prefixed to the stored user agent."""
    m = _APP_UA.search(user_agent or "")
    if not m:
        return None, None
    plat = (m.group("plat") or "").strip() or None
    return m.group("ver"), plat


def _aware(dt: Optional[datetime]) -> Optional[datetime]:
    if dt is not None and dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt

SYSTEM_ROLES = {
    "super_admin": "مدير المنصة",
    "owner": "مالك",
    "manager": "مدير",
    "employee": "موظف",
    "personal": "مستخدم فردي",
}

# Baseline resource permissions per role
ROLE_PERMISSIONS = {
    "super_admin": {"*": ["create", "read", "update", "delete"]},
    "owner": {
        "*": ["create", "read", "update", "delete"],
        "organizations": ["create", "read", "update", "delete"],
        "users": ["create", "read", "update", "delete"],
        "customers": ["create", "read", "update", "delete"],
        "suppliers": ["create", "read", "update", "delete"],
        "products": ["create", "read", "update", "delete"],
        "invoices": ["create", "read", "update", "delete"],
        "accounts": ["create", "read", "update", "delete"],
        "reports": ["read"],
    },
    "manager": {
        "customers": ["create", "read", "update"],
        "suppliers": ["create", "read", "update"],
        "products": ["create", "read", "update"],
        "inventory": ["create", "read", "update"],
        "inventory_cost": ["read"],
        "inventory_profit": ["read"],
        "falcon": ["read"],
        "invoices": ["create", "read", "update"],
        "reports": ["read"],
        "banking": ["create", "read", "update", "delete"],
        "reconciliation": ["create", "read", "update"],
        "payments": ["create", "read", "update", "delete"],
        "expenses": ["create", "read", "update", "delete"],
        "cheques": ["create", "read", "update", "delete"],
        "notifications": ["create", "read", "update", "delete"],
    },
    "employee": {
        "customers": ["read"],
        "products": ["read"],
        "inventory": ["read"],
        "invoices": ["create", "read"],
        "payments": ["create", "read", "update"],
        "expenses": ["create", "read", "update"],
        "notifications": ["read", "update"],
    },
    "personal": {
        "personal_finance": ["create", "read", "update", "delete"],
        "banking": ["create", "read", "update", "delete"],
        "payments": ["create", "read", "update", "delete"],
        "expenses": ["create", "read", "update", "delete"],
        "cheques": ["create", "read", "update", "delete"],
        "notifications": ["read", "update"],
    },
}


class AuthService:
    UPDATABLE_FIELDS = {
        "full_name",
        "email",
        "phone",
        "preferred_language",
        "preferred_currency",
        "preferred_usage_mode",
        # NOTE: "avatar" is deliberately NOT updatable here — the dedicated
        # POST /auth/me/avatar endpoint is the only writer (validated image
        # + owner-scoped path). Accepting it here would let any client store
        # an arbitrary external URL that other devices would then download.
    }

    def __init__(
        self,
        org_repo: OrganizationRepository,
        user_repo: UserRepository,
        session_repo: SessionRepository,
        role_repo: RoleRepository,
        pending_repo: Optional[PendingRegistrationRepository] = None,
    ):
        self._org_repo = org_repo
        self._user_repo = user_repo
        self._session_repo = session_repo
        self._role_repo = role_repo
        self._pending_repo = pending_repo

    async def _create_default_roles(self, org: Organization) -> None:
        # Create default roles with permissions for organization
        for role_key, role_name in SYSTEM_ROLES.items():
            new_role = Role(
                organization_id=org.id, name=role_key, name_ar=role_name, is_system=True
            )
            new_role = await self._role_repo.create(new_role)
            # Assign baseline permissions
            perms = ROLE_PERMISSIONS.get(role_key, {})
            for resource, actions in perms.items():
                rp = RolePermission(
                    role_id=new_role.id,
                    resource=resource,
                    can_create="create" in actions,
                    can_read="read" in actions,
                    can_update="update" in actions,
                    can_delete="delete" in actions,
                )
                await self._role_repo.assign_permission(rp)

    async def login_with_firebase(
        self, id_token: str, *, google_id_token: str | None = None,
        device_name: Optional[str] = None,
        ip_address: Optional[str] = None,
        user_agent: Optional[str] = None,
        device_model: Optional[str] = None,
        os_version: Optional[str] = None,
        fingerprint: Optional[str] = None,
        country: Optional[str] = None,
        region: Optional[str] = None,
        city: Optional[str] = None,
    ) -> AuthResponse:
        claims = firebase_auth.verify_id_token(id_token, google_id_token=google_id_token)
        if not claims:
            raise ValueError("رمز المصادقة غير صالح أو منتهي")

        uid = claims.get("uid")
        email = (claims.get("email") or "").lower()
        if not email:
            raise ValueError("الحساب لا يحتوي على بريد إلكتروني")
        name = claims.get("name") or email.split("@")[0]
        photo = claims.get("picture")
        provider = (claims.get("firebase") or {}).get("sign_in_provider", "firebase")
        email_verified = bool(claims.get("email_verified", False))

        # Email/password accounts must confirm their email before signing in.
        # Google accounts are verified automatically by Firebase.
        if provider == "password" and not email_verified:
            raise ValueError(
                "يرجى تأكيد بريدك الإلكتروني أولاً. تحقق من الرسالة المرسلة إلى بريدك"
            )

        user = await self._user_repo.get_by_firebase_uid(uid)
        if not user:
            user = await self._user_repo.get_by_email(email)

        if user:
            if user.status != "active":
                raise ValueError("الحساب غير نشط. يرجى التواصل مع الدعم")
            await self.ensure_session_slot(user.id, fingerprint)
            user.firebase_uid = uid
            user.auth_provider = provider
            user.email_verified = email_verified
            if photo and not user.photo_url:
                user.photo_url = photo
            if photo and not user.avatar:
                user.avatar = photo
            user.last_login_at = datetime.now(timezone.utc)
            user = await self._user_repo.update(user)
            return await self._generate_auth_response(
                user,
                device_name=device_name,
                ip_address=ip_address,
                user_agent=user_agent,
                device_model=device_model,
                os_version=os_version,
                fingerprint=fingerprint,
                country=country,
                region=region,
                city=city,
            )

        # First-time login: create organization + user (role owner)
        base_slug = (name).strip().lower().replace(" ", "-")
        org = Organization(
            name=f"{name}'s Organization",
            slug=f"{base_slug}-{uuid4().hex[:8]}",
        )
        org = await self._org_repo.create(org)

        user = User(
            organization_id=org.id,
            full_name=name,
            email=email,
            phone=None,
            password_hash=None,
            firebase_uid=uid,
            auth_provider=provider,
            photo_url=photo,
            avatar=photo,
            role="owner",
            email_verified=email_verified,
            preferred_usage_mode="personal",
        )
        user = await self._user_repo.create(user)

        await self._create_default_roles(org)

        return await self._generate_auth_response(
            user,
            device_name=device_name,
            ip_address=ip_address,
            user_agent=user_agent,
            device_model=device_model,
            os_version=os_version,
            fingerprint=fingerprint,
            country=country,
            region=region,
            city=city,
        )

    async def refresh_token(
        self,
        refresh_token: str,
        ip_address: Optional[str] = None,
        user_agent: Optional[str] = None,
    ) -> TokenResponse:
        token_hash = hash_refresh_token(refresh_token)
        session = await self._session_repo.get_by_refresh_token(token_hash)
        if not session:
            raise ValueError("الجلسة غير صالحة أو منتهية")
        if not session.is_active:
            raise ValueError("تم إنهاء هذه الجلسة")

        payload = decode_token(refresh_token)
        if not payload:
            await self._session_repo.deactivate(session.id)
            raise ValueError("انتهت صلاحية الجلسة")

        user = await self._user_repo.get_by_id(session.user_id)
        if not user or user.status != "active":
            raise ValueError("المستخدم غير موجود أو غير نشط")

        # Rotate IN PLACE on the same session row (new token hash + expiry +
        # activity stamp). The old deactivate+create churned a brand-new
        # device-blank session on every refresh, flooding the sessions list
        # with "unknown device" rows and tripping the 5-device cap.
        new_raw = create_refresh_token(str(user.id))
        session.refresh_token = hash_refresh_token(new_raw)
        session.expires_at = datetime.now(timezone.utc) + timedelta(
            days=settings.JWT_REFRESH_TOKEN_EXPIRE_DAYS
        )
        session.last_activity = datetime.now(timezone.utc)
        # Keep "last seen from" and the app version current for the
        # sessions screen (never blank them out).
        if ip_address:
            session.ip_address = ip_address
        if user_agent and parse_app_agent(user_agent)[0]:
            session.user_agent = user_agent
        await self._session_repo.update(session)

        return TokenResponse(
            access_token=create_access_token(
                str(user.id), str(user.organization_id), user.role,
                session_id=str(session.id),
            ),
            refresh_token=new_raw,
        )

    async def logout(self, user_id: UUID, refresh_token: Optional[str] = None) -> None:
        if refresh_token:
            token_hash = hash_refresh_token(refresh_token)
            session = await self._session_repo.get_by_refresh_token(token_hash)
            if session:
                await self._session_repo.deactivate(session.id)
        else:
            await self._session_repo.deactivate_all_for_user(user_id)
            # Invalidate every access token issued so far (instant kick-all):
            # get_current_user_uuid rejects tokens with iat < tokens_valid_after.
            user = await self._user_repo.get_by_id(user_id)
            if user:
                user.tokens_valid_after = datetime.now(timezone.utc)
                await self._user_repo.update(user)
        logger.info("user_logged_out", user_id=str(user_id))

    async def live_sessions(self, user_id: UUID) -> list[UserSession]:
        """Active, non-expired sessions, primary first then oldest first.

        Housekeeping on the way: expired rows still flagged active are closed
        (the refresh endpoint already rejects them), and when the primary
        device is gone (signed out / expired) the OLDEST remaining session
        becomes primary: the primary is always the account's first device.
        """
        # list_active_for_user filters expired rows out; close them for real
        # so they never hold a primary flag (unique index) or a device slot.
        closer = getattr(self._session_repo, "deactivate_expired_for_user", None)
        if closer is not None:
            await closer(user_id)
        rows = await self._session_repo.list_active_for_user(user_id)
        rows.sort(key=lambda s: (_aware(s.created_at) or datetime.min.replace(tzinfo=timezone.utc)))
        primaries = [s for s in rows if s.is_primary]
        if not primaries and rows:
            rows[0].is_primary = True
            await self._session_repo.update(rows[0])
            logger.info("session_primary_promoted", user_id=str(user_id),
                        session_id=str(rows[0].id))
        elif len(primaries) > 1:
            for extra in primaries[1:]:
                extra.is_primary = False
                await self._session_repo.update(extra)
        rows.sort(key=lambda s: 0 if s.is_primary else 1)
        return rows

    async def ensure_session_slot(
        self, user_id: UUID, fingerprint: Optional[str] = None
    ) -> None:
        """Refuse a NEW device when the account already has the maximum of
        live sessions. The same device signing in again (fingerprint match)
        reuses its own slot and is never refused."""
        if fingerprint:
            dup = await self._session_repo.get_active_by_fingerprint(user_id, fingerprint)
            if dup is not None:
                return
        limit = session_limit()
        live = await self.live_sessions(user_id)
        if len(live) >= limit:
            logger.info("session_limit_reached", user_id=str(user_id), limit=limit)
            raise SessionLimitReached(limit)

    async def revoke_session(
        self,
        user_id: UUID,
        session_id: UUID,
        caller_session_id: Optional[UUID] = None,
    ) -> None:
        """Kick a single session, verifying it belongs to the caller.

        The primary (first) device can never be kicked. Only the primary
        device may revoke OTHER sessions; any device may always revoke its
        OWN session (self logout). The kicked device's access token dies on
        its next request (sid check) and its refresh token is refused.
        """
        await self.live_sessions(user_id)
        session = await self._session_repo.get(session_id)
        if not session or session.user_id != user_id or not session.is_active:
            raise ValueError("الجلسة غير موجودة")
        if session.is_primary:
            raise ValueError("لا يمكن حذف الجهاز الرئيسي")
        if caller_session_id is not None and str(session_id) != str(caller_session_id):
            caller = await self._session_repo.get(caller_session_id)
            if not caller or caller.user_id != user_id or not caller.is_primary:
                raise PermissionError("فقط الجهاز الرئيسي يمكنه إدارة الجلسات")
        await self._session_repo.deactivate(session.id)
        logger.info("session_revoked", user_id=str(user_id), session_id=str(session_id))

    async def update_session_custom_name(
        self,
        user_id: UUID,
        session_id: UUID,
        custom_name: str,
        caller_session_id: Optional[UUID] = None,
    ) -> None:
        """Rename a device (stored on the server, seen on every device).

        A device may rename itself; the primary device may rename any
        device of the account. An empty name restores the device's own name.
        """
        session = await self._session_repo.get(session_id)
        if not session or session.user_id != user_id or not session.is_active:
            raise ValueError("الجلسة غير موجودة")
        if caller_session_id is not None and str(session_id) != str(caller_session_id):
            caller = await self._session_repo.get(caller_session_id)
            if not caller or caller.user_id != user_id or not caller.is_primary:
                raise PermissionError("فقط الجهاز الرئيسي يمكنه تعديل أسماء الأجهزة الأخرى")
        name = " ".join((custom_name or "").split())
        if len(name) > 60:
            raise ValueError("اسم الجهاز طويل جداً (60 حرفاً كحد أقصى)")
        await self._session_repo.update_custom_name(session_id, name or None)
        logger.info("session_renamed", user_id=str(user_id), session_id=str(session_id))

    async def get_active_sessions(
        self, user_id: UUID, current_refresh_token: Optional[str] = None
    ) -> list[dict]:
        sessions = await self.live_sessions(user_id)
        current_hash = (
            hash_refresh_token(current_refresh_token) if current_refresh_token else None
        )
        limit = session_limit()
        out = []
        for s in sessions:
            app_version, platform = parse_app_agent(s.user_agent)
            out.append({
                "id": str(s.id),
                "device_info": _describe_device(s.device_name, s.user_agent),
                "device_model": s.device_model,
                "os_version": s.os_version,
                "app_version": app_version,
                "platform": platform,
                "fingerprint": s.fingerprint,
                "country": s.country,
                "region": s.region,
                "city": s.city,
                "ip_address": s.ip_address,
                "is_current": bool(current_hash and s.refresh_token == current_hash),
                "is_primary": bool(s.is_primary),
                "custom_name": s.custom_name,
                "last_activity": (s.last_activity or s.created_at).isoformat()
                if (s.last_activity or s.created_at)
                else None,
                "expires_at": s.expires_at.isoformat() if s.expires_at else None,
                "created_at": s.created_at.isoformat() if s.created_at else None,
                "is_active": True,
                "session_limit": limit,
            })
        return out

    async def get_user_by_id(self, user_id: UUID) -> Optional[User]:
        return await self._user_repo.get_by_id(user_id)

    async def get_user_by_email(self, email: str) -> Optional[User]:
        return await self._user_repo.get_by_email(email)

    async def update_user(self, user_id: UUID, data: dict) -> User:
        user = await self._user_repo.get_by_id(user_id)
        if not user:
            raise ValueError("المستخدم غير موجود")
        for key, value in data.items():
            if value is None or key not in self.UPDATABLE_FIELDS:
                continue
            if key == "phone":
                await self._validate_and_apply_phone(user, value)
            else:
                setattr(user, key, value)
        user.updated_at = datetime.now(timezone.utc)
        return await self._user_repo.update(user)

    async def update_user_phone(
        self, user_id: UUID, phone: str, country: Optional[str] = None
    ) -> User:
        """Validate + persist a user's phone (E.164) with its metadata.

        Used by the dedicated ``POST /auth/me/phone`` endpoint so the free
        subscription gate can rely on a properly validated number. The number
        is de-duplicated against every other user before being saved.
        """
        user = await self._user_repo.get_by_id(user_id)
        if not user:
            raise ValueError("المستخدم غير موجود")
        await self._validate_and_apply_phone(user, phone, country=country)
        user.updated_at = datetime.now(timezone.utc)
        return await self._user_repo.update(user)

    async def _validate_and_apply_phone(
        self,
        user: User,
        phone: str,
        country: Optional[str] = None,
    ) -> None:
        info = normalize_phone(phone, expected_country=country)
        existing = await self._user_repo.get_by_phone(info.e164)
        if existing and existing.id != user.id:
            raise ValueError("رقم الهاتف مسجل لحساب آخر بالفعل")

        now = datetime.now(timezone.utc)
        user.phone = info.e164
        user.phone_country = info.country
        user.phone_calling_code = info.country_code
        user.phone_type = info.number_type
        user.phone_carrier = info.carrier
        if user.phone_added_at is None:
            user.phone_added_at = now
        user.phone_updated_at = now

    def user_has_valid_phone(self, user: User) -> bool:
        """True when the user holds a well-formed phone (E.164 or a real number
        parseable in their stored/default region). Existing accounts with a
        malformed placeholder value are treated as missing a phone."""
        if not user or not user.phone:
            return False
        return is_valid_phone(user.phone, region=user.phone_country or "SA")

    # ──────────────────────────────────────────────
    #  Email / Password Auth (OTP flows)
    # ──────────────────────────────────────────────

    async def _create_org_and_user(self, pending: PendingRegistration) -> User:
        """Create an organization + owner user + default roles."""
        base_slug = pending.full_name.strip().lower().replace(" ", "-")
        org = Organization(
            name=pending.organization_name
            or f"منظمة {pending.full_name.strip()}",
            slug=f"{base_slug}-{uuid4().hex[:8]}",
        )
        org = await self._org_repo.create(org)

        user = User(
            organization_id=org.id,
            full_name=pending.full_name,
            email=pending.email,
            phone=pending.phone,
            password_hash=pending.password_hash,
            auth_provider="email",
            role="owner",
            email_verified=True,
            preferred_usage_mode=pending.preferred_usage_mode or "personal",
        )
        user = await self._user_repo.create(user)
        await self._create_default_roles(org)
        return user

    async def register(
        self,
        full_name: str,
        email: str,
        password: str,
        phone: Optional[str] = None,
        organization_name: Optional[str] = None,
        preferred_usage_mode: Optional[str] = None,
        device_name: Optional[str] = None,
        ip_address: Optional[str] = None,
    ) -> dict:
        """Start signup: store a pending registration and send an OTP.

        Re-submitting the same email resumes an existing (non-expired) pending
        registration and issues a fresh OTP.
        """
        email = email.lower()
        existing = await self._user_repo.get_by_email(email)
        if existing:
            raise ValueError("هذا البريد الإلكتروني مسجل بالفعل")

        pending = await self._pending_repo.get_by_email(email)
        if pending and pending.expires_at > datetime.now(timezone.utc):
            pending.full_name = full_name
            pending.phone = phone
            pending.password_hash = hash_password(password)
            pending.organization_name = organization_name
            pending.preferred_usage_mode = preferred_usage_mode
            await self._pending_repo.create(pending)
        else:
            if pending:
                await self._pending_repo.delete(pending.id)
            pending = PendingRegistration(
                email=email,
                full_name=full_name,
                phone=phone,
                password_hash=hash_password(password),
                organization_name=organization_name,
                preferred_usage_mode=preferred_usage_mode,
                expires_at=datetime.now(timezone.utc) + timedelta(
                    minutes=settings.PENDING_REGISTRATION_TTL_MINUTES
                ),
            )
            await self._pending_repo.create(pending)

        await self._send_otp("signup", email, purpose_label="للتسجيل")
        return {
            "expires_in_seconds": settings.PENDING_REGISTRATION_TTL_MINUTES * 60,
            "otp_ttl_seconds": otp_service.OTP_TTL_SECONDS,
        }

    async def verify_registration(
        self, email: str, otp: str
    ) -> AuthResponse:
        """Complete signup: verify OTP, create account, return tokens."""
        email = email.lower()
        if not await otp_service.verify_otp("signup", email, otp):
            raise ValueError("رمز التحقق غير صالح أو منتهي")

        pending = await self._pending_repo.get_by_email(email)
        if not pending or pending.expires_at <= datetime.now(timezone.utc):
            raise ValueError("انتهت صلاحية بيانات التسجيل، يرجى إعادة المحاولة")

        user = await self._create_org_and_user(pending)
        await self._pending_repo.delete(pending.id)

        await email_service.send_email(
            to=email,
            subject="أهلاً بك في Fyona ERP 🎉",
            html=email_templates.welcome_email(pending.full_name),
            text=f"أهلاً بك {pending.full_name} في Fyona ERP، تم إنشاء حسابك بنجاح.",
        )

        logger.info("user_registered", user_id=str(user.id), email=email)
        return await self._generate_auth_response(user)

    async def resend_registration_otp(self, email: str) -> dict:
        """Resend the signup OTP for a pending registration (cooldown-guarded)."""
        email = email.lower()
        pending = await self._pending_repo.get_by_email(email)
        if not pending or pending.expires_at <= datetime.now(timezone.utc):
            raise ValueError("لا يوجد تسجيل قيد الإتمام، يرجى إعادة التسجيل")
        await self._send_otp("signup", email, purpose_label="للتسجيل")
        return {
            "expires_in_seconds": settings.PENDING_REGISTRATION_TTL_MINUTES * 60,
            "otp_ttl_seconds": otp_service.OTP_TTL_SECONDS,
        }

    async def login(
        self,
        email: str,
        password: str,
        device_name: Optional[str] = None,
        ip_address: Optional[str] = None,
        user_agent: Optional[str] = None,
        device_model: Optional[str] = None,
        os_version: Optional[str] = None,
        fingerprint: Optional[str] = None,
        country: Optional[str] = None,
        region: Optional[str] = None,
        city: Optional[str] = None,
    ) -> AuthResponse:
        """Email/password sign-in. Generates a security alert on new devices."""
        email = email.lower()
        user = await self._user_repo.get_by_email(email)
        if not user or user.auth_provider == "firebase":
            raise ValueError("البريد الإلكتروني أو كلمة المرور غير صحيحة")
        if not verify_password(password, user.password_hash):
            raise ValueError("البريد الإلكتروني أو كلمة المرور غير صحيحة")
        if password_needs_rehash(user.password_hash):
            user.password_hash = hash_password(password)
        if user.status != "active":
            raise ValueError("الحساب غير نشط. يرجى التواصل مع الدعم")
        if not user.email_verified:
            raise ValueError(
                "يرجى تأكيد بريدك الإلكتروني أولاً. تحقق من الرسالة المرسلة إلى بريدك"
            )

        # Hard device cap: refuse a 4th device BEFORE any alert goes out.
        await self.ensure_session_slot(user.id, fingerprint)

        previous = await self._session_repo.list_active_for_user(user.id)
        is_new_device = not previous or not any(
            s.ip_address == ip_address and s.device_name == device_name
            for s in previous
        )
        if is_new_device:
            # Send email alert (HTML + organized plain-text twin so text
            # clients never glue the header and the time row together).
            device_label = device_name or "جهاز غير معروف"
            ip_label = ip_address or "غير معروف"
            time_label = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
            await email_service.send_email(
                to=email,
                subject="تسجيل دخول من جهاز جديد — Fyona ERP",
                html=email_templates.login_alert_email(
                    device_label,
                    ip_label,
                    time_label,
                ),
                text=email_templates.login_alert_text(
                    device_label,
                    ip_label,
                    time_label,
                ),
            )

        user.last_login_at = datetime.now(timezone.utc)
        await self._user_repo.update(user)
        logger.info("user_logged_in", user_id=str(user.id))
        return await self._generate_auth_response(
            user,
            device_name=device_name,
            ip_address=ip_address,
            user_agent=user_agent,
            device_model=device_model,
            os_version=os_version,
            fingerprint=fingerprint,
            country=country,
            region=region,
            city=city,
        )

    async def forgot_password(self, email: str, purpose: str = "reset") -> dict:
        """Send an OTP — only for a really registered email account.

        `purpose="reset"` guards the ACCOUNT PASSWORD, so it stays limited to
        password-backed (email) accounts. `purpose="pin"` verifies ownership of
        the address for the DEVICE PIN only: it never touches the password, so
        external logins (Google) may use it exactly like anyone else.

        Unlike the old generic-success behavior, unknown addresses are
        rejected explicitly so users reliably learn about typos instead of
        waiting for an email that will never arrive. Lookup is exact first,
        then case-insensitive (legacy mixed-case rows), so a truly existing
        address is never misreported as unknown.
        """
        email = (email or "").strip().lower()
        user = await self._user_repo.get_by_email(email)
        if user is None:
            try:
                user = await self._user_repo.get_by_email_ci(email)
            except Exception:
                user = None
        if user is None:
            raise ValueError(
                "هذا البريد الإلكتروني غير مسجل في التطبيق. "
                "تأكد من كتابة البريد الصحيح الخاص بحسابك"
            )
        if purpose != "pin" and (user.auth_provider or "email") != "email":
            provider = (user.auth_provider or "").strip().lower()
            if "google" in provider:
                raise ValueError(
                    "هذا الحساب مسجل عبر Google ولا يملك كلمة مرور — "
                    "سجل الدخول بالضغط على زر المتابعة عبر Google "
                    "دون إدخال كلمة مرور"
                )
            raise ValueError(
                "هذا الحساب مسجل بتسجيل دخول خارجي ولا يملك كلمة مرور — "
                "سجل الدخول بالطريقة نفسها"
            )
        await self._send_otp(
            purpose,
            email,
            purpose_label=(
                "لإعادة تعيين رمز القفل (PIN)"
                if purpose == "pin"
                else "لإعادة تعيين كلمة المرور"
            ),
        )
        return {"expires_in_seconds": otp_service.OTP_TTL_SECONDS, "cooldown_seconds": 0}

    async def verify_otp(self, email: str, otp: str, purpose: str) -> str:
        """Verify an OTP and return a short-lived verification token."""
        email = email.lower()
        if purpose == "reset":
            user = await self._user_repo.get_by_email(email)
            if not user or user.auth_provider != "email":
                raise ValueError("رمز التحقق غير صالح أو منتهي")
        if not await otp_service.verify_otp(purpose, email, otp):
            raise ValueError("رمز التحقق غير صالح أو منتهي")
        ttl_min = 10
        return create_reset_token(
            email,
            ttl_minutes=ttl_min,
            # A PIN verification must NOT be redeemable as a password reset.
            purpose="pin_reset" if purpose == "pin" else "reset",
        )

    async def reset_password(self, reset_token: str, new_password: str) -> AuthResponse:
        """Set a new password, revoke all sessions and return fresh tokens."""
        payload = decode_reset_token(reset_token)
        if not payload:
            raise ValueError("الرابط غير صالح أو منتهي الصلاحية")
        email = payload.get("sub")
        user = await self._user_repo.get_by_email(email)
        if not user:
            raise ValueError("المستخدم غير موجود")

        user.password_hash = hash_password(new_password)
        user.email_verified = True
        user.updated_at = datetime.now(timezone.utc)
        user.tokens_valid_after = datetime.now(timezone.utc)
        await self._user_repo.update(user)

        await self._session_repo.deactivate_all_for_user(user.id)

        await email_service.send_email(
            to=email,
            subject="تم تغيير كلمة المرور — Fyona ERP",
            html=email_templates.password_changed_email(),
            text="تم تغيير كلمة المرور لحسابك بنجاح.",
        )
        logger.info("password_reset", user_id=str(user.id))
        return await self._generate_auth_response(user)

    async def change_password(
        self,
        user_id: UUID,
        current_password: str,
        new_password: str,
        device_name: Optional[str] = None,
    ) -> None:
        """Change password for an authenticated user and revoke all sessions."""
        user = await self._user_repo.get_by_id(user_id)
        if not user:
            raise ValueError("المستخدم غير موجود")
        if user.auth_provider == "firebase" or not user.password_hash:
            raise ValueError("لا يمكن تغيير كلمة المرور لحساب مسجل عبر جوجل")
        if not verify_password(current_password, user.password_hash):
            raise ValueError("كلمة المرور الحالية غير صحيحة")

        user.password_hash = hash_password(new_password)
        user.updated_at = datetime.now(timezone.utc)
        user.tokens_valid_after = datetime.now(timezone.utc)
        await self._user_repo.update(user)
        await self._session_repo.deactivate_all_for_user(user_id)

        await email_service.send_email(
            to=user.email,
            subject="تم تغيير كلمة المرور — Fyona ERP",
            html=email_templates.password_changed_email(device_name or ""),
            text="تم تغيير كلمة المرور لحسابك بنجاح.",
        )
        logger.info("password_changed", user_id=str(user_id))

    async def _send_otp(
        self, purpose: str, email: str, purpose_label: str = ""
    ) -> None:
        if await otp_service.otp_sent_recently(purpose, email):
            raise ValueError("انتظر قليلاً قبل طلب رمز جديد")
        code = await otp_service.create_otp(purpose, email)
        await otp_service.mark_otp_sent(purpose, email)
        ttl_minutes = otp_service.OTP_TTL_SECONDS // 60
        sent = await email_service.send_email(
            to=email,
            subject="رمز التحقق الخاص بك — Fyona ERP",
            html=email_templates.otp_email(code, ttl_minutes, purpose_label),
            text=f"رمز التحقق الخاص بك هو: {code} (صالح لمدة {ttl_minutes} دقائق)",
        )
        # Do NOT swallow delivery failures: register must not report "OTP sent"
        # when the SMTP transaction did not succeed (is_configured False, auth
        # failure, connection/TLS error, or refused recipient). The detailed
        # step/traceback is already logged by email_service.send_email.
        if not sent:
            raise ValueError(
                "فشل إرسال رمز التحقق بالبريد الإلكتروني. "
                "تحقق من إعدادات SMTP أو استخدم رمزاً صالحاً."
            )

    async def request_email_change(self, user: User) -> dict:
        """Send a verification code to the user's CURRENT (old) email.

        The new email is captured only at verify time; this proves the user
        controls the currently registered (old) inbox before it is changed.
        """
        old_email = user.email
        if not old_email:
            raise ValueError("لم يتم ربط بريد إلكتروني بهذا الحساب")
        await self._send_otp("email_change", old_email, purpose_label="لتغيير البريد الإلكتروني")
        return {
            "expires_in_seconds": otp_service.OTP_TTL_SECONDS,
            "cooldown_seconds": otp_service.OTP_COOLDOWN_SECONDS,
        }

    async def verify_email_change(
        self,
        user: User,
        otp: str,
        new_email: str,
        current_session_id: Optional[UUID] = None,
    ) -> AuthResponse:
        """Verify the code sent to the OLD email, then update the email address."""
        new_email = new_email.strip().lower()
        if not new_email:
            raise ValueError("الرجاء إدخال البريد الإلكتروني الجديد")
        if new_email == user.email:
            raise ValueError("هذا هو بريدك الإلكتروني الحالي")
        existing = await self._user_repo.get_by_email(new_email)
        if existing and existing.id != user.id:
            raise ValueError("هذا البريد الإلكتروني مستخدم لحساب آخر")

        old_email = user.email
        if not await otp_service.verify_otp("email_change", old_email, otp):
            raise ValueError("رمز التحقق غير صالح أو منتهي")

        user.email = new_email
        user.email_verified = True
        user.updated_at = datetime.now(timezone.utc)
        await self._user_repo.update(user)

        logger.info("email_changed", user_id=str(user.id), old=old_email, new=new_email)

        await email_service.send_email(
            to=old_email,
            subject="تم تغيير بريدك الإلكتروني — Fyona ERP",
            html=email_templates.notification_email(
                title="تم تغيير بريدك الإلكتروني",
                message=(
                    f"تم تغيير بريدك الإلكتروني إلى {new_email}. "
                    "إذا لم تقم بهذا التغيير، راجئنا فوراً."
                ),
            ),
            text=(
                f"تم تغيير بريدك الإلكتروني الآن إلى {new_email}. "
                "إذا لم تقم بهذا التغيير، راجئنا فوراً."
            ),
        )

        # Same device, same session: rotate its tokens in place instead of
        # opening a second session (which would eat a device slot).
        return await self._generate_auth_response(
            user, reuse_session_id=current_session_id, enforce_limit=False)

    async def _generate_auth_response(
        self,
        user: User,
        device_name: Optional[str] = None,
        ip_address: Optional[str] = None,
        user_agent: Optional[str] = None,
        device_model: Optional[str] = None,
        os_version: Optional[str] = None,
        fingerprint: Optional[str] = None,
        country: Optional[str] = None,
        region: Optional[str] = None,
        city: Optional[str] = None,
        reuse_session_id: Optional[UUID] = None,
        enforce_limit: bool = True,
    ) -> AuthResponse:
        session, raw_refresh_token = await self._create_session(
            user,
            device_name=device_name,
            ip_address=ip_address,
            user_agent=user_agent,
            device_model=device_model,
            os_version=os_version,
            fingerprint=fingerprint,
            country=country,
            region=region,
            city=city,
            reuse_session_id=reuse_session_id,
            enforce_limit=enforce_limit,
        )
        org = await self._org_repo.get_by_id(user.organization_id)
        user_resp = await self.get_user_response(user, org)
        return AuthResponse(
            access_token=create_access_token(
                str(user.id), str(user.organization_id), user.role,
                session_id=str(session.id),
            ),
            refresh_token=raw_refresh_token,
            user=user_resp,
            session_id=str(session.id),
        )

    async def _create_session(
        self,
        user: User,
        device_name: Optional[str] = None,
        ip_address: Optional[str] = None,
        user_agent: Optional[str] = None,
        device_model: Optional[str] = None,
        os_version: Optional[str] = None,
        fingerprint: Optional[str] = None,
        country: Optional[str] = None,
        region: Optional[str] = None,
        city: Optional[str] = None,
        reuse_session_id: Optional[UUID] = None,
        enforce_limit: bool = True,
    ) -> tuple[UserSession, str]:
        expires_at = datetime.now(timezone.utc) + timedelta(
            days=settings.JWT_REFRESH_TOKEN_EXPIRE_DAYS
        )
        raw_token = create_refresh_token(str(user.id))
        now = datetime.now(timezone.utc)
        if reuse_session_id is not None:
            own = await self._session_repo.get(reuse_session_id)
            if (own is not None and own.user_id == user.id and own.is_active
                    and (_aware(own.expires_at) or now) > now):
                own.refresh_token = hash_refresh_token(raw_token)
                own.expires_at = expires_at
                own.last_activity = now
                return await self._session_repo.update(own), raw_token
        # Fingerprint re-login: the SAME physical device must never pile up
        # duplicate rows. Rotate its existing active session in place
        # (fresh tokens + current device info/geo), preserving ownership.
        if fingerprint:
            dup = await self._session_repo.get_active_by_fingerprint(
                user.id, fingerprint
            )
            if dup is not None:
                dup.refresh_token = hash_refresh_token(raw_token)
                dup.expires_at = now + timedelta(
                    days=settings.JWT_REFRESH_TOKEN_EXPIRE_DAYS
                )
                if device_name and device_name != "تطبيق موبايل":
                    dup.device_name = device_name
                if ip_address:
                    dup.ip_address = ip_address
                if user_agent:
                    dup.user_agent = user_agent
                if device_model:
                    dup.device_model = device_model
                if os_version:
                    dup.os_version = os_version
                if country:
                    dup.country = country
                if region:
                    dup.region = region
                if city:
                    dup.city = city
                dup.last_activity = now
                updated = await self._session_repo.update(dup)
                return updated, raw_token
        # Hard device cap (all users): a NEW device beyond the limit is refused.
        existing = await self.live_sessions(user.id)
        if enforce_limit and len(existing) >= session_limit():
            raise SessionLimitReached(session_limit())
        # Check if a primary session already exists to avoid race condition
        has_primary = any(s.is_primary for s in existing)
        is_primary = not has_primary
        session = UserSession(
            user_id=user.id,
            refresh_token=hash_refresh_token(raw_token),
            expires_at=expires_at,
            device_name=device_name,
            ip_address=ip_address,
            user_agent=user_agent,
            device_model=device_model,
            os_version=os_version,
            fingerprint=fingerprint,
            country=country,
            region=region,
            city=city,
            last_activity=datetime.now(timezone.utc),
            is_primary=is_primary,
        )
        try:
            created = await self._session_repo.create(session)
        except Exception:
            # Lost a primary-creation race (partial unique index): retry once
            # as an ordinary secondary session instead of failing the login.
            if is_primary:
                session.is_primary = False
                created = await self._session_repo.create(session)
            else:
                raise
        # No silent eviction any more: the device cap is enforced up front
        # (SessionLimitReached), so signing in never kicks another device.
        return created, raw_token

    async def get_user_response(self, user: User, org: Optional[Organization] = None) -> UserResponse:
        # Trial is considered "used" once a trial end date has ever been set
        # OR the durable free-plan marker was raised (paid activation,
        # admin activation, paid request). The durable flag survives every
        # paid-path reset, so the free plan can never be offered twice.
        trial_used = bool(
            org and (getattr(org, "has_used_free_plan", False) or org.trial_end_date is not None)
        )
        now = datetime.now(timezone.utc)
        admin_permissions: list[str] = []
        if user.is_platform_admin:
            perm_rows = await self._role_repo.list_admin_permissions(user.id)
            if perm_rows:
                admin_permissions = admin_permission_codes(perm_rows)
            else:
                admin_permissions = all_admin_permission_codes()
        return UserResponse(
            id=str(user.id),
            organization_id=str(user.organization_id),
            full_name=user.full_name,
            organization_name=org.name if org else None,
            organization_avatar=(getattr(org, "avatar", None) if org else None),
            # Phone-first accounts carry an internal placeholder address.
            email="" if (user.email or "").lower().endswith(".fyona.invalid") else user.email,
            phone=user.phone,
            phone_masked=mask_phone(user.phone),
            phone_complete=bool(user.phone),
            phone_verified=bool(getattr(user, "phone_verified_at", None)
                                and getattr(user, "phone_e164", None)),
            role=user.role,
            avatar=user.avatar,
            username=user.full_name,
            is_active=(user.status == "active") if user.status else True,
            is_platform_admin=bool(user.is_platform_admin) if user.is_platform_admin is not None else False,
            admin_permissions=admin_permissions,
            preferred_language=user.preferred_language or "ar",
            preferred_currency=user.preferred_currency or "SAR",
            preferred_usage_mode=user.preferred_usage_mode,
            email_verified=bool(user.email_verified) if user.email_verified is not None else False,
            last_login_at=user.last_login_at,
            created_at=user.created_at,
            subscription_plan=org.subscription_plan if org else None,
            subscription_status=org.subscription_status if org else None,
            status=org.subscription_status if org else None,
            subscription_start_date=org.subscription_start_date if org else None,
            subscription_end_date=org.subscription_end_date if org else None,
            trial_start_date=org.subscription_start_date if org and trial_used else None,
            trial_end_date=org.trial_end_date if org else None,
            personal_trial_activated=trial_used,
            business_trial_activated=False,
        )


def _describe_device(device_name: Optional[str], user_agent: Optional[str]) -> str:
    """Human-friendly label for a session: X-Device-Name wins, else UA hint."""
    if device_name and device_name.strip():
        return device_name.strip()
    ua = (user_agent or '').lower()
    if 'android' in ua:
        base = 'Android'
    elif 'iphone' in ua or 'ipad' in ua or 'ios' in ua:
        base = 'iOS'
    elif 'windows' in ua:
        base = 'Windows'
    elif 'mac os' in ua or 'macintosh' in ua:
        base = 'macOS'
    elif 'linux' in ua:
        base = 'Linux'
    elif ua:
        return user_agent[:60]
    else:
        return 'جهاز غير معروف'
    browser = (
        'Chrome' if 'chrome' in ua
        else ('Firefox' if 'firefox' in ua else ('Safari' if 'safari' in ua else ''))
    )
    return base + (f' - {browser}' if browser else '')
