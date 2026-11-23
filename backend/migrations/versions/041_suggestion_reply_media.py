"""Add media (images/videos/audios) to suggestion replies.

Allows the admin web chat composer to attach images, videos and audio files to
a reply inside a customer-suggestion conversation. Additive-only columns.

Revision ID: 041
Revises: 040
Create Date: 2026-09-07
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

revision: str = "041"
down_revision: Union[str, None] = "039"
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
    for col in ("images", "videos", "audios"):
        if not _column_exists("suggestion_replies", col):
            add_column_if_missing("suggestion_replies", sa.Column(col, sa.JSON(), nullable=True))


def downgrade() -> None:
    for col in ("images", "videos", "audios"):
        if _column_exists("suggestion_replies", col):
            op.drop_column("suggestion_replies", col)