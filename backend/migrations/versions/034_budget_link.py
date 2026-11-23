"""Add budget_id and budget_category_id to personal_transactions

Revision ID: 034
Revises: 033
Create Date: 2026-09-05
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

revision = "034"
down_revision = "033"
branch_labels = None
depends_on = None


def upgrade() -> None:
    add_column_if_missing("personal_transactions", sa.Column("budget_id", sa.UUID(), sa.ForeignKey("personal_budgets.id", ondelete="SET NULL"), nullable=True))
    add_column_if_missing("personal_transactions", sa.Column("budget_category_id", sa.UUID(), sa.ForeignKey("personal_budget_categories.id", ondelete="SET NULL"), nullable=True))
    create_index_if_missing("ix_personal_transactions_budget_id", "personal_transactions", ["budget_id"])


def downgrade() -> None:
    op.drop_index("ix_personal_transactions_budget_id", table_name="personal_transactions")
    op.drop_column("personal_transactions", "budget_category_id")
    op.drop_column("personal_transactions", "budget_id")
