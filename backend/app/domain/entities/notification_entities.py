import uuid
from datetime import datetime, timezone
from sqlalchemy import (
    Column, String, Boolean, DateTime, ForeignKey, Text, Integer, UniqueConstraint
)
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class AppNotification(Base):
    __tablename__ = "app_notifications"
    __table_args__ = (
        UniqueConstraint("organization_id", "source_notif_id", name="uq_app_notif_source"),
    )

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    user_id = Column(UUID(as_uuid=True), nullable=True, index=True)
    source_notif_id = Column(UUID(as_uuid=True), nullable=True, index=True)
    type = Column(String(30), default="info")  # info, warning, success, report, reminder
    title = Column(String(300), nullable=False)
    message = Column(Text)
    action = Column(String(100))  # open_screen / open_url / report
    action_payload = Column(Text)  # route name or url
    is_system = Column(Boolean, default=True, index=True)
    is_read = Column(Boolean, default=False, index=True)
    created_at = Column(DateTime(timezone=True), default=utcnow, index=True)
    # Logical separation: 'main' (default app center) vs 'commercial_debt'
    # (the debts/merchant-linking feature). Each center lists only its own.
    domain = Column(String(20), nullable=False, default="main")
    # Exactly one notification per logical event per recipient.
    event_id = Column(String(80), nullable=True)
    # Deep-link target (real ids) opened when the notification is tapped.
    route = Column(String(200), nullable=True)
    image_url = Column(Text, nullable=True)


class NotificationPreference(Base):
    __tablename__ = "notification_preferences"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    user_id = Column(UUID(as_uuid=True), nullable=True, index=True)
    email_alerts = Column(Boolean, default=True)
    invoice_alerts = Column(Boolean, default=True)
    payment_alerts = Column(Boolean, default=True)
    system_updates = Column(Boolean, default=True)
    budget_alerts = Column(Boolean, default=True)
    low_balance_alerts = Column(Boolean, default=True)
    daily_report = Column(Boolean, default=False)
    weekly_report = Column(Boolean, default=False)
    monthly_report = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class Reminder(Base):
    __tablename__ = "reminders"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    user_id = Column(UUID(as_uuid=True), nullable=True, index=True)
    title = Column(String(300), nullable=False)
    message = Column(Text)
    remind_at = Column(DateTime(timezone=True), nullable=False, index=True)
    repeat = Column(String(20), default="none")  # none, daily, weekly, monthly
    is_active = Column(Boolean, default=True)
    last_triggered_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
