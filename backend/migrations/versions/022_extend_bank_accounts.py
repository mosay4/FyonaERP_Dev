"""Extend platform_bank_accounts with payment method fields.

Adds columns needed for the admin Payment Methods section:
  * account_holder_name  -> beneficiary / account holder
  * account_number       -> bank account number
  * iban                 -> International Bank Account Number
  * country              -> country code (e.g. SA, YE)
  * sort_order           -> display ordering

All changes are additive and idempotent.

Revision ID: 022
Revises: 021
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "022"
down_revision: Union[str, None] = "021"
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
    table = "platform_bank_accounts"

    if not _column_exists(table, "account_holder_name"):
        op.add_column(table, sa.Column("account_holder_name", sa.String(200), nullable=True))

    if not _column_exists(table, "account_number"):
        op.add_column(table, sa.Column("account_number", sa.String(50), nullable=True))

    if not _column_exists(table, "iban"):
        op.add_column(table, sa.Column("iban", sa.String(50), nullable=True))

    if not _column_exists(table, "country"):
        op.add_column(table, sa.Column("country", sa.String(10), server_default="SA"))

    if not _column_exists(table, "sort_order"):
        op.add_column(table, sa.Column("sort_order", sa.Integer(), server_default="0"))
