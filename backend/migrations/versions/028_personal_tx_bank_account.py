"""Link personal transactions to a bank account and track payment method.

Adds bank_account_id (nullable FK -> personal_bank_accounts) and
payment_method to personal_transactions so income/expense entries can be
tied to a specific bank account and the backend can update its balance.

Revision ID: 028
Revises: 027
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
from sqlalchemy.dialects.postgresql import UUID

revision: str = "028"
down_revision: Union[str, None] = "027"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _column_exists(table: str, column: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.columns WHERE table_name = :table AND column_name = :column)"
        ),
        {"table": table, "column": column},
    )
    return result.scalar()


def upgrade() -> None:
    # ── 1. payment_method ──
    if not _column_exists("personal_transactions", "payment_method"):
        add_column_if_missing(
            "personal_transactions",
            sa.Column("payment_method", sa.String(20), nullable=True),
        )

    # ── 2. bank_account_id ──
    if not _column_exists("personal_transactions", "bank_account_id"):
        add_column_if_missing(
            "personal_transactions",
            sa.Column(
                "bank_account_id",
                UUID(as_uuid=True),
                sa.ForeignKey("personal_bank_accounts.id", ondelete="SET NULL"),
                nullable=True,
            ),
        )
        create_index_if_missing(
            "ix_personal_transactions_bank_account_id",
            "personal_transactions",
            ["bank_account_id"],
        )


def downgrade() -> None:
    if _column_exists("personal_transactions", "bank_account_id"):
        op.drop_index(
            "ix_personal_transactions_bank_account_id",
            table_name="personal_transactions",
        )
        op.drop_column("personal_transactions", "bank_account_id")
    if _column_exists("personal_transactions", "payment_method"):
        op.drop_column("personal_transactions", "payment_method")