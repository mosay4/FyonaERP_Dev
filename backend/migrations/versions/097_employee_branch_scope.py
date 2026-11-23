"""Persist explicitly assigned employee branches.

Revision ID: 097
Revises: 096
"""
from alembic import op
import sqlalchemy as sa

revision = '097'
down_revision = '096'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('employee_workspace', sa.Column('branch_ids', sa.Text(), nullable=True))
    op.add_column('employee_invitations', sa.Column('branch_ids', sa.Text(), nullable=True))


def downgrade():
    op.drop_column('employee_invitations', 'branch_ids')
    op.drop_column('employee_workspace', 'branch_ids')
