"""Optional picture per product category (shown in the in-place browser).

Revision ID: 074
Revises: 073
"""
from alembic import op
import sqlalchemy as sa

revision = "074"
down_revision = "073"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "product_categories", sa.Column("image", sa.String(500), nullable=True)
    )


def downgrade():
    op.drop_column("product_categories", "image")
