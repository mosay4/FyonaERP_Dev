"""Central FX System: add currency columns + ExchangeRateHistory + enhance AdminExchangeRate.

Adds currency tracking to all financial entities that were missing it.
Adds ExchangeRateHistory table for audit trail.
Enhances AdminExchangeRate with base_currency, rate_type, source, provider, changed_by.

Revision ID: 024
Revises: 023
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "024"
down_revision: Union[str, None] = "023"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _column_exists(table: str, column: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.columns WHERE table_name = :table AND column_name = :column)"
        ),
        {"table": table, "column": column},
    )
    return result.scalar()


def _table_exists(table: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = :table)"
        ),
        {"table": table},
    )
    return result.scalar()


def upgrade() -> None:
    # ── 1. PersonalTransaction: add currency ──
    if not _column_exists("personal_transactions", "currency"):
        op.add_column(
            "personal_transactions",
            sa.Column("currency", sa.String(10), server_default="SAR", nullable=False),
        )

    # ── 2. PersonalRecurringTransaction: add currency ──
    if not _column_exists("personal_recurring_transactions", "currency"):
        op.add_column(
            "personal_recurring_transactions",
            sa.Column("currency", sa.String(10), server_default="SAR", nullable=False),
        )

    # ── 3. PersonalDebtPayment: add currency ──
    if not _column_exists("personal_debt_payments", "currency"):
        op.add_column(
            "personal_debt_payments",
            sa.Column("currency", sa.String(10), server_default="SAR", nullable=False),
        )

    # ── 4. BankTransaction: add currency ──
    if not _column_exists("bank_transactions", "currency"):
        op.add_column(
            "bank_transactions",
            sa.Column("currency", sa.String(10), server_default="SAR", nullable=False),
        )

    # ── 5. FinancialPayment: add currency ──
    if not _column_exists("financial_payments", "currency"):
        op.add_column(
            "financial_payments",
            sa.Column("currency", sa.String(10), server_default="SAR", nullable=False),
        )

    # ── 6. Expense: add currency ──
    if not _column_exists("expenses", "currency"):
        op.add_column(
            "expenses",
            sa.Column("currency", sa.String(10), server_default="SAR", nullable=False),
        )

    # ── 7. Enhance AdminExchangeRate ──
    if not _column_exists("admin_exchange_rates", "base_currency"):
        op.add_column(
            "admin_exchange_rates",
            sa.Column("base_currency", sa.String(10), server_default="USD", nullable=False),
        )
    if not _column_exists("admin_exchange_rates", "rate_type"):
        op.add_column(
            "admin_exchange_rates",
            sa.Column("rate_type", sa.String(20), server_default="average", nullable=False),
        )
    if not _column_exists("admin_exchange_rates", "source"):
        op.add_column(
            "admin_exchange_rates",
            sa.Column("source", sa.String(50), server_default="manual", nullable=False),
        )
    if not _column_exists("admin_exchange_rates", "provider"):
        op.add_column(
            "admin_exchange_rates",
            sa.Column("provider", sa.String(100), nullable=True),
        )
    if not _column_exists("admin_exchange_rates", "changed_by"):
        op.add_column(
            "admin_exchange_rates",
            sa.Column(
                "changed_by",
                sa.dialects.postgresql.UUID(as_uuid=True),
                sa.ForeignKey("users.id", ondelete="SET NULL"),
                nullable=True,
            ),
        )

    # ── 8. Create ExchangeRateHistory ──
    if not _table_exists("exchange_rate_history"):
        op.create_table(
            "exchange_rate_history",
            sa.Column("id", sa.dialects.postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column("currency_code", sa.String(20), nullable=False),
            sa.Column("base_currency", sa.String(10), nullable=False, server_default="USD"),
            sa.Column("rate_type", sa.String(20), server_default="average"),
            sa.Column("buy_rate", sa.Float(), nullable=False),
            sa.Column("sell_rate", sa.Float(), nullable=False),
            sa.Column("average_rate", sa.Float(), nullable=False),
            sa.Column("source", sa.String(50), nullable=False),
            sa.Column("provider", sa.String(100), nullable=True),
            sa.Column(
                "changed_by",
                sa.dialects.postgresql.UUID(as_uuid=True),
                sa.ForeignKey("users.id", ondelete="SET NULL"),
                nullable=True,
            ),
            sa.Column("previous_buy_rate", sa.Float(), nullable=True),
            sa.Column("previous_sell_rate", sa.Float(), nullable=True),
            sa.Column("previous_average_rate", sa.Float(), nullable=True),
            sa.Column("metadata_json", sa.Text(), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        )
        op.create_index(
            "ix_exchange_rate_history_currency_code",
            "exchange_rate_history",
            ["currency_code"],
        )
        op.create_index(
            "ix_exchange_rate_history_created_at",
            "exchange_rate_history",
            ["created_at"],
        )


def downgrade() -> None:
    op.drop_table("exchange_rate_history")

    for col in ["changed_by", "provider", "source", "rate_type", "base_currency"]:
        if _column_exists("admin_exchange_rates", col):
            op.drop_column("admin_exchange_rates", col)

    for table, col in [
        ("expenses", "currency"),
        ("financial_payments", "currency"),
        ("bank_transactions", "currency"),
        ("personal_debt_payments", "currency"),
        ("personal_recurring_transactions", "currency"),
        ("personal_transactions", "currency"),
    ]:
        if _column_exists(table, col):
            op.drop_column(table, col)
