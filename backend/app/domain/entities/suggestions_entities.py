import uuid
from datetime import datetime, timezone

from sqlalchemy import Column, String, Boolean, DateTime, Text, JSON, ForeignKey
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class Suggestion(Base):
    """A product improvement suggestion submitted by any user.

    Reaches the platform admin dashboard for review
    (pending → proposed/in_progress/completed/rejected).
    organization_id is optional because personal-mode users may not belong to an org.
    """

    __tablename__ = "suggestions"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), nullable=False, index=True)
    organization_id = Column(UUID(as_uuid=True), nullable=True, index=True)
    title = Column(String(200), nullable=False, default="")
    body = Column(Text, nullable=False)
    images = Column(JSON, default=list)  # list of stored file paths
    videos = Column(JSON, default=list)  # list of stored video file paths
    audios = Column(JSON, default=list)  # list of stored audio file paths
    status = Column(String(20), nullable=False, default="pending")  # pending|proposed|in_progress|completed|rejected
    admin_note = Column(Text, nullable=True)
    # Set when a platform admin opens/reads this suggestion inside a
    # conversation; used to compute per-conversation unread counts.
    admin_read_at = Column(DateTime(timezone=True), nullable=True)
    is_deleted = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class SuggestionReply(Base):
    """A reply from the platform admin to the user who submitted a suggestion.

    Linked to the suggestion (suggestion_id) and to the suggestion owner
    (user_id) so the reply always reaches the correct user.
    """

    __tablename__ = "suggestion_replies"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    suggestion_id = Column(
        UUID(as_uuid=True),
        ForeignKey("suggestions.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    user_id = Column(UUID(as_uuid=True), nullable=False, index=True)
    admin_id = Column(UUID(as_uuid=True), nullable=True)
    body = Column(Text, nullable=False)
    is_deleted = Column(Boolean, default=False)
    is_edited = Column(Boolean, default=False)
    images = Column(JSON, nullable=True)
    videos = Column(JSON, nullable=True)
    audios = Column(JSON, nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
