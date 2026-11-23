"""Add videos/audios JSON columns to suggestions for media attachments.

Revision ID: 018
Revises: 017
Create Date: 2026-08-13
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "018"
down_revision: Union[str, None] = "017"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _has_column(table, column):
    conn = op.get_bind()
    r = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.columns "
            "WHERE table_name = :t AND column_name = :c)"
        ),
        {"t": table, "c": column},
    )
    return r.scalar()


def upgrade():
    for col in ("videos", "audios"):
        if not _has_column("suggestions", col):
            op.add_column(
                "suggestions",
                sa.Column(col, postgresql.JSON(), nullable=True),
            )


def downgrade():
    for col in ("videos", "audios"):
        if _has_column("suggestions", col):
            op.drop_column("suggestions", col)
