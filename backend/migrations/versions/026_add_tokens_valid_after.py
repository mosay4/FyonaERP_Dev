"""Add users.tokens_valid_after for instant session revocation.

Revision ID: 026
Revises: 024
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "026"
down_revision: Union[str, None] = "024"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()
    result = bind.execute(
        sa.text(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_name = 'users' AND column_name = 'tokens_valid_after'"
        )
    )
    if result.scalar_one_or_none() is None:
        bind.execute(
            sa.text("ALTER TABLE users ADD COLUMN tokens_valid_after TIMESTAMPTZ")
        )


def downgrade() -> None:
    op.drop_column("users", "tokens_valid_after")
