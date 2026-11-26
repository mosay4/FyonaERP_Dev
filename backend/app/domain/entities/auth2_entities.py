"""Auth v2 tables: identities, trusted devices, nonces, OTP engine, budgets.

Sensitive values are never stored in clear:
* OTP codes: HMAC-SHA256 (``code_hmac``) for verification; a Fernet copy
  (``code_enc``) exists only while the challenge is live (async/restart-safe
  delivery and the primary-device approval fetch) and is wiped on any
  terminal state.
* Target phone numbers of challenges: Fernet (``target_enc``) + HMAC hash for
  caps; wiped on terminal state. Challenge payloads (pending signup data:
  password HASH, device) are Fernet-encrypted as well.
* Apple refresh tokens: Fernet.
"""

import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    JSON,
    Boolean,
    Column,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class AuthIdentity(Base):
    """A social identity (Google / Apple) linked to exactly one user."""

    __tablename__ = "auth_identities"
    __table_args__ = (
        UniqueConstraint("provider", "subject", name="uq_auth_identities_provider_subject"),
    )

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"),
                     nullable=False, index=True)
    provider = Column(String(20), nullable=False)
    subject = Column(String(255), nullable=False)
    email = Column(String(255), nullable=True)
    email_verified = Column(Boolean, nullable=False, default=False, server_default=text("false"))
    is_private_email = Column(Boolean, nullable=False, default=False, server_default=text("false"))
    refresh_token_enc = Column(Text, nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    last_login_at = Column(DateTime(timezone=True), nullable=True)


class AuthDevice(Base):
    """An app install with its device-bound public key (ECDSA P-256)."""

    __tablename__ = "auth_devices"
    __table_args__ = (
        UniqueConstraint("user_id", "device_id", name="uq_auth_devices_user_device"),
        # At most one primary device per account (DB-level guard).
        Index("uq_auth_devices_one_primary", "user_id", unique=True,
              postgresql_where=text("is_primary"), sqlite_where=text("is_primary")),
    )

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"),
                     nullable=False, index=True)
    device_id = Column(String(64), nullable=False, index=True)
    public_key = Column(Text, nullable=False)
    key_fingerprint = Column(String(64), nullable=False)
    name = Column(String(100), nullable=True)
    custom_name = Column(String(100), nullable=True)
    model = Column(String(100), nullable=True)
    os = Column(String(30), nullable=True)
    os_version = Column(String(50), nullable=True)
    app_version = Column(String(40), nullable=True)
    is_primary = Column(Boolean, nullable=False, default=False, server_default=text("false"))
    trusted = Column(Boolean, nullable=False, default=False, server_default=text("false"))
    trusted_at = Column(DateTime(timezone=True), nullable=True)
    revoked_at = Column(DateTime(timezone=True), nullable=True)
    last_seen = Column(DateTime(timezone=True), nullable=True)
    last_ip = Column(String(64), nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)


class AuthDeviceNonce(Base):
    """Single-use server nonce (60 s) for a device key proof."""

    __tablename__ = "auth_device_nonces"

    nonce = Column(String(64), primary_key=True)
    device_id = Column(String(64), nullable=False)
    expires_at = Column(DateTime(timezone=True), nullable=False, index=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)


