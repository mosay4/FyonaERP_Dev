"""Separate documented FX effective time from its audit recording time."""
from alembic import op
import sqlalchemy as sa

revision = '094'
down_revision = '093'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('exchange_rate_history', sa.Column('effective_at',
                  sa.DateTime(timezone=True), nullable=True))
    op.create_index('ix_exchange_rate_history_effective_at',
                    'exchange_rate_history', ['effective_at'])


def downgrade():
    op.drop_index('ix_exchange_rate_history_effective_at', table_name='exchange_rate_history')
    op.drop_column('exchange_rate_history', 'effective_at')
