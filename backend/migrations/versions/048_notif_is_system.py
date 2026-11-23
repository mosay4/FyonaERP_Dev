"""Classify app notifications: automatic system vs admin-written.

- app_notifications.is_system: True for every automatic notification
  (subscription, maintenance/controls, payments, ...), False ONLY for
  rows fanned out from a manually-written admin broadcast
  (POST /admin/notifications).

Backfill rule for existing rows:
- rows without a source platform id → system (True);
- rows fanned out from the automatic "system status" broadcast
  (title 'إشعار حالة النظام') → system (True);
- every other fanned-out row (a human wrote it in the admin panel) →
  admin-written (False).

Additive-only; no data is dropped or rewritten.

Revision ID: 048
Revises: 047
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

revision: str = "048"
down_revision: Union[str, None] = "047"
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
    if not _column_exists("app_notifications", "is_system"):
        add_column_if_missing(
            "app_notifications",
            sa.Column("is_system", sa.Boolean(), nullable=True),
        )
    # Backfill: manual admin broadcasts are the only non-system rows.
    conn = op.get_bind()
    conn.execute(
        sa.text(
            "UPDATE app_notifications SET is_system = "
            "(source_notif_id IS NULL OR title = 'إشعار حالة النظام') "
            "WHERE is_system IS NULL"
        )
    )
    conn.execute(
        sa.text(
            "UPDATE app_notifications SET is_system = TRUE "
            "WHERE is_system IS NULL"
        )
    )
    if not _index_exists("ix_app_notifications_is_system"):
        create_index_if_missing(
            "ix_app_notifications_is_system",
            "app_notifications",
            ["organization_id", "is_system"],
        )


def downgrade() -> None:
    try:
        op.drop_index(
            "ix_app_notifications_is_system",
            table_name="app_notifications",
        )
    except Exception:
        pass
    if _column_exists("app_notifications", "is_system"):
        op.drop_column("app_notifications", "is_system")
