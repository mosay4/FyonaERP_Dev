"""Add exchange-rate snapshot columns to personal_transactions.

Financial correctness requirement: a transaction executed OFFLINE must keep the
exchange rate it actually used at execution time. When the device comes back
online the historical transaction must NEVER be recomputed with a newer rate.

Additive-only columns:
- exchange_rate: the rate (base→currency) used when the row was created.
- exchange_rate_currency: which base currency the rate refers to (e.g. YER_OLD).
- fx_source: where the rate came from (backend / cache / offline_snapshot).

Revision ID: 044
Revises: 043
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

revision: str = "044"
down_revision: Union[str, None] = "043"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _column_exists(table: str, column: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.columns "
            "WHERE table_name = :table AND column_name = :column)"
        ),
        {"table": table, "column": column},
    )
    return result.scalar()


def upgrade() -> None:
    if not _column_exists("personal_transactions", "exchange_rate"):
        add_column_if_missing(
            "personal_transactions",
            sa.Column("exchange_rate", sa.Numeric(20, 8), nullable=True),
        )
    if not _column_exists("personal_transactions", "exchange_rate_currency"):
        add_column_if_missing(
            "personal_transactions",
            sa.Column("exchange_rate_currency", sa.String(10), nullable=True),
        )
    if not _column_exists("personal_transactions", "fx_source"):
        add_column_if_missing(
            "personal_transactions",
            sa.Column("fx_source", sa.String(30), nullable=True),
        )


def downgrade() -> None:
    for col in ("exchange_rate", "exchange_rate_currency", "fx_source"):
        if _column_exists("personal_transactions", col):
            op.drop_column("personal_transactions", col)