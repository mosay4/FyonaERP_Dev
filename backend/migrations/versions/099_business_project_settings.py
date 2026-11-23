"""Company-shared settings, separate from employee device preferences."""
from alembic import op
import sqlalchemy as sa
revision = '099'
down_revision = '098'
branch_labels = None
depends_on = None

def upgrade():
    op.add_column('branch_members', sa.Column('scope_valid_after', sa.DateTime(timezone=True), nullable=True))
    op.create_table('business_project_settings',
        sa.Column('organization_id', sa.UUID(), sa.ForeignKey('organizations.id', ondelete='CASCADE'), primary_key=True),
        sa.Column('settings', sa.Text(), nullable=False, server_default='{}'),
        sa.Column('updated_at', sa.DateTime(timezone=True)))
    op.create_table('business_project_backups',
        sa.Column('id', sa.UUID(), primary_key=True),
        sa.Column('organization_id', sa.UUID(), sa.ForeignKey('organizations.id', ondelete='CASCADE'), nullable=False),
        sa.Column('payload', sa.Text(), nullable=False), sa.Column('checksum', sa.Text(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True)))

def downgrade():
    op.drop_table('business_project_backups')
    op.drop_table('business_project_settings')
    op.drop_column('branch_members', 'scope_valid_after')
