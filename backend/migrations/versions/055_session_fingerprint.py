"""Device fingerprint on sessions.

- user_sessions.fingerprint: stable per-device id recorded at login
  (Android ID / iOS identifierForVendor / client-persisted fallback).
  Lets every device identify ITSELF unambiguously, even among identical
  phone models sharing one account.

Additive-only; no data is dropped or rewritten.

Revision ID: 055
Revises: 054
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

revision: str = "055"
down_revision: Union[str, None] = "054"
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
    if not _column_exists("user_sessions", "fingerprint"):
        add_column_if_missing(
            "user_sessions",
            sa.Column("fingerprint", sa.String(100), nullable=True),
        )


def downgrade() -> None:
    if _column_exists("user_sessions", "fingerprint"):
        op.drop_column("user_sessions", "fingerprint")
