"""Entities for Stripe payments & subscriptions.

This module defines the NEW, additive tables for Stripe checkout / webhook /
subscription tracking (`payments`, `subscriptions`, `stripe_webhook_events`,
`app_config`). It does **not** alter existing tables.

Pricing catalogs reuse the existing `plans` table from `app.domain.entities.admin_entities`
(extended there with nullable Stripe columns) so there is a single source of
truth for plans, shared with `/admin/plans` and `/subscription/plans`.
"""
import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
)
from sqlalchemy.dialects.postgresql import UUID as PG_UUID

from app.core.database import Base
# Reuse the single plan catalog (extended with Stripe price/product columns).
from app.domain.entities.admin_entities import Plan  # noqa: F401  (re-exported)


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class StripePayment(Base):
    __tablename__ = "stripe_payments"

    id = Column(PG_UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(PG_UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    organization_id = Column(PG_UUID(as_uuid=True), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True)
    plan_id = Column(PG_UUID(as_uuid=True), ForeignKey("plans.id", ondelete="SET NULL"), nullable=True, index=True)
    provider = Column(String(20), default="stripe")
    stripe_checkout_session_id = Column(String(255), index=True)
    stripe_payment_intent_id = Column(String(255), index=True)
    stripe_event_id = Column(String(255), unique=True, index=True)
    amount = Column(Float)
    amount_minor = Column(Integer, default=0)  # exact Stripe minor-unit amount charged
    currency = Column(String(10))
    # ── Server-side FX pricing metadata (single source of truth) ──
    base_currency = Column(String(10), default="SAR")  # plan's stored price currency
    base_amount = Column(Float)                          # plan price in [base_currency]
    exchange_rate = Column(Float)                        # rate applied base->charge currency
    fx_source = Column(String(20), default="stripe_price")  # live_fx | currency_engine | stripe_price
    mode = Column(String(10), default="test")            # test | live (STRIPE_MODE at charge time)
    idempotency_key = Column(String(200), index=True)    # client-supplied retry guard
    status = Column(String(20), default="pending", index=True)  # pending|paid|failed|refunded|canceled
    plan_name = Column(String(50))
    period = Column(String(20), default="yearly")  # monthly | yearly
    metadata_ = Column("metadata", Text)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)

    __table_args__ = (Index("ix_payments_org_status", "organization_id", "status"),)


class StripeSubscription(Base):
    __tablename__ = "subscriptions"
    __table_args__ = (
        Index("ix_subscriptions_org_status", "organization_id", "status"),
        Index("ix_subscriptions_stripe_sub", "stripe_subscription_id"),
    )

    id = Column(PG_UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(PG_UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    organization_id = Column(PG_UUID(as_uuid=True), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True)
    plan_id = Column(PG_UUID(as_uuid=True), ForeignKey("plans.id", ondelete="SET NULL"), nullable=True, index=True)
    stripe_customer_id = Column(String(255), index=True)
    stripe_subscription_id = Column(String(255), index=True)
    plan_name = Column(String(50))
    status = Column(String(20), default="incomplete", index=True)
    current_period_start = Column(DateTime(timezone=True))
    current_period_end = Column(DateTime(timezone=True))
    cancel_at_period_end = Column(Boolean, default=False)
    # Renewal retry bookkeeping (custom off-session retry schedule):
    # consecutive failed collection attempts + next scheduled attempt.
    renewal_retry_count = Column(Integer, default=0)
    renewal_next_retry_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class StripeWebhookEvent(Base):
    """Idempotency log for Stripe webhook events.

    Recording the Stripe event id guarantees an event is processed at most once,
    even if Stripe retries delivery.
    """
    __tablename__ = "stripe_webhook_events"

    event_id = Column(String(255), primary_key=True)
    event_type = Column(String(100), nullable=False)
    status = Column(String(20), default="processed")  # processed | error
    processed_at = Column(DateTime(timezone=True), default=utcnow)


class AppSetting(Base):
    """Key/value store for admin-configurable runtime settings.

    All values are encrypted at rest with a Fernet key derived from the
    server's JWT_SECRET_KEY (see core.config.settings.config_master_key).
    No plaintext secret is ever persisted.
    """
    __tablename__ = "app_config"

    key = Column(String(100), primary_key=True)
    value_encrypted = Column(Text, nullable=False)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)

    @staticmethod
    def known_stripe_keys() -> list:
        return [
            "stripe_enabled",
            "stripe_mode",
            "stripe_publishable_key",
            "stripe_secret_key",
            "stripe_webhook_secret",
        ]
