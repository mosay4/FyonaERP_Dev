"""Chat between a merchant and a LINKED customer/supplier.

One conversation per `MerchantLink` (so it is isolated per relationship). No
chat exists unless the party is actually linked (accepted). Messages support
text, image, voice and an attached invoice. Delivery/read receipts + presence
are tracked so the sender sees ✔️ / ✔️✔️ / ✔️✔️(blue).
"""

import uuid
from datetime import datetime, timezone

from sqlalchemy import Column, DateTime, Integer, String, Text, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


def _now():
    return datetime.now(timezone.utc)


class ChatMessage(Base):
    __tablename__ = "chat_messages"
    __table_args__ = (
        UniqueConstraint("sender_user_id", "client_id",
                         name="uq_chat_sender_client"),
    )
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    link_id = Column(UUID(as_uuid=True), nullable=False, index=True)
    merchant_org_id = Column(UUID(as_uuid=True), nullable=False, index=True)
    sender_user_id = Column(UUID(as_uuid=True), nullable=False, index=True)
    recipient_user_id = Column(UUID(as_uuid=True), nullable=False, index=True)
    kind = Column(String(12), nullable=False, default="text")  # text|image|video|voice|invoice
    # Which SIDE sent it ('merchant' | 'personal') — direction must not depend
    # on the user id alone (the same account can be both sides).
    sender_side = Column(String(10), nullable=True)
    text = Column(Text, nullable=True)  # text OR the media caption
    media_path = Column(String(500), nullable=True)
    media = Column(Text, nullable=True)  # JSON list [{url,kind,file_name}] (album)
    file_name = Column(String(255), nullable=True)
    duration_ms = Column(Integer, nullable=True)
    invoice_id = Column(UUID(as_uuid=True), nullable=True)
    reply_to_id = Column(UUID(as_uuid=True), nullable=True)
    client_id = Column(String(80), nullable=True)
    delivered_at = Column(DateTime(timezone=True), nullable=True)
    read_at = Column(DateTime(timezone=True), nullable=True)
    edited_at = Column(DateTime(timezone=True), nullable=True)
    deleted_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=_now, index=True)


class ChatPresence(Base):
    """Last time each user polled/opened the chat. `online` = seen within 45s,
    which matches «مفتوح داخل التطبيق» without a WebSocket dependency."""

    __tablename__ = "chat_presence"
    user_id = Column(UUID(as_uuid=True), primary_key=True)
    last_seen_at = Column(DateTime(timezone=True), default=_now, index=True)
