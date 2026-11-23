"""Subscription hardening: canonical package types, single-pending guard,
invoice payment snapshots, e-payment idempotency.

- plans.package_type / plans.duration_days (+ backfill from name_en).
- subscription_requests: one PENDING request per org (partial unique index).
- subscription_revenues: one row per request (partial unique index).
- subscription_invoices: bank_name / card_brand / provider_payment_id
  (+ partial unique index on provider_payment_id for e-payments).
- stripe_payments.idempotency_key: unique index (NULLs allowed).

Additive-only; no data is dropped or rewritten.

Revision ID: 051
Revises: 050
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


revision: str = "051"
down_revision: Union[str, None] = "050"
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


def _index_exists(name: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text("SELECT EXISTS (SELECT FROM pg_indexes WHERE indexname = :name)"),
        {"name": name},
    )
    return result.scalar()


def upgrade() -> None:
    # ── plans: canonical package type + duration ──
    if not _column_exists("plans", "package_type"):
        add_column_if_missing(
            "plans",
            sa.Column("package_type", sa.String(20), nullable=True),
        )
    if not _column_exists("plans", "duration_days"):
        add_column_if_missing(
            "plans",
            sa.Column("duration_days", sa.Integer(), nullable=True),
        )
    # Backfill canonical types from the English names (idempotent).
    conn = op.get_bind()
    conn.execute(
        sa.text(
            "UPDATE plans SET package_type = CASE "
            "WHEN lower(name_en) LIKE '%free%' THEN 'free' "
            "WHEN lower(name_en) LIKE '%personal%' AND lower(name_en) LIKE '%business%' THEN 'premium' "
            "WHEN lower(name_en) LIKE '%business%' THEN 'business' "
            "WHEN lower(name_en) LIKE '%personal%' THEN 'personal' "
            "ELSE package_type END "
            "WHERE package_type IS NULL"
        )
    )
    conn.execute(
        sa.text(
            "UPDATE plans SET duration_days = 365 "
            "WHERE duration_days IS NULL"
        )
    )

    # ── One PENDING subscription request per organization ──
    if not _index_exists("uq_sub_req_org_pending"):
        create_index_if_missing(
            "uq_sub_req_org_pending",
            "subscription_requests",
            ["organization_id"],
            unique=True,
            postgresql_where=sa.text("status = 'pending'"),
        )

    # ── One revenue row per manual request ──
    if not _index_exists("uq_sub_rev_request"):
        create_index_if_missing(
            "uq_sub_rev_request",
            "subscription_revenues",
            ["request_id"],
            unique=True,
            postgresql_where=sa.text("request_id IS NOT NULL"),
        )

    # ── Invoice payment snapshots ──
    if not _column_exists("subscription_invoices", "bank_name"):
        add_column_if_missing(
            "subscription_invoices",
            sa.Column("bank_name", sa.String(200), nullable=True),
        )
    if not _column_exists("subscription_invoices", "card_brand"):
        add_column_if_missing(
            "subscription_invoices",
            sa.Column("card_brand", sa.String(50), nullable=True),
        )
    if not _column_exists("subscription_invoices", "provider_payment_id"):
        add_column_if_missing(
            "subscription_invoices",
            sa.Column("provider_payment_id", sa.String(200), nullable=True),
        )
    if not _index_exists("uq_sub_inv_provider_payment"):
        create_index_if_missing(
            "uq_sub_inv_provider_payment",
            "subscription_invoices",
            ["provider_payment_id"],
            unique=True,
            postgresql_where=sa.text("provider_payment_id IS NOT NULL"),
        )

    # ── E-payment idempotency key uniqueness ──
    if not _index_exists("uq_stripe_payments_idempotency_key"):
        create_index_if_missing(
            "uq_stripe_payments_idempotency_key",
            "stripe_payments",
            ["idempotency_key"],
            unique=True,
            postgresql_where=sa.text("idempotency_key IS NOT NULL"),
        )


def downgrade() -> None:
    if _index_exists("uq_stripe_payments_idempotency_key"):
        op.drop_index("uq_stripe_payments_idempotency_key", table_name="stripe_payments")
    if _index_exists("uq_sub_inv_provider_payment"):
        op.drop_index("uq_sub_inv_provider_payment", table_name="subscription_invoices")
    if _column_exists("subscription_invoices", "provider_payment_id"):
        op.drop_column("subscription_invoices", "provider_payment_id")
    if _column_exists("subscription_invoices", "card_brand"):
        op.drop_column("subscription_invoices", "card_brand")
    if _column_exists("subscription_invoices", "bank_name"):
        op.drop_column("subscription_invoices", "bank_name")
    if _index_exists("uq_sub_rev_request"):
        op.drop_index("uq_sub_rev_request", table_name="subscription_revenues")
    if _index_exists("uq_sub_req_org_pending"):
        op.drop_index("uq_sub_req_org_pending", table_name="subscription_requests")
    if _column_exists("plans", "duration_days"):
        op.drop_column("plans", "duration_days")
    if _column_exists("plans", "package_type"):
        op.drop_column("plans", "package_type")
