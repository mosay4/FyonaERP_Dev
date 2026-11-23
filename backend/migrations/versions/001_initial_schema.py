"""Initial schema

Revision ID: 001
Revises:
Create Date: 2026-07-13
"""

from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # ── Organizations ──
    op.create_table(
        "organizations",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("legal_name", sa.String(200), nullable=True),
        sa.Column("cr_number", sa.String(100), nullable=True),
        sa.Column("tax_number", sa.String(100), nullable=True),
        sa.Column("address", sa.Text(), nullable=True),
        sa.Column("phone", sa.String(50), nullable=True),
        sa.Column("email", sa.String(100), nullable=True),
        sa.Column("logo", sa.String(500), nullable=True),
        sa.Column("business_type", sa.String(50), nullable=True),
        sa.Column("onboarding_completed", sa.Boolean(), default=False),
        sa.Column("currency", sa.String(10), default="SAR"),
        sa.Column("locale", sa.String(10), default="ar_SA"),
        sa.Column("is_active", sa.Boolean(), default=True),
        sa.Column("subscription_plan", sa.String(100), nullable=True),
        sa.Column("subscription_status", sa.String(50), default="trial"),
        sa.Column("subscription_start_date", sa.DateTime(), nullable=True),
        sa.Column("subscription_end_date", sa.DateTime(), nullable=True),
        sa.Column("trial_start_date", sa.DateTime(), nullable=True),
        sa.Column("trial_end_date", sa.DateTime(), nullable=True),
        sa.Column("created_at", sa.DateTime(), server_default=sa.func.now()),
        sa.Column(
            "updated_at",
            sa.DateTime(),
            server_default=sa.func.now(),
            onupdate=sa.func.now(),
        ),
        sa.Column("is_deleted", sa.Boolean(), default=False),
        sa.Column("version", sa.Integer(), default=1),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("idx_org_name", "organizations", ["name"])
    op.create_index("idx_org_status", "organizations", ["subscription_status"])

    # ── Users ──
    op.create_table(
        "users",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("username", sa.String(100), nullable=False),
        sa.Column("email", sa.String(100), nullable=True),
        sa.Column("password_hash", sa.String(255), nullable=False),
        sa.Column("full_name", sa.String(200), nullable=True),
        sa.Column("phone", sa.String(50), nullable=True),
        sa.Column("role", sa.String(20), nullable=False, default="employee"),
        sa.Column("is_active", sa.Boolean(), default=True),
        sa.Column("status", sa.String(20), default="active"),
        sa.Column("mfa_enabled", sa.Boolean(), default=False),
        sa.Column("mfa_secret", sa.String(64), nullable=True),
        sa.Column("is_platform_admin", sa.Boolean(), default=False),
        sa.Column("last_login", sa.DateTime(), nullable=True),
        sa.Column("preferred_usage_mode", sa.String(20), nullable=True),
        sa.Column("organization_id", sa.UUID(), nullable=False),
        sa.Column("created_at", sa.DateTime(), server_default=sa.func.now()),
        sa.Column(
            "updated_at",
            sa.DateTime(),
            server_default=sa.func.now(),
            onupdate=sa.func.now(),
        ),
        sa.Column("is_deleted", sa.Boolean(), default=False),
        sa.Column("version", sa.Integer(), default=1),
        sa.ForeignKeyConstraint(
            ["organization_id"], ["organizations.id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("username"),
    )
    op.create_index("idx_users_org_role", "users", ["organization_id", "role"])

    # ── User Sessions ──
    op.create_table(
        "user_sessions",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("refresh_token", sa.String(500), nullable=False),
        sa.Column("ip_address", sa.String(50), nullable=True),
        sa.Column("device_info", sa.String(200), nullable=True),
        sa.Column("is_active", sa.Boolean(), default=True),
        sa.Column("last_activity", sa.DateTime(), server_default=sa.func.now()),
        sa.Column("created_at", sa.DateTime(), server_default=sa.func.now()),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )

    # ── Audit Logs ──
    op.create_table(
        "audit_logs",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("user_id", sa.UUID(), nullable=True),
        sa.Column("organization_id", sa.UUID(), nullable=False),
        sa.Column("action", sa.String(50), nullable=False),
        sa.Column("resource", sa.String(100), nullable=False),
        sa.Column("resource_id", sa.String(50), nullable=True),
        sa.Column("details", sa.Text(), nullable=True),
        sa.Column("ip_address", sa.String(50), nullable=True),
        sa.Column("created_at", sa.DateTime(), server_default=sa.func.now()),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="SET NULL"),
        sa.ForeignKeyConstraint(
            ["organization_id"], ["organizations.id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "idx_audit_logs_org_action", "audit_logs", ["organization_id", "action"]
    )

    # ── Permissions ──
    op.create_table(
        "permissions",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("organization_id", sa.UUID(), nullable=True),
        sa.Column("role", sa.String(50), nullable=False),
        sa.Column("resource", sa.String(100), nullable=False),
        sa.Column("can_create", sa.Boolean(), default=False),
        sa.Column("can_read", sa.Boolean(), default=False),
        sa.Column("can_update", sa.Boolean(), default=False),
        sa.Column("can_delete", sa.Boolean(), default=False),
        sa.ForeignKeyConstraint(
            ["organization_id"], ["organizations.id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "organization_id",
            "role",
            "resource",
            name="uq_permission_org_role_resource",
        ),
    )

    # ── Subscription Plans ──
    op.create_table(
        "subscription_plans",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column("name_ar", sa.String(100), nullable=True),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("price_monthly", sa.Float(), default=0),
        sa.Column("price_yearly", sa.Float(), default=0),
        sa.Column("features", sa.Text(), nullable=True),
        sa.Column("is_active", sa.Boolean(), default=True),
        sa.Column("created_at", sa.DateTime(), server_default=sa.func.now()),
        sa.PrimaryKeyConstraint("id"),
    )

    # ── Subscription Requests ──
    op.create_table(
        "subscription_requests",
        sa.Column("id", sa.UUID(), nullable=False),
        sa.Column("user_id", sa.UUID(), nullable=False),
        sa.Column("organization_id", sa.UUID(), nullable=False),
        sa.Column("plan_id", sa.UUID(), nullable=False),
        sa.Column("period", sa.String(20), nullable=False),
        sa.Column("amount", sa.Float(), nullable=False),
        sa.Column("status", sa.String(20), default="pending"),
        sa.Column("proof_image", sa.String(500), nullable=True),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(), server_default=sa.func.now()),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(
            ["organization_id"], ["organizations.id"], ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["plan_id"], ["subscription_plans.id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id"),
    )


def downgrade() -> None:
    op.drop_table("subscription_requests")
    op.drop_table("subscription_plans")
    op.drop_table("permissions")
    op.drop_table("audit_logs")
    op.drop_table("user_sessions")
    op.drop_table("users")
    op.drop_table("organizations")
