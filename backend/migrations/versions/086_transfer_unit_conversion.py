"""Persist target-base quantity and unit conversion for inventory transfers.

Existing transfer items keep the legacy 1:1 base relationship.

Revision ID: 086
Revises: 085
"""
from alembic import op
import sqlalchemy as sa

revision = "086"
down_revision = "085"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("branch_transfer_items", sa.Column(
        "target_base_quantity", sa.Numeric(18, 4), nullable=False,
        server_default="0"))
    op.add_column("branch_transfer_items", sa.Column(
        "conversion_factor", sa.Numeric(18, 6), nullable=False,
        server_default="1"))
    op.execute(
        "UPDATE branch_transfer_items SET target_base_quantity = base_quantity "
        "WHERE target_base_quantity = 0")


def downgrade():
    op.drop_column("branch_transfer_items", "conversion_factor")
    op.drop_column("branch_transfer_items", "target_base_quantity")
