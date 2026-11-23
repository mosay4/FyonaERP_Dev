"""Link purchase returns to the original purchase invoice.

Sale returns already link to their invoice (`invoice_returns.invoice_id`).
Purchase returns previously only had `purchase_order_id`; the app's returns
feature always returns against the original purchase INVOICE, so add the
invoice link (and the per-line item link) mirroring the sale-return tables.

Revision ID: 075
Revises: 074
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID

revision = "075"
down_revision = "074"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "purchase_returns",
        sa.Column(
            "invoice_id",
            UUID(as_uuid=True),
            sa.ForeignKey("invoices.id", ondelete="CASCADE"),
            nullable=True,
        ),
    )
    op.create_index(
        "ix_purchase_returns_invoice_id", "purchase_returns", ["invoice_id"]
    )
    op.add_column(
        "purchase_return_items",
        sa.Column(
            "invoice_item_id",
            UUID(as_uuid=True),
            sa.ForeignKey("invoice_items.id", ondelete="SET NULL"),
            nullable=True,
        ),
    )
    op.create_index(
        "ix_purchase_return_items_invoice_item_id",
        "purchase_return_items",
        ["invoice_item_id"],
    )


def downgrade():
    op.drop_index(
        "ix_purchase_return_items_invoice_item_id",
        table_name="purchase_return_items",
    )
    op.drop_column("purchase_return_items", "invoice_item_id")
    op.drop_index("ix_purchase_returns_invoice_id", table_name="purchase_returns")
    op.drop_column("purchase_returns", "invoice_id")
