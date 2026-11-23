"""System flag on platform banks.

- platform_bank_accounts.is_system (boolean, default false): marks
  platform-owned banks such as the virtual "Stripe" settlement bank, which
  cannot be renamed, deactivated or deleted via API/UI.

Additive-only; no data is dropped or rewritten.

Revision ID: 056
Revises: 055
"""
from typing import Sequence, Union

from alembic import op
from migrations.idempotent_ops import (
    add_column_if_missing,
)
import sqlalchemy as sa

revision: str = "056"
down_revision: Union[str, None] = "055"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    add_column_if_missing(
        "platform_bank_accounts",
        sa.Column("is_system", sa.Boolean(), server_default=sa.false()),
    )


def downgrade() -> None:
    with op.batch_alter_table("platform_bank_accounts") as batch_op:
        try:
            batch_op.drop_column("is_system")
        except Exception:
            pass
