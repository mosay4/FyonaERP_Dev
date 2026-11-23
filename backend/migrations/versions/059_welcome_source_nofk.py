"""Drop the FK from app_notifications.source_notif_id to platform_notifications.

The column doubles as a generic idempotency key: the subscription-welcome
flow stores synthetic uuid5 ids that never exist in platform_notifications,
so EVERY welcome insert failed with a foreign-key violation (silently
mislogged as an idempotency duplicate) and no welcome row or push ever
materialized. Dropping the FK fixes all welcome paths (trial, Stripe,
manual approval) with zero data changes.

The (organization_id, source_notif_id) UNIQUE index stays untouched, so
platform-broadcast fanout idempotency is fully preserved.

Revision ID: 059
Revises: 058
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "059"
down_revision: Union[str, None] = "058"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(sa.text(
        "ALTER TABLE app_notifications "
        "DROP CONSTRAINT IF EXISTS app_notifications_source_notif_id_fkey"
    ))


def downgrade() -> None:
    # Best-effort restore; fails open when synthetic ids already exist.
    try:
        op.create_foreign_key(
            "app_notifications_source_notif_id_fkey",
            "app_notifications", "platform_notifications",
            ["source_notif_id"], ["id"],
        )
    except Exception:
        pass
