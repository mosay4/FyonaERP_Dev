"""Widen bank_transactions.tx_type to fit the new reconciliation_* types
('reconciliation_decrease' = 24 chars > the old String(20) limit).

Revision ID: 077
Revises: 076
"""
from alembic import op
import sqlalchemy as sa

revision = "077"
down_revision = "076"
branch_labels = None
depends_on = None


def upgrade():
    op.alter_column(
        "bank_transactions",
        "tx_type",
        existing_type=sa.String(20),
        type_=sa.String(40),
        existing_nullable=False,
    )
    op.alter_column(
        "inventory_movements",
        "movement_type",
        existing_type=sa.String(50),
        type_=sa.String(50),
        existing_nullable=False,
    )


def downgrade():
    op.alter_column(
        "bank_transactions",
        "tx_type",
        existing_type=sa.String(40),
        type_=sa.String(20),
        existing_nullable=False,
    )