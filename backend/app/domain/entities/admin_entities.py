import json
import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, Column, DateTime, Float, ForeignKey, Integer, Numeric, String, Text
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


def dumps_features(features):
    if features is None:
        return "[]"
    if isinstance(features, str):
        return features
    return json.dumps(features, ensure_ascii=False)


def loads_features(raw):
    if not raw:
        return []
    if isinstance(raw, list):
        return raw
    try:
        return json.loads(raw)
    except (TypeError, ValueError):
        return []


class Plan(Base):
    __tablename__ = "plans"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String(100), nullable=False)
    name_en = Column(String(100))
    description = Column(Text)
    price_monthly = Column(Float, default=0)
    price_yearly = Column(Float, default=0)
    currency = Column(String(10), default="SAR")
    features = Column(Text, default="[]")
    color = Column(String(20), default="#A01530")
    icon = Column(String(50), default="star")
    # Canonical package identity (single source of truth):
    # free | personal | business | premium
    package_type = Column(String(20), nullable=True)
    duration_days = Column(Integer, nullable=True)
    is_active = Column(Boolean, default=True)
    max_users = Column(Integer)
    max_storage_gb = Column(Integer)
    # Stripe integration (nullable; configured per-plan in Admin → Settings → Payments)
    stripe_product_id = Column(String(100), nullable=True)
    stripe_price_id_monthly = Column(String(100), nullable=True)
    stripe_price_id_yearly = Column(String(100), nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class SubscriptionRequest(Base):
    __tablename__ = "subscription_requests"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), index=True)
    organization_id = Column(UUID(as_uuid=True), index=True)
    plan_id = Column(String(50), nullable=False)
    plan_name = Column(String(200))
    status = Column(String(20), default="pending", index=True)
    message = Column(Text)
    proof_image = Column(String(500), nullable=True)
    proof_images = Column(Text, nullable=True)  # JSON array of proof paths
    period = Column(String(20), nullable=True)
    # Currency the user paid in (selected on the plans page). The admin sees and
    # records revenue in the SAME currency the customer actually paid.
    currency = Column(String(10), nullable=True)
    rejection_reason = Column(Text, nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow, index=True)
    reviewed_at = Column(DateTime(timezone=True))
    reviewed_by = Column(UUID(as_uuid=True))


class PlatformNotification(Base):
    __tablename__ = "platform_notifications"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    title = Column(String(300), nullable=False)
    message = Column(Text)
    target = Column(String(30), default="all")  # all, users, admins
    type = Column(String(30), default="info")  # info, warning, success, error
    read_count = Column(Integer, default=0)
    sent_at = Column(DateTime(timezone=True), default=utcnow, index=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)


class TrashItem(Base):
    __tablename__ = "trash_items"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    item_type = Column(String(50), nullable=False, index=True)
    item_id = Column(String(100), nullable=False)
    item_name = Column(String(300))
    payload = Column(Text)
    status = Column(String(20), default="trashed", index=True)
    deleted_by = Column(UUID(as_uuid=True))
    created_at = Column(DateTime(timezone=True), default=utcnow, index=True)
    restored_at = Column(DateTime(timezone=True))


class PlatformBankAccount(Base):
    """Company/platform bank accounts where subscription revenues are booked."""

    __tablename__ = "platform_bank_accounts"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    bank_name = Column(String(200), nullable=False)
    account_holder_name = Column(String(200))
    account_number = Column(String(50))
    iban = Column(String(50))
    country = Column(String(10), default="SA")
    currency = Column(String(10), default="SAR")
    opening_balance = Column(Numeric(14, 2), default=0)
    # Optional per-currency configuration (JSON list of
    # {"currency":"SAR","opening_balance":0}). Backward-compatible: banks with
    # only the legacy single currency keep an implicit one-currency list.
    currencies = Column(Text)
    notes = Column(Text)
    is_active = Column(Boolean, default=True)
    # System-owned banks (e.g. the virtual "Stripe" settlement bank) are
    # created and managed by the platform itself: they cannot be renamed,
    # deactivated or deleted via the API/UI.
    is_system = Column(Boolean, default=False)
    sort_order = Column(Integer, default=0)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class SubscriptionRevenue(Base):
    """Accounting entry created when a subscription request is approved."""

    __tablename__ = "subscription_revenues"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    request_id = Column(UUID(as_uuid=True), ForeignKey("subscription_requests.id", ondelete="SET NULL"), index=True)
    organization_id = Column(UUID(as_uuid=True), index=True)
    user_id = Column(UUID(as_uuid=True), index=True)
    bank_account_id = Column(UUID(as_uuid=True), ForeignKey("platform_bank_accounts.id", ondelete="SET NULL"), index=True)
    plan_name = Column(String(200))
    period = Column(String(20))
    amount = Column(Numeric(14, 2), nullable=False, default=0)
    currency = Column(String(10), default="SAR")
    note = Column(Text)
    # E-payment linkage: Stripe payment_intent id / checkout session id.
    # NULL for manual bank-transfer approvals (linked via request_id).
    provider_payment_id = Column(String(200), nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow, index=True)


class AdminOperation(Base):
    """Administrative bank operations: deposits (إيداع) & withdrawals (صرفية).

    Additive table that records every admin-led movement on platform bank
    accounts, separate from subscription revenue (which stays on
    subscription_revenues).
    """

    __tablename__ = "admin_operations"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    bank_account_id = Column(UUID(as_uuid=True), ForeignKey("platform_bank_accounts.id", ondelete="SET NULL"), index=True)
    bank_name = Column(String(200))
    type = Column(String(20), default="deposit")  # deposit | withdraw
    amount = Column(Numeric(14, 2), nullable=False, default=0)
    currency = Column(String(10), default="SAR")
    description = Column(Text)  # سبب الصرفية / بيان الإيداع
    person_name = Column(String(200))  # لمن الصرفية
    created_by = Column(UUID(as_uuid=True))
    created_at = Column(DateTime(timezone=True), default=utcnow, index=True)
