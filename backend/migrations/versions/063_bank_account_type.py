"""Business bank account type (checking/savings), mirroring Personal.

Revision ID: 063
Revises: 062
"""
from alembic import op
import sqlalchemy as sa

revision = "063"
down_revision = "062"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "bank_accounts",
        sa.Column(
            "account_type",
            sa.String(20),
            nullable=False,
            server_default="checking",
        ),
    )


def downgrade():
    op.drop_column("bank_accounts", "account_type")
