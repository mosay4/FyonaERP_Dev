"""Sale invoices: product units/barcodes, currency+branch+idempotency on
invoices, line snapshots, payment accounts, receivables, returns-ready.

Revision ID: 062
Revises: 061
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID

revision = "062"
down_revision = "061"
branch_labels = None
depends_on = None


def upgrade():
    # ── product_units ──
    op.create_table(
        "product_units",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("organization_id", UUID(as_uuid=True), nullable=False, index=True),
        sa.Column("product_id", UUID(as_uuid=True), nullable=False, index=True),
        sa.Column("name", sa.String(50), nullable=False),
        sa.Column("factor", sa.Numeric(12, 4), nullable=False, server_default="1"),
        sa.Column("barcode", sa.String(100)),
        sa.Column("sale_price", sa.Numeric(12, 2)),
        sa.Column("purchase_price", sa.Numeric(12, 2)),
        sa.Column("is_base", sa.Boolean(), server_default=sa.false()),
        sa.Column("is_active", sa.Boolean(), server_default=sa.true()),
        sa.Column("created_at", sa.DateTime(timezone=True)),
        sa.Column("updated_at", sa.DateTime(timezone=True)),
        sa.ForeignKeyConstraint(["organization_id"], ["organizations.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["product_id"], ["products.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("organization_id", "product_id", "name", name="uq_unit_org_product_name"),
        sa.CheckConstraint("factor > 0", name="ck_unit_factor_positive"),
    )

    # ── product_barcodes ──
    op.create_table(
        "product_barcodes",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("organization_id", UUID(as_uuid=True), nullable=False, index=True),
        sa.Column("product_id", UUID(as_uuid=True), nullable=False, index=True),
        sa.Column("unit_id", UUID(as_uuid=True), nullable=True, index=True),
        sa.Column("barcode", sa.String(100), nullable=False),
        sa.ForeignKeyConstraint(["organization_id"], ["organizations.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["product_id"], ["products.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["unit_id"], ["product_units.id"], ondelete="SET NULL"),
        sa.UniqueConstraint("organization_id", "barcode", name="uq_barcode_org_code"),
    )

    # ── branches ──
    op.create_table(
        "branches",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("organization_id", UUID(as_uuid=True), nullable=False, index=True),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("is_default", sa.Boolean(), server_default=sa.false()),
        sa.Column("is_active", sa.Boolean(), server_default=sa.true()),
        sa.Column("created_at", sa.DateTime(timezone=True)),
        sa.ForeignKeyConstraint(["organization_id"], ["organizations.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("organization_id", "name", name="uq_branch_org_name"),
    )

    # ── invoices extensions ──
    op.add_column("invoices", sa.Column("currency", sa.String(10), nullable=False, server_default="SAR"))
    op.add_column("invoices", sa.Column("branch_id", UUID(as_uuid=True), nullable=True))
    op.add_column("invoices", sa.Column("idempotency_key", sa.String(100), nullable=True))
    op.create_foreign_key("fk_invoices_branch", "invoices", "branches", ["branch_id"], ["id"], ondelete="SET NULL")
    op.create_unique_constraint("uq_invoices_org_idempotency", "invoices", ["organization_id", "idempotency_key"])

    # ── invoice_items extensions ──
    op.add_column("invoice_items", sa.Column("unit_id", UUID(as_uuid=True), nullable=True))
    op.add_column("invoice_items", sa.Column("unit_name", sa.String(50), nullable=True))
    op.add_column("invoice_items", sa.Column("base_quantity", sa.Float(), server_default="0"))
    op.add_column("invoice_items", sa.Column("is_service", sa.Boolean(), server_default=sa.false()))
    op.create_foreign_key("fk_invoice_items_unit", "invoice_items", "product_units", ["unit_id"], ["id"], ondelete="SET NULL")
    op.create_index("ix_invoice_items_unit_id", "invoice_items", ["unit_id"])

    # ── payments extension ──
    op.add_column("payments", sa.Column("bank_account_id", UUID(as_uuid=True), nullable=True))
    op.create_foreign_key("fk_payments_bank_account", "payments", "bank_accounts", ["bank_account_id"], ["id"], ondelete="SET NULL")
    op.create_index("ix_payments_bank_account_id", "payments", ["bank_account_id"])

    # ── customer_receivables ──
    op.create_table(
        "customer_receivables",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("organization_id", UUID(as_uuid=True), nullable=False, index=True),
        sa.Column("customer_id", UUID(as_uuid=True), nullable=False, index=True),
        sa.Column("invoice_id", UUID(as_uuid=True), nullable=False, index=True),
        sa.Column("amount", sa.Numeric(12, 2), nullable=False, server_default="0"),
        sa.Column("paid", sa.Numeric(12, 2), nullable=False, server_default="0"),
        sa.Column("status", sa.String(20), nullable=False, server_default="open"),
        sa.Column("created_at", sa.DateTime(timezone=True)),
        sa.Column("updated_at", sa.DateTime(timezone=True)),
        sa.ForeignKeyConstraint(["organization_id"], ["organizations.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["customer_id"], ["customers.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["invoice_id"], ["invoices.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("invoice_id", name="uq_receivable_invoice"),
        sa.CheckConstraint("amount >= 0", name="ck_receivable_amount_non_negative"),
        sa.CheckConstraint("paid >= 0", name="ck_receivable_paid_non_negative"),
        sa.CheckConstraint("status IN ('open', 'partial', 'paid', 'cancelled')", name="ck_receivable_status_valid"),
    )

    # ── invoice_returns + items ──
    op.create_table(
        "invoice_returns",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("organization_id", UUID(as_uuid=True), nullable=False, index=True),
        sa.Column("invoice_id", UUID(as_uuid=True), nullable=False, index=True),
        sa.Column("return_number", sa.String(50), nullable=False, index=True),
        sa.Column("return_date", sa.Date(), nullable=False),
        sa.Column("status", sa.String(20), nullable=False, server_default="confirmed"),
        sa.Column("reason", sa.Text()),
        sa.Column("total", sa.Numeric(12, 2), nullable=False, server_default="0"),
        sa.Column("created_by", UUID(as_uuid=True), nullable=True, index=True),
        sa.Column("created_at", sa.DateTime(timezone=True)),
        sa.ForeignKeyConstraint(["organization_id"], ["organizations.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["invoice_id"], ["invoices.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["created_by"], ["users.id"], ondelete="SET NULL"),
        sa.UniqueConstraint("organization_id", "return_number", name="uq_returns_org_number"),
        sa.CheckConstraint("status IN ('confirmed', 'cancelled')", name="ck_return_status_valid"),
    )
    op.create_table(
        "invoice_return_items",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("return_id", UUID(as_uuid=True), nullable=False, index=True),
        sa.Column("invoice_item_id", UUID(as_uuid=True), nullable=True, index=True),
        sa.Column("product_id", UUID(as_uuid=True), nullable=True, index=True),
        sa.Column("description", sa.String(500), nullable=False),
        sa.Column("quantity", sa.Float(), nullable=False),
        sa.Column("unit_price", sa.Numeric(12, 2), nullable=False, server_default="0"),
        sa.Column("total", sa.Numeric(12, 2), nullable=False, server_default="0"),
        sa.ForeignKeyConstraint(["return_id"], ["invoice_returns.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["invoice_item_id"], ["invoice_items.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(["product_id"], ["products.id"], ondelete="SET NULL"),
        sa.CheckConstraint("quantity > 0", name="ck_return_item_qty_positive"),
    )


def downgrade():
    op.drop_table("invoice_return_items")
    op.drop_table("invoice_returns")
    op.drop_table("customer_receivables")
    op.drop_index("ix_payments_bank_account_id", table_name="payments")
    op.drop_constraint("fk_payments_bank_account", "payments", type_="foreignkey")
    op.drop_column("payments", "bank_account_id")
    op.drop_index("ix_invoice_items_unit_id", table_name="invoice_items")
    op.drop_constraint("fk_invoice_items_unit", "invoice_items", type_="foreignkey")
    op.drop_column("invoice_items", "is_service")
    op.drop_column("invoice_items", "base_quantity")
    op.drop_column("invoice_items", "unit_name")
    op.drop_column("invoice_items", "unit_id")
    op.drop_constraint("uq_invoices_org_idempotency", "invoices", type_="unique")
    op.drop_constraint("fk_invoices_branch", "invoices", type_="foreignkey")
    op.drop_column("invoices", "idempotency_key")
    op.drop_column("invoices", "branch_id")
    op.drop_column("invoices", "currency")
    op.drop_table("branches")
    op.drop_table("product_barcodes")
    op.drop_table("product_units")
