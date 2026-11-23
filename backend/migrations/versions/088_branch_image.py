"""Per-branch profile image.

Revision ID: 088
Revises: 087
"""
from alembic import op
import sqlalchemy as sa

revision = "088"
down_revision = "087"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("branches", sa.Column("image", sa.String(500),
                                        nullable=True))


def downgrade():
    op.drop_column("branches", "image")
