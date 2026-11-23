"""Add admin_read_at to suggestions for conversation unread tracking.

Revision ID: 020
Revises: 019
Create Date: 2026-08-14
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "020"
down_revision: Union[str, None] = "019"
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
    if not _has_column("suggestions", "admin_read_at"):
        op.add_column(
            "suggestions",
            sa.Column("admin_read_at", sa.DateTime(timezone=True), nullable=True),
        )


def downgrade():
    if _has_column("suggestions", "admin_read_at"):
        op.drop_column("suggestions", "admin_read_at")
