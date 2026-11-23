"""Durable "free plan consumed exactly once" marker on organizations.

The free/trial offer used to be gated only by `organizations.trial_end_date`,
which is cleared whenever a paid plan activates — so free → paid → cancel made
the free plan reappear forever. This adds a never-cleared boolean and
backfills it for every org that already had a trial or a paid subscription.

Revision ID: 060
Revises: 059
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "060"
down_revision: Union[str, None] = "059"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "organizations",
        sa.Column(
            "has_used_free_plan",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
    )
    op.execute(sa.text(
        "UPDATE organizations SET has_used_free_plan = TRUE "
        "WHERE trial_end_date IS NOT NULL OR subscription_start_date IS NOT NULL"
    ))


def downgrade() -> None:
    op.drop_column("organizations", "has_used_free_plan")
