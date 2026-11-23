"""Offline-first sync hardening: idempotent pushes + batch dedup.

- entity_versions.operation_id: client-generated idempotency key; a retried
  operation with the same (org, entity_type, entity_id) + operation_id is a
  server-side no-op instead of being applied twice.
- sync_batches unique (organization_id, batch_id, direction): re-POSTing the
  same batch after a mid-flight disconnect is detected and short-circuited.

Additive-only; no data is dropped or rewritten.

Revision ID: 042
Revises: 041
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

revision: str = "042"
down_revision: Union[str, None] = "041"
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


def _constraint_exists(constraint: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM pg_constraint WHERE conname = :name)"
        ),
        {"name": constraint},
    )
    return result.scalar()


def upgrade() -> None:
    if not _column_exists("entity_versions", "operation_id"):
        add_column_if_missing(
            "entity_versions",
            sa.Column("operation_id", sa.String(100), nullable=True),
        )
    if not _constraint_exists("uq_sync_batch_org_batch"):
        create_unique_constraint_if_missing(
            "uq_sync_batch_org_batch",
            "sync_batches",
            ["organization_id", "batch_id", "direction"],
        )


def downgrade() -> None:
    if _constraint_exists("uq_sync_batch_org_batch"):
        op.drop_constraint("uq_sync_batch_org_batch", "sync_batches", type_="unique")
    if _column_exists("entity_versions", "operation_id"):
        op.drop_column("entity_versions", "operation_id")