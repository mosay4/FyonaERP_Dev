"""Per-branch invoice design override (falls back to main when absent).

Revision ID: 089
Revises: 088
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID

revision = "089"
down_revision = "088"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("org_invoice_designs", sa.Column(
        "branch_id", UUID(as_uuid=True),
        sa.ForeignKey("branches.id", ondelete="CASCADE"), nullable=True))
    op.create_index("ix_org_invoice_designs_branch_id",
                    "org_invoice_designs", ["branch_id"])
    op.drop_constraint("uq_org_invoice_design", "org_invoice_designs",
                       type_="unique")
    op.create_unique_constraint(
        "uq_org_invoice_design_branch", "org_invoice_designs",
        ["organization_id", "branch_id", "template_id"])


def downgrade():
    op.drop_constraint("uq_org_invoice_design_branch", "org_invoice_designs",
                       type_="unique")
    op.create_unique_constraint("uq_org_invoice_design", "org_invoice_designs",
                                ["organization_id", "template_id"])
    op.drop_index("ix_org_invoice_designs_branch_id",
                  table_name="org_invoice_designs")
    op.drop_column("org_invoice_designs", "branch_id")
