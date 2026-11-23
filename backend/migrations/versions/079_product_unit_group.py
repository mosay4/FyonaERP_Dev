"""Add product_units.group — the measurement family of a unit. Additive and
nullable (legacy rows stay NULL = unknown), so it is safe and reversible.

Revision ID: 079
Revises: 078
"""
from alembic import op
import sqlalchemy as sa

revision = "079"
down_revision = "078"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "product_units",
        sa.Column("group", sa.String(20), nullable=True),
    )


def downgrade():
    op.drop_column("product_units", "group")
