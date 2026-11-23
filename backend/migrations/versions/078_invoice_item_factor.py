"""Add invoice_items.factor — the conversion-factor snapshot frozen at issue
time (base units per sold unit). Historical sales/purchases and their returns
must never depend on the unit's CURRENT factor.

Additive + nullable → safe and reversible. Legacy rows stay NULL and fall back
to the unit's current factor (unchanged behaviour).

Revision ID: 078
Revises: 077
"""
from alembic import op
import sqlalchemy as sa

revision = "078"
down_revision = "077"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "invoice_items",
        sa.Column("factor", sa.Numeric(12, 4), nullable=True),
    )


def downgrade():
    op.drop_column("invoice_items", "factor")
