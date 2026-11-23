import uuid
from datetime import datetime, timezone
from sqlalchemy import (
    Column, String, DateTime, Date, ForeignKey, Text, Numeric, UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class SubscriptionInvoice(Base):
    """Official invoice generated automatically when a subscription is approved."""

    __tablename__ = "subscription_invoices"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    invoice_number = Column(String(50), nullable=False, index=True, unique=True)
    organization_id = Column(
        UUID(as_uuid=True), ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), index=True)
    request_id = Column(
        UUID(as_uuid=True), ForeignKey("subscription_requests.id", ondelete="SET NULL"),
        index=True,
    )
    plan_name = Column(String(200), nullable=False)
    plan_description = Column(Text)
    period = Column(String(20), nullable=False, default="yearly")
    amount = Column(Numeric(14, 2), nullable=False, default=0)
    currency = Column(String(10), nullable=False, default="SAR")
    status = Column(String(20), nullable=False, default="paid")
    payment_method = Column(String(50), default="bank_transfer")
    # Payment snapshot: exact bank/card used, frozen at approval time.
    bank_name = Column(String(200), nullable=True)
    card_brand = Column(String(50), nullable=True)
    # E-payment idempotency: Stripe payment_intent id / checkout session id.
    provider_payment_id = Column(String(200), nullable=True)
    subscription_start_date = Column(DateTime(timezone=True))
    subscription_end_date = Column(DateTime(timezone=True))
    notes = Column(Text)
    created_at = Column(DateTime(timezone=True), default=utcnow, index=True)

    __table_args__ = (
        UniqueConstraint("organization_id", "request_id", name="uq_sub_inv_org_request"),
    )
