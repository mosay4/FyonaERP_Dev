"""Device token entity for FCM push notifications."""
import uuid
from datetime import datetime, timezone

from sqlalchemy import Column, String, Boolean, DateTime
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class DeviceToken(Base):
    """An FCM registration token bound to a user, used for push notifications.

    One user may register many devices; one token belongs to the most recent
    user who logged in on that device.
    """

    __tablename__ = "device_tokens"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), nullable=False, index=True)
    token = Column(String(500), nullable=False, index=True)
    platform = Column(String(30), default="android")  # android | ios | web
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
