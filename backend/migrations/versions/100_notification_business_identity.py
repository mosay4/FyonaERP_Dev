"""Business identity pictures for employment notifications."""
from alembic import op
import sqlalchemy as sa
revision = '100'
down_revision = '099'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('app_notifications', sa.Column('image_url', sa.Text(), nullable=True))


def downgrade():
    op.drop_column('app_notifications', 'image_url')
