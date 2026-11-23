"""Fix conflict_logs resolved_by/resolved_at to be nullable.

Revision ID: 046
Revises: 045
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision = "046"
down_revision = "045"
branch_labels = None
depends_on = None

def upgrade():
    try:
        op.execute("ALTER TABLE conflict_logs ALTER COLUMN resolved_by DROP NOT NULL")
    except Exception:
        pass
    try:
        op.execute("ALTER TABLE conflict_logs ALTER COLUMN resolved_at DROP NOT NULL")
    except Exception:
        pass
    try:
        op.execute("ALTER TABLE conflict_logs ALTER COLUMN server_data DROP NOT NULL")
    except Exception:
        pass
    try:
        op.execute("ALTER TABLE sync_logs ALTER COLUMN details DROP NOT NULL")
    except Exception:
        pass
    try:
        op.execute("ALTER TABLE entity_versions ALTER COLUMN data_hash DROP NOT NULL")
    except Exception:
        pass

def downgrade():
    pass
