"""Pending registrations for the email/password OTP signup flow.

Adds the pending_registrations table so a user who closes the app after
submitting registration data (but before entering the OTP) can resume within
a short TTL window.

Revision ID: 014
Revises: 013
Create Date: 2026-08-07
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "014"
down_revision: Union[str, None] = "013"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _table_exists(table: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.tables "
            "WHERE table_name = :table)"
        ),
        {"table": table},
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
    if _table_exists("pending_registrations"):
        return

    op.create_table(
        "pending_registrations",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("email", sa.String(100), nullable=False),
        sa.Column("full_name", sa.String(200), nullable=False),
        sa.Column("phone", sa.String(50), nullable=True),
        sa.Column("password_hash", sa.String(255), nullable=False),
        sa.Column("organization_name", sa.String(200), nullable=True),
        sa.Column("preferred_usage_mode", sa.String(20), nullable=True),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("email", name="uq_pending_registration_email"),
    )

    if not _index_exists("pending_registrations", "ix_pending_registrations_email"):
        op.create_index(
            "ix_pending_registrations_email",
            "pending_registrations",
            ["email"],
            if_not_exists=True,
        )


def downgrade() -> None:
    if _table_exists("pending_registrations"):
        op.drop_table("pending_registrations")
