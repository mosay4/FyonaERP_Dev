"""Add sales, purchases, and accounting tables for Milestone 4

Revision ID: 007
Revises: 006
Create Date: 2026-07-14
"""

from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "007"
down_revision: Union[str, None] = "006"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _table_exists(name: str) -> bool:
    conn = op.get_bind()
    r = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = :n)"
        ),
        {"n": name},
    )
    return r.scalar()


def upgrade() -> None:
    # ── Sales Orders ──
    if not _table_exists("sales_orders"):
        op.create_table(
            "sales_orders",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "organization_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("organizations.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "customer_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("customers.id", ondelete="SET NULL"),
            ),
            sa.Column("order_number", sa.String(50), nullable=False),
            sa.Column("order_date", sa.Date, nullable=False),
            sa.Column("status", sa.String(20), nullable=False, server_default="draft"),
            sa.Column("subtotal", sa.Numeric(12, 2), server_default="0"),
            sa.Column("discount_type", sa.String(20)),
            sa.Column("discount_value", sa.Numeric(12, 2), server_default="0"),
            sa.Column("discount_amount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("tax_type", sa.String(20)),
            sa.Column("tax_rate", sa.Numeric(5, 2), server_default="0"),
            sa.Column("tax_amount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("total", sa.Numeric(12, 2), server_default="0"),
            sa.Column("paid_amount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("balance", sa.Numeric(12, 2), server_default="0"),
            sa.Column("notes", sa.Text),
            sa.Column("terms", sa.Text),
            sa.Column(
                "created_by",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("users.id", ondelete="SET NULL"),
            ),
            sa.Column("created_at", sa.DateTime(timezone=True)),
            sa.Column("updated_at", sa.DateTime(timezone=True)),
            sa.Column("is_deleted", sa.Boolean, server_default="false"),
            sa.Column("deleted_at", sa.DateTime(timezone=True)),
            sa.Column("confirmed_at", sa.DateTime(timezone=True)),
            sa.Column("delivered_at", sa.DateTime(timezone=True)),
            sa.Column("cancelled_at", sa.DateTime(timezone=True)),
        )
        op.create_index(
            "ix_so_org_number", "sales_orders", ["organization_id", "order_number"]
        )
        op.create_index(
            "ix_so_org_status", "sales_orders", ["organization_id", "status"]
        )

    # ── Sales Order Items ──
    if not _table_exists("sales_order_items"):
        op.create_table(
            "sales_order_items",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "sales_order_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("sales_orders.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "product_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("products.id", ondelete="SET NULL"),
            ),
            sa.Column("description", sa.String(500), nullable=False),
            sa.Column("quantity", sa.Float, nullable=False, server_default="1"),
            sa.Column(
                "unit_price", sa.Numeric(12, 2), nullable=False, server_default="0"
            ),
            sa.Column("discount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("tax_rate", sa.Numeric(5, 2), server_default="0"),
            sa.Column("total", sa.Numeric(12, 2), server_default="0"),
        )
        op.create_index("ix_soi_order", "sales_order_items", ["sales_order_id"])

    # ── Sales Returns ──
    if not _table_exists("sales_returns"):
        op.create_table(
            "sales_returns",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "organization_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("organizations.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "customer_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("customers.id", ondelete="SET NULL"),
            ),
            sa.Column(
                "sales_order_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("sales_orders.id", ondelete="SET NULL"),
            ),
            sa.Column("return_number", sa.String(50), nullable=False),
            sa.Column("return_date", sa.Date, nullable=False),
            sa.Column("status", sa.String(20), nullable=False, server_default="draft"),
            sa.Column("reason", sa.Text),
            sa.Column("total", sa.Numeric(12, 2), server_default="0"),
            sa.Column("notes", sa.Text),
            sa.Column(
                "created_by",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("users.id", ondelete="SET NULL"),
            ),
            sa.Column("created_at", sa.DateTime(timezone=True)),
            sa.Column("updated_at", sa.DateTime(timezone=True)),
        )
        op.create_index(
            "ix_sr_org_number", "sales_returns", ["organization_id", "return_number"]
        )

    # ── Sales Return Items ──
    if not _table_exists("sales_return_items"):
        op.create_table(
            "sales_return_items",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "sales_return_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("sales_returns.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "product_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("products.id", ondelete="SET NULL"),
            ),
            sa.Column("description", sa.String(500), nullable=False),
            sa.Column("quantity", sa.Float, nullable=False, server_default="1"),
            sa.Column("unit_price", sa.Numeric(12, 2), server_default="0"),
            sa.Column("total", sa.Numeric(12, 2), server_default="0"),
        )
        op.create_index("ix_sri_return", "sales_return_items", ["sales_return_id"])

    # ── Sales Quotes ──
    if not _table_exists("sales_quotes"):
        op.create_table(
            "sales_quotes",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "organization_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("organizations.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "customer_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("customers.id", ondelete="SET NULL"),
            ),
            sa.Column("quote_number", sa.String(50), nullable=False),
            sa.Column("quote_date", sa.Date, nullable=False),
            sa.Column("expiry_date", sa.Date),
            sa.Column("status", sa.String(20), nullable=False, server_default="draft"),
            sa.Column("subtotal", sa.Numeric(12, 2), server_default="0"),
            sa.Column("discount_type", sa.String(20)),
            sa.Column("discount_value", sa.Numeric(12, 2), server_default="0"),
            sa.Column("discount_amount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("tax_type", sa.String(20)),
            sa.Column("tax_rate", sa.Numeric(5, 2), server_default="0"),
            sa.Column("tax_amount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("total", sa.Numeric(12, 2), server_default="0"),
            sa.Column("notes", sa.Text),
            sa.Column("terms", sa.Text),
            sa.Column(
                "created_by",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("users.id", ondelete="SET NULL"),
            ),
            sa.Column("created_at", sa.DateTime(timezone=True)),
            sa.Column("updated_at", sa.DateTime(timezone=True)),
        )
        op.create_index(
            "ix_sq_org_number", "sales_quotes", ["organization_id", "quote_number"]
        )

    if not _table_exists("quote_items"):
        op.create_table(
            "quote_items",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "quote_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("sales_quotes.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "product_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("products.id", ondelete="SET NULL"),
            ),
            sa.Column("description", sa.String(500), nullable=False),
            sa.Column("quantity", sa.Float, nullable=False, server_default="1"),
            sa.Column(
                "unit_price", sa.Numeric(12, 2), nullable=False, server_default="0"
            ),
            sa.Column("discount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("total", sa.Numeric(12, 2), server_default="0"),
        )

    if not _table_exists("delivery_notes"):
        op.create_table(
            "delivery_notes",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "organization_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("organizations.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "customer_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("customers.id", ondelete="SET NULL"),
            ),
            sa.Column(
                "sales_order_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("sales_orders.id", ondelete="SET NULL"),
            ),
            sa.Column("delivery_number", sa.String(50), nullable=False),
            sa.Column("delivery_date", sa.Date, nullable=False),
            sa.Column("status", sa.String(20), nullable=False, server_default="draft"),
            sa.Column("notes", sa.Text),
            sa.Column(
                "created_by",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("users.id", ondelete="SET NULL"),
            ),
            sa.Column("created_at", sa.DateTime(timezone=True)),
            sa.Column("updated_at", sa.DateTime(timezone=True)),
        )
        op.create_index(
            "ix_dn_org_number", "delivery_notes", ["organization_id", "delivery_number"]
        )

    if not _table_exists("delivery_note_items"):
        op.create_table(
            "delivery_note_items",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "delivery_note_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("delivery_notes.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "product_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("products.id", ondelete="SET NULL"),
            ),
            sa.Column("description", sa.String(500), nullable=False),
            sa.Column("quantity", sa.Float, nullable=False, server_default="1"),
            sa.Column("unit_price", sa.Numeric(12, 2), server_default="0"),
            sa.Column("total", sa.Numeric(12, 2), server_default="0"),
        )

    # ── Purchase Orders ──
    if not _table_exists("purchase_orders"):
        op.create_table(
            "purchase_orders",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "organization_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("organizations.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "supplier_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("suppliers.id", ondelete="SET NULL"),
            ),
            sa.Column("order_number", sa.String(50), nullable=False),
            sa.Column("order_date", sa.Date, nullable=False),
            sa.Column("status", sa.String(20), nullable=False, server_default="draft"),
            sa.Column("subtotal", sa.Numeric(12, 2), server_default="0"),
            sa.Column("discount_type", sa.String(20)),
            sa.Column("discount_value", sa.Numeric(12, 2), server_default="0"),
            sa.Column("discount_amount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("tax_type", sa.String(20)),
            sa.Column("tax_rate", sa.Numeric(5, 2), server_default="0"),
            sa.Column("tax_amount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("total", sa.Numeric(12, 2), server_default="0"),
            sa.Column("paid_amount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("balance", sa.Numeric(12, 2), server_default="0"),
            sa.Column("notes", sa.Text),
            sa.Column("terms", sa.Text),
            sa.Column(
                "created_by",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("users.id", ondelete="SET NULL"),
            ),
            sa.Column("created_at", sa.DateTime(timezone=True)),
            sa.Column("updated_at", sa.DateTime(timezone=True)),
            sa.Column("is_deleted", sa.Boolean, server_default="false"),
            sa.Column("deleted_at", sa.DateTime(timezone=True)),
            sa.Column("confirmed_at", sa.DateTime(timezone=True)),
            sa.Column("received_at", sa.DateTime(timezone=True)),
            sa.Column("cancelled_at", sa.DateTime(timezone=True)),
        )
        op.create_index(
            "ix_po_org_number", "purchase_orders", ["organization_id", "order_number"]
        )

    if not _table_exists("purchase_order_items"):
        op.create_table(
            "purchase_order_items",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "purchase_order_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("purchase_orders.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "product_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("products.id", ondelete="SET NULL"),
            ),
            sa.Column("description", sa.String(500), nullable=False),
            sa.Column("quantity", sa.Float, nullable=False, server_default="1"),
            sa.Column(
                "unit_price", sa.Numeric(12, 2), nullable=False, server_default="0"
            ),
            sa.Column("discount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("total", sa.Numeric(12, 2), server_default="0"),
        )

    if not _table_exists("purchase_receipts"):
        op.create_table(
            "purchase_receipts",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "organization_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("organizations.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "supplier_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("suppliers.id", ondelete="SET NULL"),
            ),
            sa.Column(
                "purchase_order_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("purchase_orders.id", ondelete="SET NULL"),
            ),
            sa.Column("receipt_number", sa.String(50), nullable=False),
            sa.Column("receipt_date", sa.Date, nullable=False),
            sa.Column("status", sa.String(20), nullable=False, server_default="draft"),
            sa.Column("notes", sa.Text),
            sa.Column(
                "created_by",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("users.id", ondelete="SET NULL"),
            ),
            sa.Column("created_at", sa.DateTime(timezone=True)),
            sa.Column("updated_at", sa.DateTime(timezone=True)),
        )
        op.create_index(
            "ix_prec_org_number",
            "purchase_receipts",
            ["organization_id", "receipt_number"],
        )

    if not _table_exists("purchase_receipt_items"):
        op.create_table(
            "purchase_receipt_items",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "purchase_receipt_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("purchase_receipts.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "product_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("products.id", ondelete="SET NULL"),
            ),
            sa.Column("description", sa.String(500), nullable=False),
            sa.Column("quantity", sa.Float, nullable=False, server_default="1"),
            sa.Column("unit_price", sa.Numeric(12, 2), server_default="0"),
            sa.Column("total", sa.Numeric(12, 2), server_default="0"),
        )

    if not _table_exists("purchase_returns"):
        op.create_table(
            "purchase_returns",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "organization_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("organizations.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "supplier_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("suppliers.id", ondelete="SET NULL"),
            ),
            sa.Column(
                "purchase_order_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("purchase_orders.id", ondelete="SET NULL"),
            ),
            sa.Column("return_number", sa.String(50), nullable=False),
            sa.Column("return_date", sa.Date, nullable=False),
            sa.Column("status", sa.String(20), nullable=False, server_default="draft"),
            sa.Column("reason", sa.Text),
            sa.Column("total", sa.Numeric(12, 2), server_default="0"),
            sa.Column("notes", sa.Text),
            sa.Column(
                "created_by",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("users.id", ondelete="SET NULL"),
            ),
            sa.Column("created_at", sa.DateTime(timezone=True)),
            sa.Column("updated_at", sa.DateTime(timezone=True)),
        )
        op.create_index(
            "ix_pur_org_number",
            "purchase_returns",
            ["organization_id", "return_number"],
        )

    if not _table_exists("purchase_return_items"):
        op.create_table(
            "purchase_return_items",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "purchase_return_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("purchase_returns.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "product_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("products.id", ondelete="SET NULL"),
            ),
            sa.Column("description", sa.String(500), nullable=False),
            sa.Column("quantity", sa.Float, nullable=False, server_default="1"),
            sa.Column("unit_price", sa.Numeric(12, 2), server_default="0"),
            sa.Column("total", sa.Numeric(12, 2), server_default="0"),
        )

    if not _table_exists("supplier_bills"):
        op.create_table(
            "supplier_bills",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "organization_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("organizations.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "supplier_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("suppliers.id", ondelete="SET NULL"),
            ),
            sa.Column(
                "purchase_order_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("purchase_orders.id", ondelete="SET NULL"),
            ),
            sa.Column("bill_number", sa.String(50), nullable=False),
            sa.Column("bill_date", sa.Date, nullable=False),
            sa.Column("due_date", sa.Date),
            sa.Column("status", sa.String(20), nullable=False, server_default="draft"),
            sa.Column("subtotal", sa.Numeric(12, 2), server_default="0"),
            sa.Column("discount_type", sa.String(20)),
            sa.Column("discount_value", sa.Numeric(12, 2), server_default="0"),
            sa.Column("discount_amount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("tax_type", sa.String(20)),
            sa.Column("tax_rate", sa.Numeric(5, 2), server_default="0"),
            sa.Column("tax_amount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("total", sa.Numeric(12, 2), server_default="0"),
            sa.Column("paid_amount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("balance", sa.Numeric(12, 2), server_default="0"),
            sa.Column("notes", sa.Text),
            sa.Column(
                "created_by",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("users.id", ondelete="SET NULL"),
            ),
            sa.Column("created_at", sa.DateTime(timezone=True)),
            sa.Column("updated_at", sa.DateTime(timezone=True)),
        )
        op.create_index(
            "ix_sb_org_number", "supplier_bills", ["organization_id", "bill_number"]
        )

    # ── Accounting ──
    if not _table_exists("accounts"):
        op.create_table(
            "accounts",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "organization_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("organizations.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column("code", sa.String(20), nullable=False),
            sa.Column("name", sa.String(200), nullable=False),
            sa.Column("name_ar", sa.String(200)),
            sa.Column("type", sa.String(20), nullable=False),
            sa.Column(
                "parent_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("accounts.id", ondelete="SET NULL"),
            ),
            sa.Column("is_active", sa.Boolean, server_default="true"),
            sa.Column("balance", sa.Numeric(12, 2), server_default="0"),
            sa.Column("created_at", sa.DateTime(timezone=True)),
            sa.Column("updated_at", sa.DateTime(timezone=True)),
        )
        op.create_index("ix_account_org_code", "accounts", ["organization_id", "code"])

    if not _table_exists("journal_entries"):
        op.create_table(
            "journal_entries",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "organization_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("organizations.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column("entry_number", sa.String(50), nullable=False),
            sa.Column("entry_date", sa.Date, nullable=False),
            sa.Column("description", sa.Text, nullable=False),
            sa.Column("reference_type", sa.String(50)),
            sa.Column("reference_id", postgresql.UUID(as_uuid=True)),
            sa.Column("status", sa.String(20), nullable=False, server_default="draft"),
            sa.Column(
                "created_by",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("users.id", ondelete="SET NULL"),
            ),
            sa.Column("created_at", sa.DateTime(timezone=True)),
            sa.Column("updated_at", sa.DateTime(timezone=True)),
            sa.Column("posted_at", sa.DateTime(timezone=True)),
            sa.Column("cancelled_at", sa.DateTime(timezone=True)),
        )
        op.create_index(
            "ix_je_org_number", "journal_entries", ["organization_id", "entry_number"]
        )

    if not _table_exists("journal_entry_lines"):
        op.create_table(
            "journal_entry_lines",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
            sa.Column(
                "journal_entry_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("journal_entries.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "account_id",
                postgresql.UUID(as_uuid=True),
                sa.ForeignKey("accounts.id", ondelete="RESTRICT"),
                nullable=False,
            ),
            sa.Column("description", sa.String(500)),
            sa.Column("debit", sa.Numeric(12, 2), server_default="0"),
            sa.Column("credit", sa.Numeric(12, 2), server_default="0"),
        )
        op.create_index("ix_jel_entry", "journal_entry_lines", ["journal_entry_id"])


def downgrade() -> None:
    tables = [
        "journal_entry_lines",
        "journal_entries",
        "accounts",
        "supplier_bills",
        "purchase_return_items",
        "purchase_returns",
        "purchase_receipt_items",
        "purchase_receipts",
        "purchase_order_items",
        "purchase_orders",
        "delivery_note_items",
        "delivery_notes",
        "quote_items",
        "sales_quotes",
        "sales_return_items",
        "sales_returns",
        "sales_order_items",
        "sales_orders",
    ]
    for t in tables:
        if _table_exists(t):
            op.drop_table(t)
