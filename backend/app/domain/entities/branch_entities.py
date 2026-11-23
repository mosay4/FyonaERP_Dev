"""Branch membership, invitations and branch-to-branch transfers.

These tables are additive: existing business rows keep their `branch_id` and
are never rewritten. A membership grants an EXISTING FYONA user access to one
or more branches of a company without changing the user's own organization or
Personal data. Permissions are evaluated server-side on every request.
"""

import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    Boolean, Column, DateTime, ForeignKey, Numeric, String, Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class BranchMember(Base):
    __tablename__ = "branch_members"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    user_id = Column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    branch_ids = Column(Text, nullable=False, default="[]")  # JSON list of UUID
    permissions = Column(Text, nullable=False, default="{}")  # JSON map
    per_branch = Column(Text, nullable=False, default="{}")  # JSON branch -> map
    all_branches = Column(Boolean, nullable=False, default=False,
                          server_default="false")
    can_transfer = Column(Boolean, nullable=False, default=False,
                          server_default="false")
    status = Column(String(20), nullable=False, default="active",
                    server_default="active")
    invited_by = Column(UUID(as_uuid=True), nullable=True)
    scope_valid_after = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow,
                        onupdate=utcnow)

    __table_args__ = (
        UniqueConstraint("organization_id", "user_id",
                         name="uq_branch_member_org_user"),
    )


class BranchInvitation(Base):
    __tablename__ = "branch_invitations"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    branch_id = Column(
        UUID(as_uuid=True),
        ForeignKey("branches.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    invited_user_id = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    invited_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    identifier_type = Column(String(10), nullable=False, default="code")
    identifier = Column(String(120), nullable=True)
    status = Column(String(20), nullable=False, default="pending",
                    server_default="pending")
    permissions = Column(Text, nullable=False, default="{}")
    can_transfer = Column(Boolean, nullable=False, default=False,
                          server_default="false")
    created_at = Column(DateTime(timezone=True), default=utcnow)
    expires_at = Column(DateTime(timezone=True), nullable=True)
    responded_at = Column(DateTime(timezone=True), nullable=True)



class BranchTransfer(Base):
    __tablename__ = "branch_transfers"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    transfer_number = Column(String(60), nullable=False, index=True)
    kind = Column(String(20), nullable=False)  # financial | inventory
    from_branch_id = Column(
        UUID(as_uuid=True), ForeignKey("branches.id", ondelete="RESTRICT"),
        nullable=False, index=True,
    )
    to_branch_id = Column(
        UUID(as_uuid=True), ForeignKey("branches.id", ondelete="RESTRICT"),
        nullable=False, index=True,
    )
    actor_user_id = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    actor_role = Column(String(20), nullable=True)
    status = Column(String(20), nullable=False, default="completed",
                    server_default="completed")
    from_account_id = Column(
        UUID(as_uuid=True), ForeignKey("bank_accounts.id", ondelete="SET NULL"),
        nullable=True,
    )
    to_account_id = Column(
        UUID(as_uuid=True), ForeignKey("bank_accounts.id", ondelete="SET NULL"),
        nullable=True,
    )
    amount = Column(Numeric(18, 4), nullable=True)
    currency = Column(String(10), nullable=True)
    to_currency = Column(String(10), nullable=True)
    exchange_rate = Column(Numeric(18, 8), nullable=True)
    received_amount = Column(Numeric(18, 4), nullable=True)
    total_cost = Column(Numeric(18, 4), nullable=True)
    reversal_of_id = Column(
        UUID(as_uuid=True), ForeignKey("branch_transfers.id", ondelete="SET NULL"),
        nullable=True, index=True,
    )
    reversed_amount = Column(Numeric(18, 4), nullable=False, default=0,
                             server_default="0")
    idempotency_key = Column(String(120), nullable=True)
    notes = Column(Text, nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    completed_at = Column(DateTime(timezone=True), default=utcnow)
    reversed_at = Column(DateTime(timezone=True), nullable=True)

    __table_args__ = (
        UniqueConstraint("organization_id", "transfer_number",
                         name="uq_branch_transfer_number"),
        UniqueConstraint("organization_id", "idempotency_key",
                         name="uq_branch_transfer_idempotency"),
    )


class BranchTransferItem(Base):
    __tablename__ = "branch_transfer_items"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    transfer_id = Column(
        UUID(as_uuid=True),
        ForeignKey("branch_transfers.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    from_product_id = Column(
        UUID(as_uuid=True), ForeignKey("products.id", ondelete="SET NULL"),
        nullable=True,
    )
    to_product_id = Column(
        UUID(as_uuid=True), ForeignKey("products.id", ondelete="SET NULL"),
        nullable=True,
    )
    from_unit_id = Column(
        UUID(as_uuid=True), ForeignKey("product_units.id", ondelete="SET NULL"),
        nullable=True,
    )
    to_unit_id = Column(
        UUID(as_uuid=True), ForeignKey("product_units.id", ondelete="SET NULL"),
        nullable=True,
    )
    unit_name = Column(String(50), nullable=True)
    from_quantity = Column(Numeric(18, 4), nullable=False, default=0)
    to_quantity = Column(Numeric(18, 4), nullable=False, default=0)
    base_quantity = Column(Numeric(18, 4), nullable=False, default=0)
    # Target BASE quantity may differ from source base when a saved unit
    # conversion bridges two independent branch products.
    target_base_quantity = Column(Numeric(18, 4), nullable=False, default=0,
                                  server_default="0")
    conversion_factor = Column(Numeric(18, 6), nullable=False, default=1,
                               server_default="1")
    factor = Column(Numeric(18, 6), nullable=False, default=1)
    unit_cost = Column(Numeric(18, 6), nullable=False, default=0)
    total_cost = Column(Numeric(18, 4), nullable=False, default=0)
    currency = Column(String(10), nullable=True)
    reversed_quantity = Column(Numeric(18, 4), nullable=False, default=0,
                               server_default="0")
    created_at = Column(DateTime(timezone=True), default=utcnow)


class BranchTransferLotMove(Base):
    """Exact per-item FIFO provenance; reversals restore the original source lot."""
    __tablename__ = 'branch_transfer_lot_moves'
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    transfer_item_id = Column(UUID(as_uuid=True), ForeignKey('branch_transfer_items.id', ondelete='CASCADE'), nullable=False, index=True)
    source_lot_id = Column(UUID(as_uuid=True), ForeignKey('inventory_lots.id', ondelete='RESTRICT'), nullable=False)
    target_lot_id = Column(UUID(as_uuid=True), ForeignKey('inventory_lots.id', ondelete='RESTRICT'), nullable=False)
    source_quantity = Column(Numeric(24, 8), nullable=False)
    target_quantity = Column(Numeric(24, 8), nullable=False)
    returned_quantity = Column(Numeric(24, 8), nullable=False, default=0, server_default='0')
