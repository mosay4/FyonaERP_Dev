"""Analytics & monitoring events recorded by the Sara AI agent.

Every agent round, tool call, error and user question is stored (org-scoped) so
production monitoring can measure quality, tool success rates and latency.
"""

import uuid
from datetime import datetime, timezone

from sqlalchemy import Column, String, Boolean, DateTime, Integer, Text
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class AgentAnalyticsEvent(Base):
    __tablename__ = "agent_analytics_events"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    org_id = Column(UUID(as_uuid=True), nullable=False, index=True)
    user_id = Column(UUID(as_uuid=True), nullable=False, index=True)

    event_type = Column(String(32), nullable=False)  # round | tool | error | question

    tool_name = Column(String(128), nullable=True)
    success = Column(Boolean, nullable=True)
    latency_ms = Column(Integer, nullable=True)
    error_type = Column(String(64), nullable=True)
    question = Column(Text, nullable=True)

    rounds = Column(Integer, nullable=True)
    tool_count = Column(Integer, nullable=True)
    tool_failures = Column(Integer, nullable=True)

    created_at = Column(DateTime(timezone=True), default=utcnow, index=True)
