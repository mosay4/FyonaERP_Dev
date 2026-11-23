"""Link Business expenses to the bank/cash account they were paid FROM, so
the money report can scope expenses to the SELECTED account exactly.

Additive + nullable (unlinked expenses stay unlinked) → safe & reversible.

Revision ID: 081
Revises: 080
"""
from alembic import op
import sqlalchemy as sa

revision = "081"
down_revision = "080"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "expenses",
        sa.Column("bank_account_id", sa.UUID(), nullable=True),
    )
    op.create_foreign_key(
        "fk_expenses_bank_account",
        "expenses", "bank_accounts", ["bank_account_id"], ["id"],
        ondelete="SET NULL",
    )


def downgrade():
    op.drop_constraint("fk_expenses_bank_account", "expenses",
                       type_="foreignkey")
    op.drop_column("expenses", "bank_account_id")
