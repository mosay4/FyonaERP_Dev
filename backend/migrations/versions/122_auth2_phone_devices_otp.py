"""Auth v2: verified phone, social identities, trusted devices, OTP engine.

Additive only (no drops in upgrade). Fresh databases may already have the
tables/columns from 025's create_all, hence the idempotent helpers.

Revision ID: 122
Revises: 121
Create Date: 2026-11-26
"""
from alembic import op
import sqlalchemy as sa

from migrations.idempotent_ops import (
    add_column_if_missing,
    create_index_if_missing,
)

revision = "122"
down_revision = "121"
branch_labels = None
depends_on = None


def upgrade() -> None:
    add_column_if_missing("users", sa.Column("phone_e164", sa.String(20), nullable=True))
    add_column_if_missing("users", sa.Column("phone_verified_at", sa.DateTime(timezone=True), nullable=True))
    create_index_if_missing("ix_users_phone_e164", "users", ["phone_e164"], unique=True)
    # The tables are defined once, in the models (single source of truth);
    # checkfirst keeps this safe on databases that already have them.
    import app.domain.entities.auth_entities  # noqa: F401
    from app.domain.entities import auth2_entities as m

    bind = op.get_bind()
    for table in (
        m.AuthIdentity.__table__, m.AuthDevice.__table__, m.AuthDeviceNonce.__table__,
        m.OtpChallenge.__table__, m.OtpDelivery.__table__, m.OtpEvent.__table__,
        m.OtpBudget.__table__, m.PrimaryTransfer.__table__,
    ):
        table.create(bind=bind, checkfirst=True)


def downgrade() -> None:
    for name in ("auth_primary_transfers", "otp_budgets", "otp_events", "otp_deliveries",
                 "otp_challenges", "auth_device_nonces", "auth_devices", "auth_identities"):
        op.execute(f"DROP TABLE IF EXISTS {name}")
    op.execute("DROP INDEX IF EXISTS ix_users_phone_e164")
    op.drop_column("users", "phone_verified_at")
    op.drop_column("users", "phone_e164")
