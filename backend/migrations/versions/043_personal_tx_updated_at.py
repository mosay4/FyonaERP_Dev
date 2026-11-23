"""Add updated_at to personal_transactions for incremental sync.

Before this migration, transactions had no updated_at column, making it
impossible for the server to do reliable incremental change detection on them.
Additive-only column; existing rows get a backfilled value.

Revision ID: 043
Revises: 042
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

revision: str = "043"
down_revision: Union[str, None] = "042"
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
    if not _column_exists("personal_transactions", "updated_at"):
        add_column_if_missing(
            "personal_transactions",
            sa.Column(
                "updated_at",
                sa.DateTime(timezone=True),
                server_default=sa.func.now(),
                nullable=True,
            ),
        )
        # Backfill older rows with created_at so delta sync catches them.
        op.execute(
            "UPDATE personal_transactions SET updated_at = created_at "
            "WHERE updated_at IS NULL"
        )


def downgrade() -> None:
    if _column_exists("personal_transactions", "updated_at"):
        op.drop_column("personal_transactions", "updated_at")