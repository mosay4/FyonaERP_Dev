"""Renewal retry bookkeeping on Stripe subscriptions.

- subscriptions.renewal_retry_count (integer, default 0): consecutive
  failed off-session collection attempts for the current renewal cycle.
- subscriptions.renewal_next_retry_at (timestamptz, nullable): next
  scheduled retry moment for the custom retry schedule.

Additive-only; no data is dropped or rewritten.

Revision ID: 057
Revises: 056
"""
from typing import Sequence, Union

from alembic import op
from migrations.idempotent_ops import (
    add_column_if_missing,
)
import sqlalchemy as sa

revision: str = "057"
down_revision: Union[str, None] = "056"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    add_column_if_missing(
        "subscriptions",
        sa.Column("renewal_retry_count", sa.Integer(), server_default="0"),
    )
    add_column_if_missing(
        "subscriptions",
        sa.Column("renewal_next_retry_at", sa.DateTime(timezone=True)),
    )


def downgrade() -> None:
    with op.batch_alter_table("subscriptions") as batch_op:
        for col in ("renewal_next_retry_at", "renewal_retry_count"):
            try:
                batch_op.drop_column(col)
            except Exception:
                pass
