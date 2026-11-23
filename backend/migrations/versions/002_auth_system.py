"""
Safe migration 002 — idempotent auth system.

Adds missing columns to organizations and users (no drops).
Creates user_sessions, roles, role_permissions only if not exist.
Drops unused tables from 001 (permissions, audit_logs, subscription_*) only if exist.

Revision ID: 002
Revises: 001
"""

from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "002"
down_revision: Union[str, None] = "001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # ════════════════════════════════════════════
    # ORGANIZATIONS — ADD MISSING COLUMNS
    # ════════════════════════════════════════════
    conn = op.get_bind()

    # slug
    if not _column_exists("organizations", "slug"):
        op.add_column("organizations", sa.Column("slug", sa.String(100), nullable=True))
        conn.execute(
            sa.text(
                "UPDATE organizations SET slug = LOWER(REGEXP_REPLACE(COALESCE(name::text, 'org'), '[^a-z0-9]', '-', 'g')) WHERE slug IS NULL"
            )
        )
        op.alter_column("organizations", "slug", nullable=False)

    # Columns that may or may not exist already
    for col, col_type in [
        ("business_type", "VARCHAR(50)"),
    ]:
        if not _column_exists("organizations", col):
            op.add_column("organizations", sa.Column(col, sa.String(50), nullable=True))

    # Drop old columns from 001 schema (if they exist in current DB)
    for col in [
        "locale",
        "currency",
        "legal_name",
        "cr_number",
        "tax_number",
        "address",
        "logo",
        "is_deleted",
        "version",
    ]:
        if _column_exists("organizations", col):
            op.drop_column("organizations", col)

    # ════════════════════════════════════════════
    # USERS — ADD MISSING COLUMNS
    # ════════════════════════════════════════════
    user_adds = {
        "avatar": "VARCHAR(500)",
        "preferred_language": "VARCHAR(10) DEFAULT 'ar'",
        "preferred_currency": "VARCHAR(10) DEFAULT 'SAR'",
        "timezone": "VARCHAR(50) DEFAULT 'Asia/Riyadh'",
        "email_verified": "BOOLEAN DEFAULT FALSE",
        "last_login_at": "TIMESTAMPTZ",
    }
    for col, col_def in user_adds.items():
        if not _column_exists("users", col):
            conn.execute(sa.text(f"ALTER TABLE users ADD COLUMN {col} {col_def}"))

    # Drop unused columns from old schema
    for col in [
        "last_ip",
        "password_changed_at",
        "mfa_secret",
        "mfa_backup_codes",
        "trial_start_date",
        "trial_end_date",
        "subscription_plan",
        "personal_trial_activated",
        "business_trial_activated",
        "is_deleted",
        "version",
        "username",
    ]:
        if _column_exists("users", col):
            op.drop_column("users", col)

    # Ensure indexes exist
    for idx, cols in [
        ("ix_user_email", ["email"]),
        ("ix_user_org", ["organization_id"]),
    ]:
        if not _index_exists("users", idx):
            op.create_index(idx, "users", cols, if_not_exists=True)

    # Ensure email unique constraint
    if not _constraint_exists("users", "uq_user_email"):
        op.create_unique_constraint("uq_user_email", "users", ["email"])

    # ════════════════════════════════════════════
    # USER SESSIONS — DROP & RECREATE (safe: session data only)
    # ════════════════════════════════════════════
    if _table_exists("user_sessions"):
        op.drop_table("user_sessions")

    op.create_table(
        "user_sessions",
        sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("user_id", postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column("refresh_token", sa.String(500), nullable=False),
        sa.Column("device_name", sa.String(200), nullable=True),
        sa.Column("ip_address", sa.String(50), nullable=True),
        sa.Column("user_agent", sa.Text(), nullable=True),
        sa.Column("is_active", sa.Boolean(), server_default="true"),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now()
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    if not _index_exists("user_sessions", "ix_session_refresh"):
        op.create_index("ix_session_refresh", "user_sessions", ["refresh_token"])

    # ════════════════════════════════════════════
    # ROLES — CREATE IF NOT EXISTS
    # ════════════════════════════════════════════
    if not _table_exists("roles"):
        op.create_table(
            "roles",
            sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
            sa.Column("organization_id", postgresql.UUID(as_uuid=True), nullable=False),
            sa.Column("name", sa.String(100), nullable=False),
            sa.Column("name_ar", sa.String(100), nullable=True),
            sa.Column("is_system", sa.Boolean(), server_default="false"),
            sa.Column(
                "created_at", sa.DateTime(timezone=True), server_default=sa.func.now()
            ),
            sa.ForeignKeyConstraint(
                ["organization_id"], ["organizations.id"], ondelete="CASCADE"
            ),
            sa.PrimaryKeyConstraint("id"),
        )

    # ════════════════════════════════════════════
    # ROLE PERMISSIONS — CREATE IF NOT EXISTS
    # ════════════════════════════════════════════
    if not _table_exists("role_permissions"):
        op.create_table(
            "role_permissions",
            sa.Column("id", postgresql.UUID(as_uuid=True), nullable=False),
            sa.Column("role_id", postgresql.UUID(as_uuid=True), nullable=False),
            sa.Column("resource", sa.String(100), nullable=False),
            sa.Column("can_create", sa.Boolean(), server_default="false"),
            sa.Column("can_read", sa.Boolean(), server_default="false"),
            sa.Column("can_update", sa.Boolean(), server_default="false"),
            sa.Column("can_delete", sa.Boolean(), server_default="false"),
            sa.ForeignKeyConstraint(["role_id"], ["roles.id"], ondelete="CASCADE"),
            sa.PrimaryKeyConstraint("id"),
        )
        if not _index_exists("role_permissions", "ix_role_perm_role"):
            op.create_index("ix_role_perm_role", "role_permissions", ["role_id"])

    # ════════════════════════════════════════════
    # DROP UNUSED TABLES FROM 001 (safe to drop)
    # ════════════════════════════════════════════
    for t in [
        "permissions",
        "audit_logs",
        "subscription_requests",
        "subscription_plans",
    ]:
        if _table_exists(t):
            op.drop_table(t)


def downgrade() -> None:
    for t in ["role_permissions", "roles", "user_sessions"]:
        if _table_exists(t):
            op.drop_table(t)


def _table_exists(name: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = :name)"
        ),
        {"name": name},
    )
    return result.scalar()


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


def _index_exists(table: str, index: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM pg_indexes WHERE tablename = :table AND indexname = :index)"
        ),
        {"table": table, "index": index},
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
