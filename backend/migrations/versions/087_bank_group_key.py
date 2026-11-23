"""Stable bank identity grouping for the all-branches bank view.

No rows are merged by name. Existing rows stay NULL (unconfirmed) until an
IBAN-based identity or an explicit owner link assigns a group key.

Revision ID: 087
Revises: 086
"""
from alembic import op
import sqlalchemy as sa

revision = "087"
down_revision = "086"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("bank_accounts", sa.Column(
        "bank_group_key", sa.String(120), nullable=True))
    op.create_index("ix_bank_accounts_bank_group_key", "bank_accounts",
                    ["bank_group_key"])


def downgrade():
    op.drop_index("ix_bank_accounts_bank_group_key", table_name="bank_accounts")
    op.drop_column("bank_accounts", "bank_group_key")
