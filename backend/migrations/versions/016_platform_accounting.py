"""Platform accounting (banks + subscription revenues).

Adds the platform's company bank accounts and the subscription revenue ledger
used by the admin panel to book income when a subscription request is approved.

  * `platform_bank_accounts` -> company/platform bank accounts
  * `subscription_revenues`  -> one row per approved subscription request

All changes are additive and idempotent.

Revision ID: 016
Revises: 015
Create Date: 2026-08-12
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "016"
down_revision: Union[str, None] = "015"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _exists(table: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = :table)"
        ),
        {"table": table},
    )
    return result.scalar()


def _index_exists(table: str, index: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM pg_indexes WHERE tablename = :table AND indexname = :index)"
        ),
        {"table": table, "index": index},
    )
    return result.scalar()


def upgrade() -> None:
    # ── platform_bank_accounts ──
    if not _exists("platform_bank_accounts"):
        op.create_table(
            "platform_bank_accounts",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
            sa.Column("bank_name", sa.String(200), nullable=False),
            sa.Column("currency", sa.String(10), server_default="SAR"),
            sa.Column("opening_balance", sa.Numeric(14, 2), server_default="0"),
            sa.Column("notes", sa.Text()),
            sa.Column("is_active", sa.Boolean(), server_default=sa.text("true")),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("NOW()")),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("NOW()"), onupdate=sa.text("NOW()")),
        )

    # ── subscription_revenues ──
    if not _exists("subscription_revenues"):
        op.create_table(
            "subscription_revenues",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
            sa.Column("request_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("subscription_requests.id", ondelete="SET NULL"), nullable=True, index=True),
            sa.Column("organization_id", postgresql.UUID(as_uuid=True), nullable=True, index=True),
            sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=True, index=True),
            sa.Column("bank_account_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("platform_bank_accounts.id", ondelete="SET NULL"), nullable=True, index=True),
            sa.Column("plan_name", sa.String(200)),
            sa.Column("period", sa.String(20)),
            sa.Column("amount", sa.Numeric(14, 2), nullable=False, server_default="0"),
            sa.Column("currency", sa.String(10), server_default="SAR"),
            sa.Column("note", sa.Text()),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("NOW()"), index=True),
        )
        if not _index_exists("subscription_revenues", "ix_subscription_revenues_created_at"):
            op.create_index("ix_subscription_revenues_created_at", "subscription_revenues", ["created_at"], if_not_exists=True)


def downgrade() -> None:
    for table in ("subscription_revenues", "platform_bank_accounts"):
        if _exists(table):
            op.drop_table(table)
