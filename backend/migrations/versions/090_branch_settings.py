"""Per-branch durable settings (currency customization, etc.).

Revision ID: 090
Revises: 089
"""
from alembic import op
import sqlalchemy as sa

revision = "090"
down_revision = "089"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("branches", sa.Column("settings", sa.JSON(), nullable=True))


def downgrade():
    op.drop_column("branches", "settings")
