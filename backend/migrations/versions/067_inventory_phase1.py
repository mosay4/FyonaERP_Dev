"""Inventory phase 1: movement audit columns + invoice item image snapshot.

- inventory_movements gains the plain-language adjustment audit trail
  (reason / old_quantity / new_quantity / difference / branch_id).
- invoice_items gains a frozen product-image snapshot so old invoices keep
  the picture that existed at issue time.

Revision ID: 067
Revises: 066
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "067"
down_revision = "066"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("inventory_movements", sa.Column("reason", sa.String(40), nullable=True))
    op.add_column("inventory_movements", sa.Column("old_quantity", sa.Float(), nullable=True))
    op.add_column("inventory_movements", sa.Column("new_quantity", sa.Float(), nullable=True))
    op.add_column("inventory_movements", sa.Column("difference", sa.Float(), nullable=True))
    op.add_column(
        "inventory_movements",
        sa.Column(
            "branch_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("branches.id", ondelete="SET NULL"),
            nullable=True,
        ),
    )
    op.add_column("invoice_items", sa.Column("image", sa.String(500), nullable=True))


def downgrade():
    op.drop_column("invoice_items", "image")
    op.drop_column("inventory_movements", "branch_id")
    op.drop_column("inventory_movements", "difference")
    op.drop_column("inventory_movements", "new_quantity")
    op.drop_column("inventory_movements", "old_quantity")
    op.drop_column("inventory_movements", "reason")
