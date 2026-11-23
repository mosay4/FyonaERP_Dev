"""Add Firebase auth support to users table.

Adds firebase_uid, auth_provider, photo_url columns.
Makes password_hash nullable (Google sign-in users have no password).

Revision ID: 013
Revises: 012
Create Date: 2026-08-05
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "013"
down_revision: Union[str, None] = "012"
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


def _constraint_exists(table: str, constraint: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.table_constraints "
            "WHERE table_name = :table AND constraint_name = :constraint)"
        ),
        {"table": table, "constraint": constraint},
    )
    return result.scalar()


def _index_exists(table: str, index: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM pg_indexes WHERE tablename = :table AND indexname = :index)"
        ),
        {"table": table, "index": index},
    )
    return result.scalar()


def upgrade() -> None:
    # ── password_hash → nullable (Google users have no password) ──
    conn = op.get_bind()
    exists = conn.execute(
        sa.text(
            "SELECT is_nullable FROM information_schema.columns "
            "WHERE table_name = 'users' AND column_name = 'password_hash'"
        )
    ).scalar()
    if exists == "NO":
        op.alter_column("users", "password_hash", existing_type=sa.String(255), nullable=True)

    # ── New Firebase columns ──
    if not _column_exists("users", "firebase_uid"):
        op.add_column("users", sa.Column("firebase_uid", sa.String(128), nullable=True))

    if not _column_exists("users", "auth_provider"):
        op.add_column(
            "users",
            sa.Column("auth_provider", sa.String(50), nullable=True, server_default="email"),
        )

    if not _column_exists("users", "photo_url"):
        op.add_column("users", sa.Column("photo_url", sa.String(500), nullable=True))

    if not _constraint_exists("users", "uq_user_firebase_uid"):
        op.create_unique_constraint("uq_user_firebase_uid", "users", ["firebase_uid"])

    if not _index_exists("users", "ix_user_firebase_uid"):
        op.create_index("ix_user_firebase_uid", "users", ["firebase_uid"], if_not_exists=True)


def downgrade() -> None:
    for col in ["photo_url", "auth_provider", "firebase_uid"]:
        if _column_exists("users", col):
            op.drop_column("users", col)

    if not _constraint_exists("users", "uq_user_firebase_uid"):
        return

    if _column_exists("users", "password_hash"):
        conn = op.get_bind()
        exists = conn.execute(
            sa.text(
                "SELECT is_nullable FROM information_schema.columns "
                "WHERE table_name = 'users' AND column_name = 'password_hash'"
            )
        ).scalar()
        if exists == "YES":
            op.alter_column("users", "password_hash", existing_type=sa.String(255), nullable=False)
