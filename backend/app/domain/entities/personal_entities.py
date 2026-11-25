import uuid
from datetime import datetime, timezone
from sqlalchemy import (
    Column, String, Boolean, DateTime, ForeignKey, Text, Numeric, Date, Integer, JSON
)
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


# Personal bank account kinds: جاري (current) / توفير (savings).
VALID_ACCOUNT_TYPES = ("current", "savings")
DEFAULT_ACCOUNT_TYPE = "current"
_ACCOUNT_TYPE_ALIASES = {
    "current": "current", "checking": "current", "جاري": "current",
    "savings": "savings", "saving": "savings", "توفير": "savings",
}


def normalize_account_type(value):
    """Canonical account type ('current'/'savings') for [value].

    Returns None for a missing/blank value and raises ValueError for an
    unknown one, so callers can tell "not stated" from "invalid".
    """
    if value is None:
        return None
    text = str(value).strip().lower()
    if not text:
        return None
    canonical = _ACCOUNT_TYPE_ALIASES.get(text)
    if canonical is None:
        raise ValueError("account_type must be 'current' or 'savings'")
    return canonical


def effective_account_type(row) -> str:
    """The account type a client should show (legacy NULL rows = current)."""
    return getattr(row, "account_type", None) or DEFAULT_ACCOUNT_TYPE


