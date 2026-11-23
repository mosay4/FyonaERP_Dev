"""Invoice line price snapshot (original sell price + currency + FX used).

Keeps the exact sell price/currency/unit and conversion used at issue time so
an old invoice never changes when the product price or FX rate changes later.

Revision ID: 070
Revises: 069
"""
from alembic import op
import sqlalchemy as sa

revision = "070"
down_revision = "069"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("invoice_items", sa.Column("original_unit_price", sa.Numeric(12, 2), nullable=True))
    op.add_column("invoice_items", sa.Column("price_currency", sa.String(10), nullable=True))
    op.add_column("invoice_items", sa.Column("exchange_rate_used", sa.Numeric(18, 8), nullable=True))


def downgrade():
    op.drop_column("invoice_items", "exchange_rate_used")
    op.drop_column("invoice_items", "price_currency")
    op.drop_column("invoice_items", "original_unit_price")
