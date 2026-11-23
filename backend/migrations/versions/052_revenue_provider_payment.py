"""Link subscription revenues to the provider payment for idempotency.

- subscription_revenues.provider_payment_id (nullable): Stripe
  payment_intent id / checkout session id for e-payments.
- Partial unique index so the same provider payment can never book
  revenue twice.

Additive-only.

Revision ID: 052
Revises: 051
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


revision: str = "052"
down_revision: Union[str, None] = "051"
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
    if not _column_exists("subscription_revenues", "provider_payment_id"):
        add_column_if_missing(
            "subscription_revenues",
            sa.Column("provider_payment_id", sa.String(200), nullable=True),
        )
    if not _index_exists("uq_sub_rev_provider_payment"):
        create_index_if_missing(
            "uq_sub_rev_provider_payment",
            "subscription_revenues",
            ["provider_payment_id"],
            unique=True,
            postgresql_where=sa.text("provider_payment_id IS NOT NULL"),
        )


def downgrade() -> None:
    if _index_exists("uq_sub_rev_provider_payment"):
        op.drop_index(
            "uq_sub_rev_provider_payment", table_name="subscription_revenues"
        )
    if _column_exists("subscription_revenues", "provider_payment_id"):
        op.drop_column("subscription_revenues", "provider_payment_id")
