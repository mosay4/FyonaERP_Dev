"""Stripe payments: FX pricing metadata + idempotency columns.

Additive-only: extends `stripe_payments` with server-side FX pricing metadata
(exchange_rate, base_currency, base_amount, fx_source, mode, amount_minor) and an
idempotency_key for client retry guards. All columns are nullable/additive so it
is safe to run on any existing database.

Revision ID: 036
Revises: 035
Create Date: 2026-09-05
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

revision: str = "036"
down_revision: Union[str, None] = "035"
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


def _add_column(table: str, column: str, col) -> None:
    if not _column_exists(table, column):
        add_column_if_missing(table, col)


def upgrade() -> None:
    _add_column("stripe_payments", "amount_minor", sa.Column("amount_minor", sa.Integer()))
    _add_column("stripe_payments", "base_currency", sa.Column("base_currency", sa.String(10)))
    _add_column("stripe_payments", "base_amount", sa.Column("base_amount", sa.Float()))
    _add_column("stripe_payments", "exchange_rate", sa.Column("exchange_rate", sa.Float()))
    _add_column("stripe_payments", "fx_source", sa.Column("fx_source", sa.String(20)))
    _add_column("stripe_payments", "mode", sa.Column("mode", sa.String(10)))
    _add_column("stripe_payments", "idempotency_key", sa.Column("idempotency_key", sa.String(200)))
    conn = op.get_bind()
    conn.execute(
        sa.text(
            "CREATE INDEX IF NOT EXISTS ix_stripe_payments_idempotency_key "
            "ON stripe_payments (idempotency_key)"
        )
    )


def downgrade() -> None:
    for col in ("idempotency_key", "mode", "fx_source", "exchange_rate", "base_amount", "base_currency", "amount_minor"):
        if _column_exists("stripe_payments", col):
            op.drop_column("stripe_payments", col)