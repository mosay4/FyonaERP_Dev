"""Merchant ↔ Personal linking entities (section: «حساباتي مع التجار»).

A `MerchantLink` binds ONE business party (a Customer or Supplier row in the
merchant's org) to ONE personal user account, after that user accepts the
merchant's invitation. Nothing is shared before acceptance.
"""

import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    BigInteger, Column, DateTime, Integer, Numeric, String, Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


def _now():
    return datetime.now(timezone.utc)


class UserCodeSeq(Base):
    """A single-row counter that hands out collision-free 6-digit codes."""

    __tablename__ = "user_code_seq"
    id = Column(Integer, primary_key=True)
    next_val = Column(BigInteger, nullable=False, default=0)


class MerchantLink(Base):
    __tablename__ = "merchant_links"
    __table_args__ = (
        UniqueConstraint("merchant_org_id", "party_kind", "party_id",
                         name="uq_merchant_link_party"),
    )
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    merchant_org_id = Column(UUID(as_uuid=True), nullable=False)
    party_kind = Column(String(10), nullable=False)  # customer | supplier
    party_id = Column(UUID(as_uuid=True), nullable=False)
    external_user_id = Column(UUID(as_uuid=True), nullable=True)
    phone = Column(String(50), nullable=True)
    public_code = Column(String(6), nullable=True)
    # How the party was added: 'phone' | 'code' — the detail card shows that one.
    linked_via = Column(String(10), nullable=True)
    status = Column(String(12), nullable=False, default="pending")
    display_name = Column(String(200), nullable=True)
    invited_by = Column(UUID(as_uuid=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=_now)
    responded_at = Column(DateTime(timezone=True), nullable=True)


class SettlementRequest(Base):
    """A customer-initiated payment proof the merchant must approve. Approving
    it applies the payment EXACTLY once (idempotency_key + payment_id guard)."""

    __tablename__ = "settlement_requests"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(UUID(as_uuid=True), nullable=False)
    party_kind = Column(String(10), nullable=False)
    party_id = Column(UUID(as_uuid=True), nullable=False)
    link_id = Column(UUID(as_uuid=True), nullable=True)
    external_user_id = Column(UUID(as_uuid=True), nullable=True)
    amount = Column(Numeric(18, 4), nullable=False, default=0)
    currency = Column(String(10), nullable=False, default="SAR")
    method = Column(String(20), nullable=True)
    reference = Column(String(100), nullable=True)
    receipt_url = Column(String(500), nullable=True)
    note = Column(Text, nullable=True)
    status = Column(String(12), nullable=False, default="pending")
    reject_reason = Column(Text, nullable=True)
    idempotency_key = Column(String(80), nullable=True, unique=True)
    payment_id = Column(UUID(as_uuid=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=_now)
    decided_at = Column(DateTime(timezone=True), nullable=True)


class DebtGroup(Base):
    """Organisational grouping of debt operations («دين سبتمبر»…). Purely a
    grouping — amounts are NEVER re-counted."""

    __tablename__ = "debt_groups"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(UUID(as_uuid=True), nullable=False)
    party_kind = Column(String(10), nullable=False)
    party_id = Column(UUID(as_uuid=True), nullable=False)
    name = Column(String(100), nullable=False)
    kind = Column(String(10), nullable=False, default="manual")
    period = Column(String(10), nullable=True)
    created_at = Column(DateTime(timezone=True), default=_now)


class SharedAuditLog(Base):
    __tablename__ = "shared_audit_log"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(UUID(as_uuid=True), nullable=False)
    entity_type = Column(String(30), nullable=False)
    entity_id = Column(String(60), nullable=True)
    action = Column(String(30), nullable=False)
    before_json = Column(Text, nullable=True)
    after_json = Column(Text, nullable=True)
    reason = Column(Text, nullable=True)
    actor_user_id = Column(UUID(as_uuid=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=_now)
