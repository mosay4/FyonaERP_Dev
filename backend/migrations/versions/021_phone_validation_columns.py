"""Add validated-phone metadata columns + partial unique index on users.phone.

* Stores country / calling code / line type / carrier alongside the number so
  the app can display a masked phone and later scale lookups by country.
* Adds a *partial* unique index (``phone <> ''``) so multiple NULL/empty rows
  stay legal in PostgreSQL while any two real numbers must differ — duplicate
  numbers are rejected at the database level, not just in the app.

All changes are additive and idempotent. Existing rows are left untouched.

Revision ID: 021
Revises: 020
Create Date: 2026-08-16
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "021"
down_revision: Union[str, None] = "020"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _has_column(table: str, column: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.columns "
            "WHERE table_name = :t AND column_name = :c)"
        ),
        {"t": table, "c": column},
    )
    return result.scalar()


def _index_exists(table: str, index: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM pg_indexes "
            "WHERE tablename = :t AND indexname = :i)"
        ),
        {"t": table, "i": index},
    )
    return result.scalar()


def upgrade() -> None:
    for name, type_, nullable in (
        ("phone_country", sa.String(10), True),
        ("phone_calling_code", sa.String(10), True),
        ("phone_type", sa.String(30), True),
        ("phone_carrier", sa.String(100), True),
        ("phone_added_at", sa.DateTime(timezone=True), True),
        ("phone_updated_at", sa.DateTime(timezone=True), True),
    ):
        if not _has_column("users", name):
            op.add_column("users", sa.Column(name, type_, nullable=nullable))

    # Partial unique index: real numbers must be unique, NULL/'' stay free.
    if not _index_exists("users", "uq_users_phone"):
        op.create_index(
            "uq_users_phone",
            "users",
            ["phone"],
            unique=True,
            postgresql_where=sa.text("phone IS NOT NULL AND phone <> ''"),
        )


def downgrade() -> None:
    if _index_exists("users", "uq_users_phone"):
        op.drop_index("uq_users_phone", table_name="users")
    for name in (
        "phone_country",
        "phone_calling_code",
        "phone_type",
        "phone_carrier",
        "phone_added_at",
        "phone_updated_at",
    ):
        if _has_column("users", name):
            op.drop_column("users", name)
