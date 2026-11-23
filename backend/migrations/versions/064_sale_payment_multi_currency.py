"""Sale payment multi-currency snapshot columns.

Adds the frozen exchange-rate snapshot fields used by business sale split
payments: a payment can be received in a different currency than the invoice,
so we store the money as received plus its conversion at issue time.

Revision ID: 064
Revises: 063
"""
from alembic import op
import sqlalchemy as sa

revision = "064"
down_revision = "063"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "payments", sa.Column("payment_currency", sa.String(10), nullable=True)
    )
    op.add_column(
        "payments", sa.Column("invoice_currency", sa.String(10), nullable=True)
    )
    op.add_column(
        "payments", sa.Column("original_amount", sa.Numeric(12, 2), nullable=True)
    )
    op.add_column(
        "payments", sa.Column("exchange_rate", sa.Numeric(18, 8), nullable=True)
    )
    op.add_column(
        "payments", sa.Column("equivalent_amount", sa.Numeric(12, 2), nullable=True)
    )
    op.add_column(
        "payments", sa.Column("exchange_rate_source", sa.String(20), nullable=True)
    )
    op.add_column(
        "payments",
        sa.Column("exchange_rate_timestamp", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade():
    op.drop_column("payments", "exchange_rate_timestamp")
    op.drop_column("payments", "exchange_rate_source")
    op.drop_column("payments", "equivalent_amount")
    op.drop_column("payments", "exchange_rate")
    op.drop_column("payments", "original_amount")
    op.drop_column("payments", "invoice_currency")
    op.drop_column("payments", "payment_currency")
