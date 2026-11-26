import uuid
from datetime import datetime, timezone
from sqlalchemy import Column, String, Boolean, DateTime, ForeignKey, Text, text, JSON
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class Organization(Base):
    __tablename__ = "organizations"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String(200), nullable=False, index=True)
    avatar = Column(String(500), nullable=True)
    slug = Column(String(100), unique=True, nullable=False, index=True)
    business_type = Column(String(50))
    subscription_plan = Column(String(50), default=None)
    subscription_status = Column(String(20), default="none")
    subscription_start_date = Column(DateTime(timezone=True))
    subscription_end_date = Column(DateTime(timezone=True))
    section_subscriptions = Column(JSON, nullable=True)
    business_setup_completed = Column(Boolean, nullable=False, default=False, server_default=text("false"))
    trial_end_date = Column(DateTime(timezone=True))
    has_used_free_plan = Column(Boolean, default=False, nullable=False, server_default=text("false"))
    is_active = Column(Boolean, default=True)
    onboarding_completed = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)

    users = relationship("User", back_populates="organization")


class User(Base):
    __tablename__ = "users"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
    )
    full_name = Column(String(200), nullable=False)
    email = Column(String(100), unique=True, nullable=False, index=True)
    phone = Column(String(50))
    phone_lookup_digits = Column(String(32), nullable=True, index=True)
    phone_national_digits = Column(String(32), nullable=True, index=True)
    phone_country = Column(String(10))
    phone_calling_code = Column(String(10))
    phone_type = Column(String(30))
    phone_carrier = Column(String(100))
    phone_added_at = Column(DateTime(timezone=True))
    phone_updated_at = Column(DateTime(timezone=True))
    # Auth v2: the VERIFIED phone that owns the account (login identifier).
    # Only an OTP-verified number is ever written here (unique).
    phone_e164 = Column(String(20), unique=True, nullable=True, index=True)
    phone_verified_at = Column(DateTime(timezone=True), nullable=True)
    password_hash = Column(String(255), nullable=True)
    # Stable 6-digit public code shown to other users (never the UUID).
    public_code = Column(String(6), unique=True, nullable=True, index=True)
    firebase_uid = Column(String(128), unique=True, nullable=True, index=True)
    auth_provider = Column(String(50), nullable=True, default="email")
    photo_url = Column(String(500), nullable=True)
    avatar = Column(String(500))
    role = Column(String(50), nullable=False, default="employee")
    preferred_language = Column(String(10), default="ar")
    preferred_currency = Column(String(10), default="SAR")
    timezone = Column(String(50), default="Asia/Riyadh")
    preferred_usage_mode = Column(String(20))
    status = Column(String(20), default="active")
    email_verified = Column(Boolean, default=False)
    is_platform_admin = Column(Boolean, default=False)
    last_login_at = Column(DateTime(timezone=True))
    # Access tokens issued before this instant are rejected (instant kick-all).
    tokens_valid_after = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)

    organization = relationship("Organization", back_populates="users")
    admin_permissions = relationship(
        "AdminPermission",
        back_populates="user",
        cascade="all, delete-orphan",
    )


class AdminPermission(Base):
    __tablename__ = "admin_permissions"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    resource = Column(String(100), nullable=False)
    can_create = Column(Boolean, default=False)
    can_read = Column(Boolean, default=False)
    can_update = Column(Boolean, default=False)
    can_delete = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)

    user = relationship("User", back_populates="admin_permissions")


class UserSession(Base):
    __tablename__ = "user_sessions"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    refresh_token = Column(String(500), nullable=False, index=True)
    device_name = Column(String(200))
    custom_name = Column(String(200))
    ip_address = Column(String(50))
    user_agent = Column(Text)
    # Stable per-device fingerprint (Android ID / iOS identifierForVendor,
    # client-persisted fallback). Recorded at login; lets every screen
    # identify THIS device unambiguously even among identical models.
    fingerprint = Column(String(100))
    # Full device recognition (populated at login from client headers).
    device_model = Column(String(200))
    os_version = Column(String(50))
    country = Column(String(100))
    region = Column(String(100))
    city = Column(String(100))
    # Last time this session was seen (login + every token refresh).
    # Displayed as "last activity"; list ordering uses created_at.
    last_activity = Column(DateTime(timezone=True))
    is_active = Column(Boolean, default=True)
    is_primary = Column(Boolean, default=False, nullable=False, server_default=text("false"))
    expires_at = Column(DateTime(timezone=True), nullable=False)
    created_at = Column(DateTime(timezone=True), default=utcnow)


class PendingRegistration(Base):
    __tablename__ = "pending_registrations"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email = Column(String(100), unique=True, nullable=False, index=True)
    full_name = Column(String(200), nullable=False)
    phone = Column(String(50))
    password_hash = Column(String(255), nullable=False)
    organization_name = Column(String(200))
    preferred_usage_mode = Column(String(20))
    expires_at = Column(DateTime(timezone=True), nullable=False)
    created_at = Column(DateTime(timezone=True), default=utcnow)


class Role(Base):
    __tablename__ = "roles"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
    )
    name = Column(String(100), nullable=False)
    name_ar = Column(String(100))
    is_system = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), default=utcnow)

    permissions = relationship(
        "RolePermission", back_populates="role", cascade="all, delete-orphan"
    )


class RolePermission(Base):
    __tablename__ = "role_permissions"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    role_id = Column(
        UUID(as_uuid=True), ForeignKey("roles.id", ondelete="CASCADE"), nullable=False
    )
    resource = Column(String(100), nullable=False)
    can_create = Column(Boolean, default=False)
    can_read = Column(Boolean, default=False)
    can_update = Column(Boolean, default=False)
    can_delete = Column(Boolean, default=False)

    role = relationship("Role", back_populates="permissions")


from sqlalchemy import event


@event.listens_for(User, 'before_insert')
@event.listens_for(User, 'before_update')
def _maintain_phone_lookup_keys(mapper, connection, target):
    from ...core.phone_lookup import phone_lookup_keys
    target.phone_lookup_digits, target.phone_national_digits = phone_lookup_keys(
        target.phone, target.phone_country)
