"""Persist the goal-credited amount on contribution transactions.

- personal_transactions.goal_amount: the amount actually credited to the
  linked goal in goal currency (may differ from `amount` for cross-currency
  contributions). The delete endpoint reverses THIS value so the goal
  returns to its exact pre-contribution state.

Additive-only; no data is dropped or rewritten.

Revision ID: 049
Revises: 048
"""
from typing import Sequence, Union

from alembic import op
from migrations.idempotent_ops import (
    add_column_if_missing,
    create_foreign_key_if_missing,
    create_index_if_missing,
    create_table_if_missing,
    create_unique_constraint_if_missing,
)
import sqlalchemy as sa

revision: str = "049"
down_revision: Union[str, None] = "048"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _column_exists(table: str, column: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.columns "
            "WHERE table_name = :table AND column_name = :column)"
        ),
        {"table": table, "column": column},
    )
    return result.scalar()


def upgrade() -> None:
    if not _column_exists("personal_transactions", "goal_amount"):
        add_column_if_missing(
            "personal_transactions",
            sa.Column("goal_amount", sa.Numeric(12, 2), nullable=True),
        )


def downgrade() -> None:
    if _column_exists("personal_transactions", "goal_amount"):
        op.drop_column("personal_transactions", "goal_amount")
