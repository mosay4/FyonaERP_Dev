"""Server-side warehouse settings + expiry push dedup.

- warehouse_settings: per-org expiry toggle + warn days (for the scheduler).
- expiry_notifications: one row per (org, product, day) to prevent duplicate
  daily pushes.

Revision ID: 073
Revises: 072
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "073"
down_revision = "072"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "warehouse_settings",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "organization_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("organizations.id", ondelete="CASCADE"),
            nullable=False,
            unique=True,
        ),
        sa.Column("expiry_enabled", sa.Boolean(), nullable=False, server_default="false"),
        sa.Column("expiry_warn_days", sa.Integer(), nullable=False, server_default="60"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()")),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()")),
    )
    op.create_table(
        "expiry_notifications",
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
        sa.Column("notified_on", sa.Date(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()")),
        sa.UniqueConstraint(
            "organization_id", "product_id", "notified_on",
            name="uq_expiry_notif_org_product_day",
        ),
    )


def downgrade():
    op.drop_table("expiry_notifications")
    op.drop_table("warehouse_settings")
