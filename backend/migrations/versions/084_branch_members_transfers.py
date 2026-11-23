"""Branch membership, invitations, financial/inventory transfers and reversals.

Additive + reversible. No existing row or balance is modified by this migration.

Revision ID: 084
Revises: 083
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID

revision = "084"
down_revision = "083"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "branch_members",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("organization_id", UUID(as_uuid=True),
                  sa.ForeignKey("organizations.id", ondelete="CASCADE"),
                  nullable=False),
        sa.Column("user_id", UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("branch_ids", sa.Text(), nullable=False, server_default="[]"),
        sa.Column("permissions", sa.Text(), nullable=False, server_default="{}"),
        sa.Column("per_branch", sa.Text(), nullable=False, server_default="{}"),
        sa.Column("all_branches", sa.Boolean(), nullable=False,
                  server_default=sa.text("false")),
        sa.Column("can_transfer", sa.Boolean(), nullable=False,
                  server_default=sa.text("false")),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("invited_by", UUID(as_uuid=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True)),
        sa.Column("updated_at", sa.DateTime(timezone=True)),
        sa.UniqueConstraint("organization_id", "user_id",
                            name="uq_branch_member_org_user"),
    )
    op.create_index("ix_branch_members_organization_id", "branch_members",
                    ["organization_id"])
    op.create_index("ix_branch_members_user_id", "branch_members", ["user_id"])

    op.create_table(
        "branch_invitations",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("organization_id", UUID(as_uuid=True),
                  sa.ForeignKey("organizations.id", ondelete="CASCADE"),
                  nullable=False),
        sa.Column("branch_id", UUID(as_uuid=True),
                  sa.ForeignKey("branches.id", ondelete="CASCADE"),
                  nullable=False),
        sa.Column("invited_user_id", UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("invited_by", UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True),
        sa.Column("identifier_type", sa.String(10), nullable=False,
                  server_default="code"),
        sa.Column("identifier", sa.String(120), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="pending"),
        sa.Column("permissions", sa.Text(), nullable=False, server_default="{}"),
        sa.Column("can_transfer", sa.Boolean(), nullable=False,
                  server_default=sa.text("false")),
        sa.Column("created_at", sa.DateTime(timezone=True)),
        sa.Column("expires_at", sa.DateTime(timezone=True)),
        sa.Column("responded_at", sa.DateTime(timezone=True)),
        sa.UniqueConstraint("branch_id", "invited_user_id", "status",
                            name="uq_branch_invite_pending"),
    )
    op.create_index("ix_branch_invitations_organization_id", "branch_invitations",
                    ["organization_id"])
    op.create_index("ix_branch_invitations_branch_id", "branch_invitations",
                    ["branch_id"])
    op.create_index("ix_branch_invitations_invited_user_id", "branch_invitations",
                    ["invited_user_id"])

    op.create_table(
        "branch_transfers",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("organization_id", UUID(as_uuid=True),
                  sa.ForeignKey("organizations.id", ondelete="CASCADE"),
                  nullable=False),
        sa.Column("transfer_number", sa.String(60), nullable=False),
        sa.Column("kind", sa.String(20), nullable=False),
        sa.Column("from_branch_id", UUID(as_uuid=True),
                  sa.ForeignKey("branches.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("to_branch_id", UUID(as_uuid=True),
                  sa.ForeignKey("branches.id", ondelete="RESTRICT"), nullable=False),
        sa.Column("actor_user_id", UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True),
        sa.Column("actor_role", sa.String(20), nullable=True),
        sa.Column("status", sa.String(20), nullable=False,
                  server_default="completed"),
        sa.Column("from_account_id", UUID(as_uuid=True),
                  sa.ForeignKey("bank_accounts.id", ondelete="SET NULL")),
        sa.Column("to_account_id", UUID(as_uuid=True),
                  sa.ForeignKey("bank_accounts.id", ondelete="SET NULL")),
        sa.Column("amount", sa.Numeric(18, 4)),
        sa.Column("currency", sa.String(10)),
        sa.Column("to_currency", sa.String(10)),
        sa.Column("exchange_rate", sa.Numeric(18, 8)),
        sa.Column("received_amount", sa.Numeric(18, 4)),
        sa.Column("total_cost", sa.Numeric(18, 4)),
        sa.Column("reversal_of_id", UUID(as_uuid=True),
                  sa.ForeignKey("branch_transfers.id", ondelete="SET NULL")),
        sa.Column("reversed_amount", sa.Numeric(18, 4), nullable=False,
                  server_default="0"),
        sa.Column("idempotency_key", sa.String(120), nullable=True),
        sa.Column("notes", sa.Text()),
        sa.Column("created_at", sa.DateTime(timezone=True)),
        sa.Column("completed_at", sa.DateTime(timezone=True)),
        sa.Column("reversed_at", sa.DateTime(timezone=True)),
        sa.UniqueConstraint("organization_id", "transfer_number",
                            name="uq_branch_transfer_number"),
        sa.UniqueConstraint("organization_id", "idempotency_key",
                            name="uq_branch_transfer_idempotency"),
    )
    op.create_index("ix_branch_transfers_organization_id", "branch_transfers",
                    ["organization_id"])
    op.create_index("ix_branch_transfers_from_branch_id", "branch_transfers",
                    ["from_branch_id"])
    op.create_index("ix_branch_transfers_to_branch_id", "branch_transfers",
                    ["to_branch_id"])
    op.create_index("ix_branch_transfers_transfer_number", "branch_transfers",
                    ["transfer_number"])
    op.create_index("ix_branch_transfers_reversal_of_id", "branch_transfers",
                    ["reversal_of_id"])

    op.create_table(
        "branch_transfer_items",
        sa.Column("id", UUID(as_uuid=True), primary_key=True),
        sa.Column("transfer_id", UUID(as_uuid=True),
                  sa.ForeignKey("branch_transfers.id", ondelete="CASCADE"),
                  nullable=False),
        sa.Column("from_product_id", UUID(as_uuid=True),
                  sa.ForeignKey("products.id", ondelete="SET NULL")),
        sa.Column("to_product_id", UUID(as_uuid=True),
                  sa.ForeignKey("products.id", ondelete="SET NULL")),
        sa.Column("from_unit_id", UUID(as_uuid=True),
                  sa.ForeignKey("product_units.id", ondelete="SET NULL")),
        sa.Column("to_unit_id", UUID(as_uuid=True),
                  sa.ForeignKey("product_units.id", ondelete="SET NULL")),
        sa.Column("unit_name", sa.String(50)),
        sa.Column("from_quantity", sa.Numeric(18, 4), nullable=False,
                  server_default="0"),
        sa.Column("to_quantity", sa.Numeric(18, 4), nullable=False,
                  server_default="0"),
        sa.Column("base_quantity", sa.Numeric(18, 4), nullable=False,
                  server_default="0"),
        sa.Column("factor", sa.Numeric(18, 6), nullable=False,
                  server_default="1"),
        sa.Column("unit_cost", sa.Numeric(18, 6), nullable=False,
                  server_default="0"),
        sa.Column("total_cost", sa.Numeric(18, 4), nullable=False,
                  server_default="0"),
        sa.Column("currency", sa.String(10)),
        sa.Column("reversed_quantity", sa.Numeric(18, 4), nullable=False,
                  server_default="0"),
        sa.Column("created_at", sa.DateTime(timezone=True)),
    )
    op.create_index("ix_branch_transfer_items_transfer_id",
                    "branch_transfer_items", ["transfer_id"])


def downgrade():
    op.drop_table("branch_transfer_items")
    op.drop_table("branch_transfers")
    op.drop_table("branch_invitations")
    op.drop_table("branch_members")
