"""Barcode/SKU uniqueness is per branch, not per organization.

Revision ID: 091
Revises: 090
"""
from alembic import op

revision = "091"
down_revision = "090"
branch_labels = None
depends_on = None


def upgrade():
    op.drop_constraint("uq_products_org_sku", "products", type_="unique")
    op.drop_constraint("uq_products_org_barcode", "products", type_="unique")


def downgrade():
    op.create_unique_constraint("uq_products_org_sku", "products",
                                ["organization_id", "sku"])
    op.create_unique_constraint("uq_products_org_barcode", "products",
                                ["organization_id", "barcode"])
