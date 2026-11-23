"""Allow editing suggestion replies (with 24h owner window).

- suggestion_replies.updated_at: last edit time (defaults to creation).
- suggestion_replies.is_edited: shows the "edited" badge on both sides.

Additive-only; no data is dropped or rewritten.

Revision ID: 050
Revises: 049
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

revision: str = "050"
down_revision: Union[str, None] = "049"
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
    if not _column_exists("suggestion_replies", "updated_at"):
        add_column_if_missing(
            "suggestion_replies",
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        )
    if not _column_exists("suggestion_replies", "is_edited"):
        add_column_if_missing(
            "suggestion_replies",
            sa.Column("is_edited", sa.Boolean(), nullable=False, server_default="false"),
        )


def downgrade() -> None:
    if _column_exists("suggestion_replies", "is_edited"):
        op.drop_column("suggestion_replies", "is_edited")
    if _column_exists("suggestion_replies", "updated_at"):
        op.drop_column("suggestion_replies", "updated_at")
