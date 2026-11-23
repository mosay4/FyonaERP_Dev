"""Employee workspace, invitations, salary ledger and employee debts."""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = '095'
down_revision = '094'
branch_labels = None
depends_on = None
U = postgresql.UUID(as_uuid=True)

def upgrade():
    op.create_table('employee_workspace',
        sa.Column('employee_id', U, sa.ForeignKey('employees.id', ondelete='CASCADE'), primary_key=True),
        sa.Column('organization_id', U, sa.ForeignKey('organizations.id', ondelete='CASCADE'), nullable=False),
        sa.Column('linked_user_id', U, sa.ForeignKey('users.id', ondelete='SET NULL')),
        sa.Column('photo_url', sa.Text()),
        sa.Column('salary_currency', sa.String(20), nullable=False, server_default='SAR'),
        sa.Column('permissions', sa.Text(), nullable=False, server_default='{}'),
        sa.Column('created_at', sa.DateTime(timezone=True)),
        sa.Column('updated_at', sa.DateTime(timezone=True)))
    op.create_index('ix_employee_workspace_org', 'employee_workspace', ['organization_id'])
    op.create_index('ix_employee_workspace_user', 'employee_workspace', ['linked_user_id'])
    op.create_table('employee_invitations',
        sa.Column('id', U, primary_key=True),
        sa.Column('organization_id', U, sa.ForeignKey('organizations.id', ondelete='CASCADE'), nullable=False),
        sa.Column('employee_id', U, sa.ForeignKey('employees.id', ondelete='CASCADE'), nullable=False),
        sa.Column('invited_user_id', U, sa.ForeignKey('users.id', ondelete='CASCADE'), nullable=False),
        sa.Column('invited_by', U, sa.ForeignKey('users.id', ondelete='SET NULL')),
        sa.Column('status', sa.String(20), nullable=False, server_default='pending'),
        sa.Column('permissions', sa.Text(), nullable=False, server_default='{}'),
        sa.Column('created_at', sa.DateTime(timezone=True)),
        sa.Column('responded_at', sa.DateTime(timezone=True)),
        sa.UniqueConstraint('employee_id', 'invited_user_id', 'status', name='uq_employee_invite_state'))
    op.create_index('ix_employee_invitations_org', 'employee_invitations', ['organization_id'])
    op.create_index('ix_employee_invitations_emp', 'employee_invitations', ['employee_id'])
    op.create_index('ix_employee_invitations_user', 'employee_invitations', ['invited_user_id'])
    op.create_table('employee_salary_payments',
        sa.Column('id', U, primary_key=True),
        sa.Column('organization_id', U, sa.ForeignKey('organizations.id', ondelete='CASCADE'), nullable=False),
        sa.Column('employee_id', U, sa.ForeignKey('employees.id', ondelete='CASCADE'), nullable=False),
        sa.Column('operation_no', sa.String(60), nullable=False, unique=True),
        sa.Column('amount', sa.Numeric(18, 2), nullable=False, server_default='0'),
        sa.Column('currency', sa.String(20), nullable=False, server_default='SAR'),
        sa.Column('paid_at', sa.DateTime(timezone=True)),
        sa.Column('notes', sa.Text()),
        sa.Column('created_by', U, sa.ForeignKey('users.id', ondelete='SET NULL')))
    op.create_index('ix_employee_salary_org', 'employee_salary_payments', ['organization_id'])
    op.create_index('ix_employee_salary_emp', 'employee_salary_payments', ['employee_id'])
    op.create_table('employee_debts',
        sa.Column('id', U, primary_key=True),
        sa.Column('organization_id', U, sa.ForeignKey('organizations.id', ondelete='CASCADE'), nullable=False),
        sa.Column('employee_id', U, sa.ForeignKey('employees.id', ondelete='CASCADE'), nullable=False),
        sa.Column('direction', sa.String(30), nullable=False),
        sa.Column('kind', sa.String(20), nullable=False, server_default='charge'),
        sa.Column('amount', sa.Numeric(18, 2), nullable=False, server_default='0'),
        sa.Column('currency', sa.String(20), nullable=False, server_default='SAR'),
        sa.Column('notes', sa.Text()),
        sa.Column('created_by', U, sa.ForeignKey('users.id', ondelete='SET NULL')),
        sa.Column('created_at', sa.DateTime(timezone=True)))
    op.create_index('ix_employee_debts_org', 'employee_debts', ['organization_id'])
    op.create_index('ix_employee_debts_emp', 'employee_debts', ['employee_id'])

def downgrade():
    op.drop_table('employee_debts')
    op.drop_table('employee_salary_payments')
    op.drop_table('employee_invitations')
    op.drop_table('employee_workspace')
