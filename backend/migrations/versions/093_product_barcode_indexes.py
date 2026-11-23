"""Fast branch-aware barcode lookup.

Revision ID: 093
Revises: 092
"""
from alembic import op

revision = "093"
down_revision = "092"
branch_labels = None
depends_on = None


def upgrade():
    op.create_index("ix_products_org_branch_barcode", "products",
                    ["organization_id", "branch_id", "barcode"])
    op.create_index("ix_products_org_barcode", "products",
                    ["organization_id", "barcode"])


def downgrade():
    op.drop_index("ix_products_org_barcode", table_name="products")
    op.drop_index("ix_products_org_branch_barcode", table_name="products")
