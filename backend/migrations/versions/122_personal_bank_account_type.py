"""Store the Personal bank account type (جاري current / توفير savings).

Until now the type lived only on the device, so it was lost on reinstall and
never reached the user's other devices. The column is added NULLABLE with no
server default on purpose: existing rows stay NULL ("never stated", read as
'current' by the API), which lets the device that still holds the legacy
local type push it up once without ever overwriting a type that is already
stored on the server. No existing data is rewritten.

Idempotent: on a fresh database migration 025's create_all already created
the column from the current model, and app startup (init_db) also adds it
when missing; both cases are skipped here.

Revision ID: 122
Revises: 121
"""
import sqlalchemy as sa
from alembic import op

from migrations.idempotent_ops import add_column_if_missing

revision = "122"
down_revision = "121"
branch_labels = None
depends_on = None

_TABLE = "personal_bank_accounts"
_CHECK = "ck_personal_bank_accounts_account_type"


def _table_exists() -> bool:
    return _TABLE in set(sa.inspect(op.get_bind()).get_table_names())


def upgrade():
    if not _table_exists():
        return
    add_column_if_missing(
        _TABLE, sa.Column("account_type", sa.String(20), nullable=True)
    )
    if op.get_context().dialect.name == "postgresql":
        # NULL stays allowed (legacy rows); any stated value must be valid.
        op.execute(f"""
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = '{_CHECK}') THEN
        ALTER TABLE {_TABLE} ADD CONSTRAINT {_CHECK}
            CHECK (account_type IS NULL OR account_type IN ('current', 'savings'))
            NOT VALID;
    END IF;
END $$;
""")


def downgrade():
    # Dropping the column would erase every user's stored account type.
    pass
