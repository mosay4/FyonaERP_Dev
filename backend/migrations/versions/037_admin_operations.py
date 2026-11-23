"""Admin operations ledger: deposits & withdrawals on platform bank accounts.

Additive-only table for the external Admin Web App's accounting module.

Revision ID: 037
Revises: 036
Create Date: 2026-09-06
"""
from typing import Sequence, Union

from alembic import op
from migrations.idempotent_ops import (
    add_column_if_missing,
    create_foreign_key_if_missing,
    create_index_if_missing,
    create_table_if_missing,
    create_unique_constraint_if_missing,
)
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "037"
down_revision: Union[str, None] = "036"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _exists(table: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = :t)"),
        {"t": table},
    )
    return result.scalar()


def upgrade() -> None:
    if not _exists("admin_operations"):
        create_table_if_missing(
            "admin_operations",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
            sa.Column("bank_account_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("platform_bank_accounts.id", ondelete="SET NULL"), nullable=True, index=True),
            sa.Column("bank_name", sa.String(200)),
            sa.Column("type", sa.String(20), server_default="deposit"),
            sa.Column("amount", sa.Numeric(14, 2), nullable=False, server_default="0"),
            sa.Column("currency", sa.String(10), server_default="SAR"),
            sa.Column("description", sa.Text),
            sa.Column("person_name", sa.String(200)),
            sa.Column("created_by", postgresql.UUID(as_uuid=True)),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("NOW()"), index=True),
        )


def downgrade() -> None:
    if _exists("admin_operations"):
        op.drop_table("admin_operations")