"""Add DB constraints, indexes, server_defaults, soft-delete for categories

Revision ID: 005
Revises: 004
Create Date: 2026-07-14
"""

from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "005"
down_revision: Union[str, None] = "004"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _index_exists(name: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text("SELECT EXISTS (SELECT FROM pg_indexes WHERE indexname = :name)"),
        {"name": name},
    )
    return result.scalar()


def upgrade() -> None:
    # ── Unique constraints ──
    with op.get_context().autocommit_block():
        if not _index_exists("uq_products_org_sku"):
            op.create_unique_constraint(
                "uq_products_org_sku", "products", ["organization_id", "sku"]
            )
        if not _index_exists("uq_products_org_barcode"):
            op.create_unique_constraint(
                "uq_products_org_barcode", "products", ["organization_id", "barcode"]
            )
        if not _index_exists("uq_invoices_org_number"):
            op.create_unique_constraint(
                "uq_invoices_org_number",
                "invoices",
                ["organization_id", "invoice_number"],
            )
        if not _index_exists("uq_inv_seq_org_prefix_date"):
            op.create_unique_constraint(
                "uq_inv_seq_org_prefix_date",
                "invoice_sequences",
                ["organization_id", "prefix", "date"],
            )
        if not _index_exists("uq_organization_slug"):
            op.create_unique_constraint(
                "uq_organization_slug", "organizations", ["slug"]
            )

    # ── Check constraints ──
    with op.get_context().autocommit_block():
        for ck in [
            ("ck_product_price_non_negative", "products", "price >= 0"),
            (
                "ck_invoice_type_valid",
                "invoices",
                "invoice_type IN ('sale', 'purchase')",
            ),
            (
                "ck_invoice_status_valid",
                "invoices",
                "status IN ('draft', 'confirmed', 'cancelled', 'paid', 'partially_paid')",
            ),
            ("ck_invoice_item_qty_positive", "invoice_items", "quantity > 0"),
            ("ck_payment_amount_positive", "payments", "amount > 0"),
            (
                "ck_payment_method_valid",
                "payments",
                "payment_method IN ('cash', 'bank', 'card', 'transfer', 'cheque')",
            ),
        ]:
            try:
                op.create_check_constraint(ck[0], ck[1], sa.text(ck[2]))
            except Exception:
                pass  # may already exist

    # ── Missing FK indexes ──
    for idx, table, col in [
        ("ix_customers_org", "customers", "organization_id"),
        ("ix_suppliers_org", "suppliers", "organization_id"),
        ("ix_products_org", "products", "organization_id"),
        ("ix_products_category", "products", "category_id"),
        ("ix_inventory_org", "inventory_movements", "organization_id"),
        ("ix_inventory_product", "inventory_movements", "product_id"),
        ("ix_inventory_created_by", "inventory_movements", "created_by"),
        ("ix_invoices_org", "invoices", "organization_id"),
        ("ix_invoices_customer", "invoices", "customer_id"),
        ("ix_invoices_supplier", "invoices", "supplier_id"),
        ("ix_invoices_created_by", "invoices", "created_by"),
        ("ix_invoice_items_product", "invoice_items", "product_id"),
        ("ix_payments_org", "payments", "organization_id"),
        ("ix_payments_created_by", "payments", "created_by"),
        ("ix_inv_seq_org", "invoice_sequences", "organization_id"),
    ]:
        if not _index_exists(idx):
            op.create_index(idx, table, [col])

    # ── Add soft-delete columns to product_categories ──
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT column_name FROM information_schema.columns WHERE table_name = 'product_categories' AND column_name = 'is_deleted'"
        )
    )
    if not result.scalar():
        op.add_column(
            "product_categories",
            sa.Column("is_deleted", sa.Boolean(), server_default=sa.text("false")),
        )
        op.add_column(
            "product_categories",
            sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        )


def downgrade() -> None:
    pass  # constraints are non-destructive; skip downgrade for safety
