"""Product-level expiry date (for the «قرب ينتهي» filter + alerts).

Revision ID: 072
Revises: 071
"""
from alembic import op
import sqlalchemy as sa

revision = "072"
down_revision = "071"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("products", sa.Column("expiry_date", sa.Date(), nullable=True))


def downgrade():
    op.drop_column("products", "expiry_date")
