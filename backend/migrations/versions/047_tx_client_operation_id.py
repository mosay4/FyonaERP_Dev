"""Single-execution hardening for personal finance writes.

- personal_transactions.client_operation_id: client-generated idempotency key
  (one per user intent, e.g. one form submission). Retried POSTs (double-tap,
  timeout retry, offline sync replay) carrying the same key return the
  original row instead of creating duplicates. Partial unique index keeps
  legacy NULL rows unaffected.

Additive-only; no data is dropped or rewritten.

Revision ID: 047
Revises: 046
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

revision: str = "047"
down_revision: Union[str, None] = "046"
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


def _index_exists(index: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM pg_indexes WHERE indexname = :index)"
        ),
        {"index": index},
    )
    return result.scalar()


def upgrade() -> None:
    if not _column_exists("personal_transactions", "client_operation_id"):
        add_column_if_missing(
            "personal_transactions",
            sa.Column("client_operation_id", sa.String(64), nullable=True),
        )
    if not _index_exists("ix_personal_transactions_client_op"):
        create_index_if_missing(
            "ix_personal_transactions_client_op",
            "personal_transactions",
            ["user_id", "client_operation_id"],
            unique=True,
            postgresql_where=sa.text("client_operation_id IS NOT NULL"),
        )


def downgrade() -> None:
    try:
        op.drop_index(
            "ix_personal_transactions_client_op",
            table_name="personal_transactions",
        )
    except Exception:
        pass
    if _column_exists("personal_transactions", "client_operation_id"):
        op.drop_column("personal_transactions", "client_operation_id")
