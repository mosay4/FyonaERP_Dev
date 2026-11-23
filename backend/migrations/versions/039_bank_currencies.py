"""Add per-currency balances to platform bank accounts.

Each platform bank account can now hold MULTIPLE currencies, each with its own
opening balance, so the admin can book revenues in different currencies per bank
and switch between them on the bank card. Additive-only (Text JSON column).

Revision ID: 039
Revises: 038
Create Date: 2026-09-07
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

revision: str = "039"
down_revision: Union[str, None] = "038"
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


def _seed_from_legacy() -> None:
    """Seed `currencies` from the single legacy currency + opening_balance so
    existing banks start with one currency already configured."""
    conn = op.get_bind()
    rows = conn.execute(
        sa.text(
            "SELECT id, currency, COALESCE(opening_balance, 0) "
            "FROM platform_bank_accounts "
            "WHERE currencies IS NULL"
        )
    ).fetchall()
    for bank_id, currency, opening in rows:
        import json
        payload = json.dumps(
            [{"currency": currency or "SAR", "opening_balance": float(opening or 0)}],
            ensure_ascii=False,
        )
        conn.execute(
            sa.text(
                "UPDATE platform_bank_accounts SET currencies = :payload WHERE id = :id"
            ),
            {"payload": payload, "id": bank_id},
        )


def upgrade() -> None:
    if not _column_exists("platform_bank_accounts", "currencies"):
        add_column_if_missing("platform_bank_accounts", sa.Column("currencies", sa.Text(), nullable=True))
    _seed_from_legacy()


def downgrade() -> None:
    if _column_exists("platform_bank_accounts", "currencies"):
        op.drop_column("platform_bank_accounts", "currencies")
