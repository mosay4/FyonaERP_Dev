"""Add device_tokens table for FCM push notification registrations.

Revision ID: 019
Revises: 018
Create Date: 2026-08-13
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "019"
down_revision: Union[str, None] = "018"
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
    if not _exists("device_tokens"):
        op.create_table(
            "device_tokens",
            sa.Column("id", postgresql.UUID(), primary_key=True),
            sa.Column("user_id", postgresql.UUID(), nullable=False, index=True),
            sa.Column("token", sa.String(500), nullable=False, index=True),
            sa.Column("platform", sa.String(30), nullable=True),
            sa.Column("is_active", sa.Boolean(), server_default="true"),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        )


def downgrade():
    if _exists("device_tokens"):
        op.drop_table("device_tokens")