class PersonalBankAccount(Base):
    __tablename__ = "personal_bank_accounts"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    bank_name = Column(String(200), nullable=False)
    currency = Column(String(10), default="SAR")
    balance = Column(Numeric(12, 2), default=0)
    notes = Column(Text)
    # 'current' (جاري) / 'savings' (توفير). NULL = never stated (rows created
    # before the column existed, or by older clients) and reads as 'current';
    # it lets a device push its legacy local type once without ever
    # overwriting a type that was already stated on the server.
    account_type = Column(String(20), nullable=True)
    sort_order = Column(Integer, default=0)
    is_active = Column(Boolean, default=True)
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class PersonalTransaction(Base):
    __tablename__ = "personal_transactions"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    tx_type = Column(String(20), nullable=False)  # income / expense
    amount = Column(Numeric(12, 2), nullable=False)
    currency = Column(String(10), default="SAR")
    category = Column(String(100), nullable=False)
    description = Column(Text)
    bank_account_id = Column(
        UUID(as_uuid=True),
        ForeignKey("personal_bank_accounts.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    budget_id = Column(
        UUID(as_uuid=True),
        ForeignKey("personal_budgets.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    budget_category_id = Column(
        UUID(as_uuid=True),
        ForeignKey("personal_budget_categories.id", ondelete="SET NULL"),
        nullable=True,
    )
    goal_id = Column(
        UUID(as_uuid=True),
        ForeignKey("personal_savings_goals.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    debt_id = Column(
        UUID(as_uuid=True),
        ForeignKey("personal_debts.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    # Amount actually credited to the linked goal in goal currency (may
    # differ from `amount` for cross-currency contributions). The delete
    # endpoint reverses THIS value so the goal returns to its exact
    # pre-contribution state.
    goal_amount = Column(Numeric(12, 2), nullable=True)
    # Amount actually credited to the linked debt in debt currency (may
    # differ from `amount` for cross-currency payments). The delete
    # endpoint reverses THIS value so paid totals stay exact.
    debt_amount = Column(Numeric(12, 2), nullable=True)
    payment_method = Column(String(20), nullable=True)
    date = Column(DateTime(timezone=True), default=utcnow)
    # Exchange-rate snapshot used at execution time (offline-first correctness):
    # the historical transaction keeps the rate it actually used, even if the
    # live rate changes later.
    exchange_rate = Column(Numeric(20, 8), nullable=True)
    exchange_rate_currency = Column(String(10), nullable=True)
    fx_source = Column(String(30), nullable=True)
    # Client-generated idempotency key (one per user intent): retried POSTs
    # carrying the same key return the original row instead of duplicating.
    client_operation_id = Column(String(64), nullable=True, index=True)
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class PersonalSavingsGoal(Base):
    __tablename__ = "personal_savings_goals"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    name = Column(String(200), nullable=False)
    target_amount = Column(Numeric(12, 2), nullable=False)
    current_amount = Column(Numeric(12, 2), default=0)
    currency = Column(String(10), default="SAR")
    deadline = Column(Date)
    icon = Column(String(50), default="SAVINGS")
    notes = Column(Text)
    budget_id = Column(
        UUID(as_uuid=True),
        ForeignKey("personal_budgets.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    is_completed = Column(Boolean, default=False)
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class PersonalDebt(Base):
    __tablename__ = "personal_debts"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    debt_type = Column(String(20), nullable=False)  # payable / receivable
    person_name = Column(String(200), nullable=False)
    amount = Column(Numeric(12, 2), nullable=False)
    currency = Column(String(10), default="SAR")
    description = Column(Text)
    due_date = Column(Date)
    is_paid = Column(Boolean, default=False)
    paid_date = Column(Date)
    reminder = Column(Boolean, default=False)
    budget_id = Column(
        UUID(as_uuid=True),
        ForeignKey("personal_budgets.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class PersonalDebtPayment(Base):
    __tablename__ = "personal_debt_payments"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    debt_id = Column(UUID(as_uuid=True), ForeignKey("personal_debts.id", ondelete="CASCADE"), nullable=False, index=True)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    amount = Column(Numeric(12, 2), nullable=False)
    currency = Column(String(10), default="SAR")
    payment_date = Column(DateTime(timezone=True), default=utcnow)
    notes = Column(Text)
    budget_id = Column(
        UUID(as_uuid=True),
        ForeignKey("personal_budgets.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    is_deleted = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), default=utcnow)


class PersonalBudget(Base):
    __tablename__ = "personal_budgets"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    name = Column(String(200), nullable=False)
    period_type = Column(String(30), default="monthly")
    start_date = Column(DateTime(timezone=True), nullable=True)
    end_date = Column(DateTime(timezone=True), nullable=True)
    custom_days = Column(Integer, nullable=True)
    total_amount = Column(Numeric(12, 2), nullable=False)
    currency = Column(String(10), default="SAR")
    bank_account_ids = Column(JSON, default=list)
    budget_types = Column(JSON, default=lambda: ["expenses"])
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)

    # Legacy columns kept for backward compat, now nullable
    category = Column(String(100), nullable=True)
    amount = Column(Numeric(12, 2), nullable=True)
    spent = Column(Numeric(12, 2), default=0)
    month = Column(Integer, nullable=True)
    year = Column(Integer, nullable=True)


class PersonalBudgetCategory(Base):
    __tablename__ = "personal_budget_categories"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    budget_id = Column(UUID(as_uuid=True), ForeignKey("personal_budgets.id", ondelete="CASCADE"), nullable=False, index=True)
    name = Column(String(100), nullable=False)
    type = Column(String(20), nullable=False)  # expense, debt, goal
    allocated_amount = Column(Numeric(12, 2), default=0)
    spent_amount = Column(Numeric(12, 2), default=0)
    currency = Column(String(10), default="SAR")
    goal_id = Column(
        UUID(as_uuid=True),
        ForeignKey("personal_savings_goals.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    debt_id = Column(
        UUID(as_uuid=True),
        ForeignKey("personal_debts.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class PersonalRecurringTransaction(Base):
    __tablename__ = "personal_recurring_transactions"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    name = Column(String(200), nullable=True)
    tx_type = Column(String(20), nullable=False)  # income / expense
    amount = Column(Numeric(12, 2), nullable=False)
    currency = Column(String(10), default="SAR")
    category = Column(String(100), nullable=False)
    description = Column(Text)
    frequency = Column(String(20), nullable=False)  # daily, weekly, monthly, yearly
    interval_value = Column(Integer, default=1)
    next_run_date = Column(Date)
    account_type = Column(String(20), default="fixed")  # fixed / pick_at_execution
    bank_account_id = Column(UUID(as_uuid=True), ForeignKey("personal_bank_accounts.id", ondelete="SET NULL"), nullable=True)
    execution_type = Column(String(20), default="auto")  # auto / reminder
    reminder_time = Column(String(10), nullable=True)  # HH:MM format
    approximate_start_day = Column(Integer, nullable=True)
    approximate_end_day = Column(Integer, nullable=True)
    last_executed_at = Column(DateTime(timezone=True), nullable=True)
    is_active = Column(Boolean, default=True)
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
