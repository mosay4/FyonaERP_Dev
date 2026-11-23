"""Indexed phone lookups and versioned branch images."""
from alembic import op
import sqlalchemy as sa
revision = '101'
down_revision = '100'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('users', sa.Column('phone_lookup_digits', sa.String(32), nullable=True))
    op.add_column('users', sa.Column('phone_national_digits', sa.String(32), nullable=True))
    # Some installations already have this legacy timestamp. Preserve it.
    if 'updated_at' not in {column['name'] for column in sa.inspect(op.get_bind()).get_columns('branches')}:
        op.add_column('branches', sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.func.now()))
    from app.core.phone_lookup import phone_lookup_keys
    connection = op.get_bind()
    users = sa.table('users', sa.column('id', sa.UUID()), sa.column('phone', sa.String()),
        sa.column('phone_country', sa.String()), sa.column('phone_lookup_digits', sa.String()),
        sa.column('phone_national_digits', sa.String()))
    last = None
    while True:
        query = sa.select(users.c.id, users.c.phone, users.c.phone_country).where(users.c.phone.isnot(None))
        if last is not None: query = query.where(users.c.id > last)
        batch = connection.execute(query.order_by(users.c.id).limit(500)).mappings().all()
        if not batch: break
        for user in batch:
            full, national = phone_lookup_keys(user['phone'], user['phone_country'])
            connection.execute(users.update().where(users.c.id == user['id']).values(
                phone_lookup_digits=full, phone_national_digits=national))
        last = batch[-1]['id']
    op.create_index('ix_users_phone_lookup_digits', 'users', ['phone_lookup_digits'])
    op.create_index('ix_users_phone_national_digits', 'users', ['phone_national_digits'])


def downgrade():
    op.drop_index('ix_users_phone_national_digits', table_name='users')
    op.drop_index('ix_users_phone_lookup_digits', table_name='users')
    op.drop_column('users', 'phone_national_digits')
    op.drop_column('users', 'phone_lookup_digits')
    # Keep the timestamp: it may predate this migration.
