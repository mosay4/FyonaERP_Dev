"""Persistent exchange rate store (auto-fetched rates per currency).

Creates the system's durable store of every currency's rate, refreshed
with each provider fetch (and at minimum daily via startup warm-up).

Revision ID: 029
Revises: 028
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

revision: str = "029"
down_revision: Union[str, None] = "028"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _table_exists(table: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = :table)"
        ),
        {"table": table},
    )
    return result.scalar()


def upgrade() -> None:
    if _table_exists("exchange_rate_store"):
        return

    create_table_if_missing(
        "exchange_rate_store",
        sa.Column("id", sa.dialects.postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("currency_code", sa.String(20), nullable=False),
        sa.Column("base_currency", sa.String(10), nullable=False, server_default="USD"),
        sa.Column("buy_rate", sa.Float(), nullable=False, server_default="0"),
        sa.Column("sell_rate", sa.Float(), nullable=False, server_default="0"),
        sa.Column("average_rate", sa.Float(), nullable=False, server_default="0"),
        sa.Column("source", sa.String(50), nullable=False, server_default="auto"),
        sa.Column("provider", sa.String(100), nullable=True),
        sa.Column("fetched_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
    )
    create_index_if_missing(
        "ix_exchange_rate_store_currency_code",
        "exchange_rate_store",
        ["currency_code"],
        unique=True,
    )


def downgrade() -> None:
    if _table_exists("exchange_rate_store"):
        op.drop_table("exchange_rate_store")