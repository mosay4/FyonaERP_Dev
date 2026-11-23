"""Store the product stock balance as exact NUMERIC instead of a binary float.

`products.stock` / `products.min_stock`: Float (double precision) → Numeric(18,4).
The running inventory balance is the one number every sale/purchase/adjust/
return/reconciliation reads and writes, so it must be exact. Existing values are
cast WITHOUT arithmetic (`USING stock::numeric`) and the type round-trips for
every realistic quantity (integers / ≤4 decimals) — no balance is recomputed.

Reversible.

Revision ID: 080
Revises: 079
"""
from alembic import op
import sqlalchemy as sa

revision = "080"
down_revision = "079"
branch_labels = None
depends_on = None


def upgrade():
    op.alter_column(
        "products",
        "stock",
        existing_type=sa.Float(),
        type_=sa.Numeric(18, 4),
        existing_nullable=True,
        postgresql_using="stock::numeric",
    )
    op.alter_column(
        "products",
        "min_stock",
        existing_type=sa.Float(),
        type_=sa.Numeric(18, 4),
        existing_nullable=True,
        postgresql_using="min_stock::numeric",
    )


def downgrade():
    op.alter_column(
        "products",
        "stock",
        existing_type=sa.Numeric(18, 4),
        type_=sa.Float(),
        existing_nullable=True,
        postgresql_using="stock::double precision",
    )
    op.alter_column(
        "products",
        "min_stock",
        existing_type=sa.Numeric(18, 4),
        type_=sa.Float(),
        existing_nullable=True,
        postgresql_using="min_stock::double precision",
    )
