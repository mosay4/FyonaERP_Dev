"""Independent Personal/Business entitlements and business setup marker.

Revision ID: 061
Revises: 060
"""
from alembic import op
import sqlalchemy as sa

revision = "061"
down_revision = "060"
branch_labels = None
depends_on = None


def upgrade():
    # NULL deliberately means legacy: derive the entitlement from the old
    # subscription fields until its first mutation. Existing dates are retained.
    op.add_column("organizations", sa.Column("section_subscriptions", sa.JSON(), nullable=True))
    op.add_column("organizations", sa.Column("business_setup_completed", sa.Boolean(), nullable=False, server_default=sa.false()))


def downgrade():
    op.drop_column("organizations", "business_setup_completed")
    op.drop_column("organizations", "section_subscriptions")
