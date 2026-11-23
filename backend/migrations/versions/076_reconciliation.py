"""Reconciliation archive — permanent, auditable records for bank/cash and
inventory reconciliation (قسم المطابقة).

One table, one row per reconciliation operation:
- created at CHECK time (pure inspection — changes nothing),
- finalized at APPROVE time with the executed settlements and links to the
  created BankTransactions / InventoryMovements.

Revision ID: 076
Revises: 075
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID

revision = "076"
down_revision = "075"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "reconciliations",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "organization_id",
            UUID(as_uuid=True),
            sa.ForeignKey("organizations.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "branch_id",
            UUID(as_uuid=True),
            sa.ForeignKey("branches.id", ondelete="SET NULL"),
        ),
        sa.Column("ref_code", sa.String(40)),
        sa.Column("rtype", sa.String(20), nullable=False),
        sa.Column("scope", sa.String(20), nullable=False, server_default="accounts"),
        sa.Column("scope_json", sa.Text(), nullable=False, server_default="{}"),
        sa.Column("status", sa.String(20), nullable=False, server_default="draft"),
        sa.Column("period_start", sa.DateTime(timezone=True)),
        sa.Column("period_end", sa.DateTime(timezone=True)),
        sa.Column("measured_at", sa.DateTime(timezone=True)),
        sa.Column("notes", sa.Text()),
        sa.Column("lines_json", sa.Text(), nullable=False, server_default="[]"),
        sa.Column("settlements_json", sa.Text()),
        sa.Column("result_json", sa.Text()),
        sa.Column(
            "created_by",
            UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
        ),
        sa.Column(
            "approved_by",
            UUID(as_uuid=True),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
        ),
        sa.Column("created_at", sa.DateTime(timezone=True)),
        sa.Column("approved_at", sa.DateTime(timezone=True)),
        sa.Column("idempotency_key", sa.String(80)),
        sa.Column("updated_at", sa.DateTime(timezone=True)),
    )
    op.create_index("ix_reconciliations_org", "reconciliations", ["organization_id"])
    op.create_index("ix_reconciliations_ref", "reconciliations", ["ref_code"])
    op.create_index(
        "ix_reconciliations_idem", "reconciliations", ["idempotency_key"], unique=True
    )


def downgrade():
    op.drop_index("ix_reconciliations_idem", table_name="reconciliations")
    op.drop_index("ix_reconciliations_ref", table_name="reconciliations")
    op.drop_index("ix_reconciliations_org", table_name="reconciliations")
    op.drop_table("reconciliations")