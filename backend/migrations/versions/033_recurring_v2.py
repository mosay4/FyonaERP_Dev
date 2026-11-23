"""Add v2 columns to personal_recurring_transactions

Revision ID: 033_recurring_v2
Revises: 032_personal_budget_v2
Create Date: 2026-09-04
"""
from alembic import op
from migrations.idempotent_ops import (
    add_column_if_missing,
    create_foreign_key_if_missing,
    create_index_if_missing,
    create_table_if_missing,
    create_unique_constraint_if_missing,
)
import sqlalchemy as sa

revision = "033"
down_revision = "032"
branch_labels = None
depends_on = None


def upgrade() -> None:
    add_column_if_missing("personal_recurring_transactions", sa.Column("name", sa.String(200), nullable=True))
    add_column_if_missing("personal_recurring_transactions", sa.Column("account_type", sa.String(20), server_default="fixed"))
    add_column_if_missing("personal_recurring_transactions", sa.Column("bank_account_id", sa.UUID(), sa.ForeignKey("personal_bank_accounts.id", ondelete="SET NULL"), nullable=True))
    add_column_if_missing("personal_recurring_transactions", sa.Column("execution_type", sa.String(20), server_default="auto"))
    add_column_if_missing("personal_recurring_transactions", sa.Column("reminder_time", sa.String(10), nullable=True))
    add_column_if_missing("personal_recurring_transactions", sa.Column("approximate_start_day", sa.Integer(), nullable=True))
    add_column_if_missing("personal_recurring_transactions", sa.Column("approximate_end_day", sa.Integer(), nullable=True))
    add_column_if_missing("personal_recurring_transactions", sa.Column("last_executed_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    for col in ("last_executed_at", "approximate_end_day", "approximate_start_day",
                 "reminder_time", "execution_type", "bank_account_id", "account_type", "name"):
        op.drop_column("personal_recurring_transactions", col)
