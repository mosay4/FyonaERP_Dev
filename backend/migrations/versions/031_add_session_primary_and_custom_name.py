"""Add is_primary and custom_name to user_sessions

Revision ID: 031
Revises: 030
Create Date: 2026-09-01
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

revision = "031"
down_revision = "030"
branch_labels = None
depends_on = None


def upgrade():
    add_column_if_missing("user_sessions", sa.Column("is_primary", sa.Boolean(), server_default=sa.text("false"), nullable=False))
    add_column_if_missing("user_sessions", sa.Column("custom_name", sa.String(200), nullable=True))


def downgrade():
    op.drop_column("user_sessions", "custom_name")
    op.drop_column("user_sessions", "is_primary")
