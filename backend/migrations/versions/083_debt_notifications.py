"""Commercial-debt notifications — logical separation + one-notification-per-event.

* `app_notifications.domain` = 'main' (default, untouched behaviour) or
  'commercial_debt' (this feature) — indexed so each center lists only its own.
* `event_id` + UNIQUE(user_id, event_id): exactly ONE notification per logical
  financial event per recipient, regardless of retries / double taps / push+WS.
* `route`: the deep-link target (real ids) opened when the notification is tapped.
* `merchant_links.linked_via`: how the party was added ('phone' | 'code') —
  the detail card shows exactly that identifier, never the email.

Additive + reversible.

Revision ID: 083
Revises: 082
"""
from alembic import op
import sqlalchemy as sa

revision = "083"
down_revision = "082"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("app_notifications",
                  sa.Column("domain", sa.String(20), nullable=False,
                            server_default="main"))
    op.add_column("app_notifications",
                  sa.Column("event_id", sa.String(80), nullable=True))
    op.add_column("app_notifications",
                  sa.Column("route", sa.String(200), nullable=True))
    op.create_index("ix_app_notif_domain_user", "app_notifications",
                    ["domain", "user_id"])
    op.create_unique_constraint("uq_app_notif_event", "app_notifications",
                                ["user_id", "event_id"])
    op.add_column("merchant_links",
                  sa.Column("linked_via", sa.String(10), nullable=True))
    # Backfill: how the party was added (phone wins, else the public code).
    op.execute("""
        UPDATE merchant_links
        SET linked_via = CASE WHEN phone IS NOT NULL AND phone <> ''
                              THEN 'phone' ELSE 'code' END
    """)


def downgrade():
    op.drop_column("merchant_links", "linked_via")
    op.drop_constraint("uq_app_notif_event", "app_notifications", type_="unique")
    op.drop_index("ix_app_notif_domain_user", table_name="app_notifications")
    op.drop_column("app_notifications", "route")
    op.drop_column("app_notifications", "event_id")
    op.drop_column("app_notifications", "domain")
