import uuid
from datetime import datetime, timezone
from sqlalchemy import (
    Column, String, Boolean, DateTime, ForeignKey, Text, Numeric, Float
)
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class BankAccount(Base):
    __tablename__ = "bank_accounts"

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
    bank_name = Column(String(200), nullable=False)
    account_name = Column(String(200), nullable=False)
    account_number = Column(String(100), nullable=False)
    iban = Column(String(50))
    # Stable, explicit bank identity shared across branches. NULL means the
    # row has no confirmed bank link yet; the API never guesses by name alone.
    bank_group_key = Column(String(120), index=True)
    balance = Column(Numeric(12, 2), default=0)
    currency = Column(String(10), default="SAR")
    account_type = Column(String(20), default="checking")
    is_active = Column(Boolean, default=True)
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class BankTransaction(Base):
    __tablename__ = "bank_transactions"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    bank_account_id = Column(
        UUID(as_uuid=True),
        ForeignKey("bank_accounts.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    date = Column(DateTime(timezone=True), default=utcnow)
    description = Column(Text, default="")
    tx_type = Column(String(40), nullable=False)  # Matches migration 077 (incl. reversals).
    amount = Column(Numeric(12, 2), nullable=False)
    currency = Column(String(10), default="SAR")
    running_balance = Column(Numeric(12, 2), default=0)
    reference = Column(Text)
    is_deleted = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), default=utcnow)


class FinancialPayment(Base):
    __tablename__ = "financial_payments"

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
    payment_no = Column(String(50), nullable=False)
    payment_type = Column(String(20), default="incoming")
    payment_method = Column(String(20), default="cash")
    amount = Column(Numeric(12, 2), nullable=False)
    currency = Column(String(10), default="SAR")
    notes = Column(Text)
    payment_date = Column(DateTime(timezone=True), default=utcnow)
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class Expense(Base):
    __tablename__ = "expenses"

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
    expense_no = Column(String(50), nullable=False)
    category = Column(String(100), default="")
    amount = Column(Numeric(12, 2), nullable=False)
    currency = Column(String(10), default="SAR")
    description = Column(Text, default="")
    payment_method = Column(String(20), default="cash")
    # The account the expense was paid FROM (Business withdrawals). Nullable:
    # expenses entered without an account stay unlinked.
    bank_account_id = Column(
        UUID(as_uuid=True),
        ForeignKey("bank_accounts.id", ondelete="SET NULL"),
    )
    expense_date = Column(DateTime(timezone=True), default=utcnow)
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class AdminExchangeRate(Base):
    __tablename__ = "admin_exchange_rates"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    currency_code = Column(String(20), nullable=False, unique=True, index=True)
    base_currency = Column(String(10), nullable=False, default="USD")
    rate_type = Column(String(20), default="average")  # buy / sell / average
    buy_rate = Column(Float, nullable=False, default=0.0)
    sell_rate = Column(Float, nullable=False, default=0.0)
    average_rate = Column(Float, nullable=False, default=0.0)
    source = Column(String(50), default="manual")  # manual / api
    provider = Column(String(100))  # which API provider
    is_active = Column(Boolean, default=True)
    changed_by = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"))
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class ExchangeRateStore(Base):
    """Persistent store of auto-fetched exchange rates (one row per currency).

    Refreshed on every provider fetch (at minimum daily via startup warm-up).
    Serves as the system's durable "last known good" store: when all external
    sources fail, rates are recovered from here instead of hardcoded fallbacks.
    """

    __tablename__ = "exchange_rate_store"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    currency_code = Column(String(20), nullable=False, unique=True, index=True)
    base_currency = Column(String(10), nullable=False, default="USD")
    buy_rate = Column(Float, nullable=False, default=0.0)
    sell_rate = Column(Float, nullable=False, default=0.0)
    average_rate = Column(Float, nullable=False, default=0.0)
    source = Column(String(50), nullable=False, default="auto")  # auto / api / 2dec.net
    provider = Column(String(100))  # exchangerate-api.com / open.er-api.com / 2dec.net / ...
    fetched_at = Column(DateTime(timezone=True), default=utcnow, nullable=False)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class ExchangeRateHistory(Base):
    """Audit trail for ALL exchange rate changes (admin manual + API fetched)."""
    __tablename__ = "exchange_rate_history"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    currency_code = Column(String(20), nullable=False, index=True)
    base_currency = Column(String(10), nullable=False, default="USD")
    rate_type = Column(String(20), default="average")
    buy_rate = Column(Float, nullable=False)
    sell_rate = Column(Float, nullable=False)
    average_rate = Column(Float, nullable=False)
    source = Column(String(50), nullable=False)  # manual / api / fallback
    provider = Column(String(100))  # egcurrency / exchangerate.host / open.er-api / 2dec.net / manual
    changed_by = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"))
    previous_buy_rate = Column(Float)
    previous_sell_rate = Column(Float)
    previous_average_rate = Column(Float)
    metadata_json = Column(Text)  # JSON string for extra info
    created_at = Column(DateTime(timezone=True), default=utcnow)
    effective_at = Column(DateTime(timezone=True), nullable=True, index=True)


class Cheque(Base):
    __tablename__ = "cheques"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    branch_id = Column(UUID(as_uuid=True), ForeignKey("branches.id"), nullable=True, index=True)
    cheque_number = Column(String(50), nullable=False)
    amount = Column(Numeric(12, 2), nullable=False)
    status = Column(String(20), default="pending")  # pending, cashed, bounced, cancelled
    payee_name = Column(String(200))
    bank_name = Column(String(200))
    issue_date = Column(DateTime(timezone=True))
    due_date = Column(DateTime(timezone=True))
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
