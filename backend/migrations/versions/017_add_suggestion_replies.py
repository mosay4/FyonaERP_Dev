"""Add suggestion_replies table for admin-to-user replies on suggestions.

Revision ID: 017
Revises: 016
Create Date: 2026-08-12
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "017"
down_revision: Union[str, None] = "016"
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
    if not _exists("suggestion_replies"):
        op.create_table(
            "suggestion_replies",
            sa.Column("id", postgresql.UUID(), primary_key=True),
            sa.Column("suggestion_id", postgresql.UUID(), nullable=False, index=True),
            sa.Column("user_id", postgresql.UUID(), nullable=False, index=True),
            sa.Column("admin_id", postgresql.UUID(), nullable=True),
            sa.Column("body", sa.Text(), nullable=False),
            sa.Column("is_deleted", sa.Boolean(), server_default="false"),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        )
        op.create_foreign_key(
            "fk_suggestion_replies_suggestion",
            "suggestion_replies",
            "suggestions",
            ["suggestion_id"],
            ["id"],
            ondelete="CASCADE",
        )


def downgrade():
    if _exists("suggestion_replies"):
        op.drop_table("suggestion_replies")
