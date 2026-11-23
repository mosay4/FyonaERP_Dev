"""Supplier payables (money owed to suppliers on unpaid purchase invoices).

Mirrors customer_receivables for the purchase side.

Revision ID: 065
Revises: 064
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "065"
down_revision = "064"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "supplier_payables",
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
            sa.ForeignKey("suppliers.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "invoice_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("invoices.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("amount", sa.Numeric(12, 2), nullable=False, server_default="0"),
        sa.Column("paid", sa.Numeric(12, 2), nullable=False, server_default="0"),
        sa.Column("status", sa.String(20), nullable=False, server_default="open"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()")),
        sa.UniqueConstraint("invoice_id", name="uq_payable_invoice"),
        sa.CheckConstraint("amount >= 0", name="ck_payable_amount_non_negative"),
        sa.CheckConstraint("paid >= 0", name="ck_payable_paid_non_negative"),
        sa.CheckConstraint(
            "status IN ('open', 'partial', 'paid', 'cancelled')",
            name="ck_payable_status_valid",
        ),
    )
    op.create_index(
        "ix_supplier_payables_organization_id", "supplier_payables", ["organization_id"]
    )
    op.create_index(
        "ix_supplier_payables_supplier_id", "supplier_payables", ["supplier_id"]
    )
    op.create_index(
        "ix_supplier_payables_invoice_id", "supplier_payables", ["invoice_id"]
    )


def downgrade():
    op.drop_table("supplier_payables")
