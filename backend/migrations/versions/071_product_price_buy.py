"""Per-currency BUY price alongside the sell price.

Each product_prices row now carries both the purchase (buy_price) and sell
(price) price for that currency, kept fully independent.

Revision ID: 071
Revises: 070
"""
from alembic import op
import sqlalchemy as sa

revision = "071"
down_revision = "070"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("product_prices", sa.Column("buy_price", sa.Numeric(12, 2), nullable=True))


def downgrade():
    op.drop_column("product_prices", "buy_price")
