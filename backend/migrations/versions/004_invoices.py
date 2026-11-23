"""Add invoice tables (invoices, invoice_items, payments, invoice_sequences)

Revision ID: 004
Revises: 003
Create Date: 2026-07-14
"""

from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "004"
down_revision: Union[str, None] = "003"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # invoice_sequences (used for number generation)
    op.create_table(
        "invoice_sequences",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "organization_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("organizations.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("prefix", sa.String(20), nullable=False),
        sa.Column("last_sequence", sa.Integer, default=0),
        sa.Column("date", sa.Date, nullable=False),
    )
    op.create_index(
        "ix_inv_seq_org_prefix",
        "invoice_sequences",
        ["organization_id", "prefix", "date"],
    )

    # invoices
    op.create_table(
        "invoices",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "organization_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("organizations.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("invoice_number", sa.String(50), nullable=False),
        sa.Column("invoice_type", sa.String(20), nullable=False, default="sale"),
        sa.Column(
            "customer_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("customers.id", ondelete="SET NULL"),
        ),
        sa.Column(
            "supplier_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("suppliers.id", ondelete="SET NULL"),
        ),
        sa.Column("invoice_date", sa.Date, nullable=False),
        sa.Column("due_date", sa.Date),
        sa.Column("status", sa.String(20), nullable=False, default="draft"),
        sa.Column("subtotal", sa.Float, default=0),
        sa.Column("discount_type", sa.String(20)),
        sa.Column("discount_value", sa.Float, default=0),
        sa.Column("discount_amount", sa.Float, default=0),
        sa.Column("tax_type", sa.String(20)),
        sa.Column("tax_rate", sa.Float, default=0),
        sa.Column("tax_amount", sa.Float, default=0),
        sa.Column("total", sa.Float, default=0),
        sa.Column("paid_amount", sa.Float, default=0),
        sa.Column("balance", sa.Float, default=0),
        sa.Column("notes", sa.Text),
        sa.Column("terms", sa.Text),
        sa.Column(
            "created_by",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
        ),
        sa.Column("created_at", sa.DateTime(timezone=True)),
        sa.Column("updated_at", sa.DateTime(timezone=True)),
        sa.Column("is_deleted", sa.Boolean, default=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True)),
        sa.Column("confirmed_at", sa.DateTime(timezone=True)),
        sa.Column("cancelled_at", sa.DateTime(timezone=True)),
    )
    op.create_index(
        "ix_invoices_org_number", "invoices", ["organization_id", "invoice_number"]
    )
    op.create_index("ix_invoices_org_status", "invoices", ["organization_id", "status"])

    # invoice_items
    op.create_table(
        "invoice_items",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "invoice_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("invoices.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "product_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("products.id", ondelete="SET NULL"),
        ),
        sa.Column("description", sa.String(500), nullable=False),
        sa.Column("quantity", sa.Float, nullable=False, default=1),
        sa.Column("unit_price", sa.Float, nullable=False, default=0),
        sa.Column("discount", sa.Float, default=0),
        sa.Column("tax_rate", sa.Float, default=0),
        sa.Column("total", sa.Float, default=0),
    )
    op.create_index("ix_invoice_items_invoice", "invoice_items", ["invoice_id"])

    # payments
    op.create_table(
        "payments",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "organization_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("organizations.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "invoice_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("invoices.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("amount", sa.Float, nullable=False),
        sa.Column("payment_date", sa.Date, nullable=False),
        sa.Column("payment_method", sa.String(50), default="cash"),
        sa.Column("reference", sa.String(200)),
        sa.Column("notes", sa.Text),
        sa.Column(
            "created_by",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
        ),
        sa.Column("created_at", sa.DateTime(timezone=True)),
    )
    op.create_index("ix_payments_invoice", "payments", ["invoice_id"])


def downgrade() -> None:
    op.drop_table("payments")
    op.drop_table("invoice_items")
    op.drop_table("invoices")
    op.drop_table("invoice_sequences")
