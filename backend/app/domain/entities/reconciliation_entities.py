import uuid
from datetime import datetime, timezone
from sqlalchemy import (
    Column, String, Boolean, DateTime, ForeignKey, Text, Numeric,
)
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class Reconciliation(Base):
    """Permanent archive of ONE reconciliation operation (bank/cash or
    inventory). Created at CHECK time (before anything changes), finalized at
    APPROVE time. Never deleted; corrections are new records.

    rtype:  bank | inventory
    scope:  accounts (bank) | product | category | full (inventory)
    status: draft (inventory counting) -> checked -> approved
    lines_json:      [{...system/actual/diff per currency-account or product}]
    settlements_json: [{...executed adjustments, linked movement ids}]
    result_json:     summary {matched, short, surplus, stale, ...}
    """
    __tablename__ = "reconciliations"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    branch_id = Column(
        UUID(as_uuid=True), ForeignKey("branches.id", ondelete="SET NULL")
    )
    ref_code = Column(String(40), index=True)
    rtype = Column(String(20), nullable=False)
    scope = Column(String(20), nullable=False, default="accounts")
    scope_json = Column(Text, nullable=False, default="{}")
    status = Column(String(20), nullable=False, default="draft")
    period_start = Column(DateTime(timezone=True))
    period_end = Column(DateTime(timezone=True))
    # The REAL moment the system quantities/balances were snapshotted.
    measured_at = Column(DateTime(timezone=True), default=utcnow)
    notes = Column(Text)
    lines_json = Column(Text, nullable=False, default="[]")
    settlements_json = Column(Text)
    result_json = Column(Text)
    created_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL")
    )
    approved_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL")
    )
    created_at = Column(DateTime(timezone=True), default=utcnow)
    approved_at = Column(DateTime(timezone=True))
    # Idempotency: a retried check/approve returns the same archive record
    # instead of creating a duplicate.
    idempotency_key = Column(String(80), unique=True, index=True)
    updated_at = Column(DateTime(timezone=True), default=utcnow,
                        onupdate=utcnow)