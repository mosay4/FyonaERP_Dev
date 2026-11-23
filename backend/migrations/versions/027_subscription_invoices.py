"""Add subscription_invoices table.

Revision ID: 027
Revises: 026
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID

revision: str = "027"
down_revision: Union[str, None] = "026"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "subscription_invoices",
        sa.Column("id", UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
        sa.Column("invoice_number", sa.String(50), nullable=False, index=True, unique=True),
        sa.Column("organization_id", UUID(as_uuid=True), sa.ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True),
        sa.Column("user_id", UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="SET NULL"), index=True),
        sa.Column("request_id", UUID(as_uuid=True), sa.ForeignKey("subscription_requests.id", ondelete="SET NULL"), index=True),
        sa.Column("plan_name", sa.String(200), nullable=False),
        sa.Column("plan_description", sa.Text),
        sa.Column("period", sa.String(20), nullable=False, server_default="yearly"),
        sa.Column("amount", sa.Numeric(14, 2), nullable=False, server_default="0"),
        sa.Column("currency", sa.String(10), nullable=False, server_default="SAR"),
        sa.Column("status", sa.String(20), nullable=False, server_default="paid"),
        sa.Column("payment_method", sa.String(50), server_default="bank_transfer"),
        sa.Column("subscription_start_date", sa.DateTime(timezone=True)),
        sa.Column("subscription_end_date", sa.DateTime(timezone=True)),
        sa.Column("notes", sa.Text),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.UniqueConstraint("organization_id", "request_id", name="uq_sub_inv_org_request"),
    )


def downgrade() -> None:
    op.drop_table("subscription_invoices")
