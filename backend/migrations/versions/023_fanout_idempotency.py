"""Add source_notif_id to app_notifications for fanout idempotency.

Adds a nullable UUID column that links each fanout-created AppNotification
back to the originating PlatformNotification.  A unique constraint on
(organization_id, source_notif_id) guarantees that re-executing the fanout
for the same notification + org cannot produce duplicates.

Note: PostgreSQL treats NULLs as distinct in UNIQUE constraints, so
multiple rows with source_notif_id=NULL are allowed (for non-fanout
notifications like reminders and per-user alerts).

All changes are additive and idempotent.

Revision ID: 023
Revises: 022
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "023"
down_revision: Union[str, None] = "022"
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


def _constraint_exists(constraint_name: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM pg_constraint WHERE conname = :name)"
        ),
        {"name": constraint_name},
    )
    return result.scalar()


def upgrade() -> None:
    table = "app_notifications"

    if not _column_exists(table, "source_notif_id"):
        op.add_column(
            table,
            sa.Column("source_notif_id", sa.dialects.postgresql.UUID(as_uuid=True), nullable=True),
        )
        op.create_index(
            "ix_app_notifications_source_notif_id",
            table,
            ["source_notif_id"],
        )

    constraint_name = "uq_app_notif_source"
    if not _constraint_exists(constraint_name):
        op.create_unique_constraint(
            constraint_name,
            table,
            ["organization_id", "source_notif_id"],
        )
