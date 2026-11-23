"""Stripe payments & subscriptions.

Adds Stripe integration columns to the existing `plans` table and creates the
supporting tables for checkout/payment/subscription tracking + encrypted app
config. All changes are additive and idempotent.

  * `plans`        -> stripe_product_id / stripe_price_id_monthly / stripe_price_id_yearly
  * `payments`     -> one row per Stripe Checkout session (idempotency of checkout)
  * `subscriptions`-> tracks the Stripe subscription lifecycle per org
  * `stripe_webhook_events` -> de-duplicates Stripe webhook delivery
  * `app_config`   -> encrypted runtime settings (Stripe keys)
  * indexes: ix_payments_org_status, ix_subscriptions_org_status, ix_subscriptions_stripe_sub

Revision ID: 015
Revises: 014
Create Date: 2026-08-08
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "015"
down_revision: Union[str, None] = "025"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _exists(table: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = :table)"
        ),
        {"table": table},
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


def _add_column(table: str, column: str, col) -> None:
    if not _column_exists(table, column):
        op.add_column(table, col)


def upgrade() -> None:
    # ── Extend plans with Stripe price/product ids (nullable) ──
    _add_column("plans", "stripe_product_id", sa.Column("stripe_product_id", sa.String(100), nullable=True))
    _add_column("plans", "stripe_price_id_monthly", sa.Column("stripe_price_id_monthly", sa.String(100), nullable=True))
    _add_column("plans", "stripe_price_id_yearly", sa.Column("stripe_price_id_yearly", sa.String(100), nullable=True))

    # ── stripe_payments (one row per Stripe Checkout session) ──
    if not _exists("stripe_payments"):
        op.create_table(
            "stripe_payments",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
            sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True),
            sa.Column("organization_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True),
            sa.Column("plan_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("plans.id", ondelete="SET NULL"), nullable=True, index=True),
            sa.Column("provider", sa.String(20), server_default="stripe"),
            sa.Column("stripe_checkout_session_id", sa.String(255), index=True),
            sa.Column("stripe_payment_intent_id", sa.String(255), index=True),
            sa.Column("stripe_event_id", sa.String(255), unique=True, index=True),
            sa.Column("amount", sa.Float),
            sa.Column("currency", sa.String(10)),
            sa.Column("status", sa.String(20), server_default="pending", index=True),
            sa.Column("plan_name", sa.String(50)),
            sa.Column("period", sa.String(20), server_default="yearly"),
            sa.Column("metadata", sa.Text),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("NOW()")),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("NOW()"), onupdate=sa.text("NOW()")),
        )
        if not _index_exists("stripe_payments", "ix_payments_org_status"):
            op.create_index("ix_payments_org_status", "stripe_payments", ["organization_id", "status"], if_not_exists=True)

    # ── subscriptions ──
    if not _exists("subscriptions"):
        op.create_table(
            "subscriptions",
            sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True, server_default=sa.text("gen_random_uuid()")),
            sa.Column("user_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True),
            sa.Column("organization_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True),
            sa.Column("plan_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("plans.id", ondelete="SET NULL"), nullable=True, index=True),
            sa.Column("stripe_customer_id", sa.String(255), index=True),
            sa.Column("stripe_subscription_id", sa.String(255), index=True),
            sa.Column("plan_name", sa.String(50)),
            sa.Column("status", sa.String(20), server_default="incomplete", index=True),
            sa.Column("current_period_start", sa.DateTime(timezone=True)),
            sa.Column("current_period_end", sa.DateTime(timezone=True)),
            sa.Column("cancel_at_period_end", sa.Boolean, server_default=sa.text("false")),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("NOW()")),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("NOW()"), onupdate=sa.text("NOW()")),
        )
        if not _index_exists("subscriptions", "ix_subscriptions_org_status"):
            op.create_index("ix_subscriptions_org_status", "subscriptions", ["organization_id", "status"], if_not_exists=True)
        if not _index_exists("subscriptions", "ix_subscriptions_stripe_sub"):
            op.create_index("ix_subscriptions_stripe_sub", "subscriptions", ["stripe_subscription_id"], if_not_exists=True)

    # ── stripe_webhook_events (idempotency log) ──
    if not _exists("stripe_webhook_events"):
        op.create_table(
            "stripe_webhook_events",
            sa.Column("event_id", sa.String(255), primary_key=True),
            sa.Column("event_type", sa.String(100), nullable=False),
            sa.Column("status", sa.String(20), server_default="processed"),
            sa.Column("processed_at", sa.DateTime(timezone=True), server_default=sa.text("NOW()")),
        )

    # ── app_config (encrypted runtime settings) ──
    if not _exists("app_config"):
        op.create_table(
            "app_config",
            sa.Column("key", sa.String(100), primary_key=True),
            sa.Column("value_encrypted", sa.Text, nullable=False),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("NOW()"), onupdate=sa.text("NOW()")),
        )


def _index_exists(table: str, index: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM pg_indexes WHERE tablename = :table AND indexname = :index)"
        ),
        {"table": table, "index": index},
    )
    return result.scalar()


def downgrade() -> None:
    for table in ("app_config", "stripe_webhook_events", "subscriptions", "stripe_payments"):
        if _exists(table):
            op.drop_table(table)

    # ── plans: drop Stripe columns ──
    for col in ("stripe_price_id_yearly", "stripe_price_id_monthly", "stripe_product_id"):
        if _column_exists("plans", col):
            op.drop_column("plans", col)
