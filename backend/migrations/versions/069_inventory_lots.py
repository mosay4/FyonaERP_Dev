"""Inventory lots (FIFO/FEFO) + real COGS/profit.

- inventory_lots: one row per purchase batch, kept independent.
- inventory_lot_consumptions: which lot(s) each sold line consumed.
- invoice_items.cost_total / profit: frozen real cost & profit per sale line.

Revision ID: 069
Revises: 068
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "069"
down_revision = "068"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "inventory_lots",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "organization_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("organizations.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "product_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("products.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "branch_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("branches.id", ondelete="SET NULL"),
        ),
        sa.Column(
            "supplier_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("suppliers.id", ondelete="SET NULL"),
        ),
        sa.Column(
            "purchase_invoice_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("invoices.id", ondelete="SET NULL"),
        ),
        sa.Column(
            "invoice_item_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("invoice_items.id", ondelete="SET NULL"),
        ),
        sa.Column(
            "unit_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("product_units.id", ondelete="SET NULL"),
        ),
        sa.Column("received_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("remaining_quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("unit_cost", sa.Numeric(12, 4), nullable=False, server_default="0"),
        sa.Column("currency", sa.String(10)),
        sa.Column("exchange_rate", sa.Numeric(18, 8), server_default="1"),
        sa.Column("purchase_date", sa.Date()),
        sa.Column("expiry_date", sa.Date()),
        sa.Column("lot_number", sa.String(100)),
        sa.Column("source", sa.String(30)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()")),
    )
    op.create_index(
        "ix_lots_org_product", "inventory_lots", ["organization_id", "product_id"]
    )
    op.create_table(
        "inventory_lot_consumptions",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "organization_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("organizations.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "lot_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("inventory_lots.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "invoice_item_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("invoice_items.id", ondelete="CASCADE"),
        ),
        sa.Column("quantity", sa.Float(), nullable=False, server_default="0"),
        sa.Column("unit_cost", sa.Numeric(12, 4), nullable=False, server_default="0"),
        sa.Column("currency", sa.String(10)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()")),
    )
    op.add_column("invoice_items", sa.Column("cost_total", sa.Numeric(12, 2), nullable=True))
    op.add_column("invoice_items", sa.Column("profit", sa.Numeric(12, 2), nullable=True))


def downgrade():
    op.drop_column("invoice_items", "profit")
    op.drop_column("invoice_items", "cost_total")
    op.drop_table("inventory_lot_consumptions")
    op.drop_index("ix_lots_org_product", table_name="inventory_lots")
    op.drop_table("inventory_lots")
