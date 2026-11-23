"""Add suggestions table for the product suggestions feature.

Revision ID: 012
Revises: 011
Create Date: 2026-08-01
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "012"
down_revision: Union[str, None] = "011"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _exists(table):
    conn = op.get_bind()
    r = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = :n)"
        ),
        {"n": table},
    )
    return r.scalar()


def upgrade():
    if not _exists("suggestions"):
        op.create_table(
            "suggestions",
            sa.Column("id", postgresql.UUID(), primary_key=True),
            sa.Column("user_id", postgresql.UUID(), nullable=False, index=True),
            sa.Column("organization_id", postgresql.UUID(), nullable=True, index=True),
            sa.Column("title", sa.String(200), server_default=""),
            sa.Column("body", sa.Text(), nullable=False),
            sa.Column("images", sa.JSON(), server_default="[]"),
            sa.Column("status", sa.String(20), server_default="pending"),
            sa.Column("admin_note", sa.Text(), nullable=True),
            sa.Column("is_deleted", sa.Boolean(), server_default="false"),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        )


def downgrade():
    if _exists("suggestions"):
        op.drop_table("suggestions")
