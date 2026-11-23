"""Budget relations: link goals/debts to budgets, transactions to goals/debts

Revision ID: 035
Revises: 034
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

revision = "035"
down_revision = "034"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Goals linked to a budget
    add_column_if_missing("personal_savings_goals", sa.Column("budget_id", sa.UUID(), sa.ForeignKey("personal_budgets.id", ondelete="SET NULL"), nullable=True))
    create_index_if_missing("ix_personal_savings_goals_budget_id", "personal_savings_goals", ["budget_id"])
    # Debts linked to a budget
    add_column_if_missing("personal_debts", sa.Column("budget_id", sa.UUID(), sa.ForeignKey("personal_budgets.id", ondelete="SET NULL"), nullable=True))
    create_index_if_missing("ix_personal_debts_budget_id", "personal_debts", ["budget_id"])
    # Transactions linked to a goal / debt (in addition to budget_id / budget_category_id)
    add_column_if_missing("personal_transactions", sa.Column("goal_id", sa.UUID(), sa.ForeignKey("personal_savings_goals.id", ondelete="SET NULL"), nullable=True))
    add_column_if_missing("personal_transactions", sa.Column("debt_id", sa.UUID(), sa.ForeignKey("personal_debts.id", ondelete="SET NULL"), nullable=True))
    create_index_if_missing("ix_personal_transactions_goal_id", "personal_transactions", ["goal_id"])
    create_index_if_missing("ix_personal_transactions_debt_id", "personal_transactions", ["debt_id"])
    # Budget categories linked to a concrete goal / debt (no name matching)
    add_column_if_missing("personal_budget_categories", sa.Column("goal_id", sa.UUID(), sa.ForeignKey("personal_savings_goals.id", ondelete="SET NULL"), nullable=True))
    add_column_if_missing("personal_budget_categories", sa.Column("debt_id", sa.UUID(), sa.ForeignKey("personal_debts.id", ondelete="SET NULL"), nullable=True))
    # Debt payments carry the budget explicitly (derived from debt.budget_id at creation)
    add_column_if_missing("personal_debt_payments", sa.Column("budget_id", sa.UUID(), sa.ForeignKey("personal_budgets.id", ondelete="SET NULL"), nullable=True))


def downgrade() -> None:
    op.drop_column("personal_debt_payments", "budget_id")
    op.drop_column("personal_budget_categories", "debt_id")
    op.drop_column("personal_budget_categories", "goal_id")
    op.drop_index("ix_personal_transactions_debt_id", table_name="personal_transactions")
    op.drop_index("ix_personal_transactions_goal_id", table_name="personal_transactions")
    op.drop_column("personal_transactions", "debt_id")
    op.drop_column("personal_transactions", "goal_id")
    op.drop_index("ix_personal_debts_budget_id", table_name="personal_debts")
    op.drop_column("personal_debts", "budget_id")
    op.drop_index("ix_personal_savings_goals_budget_id", table_name="personal_savings_goals")
    op.drop_column("personal_savings_goals", "budget_id")
