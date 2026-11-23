"""Full device recognition for sessions + single active primary.

- user_sessions: device_model, os_version, country, region, city,
  last_activity (all nullable, additive-only).
- Repair: at most ONE active primary per user (first device wins) — any
  extra active primaries are demoted to secondary (no logout impact).
- Partial unique index: one active primary per user going forward.

Revision ID: 054
Revises: 053
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

revision: str = "054"
down_revision: Union[str, None] = "053"
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
    for col in (
        sa.Column("device_model", sa.String(200), nullable=True),
        sa.Column("os_version", sa.String(50), nullable=True),
        sa.Column("country", sa.String(100), nullable=True),
        sa.Column("region", sa.String(100), nullable=True),
        sa.Column("city", sa.String(100), nullable=True),
        sa.Column("last_activity", sa.DateTime(timezone=True), nullable=True),
    ):
        if not _column_exists("user_sessions", col.name):
            add_column_if_missing("user_sessions", col)
    # Repair: demote extra active primaries, keep the OLDEST (first device).
    conn = op.get_bind()
    dupes = conn.execute(
        sa.text(
            "SELECT user_id FROM user_sessions "
            "WHERE is_active IS TRUE AND is_primary IS TRUE "
            "GROUP BY user_id HAVING COUNT(*) > 1"
        )
    ).fetchall()
    for (user_id,) in dupes:
        conn.execute(
            sa.text(
                "UPDATE user_sessions SET is_primary = FALSE "
                "WHERE user_id = :uid AND is_active IS TRUE "
                "AND is_primary IS TRUE AND id NOT IN ("
                "  SELECT id FROM user_sessions "
                "  WHERE user_id = :uid AND is_active IS TRUE "
                "  AND is_primary IS TRUE ORDER BY created_at ASC LIMIT 1)"
            ),
            {"uid": str(user_id)},
        )
    # One active primary per user going forward (partial unique index).
    conn.execute(
        sa.text(
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_one_active_primary_per_user "
            "ON user_sessions (user_id) "
            "WHERE is_active IS TRUE AND is_primary IS TRUE"
        )
    )


def downgrade() -> None:
    conn = op.get_bind()
    conn.execute(
        sa.text("DROP INDEX IF EXISTS uq_one_active_primary_per_user")
    )
    for col in ("device_model", "os_version", "country", "region",
                "city", "last_activity"):
        if _column_exists("user_sessions", col):
            op.drop_column("user_sessions", col)
