"""Add proof_images (JSON list) to subscription_requests.

Additive-only column so a user can attach multiple proofs to one request.

Revision ID: 038
Revises: 037
Create Date: 2026-09-06
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

revision: str = "038"
down_revision: Union[str, None] = "037"
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


def upgrade() -> None:
    if not _column_exists("subscription_requests", "proof_images"):
        add_column_if_missing("subscription_requests", sa.Column("proof_images", sa.Text(), nullable=True))


def downgrade() -> None:
    if _column_exists("subscription_requests", "proof_images"):
        op.drop_column("subscription_requests", "proof_images")