class OtpChallenge(Base):
    """One verification operation (persisted state machine)."""

    __tablename__ = "otp_challenges"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    purpose = Column(String(20), nullable=False)  # signup|phone_change|new_device|password_reset
    user_id = Column(UUID(as_uuid=True), nullable=True, index=True)
    phone_hash = Column(String(64), nullable=True, index=True)
    target_enc = Column(Text, nullable=True)
    country = Column(String(4), nullable=True)
    locale = Column(String(5), nullable=False, default="ar")
    code_hmac = Column(String(64), nullable=False)
    code_enc = Column(Text, nullable=True)
    attempts = Column(Integer, nullable=False, default=0)
    max_attempts = Column(Integer, nullable=False, default=5)
    # queued|sent|delivered|read|failed|fallback_sms|verified|expired|locked
    status = Column(String(20), nullable=False, default="queued", index=True)
    status_reason = Column(String(60), nullable=True)
    channel = Column(String(12), nullable=False, default="whatsapp")  # whatsapp|sms|device
    wa_message_id = Column(String(128), nullable=True, index=True)
    wa_status = Column(String(20), nullable=True)
    wa_error_code = Column(String(20), nullable=True)
    wa_attempts = Column(Integer, nullable=False, default=0)
    # DB-level "never SMS twice": flipped by a compare-and-set UPDATE and
    # backed by the partial unique index on otp_deliveries.
    sms_sent = Column(Boolean, nullable=False, default=False, server_default=text("false"))
    sms_message_id = Column(String(128), nullable=True)
    sms_status = Column(String(20), nullable=True)
    resend_count = Column(Integer, nullable=False, default=0)
    last_sent_at = Column(DateTime(timezone=True), nullable=True)
    delivery_deadline_at = Column(DateTime(timezone=True), nullable=True)
    next_action_at = Column(DateTime(timezone=True), nullable=True, index=True)
    expires_at = Column(DateTime(timezone=True), nullable=False)
    verified_at = Column(DateTime(timezone=True), nullable=True)
    consumed_at = Column(DateTime(timezone=True), nullable=True)
    idempotency_key = Column(String(100), unique=True, nullable=True)
    ip = Column(String(64), nullable=True)
    device_id = Column(String(64), nullable=True)
    current_delivery_id = Column(UUID(as_uuid=True), nullable=True)
    payload_enc = Column(Text, nullable=True)
    # Non-secret display context (requesting device name/model/os, location).
    context = Column(JSON, nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow, index=True)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class OtpDelivery(Base):
    """One send request on one channel: delivery tracking + cost ledger."""

    __tablename__ = "otp_deliveries"
    __table_args__ = (
        # Never two SMS for one challenge (DB-level guard).
        Index("uq_otp_deliveries_one_sms", "challenge_id", unique=True,
              postgresql_where=text("channel = 'sms'"),
              sqlite_where=text("channel = 'sms'")),
    )

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    challenge_id = Column(UUID(as_uuid=True), ForeignKey("otp_challenges.id", ondelete="CASCADE"),
                          nullable=False, index=True)
    channel = Column(String(12), nullable=False)
    provider = Column(String(30), nullable=False)
    provider_message_id = Column(String(128), nullable=True, index=True)
    # queued|accepted|sent|delivered|read|failed|skipped
    status = Column(String(20), nullable=False, default="queued")
    error_code = Column(String(40), nullable=True)
    error_title = Column(String(200), nullable=True)
    cost_usd = Column(Numeric(12, 5), nullable=False, default=0)
    purpose = Column(String(20), nullable=True)
    phone_hash = Column(String(64), nullable=True, index=True)
    ip = Column(String(64), nullable=True, index=True)
    device_id = Column(String(64), nullable=True, index=True)
    user_id = Column(UUID(as_uuid=True), nullable=True, index=True)
    country = Column(String(4), nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow, index=True)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class OtpEvent(Base):
    """Append-only state transitions + webhook receipts (idempotency key)."""

    __tablename__ = "otp_events"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    challenge_id = Column(UUID(as_uuid=True), nullable=True, index=True)
    kind = Column(String(40), nullable=False)
    channel = Column(String(12), nullable=True)
    detail = Column(String(200), nullable=True)
    dedupe_key = Column(String(200), unique=True, nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow, index=True)


class OtpBudget(Base):
    """Admin overrides of the per-channel / global budgets (USD)."""

    __tablename__ = "otp_budgets"

    channel = Column(String(12), primary_key=True)  # sms|whatsapp|global
    daily_usd = Column(Numeric(12, 4), nullable=True)
    monthly_usd = Column(Numeric(12, 4), nullable=True)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
    updated_by = Column(UUID(as_uuid=True), nullable=True)


class PrimaryTransfer(Base):
    """Pending 'claim primary' (recovery) — applied after the waiting period
    unless the current primary cancels it."""

    __tablename__ = "auth_primary_transfers"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"),
                     nullable=False, index=True)
    from_device_id = Column(String(64), nullable=True)
    to_device_id = Column(String(64), nullable=False)
    status = Column(String(12), nullable=False, default="pending")  # pending|applied|cancelled
    apply_at = Column(DateTime(timezone=True), nullable=False, index=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    resolved_at = Column(DateTime(timezone=True), nullable=True)
    resolved_by = Column(String(64), nullable=True)
