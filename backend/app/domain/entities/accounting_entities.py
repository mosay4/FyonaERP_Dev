import uuid
from datetime import datetime, timezone, date
from sqlalchemy import (
    Column,
    String,
    Boolean,
    DateTime,
    Date,
    ForeignKey,
    Text,
    Numeric,
    UniqueConstraint,
    CheckConstraint,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from app.core.database import Base


class Account(Base):
    __tablename__ = "accounts"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    code = Column(String(20), nullable=False)
    name = Column(String(200), nullable=False)
    name_ar = Column(String(200))
    type = Column(String(20), nullable=False)
    parent_id = Column(
        UUID(as_uuid=True), ForeignKey("accounts.id", ondelete="SET NULL"), index=True
    )
    is_active = Column(Boolean, default=True)
    balance = Column(Numeric(12, 2), default=0)
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
    updated_at = Column(
        DateTime(timezone=True),
        default=datetime.now(timezone.utc),
        onupdate=datetime.now(timezone.utc),
    )

    children = relationship(
        "Account",
        back_populates="parent",
        lazy="select",
        cascade="all, delete-orphan",
    )
    parent = relationship(
        "Account", back_populates="children", remote_side=[id], lazy="select"
    )

    __table_args__ = (
        UniqueConstraint("organization_id", "code", name="uq_account_org_code"),
        CheckConstraint(
            "type IN ('asset','liability','equity','income','expense')",
            name="ck_account_type",
        ),
    )


class JournalEntry(Base):
    __tablename__ = "journal_entries"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    branch_id = Column(
        UUID(as_uuid=True),
        ForeignKey("branches.id", ondelete="SET NULL"),
        index=True,
    )
    entry_number = Column(String(50), nullable=False, index=True)
    entry_date = Column(Date, nullable=False, default=date.today)
    description = Column(Text, nullable=False)
    reference_type = Column(String(50))
    reference_id = Column(UUID(as_uuid=True))
    status = Column(String(20), nullable=False, default="draft")
    created_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
    updated_at = Column(
        DateTime(timezone=True),
        default=datetime.now(timezone.utc),
        onupdate=datetime.now(timezone.utc),
    )
    posted_at = Column(DateTime(timezone=True))
    cancelled_at = Column(DateTime(timezone=True))

    lines = relationship(
        "JournalEntryLine",
        back_populates="entry",
        lazy="selectin",
        cascade="all, delete-orphan",
    )

    __table_args__ = (
        UniqueConstraint("organization_id", "entry_number", name="uq_je_org_number"),
        CheckConstraint(
            "status IN ('draft','posted','cancelled')", name="ck_je_status"
        ),
    )


class JournalEntryLine(Base):
    __tablename__ = "journal_entry_lines"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    journal_entry_id = Column(
        UUID(as_uuid=True),
        ForeignKey("journal_entries.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    account_id = Column(
        UUID(as_uuid=True),
        ForeignKey("accounts.id", ondelete="RESTRICT"),
        nullable=False,
        index=True,
    )
    description = Column(String(500))
    debit = Column(Numeric(12, 2), default=0)
    credit = Column(Numeric(12, 2), default=0)

    entry = relationship("JournalEntry", back_populates="lines")
    account = relationship("Account", lazy="selectin")

    __table_args__ = (
        CheckConstraint("debit >= 0", name="ck_jel_debit"),
        CheckConstraint("credit >= 0", name="ck_jel_credit"),
    )
