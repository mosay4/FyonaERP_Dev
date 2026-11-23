"""Add reminder column to personal_debts.

The personal_debts table was originally created via Base.metadata.create_all
without the reminder column (reminder was added to the entity later). This
migration adds it for databases already created so the due-date reminder
toggle persists correctly.

Revision ID: 030
Revises: 029
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

revision: str = "030"
down_revision: Union[str, None] = "029"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _table_exists(table: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = :n)"
        ),
        {"n": table},
    )
    return result.scalar()


def _column_exists(table: str, column: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.columns "
            "WHERE table_name = :t AND column_name = :c)"
        ),
        {"t": table, "c": column},
    )
    return result.scalar()


def upgrade() -> None:
    if not _table_exists("personal_debts"):
        return
    if not _column_exists("personal_debts", "reminder"):
        add_column_if_missing(
            "personal_debts",
            sa.Column(
                "reminder",
                sa.Boolean(),
                nullable=False,
                server_default=sa.text("false"),
            ),
        )
    if not _column_exists("personal_debts", "is_paid"):
        add_column_if_missing(
            "personal_debts",
            sa.Column("is_paid", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        )
    if not _column_exists("personal_debts", "paid_date"):
        add_column_if_missing(
            "personal_debts",
            sa.Column("paid_date", sa.Date(), nullable=True),
        )
    if not _column_exists("personal_debts", "due_date"):
        add_column_if_missing(
            "personal_debts",
            sa.Column("due_date", sa.Date(), nullable=True),
        )


def downgrade() -> None:
    if _table_exists("personal_debts"):
        for col in ("paid_date", "due_date", "is_paid", "reminder"):
            if _column_exists("personal_debts", col):
                op.drop_column("personal_debts", col)