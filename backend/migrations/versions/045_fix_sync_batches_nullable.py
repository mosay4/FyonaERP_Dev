"""Fix sync_batches completed_at/started_at to be nullable.

Migration 009 had inverted nullable logic, making completed_at NOT NULL.
In-progress batches have completed_at = NULL until finished, so it must be nullable.

Revision ID: 045
Revises: 044
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision = "045"
down_revision = "044"
branch_labels = None
depends_on = None

def upgrade():
    # Use raw SQL to drop NOT NULL constraint; op.alter_column with nullable=True may fail on some PG versions
    # so we use ALTER TABLE ... ALTER COLUMN ... DROP NOT NULL directly
    try:
        op.execute("ALTER TABLE sync_batches ALTER COLUMN completed_at DROP NOT NULL")
    except Exception:
        pass
    try:
        op.execute("ALTER TABLE sync_batches ALTER COLUMN started_at DROP NOT NULL")
    except Exception:
        pass
    try:
        op.execute("ALTER TABLE sync_batches ALTER COLUMN created_at DROP NOT NULL")
    except Exception:
        pass

def downgrade():
    # Re-add NOT NULL (not needed, but for completeness)
    try:
        op.execute("ALTER TABLE sync_batches ALTER COLUMN completed_at SET NOT NULL")
    except Exception:
        pass
