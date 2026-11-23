"""Keep the identity printed when employee receipts are issued.

Revision ID: 098
Revises: 097
"""
from alembic import op
import sqlalchemy as sa

revision = '098'
down_revision = '097'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('employee_salary_payments', sa.Column('receipt_snapshot', sa.Text(), nullable=True))
    op.add_column('employee_debts', sa.Column('receipt_snapshot', sa.Text(), nullable=True))


def downgrade():
    op.drop_column('employee_debts', 'receipt_snapshot')
    op.drop_column('employee_salary_payments', 'receipt_snapshot')
