"""Purchase cost currency snapshot.

A purchase line's price is recorded in the invoice currency. Stores the
currency alongside the product's running cost and the inventory movement so a
historical purchase cost is never silently re-converted when exchange rates
change.

Revision ID: 066
Revises: 065
"""
from alembic import op
import sqlalchemy as sa

revision = "066"
down_revision = "065"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "products", sa.Column("cost_currency", sa.String(10), nullable=True)
    )
    op.add_column(
        "inventory_movements", sa.Column("currency", sa.String(10), nullable=True)
    )


def downgrade():
    op.drop_column("inventory_movements", "currency")
    op.drop_column("products", "cost_currency")
