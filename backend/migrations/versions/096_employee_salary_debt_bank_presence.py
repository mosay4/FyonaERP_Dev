"""employee salary/debt banking fields + presence

Revision ID: 096
Revises: 095
"""
from alembic import op
import sqlalchemy as sa

revision = '096'
down_revision = '095'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('employee_workspace', sa.Column('last_seen_at', sa.DateTime(timezone=True)))
    op.add_column('employee_workspace', sa.Column('active_organization_id', sa.UUID(), nullable=True))
    for col in ('bank_account_id', 'branch_id', 'bank_name', 'branch_name'):
        op.add_column('employee_salary_payments', sa.Column(col, sa.String(200) if 'name' in col else sa.UUID(), nullable=True))
    op.add_column('employee_salary_payments', sa.Column('base_salary', sa.Numeric(18, 2), nullable=True))
    op.add_column('employee_salary_payments', sa.Column('remaining_salary', sa.Numeric(18, 2), nullable=True))
    op.add_column('employee_salary_payments', sa.Column('invoice_no', sa.String(60), nullable=True))
    for col in ('bank_account_id', 'branch_id', 'bank_name', 'branch_name'):
        op.add_column('employee_debts', sa.Column(col, sa.String(200) if 'name' in col else sa.UUID(), nullable=True))
    op.add_column('employee_debts', sa.Column('invoice_no', sa.String(60), nullable=True))


def downgrade():
    for table, cols in {
        'employee_workspace': ['last_seen_at', 'active_organization_id'],
        'employee_salary_payments': ['bank_account_id', 'branch_id', 'bank_name', 'branch_name', 'base_salary', 'remaining_salary', 'invoice_no'],
        'employee_debts': ['bank_account_id', 'branch_id', 'bank_name', 'branch_name', 'invoice_no'],
    }.items():
        for col in cols:
            op.drop_column(table, col)
