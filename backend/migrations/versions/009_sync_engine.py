"""Add sync engine tables (entity_versions, sync_batches, conflict_logs, sync_logs)

Revision ID: 009
Revises: 008
Create Date: 2026-07-14
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "009"
down_revision = "008"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _exists(table):
    conn = op.get_bind()
    r = conn.execute(sa.text("SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = :n)"), {"n": table})
    return r.scalar()


def upgrade():
    tables = {
        "entity_versions": [
            ("id", postgresql.UUID, True), ("organization_id", postgresql.UUID, False),
            ("entity_type", sa.String(50), False), ("entity_id", postgresql.UUID, False),
            ("version", sa.Integer, False), ("checksum", sa.String(64), True),
            ("data_hash", sa.String(64), True),
            ("last_modified_at", sa.DateTime(timezone=True), True),
            ("last_modified_by", postgresql.UUID, True), ("is_deleted", sa.Boolean, True),
        ],
        "sync_batches": [
            ("id", postgresql.UUID, True), ("organization_id", postgresql.UUID, False),
            ("batch_id", sa.String(100), False), ("direction", sa.String(10), False),
            ("status", sa.String(20), True), ("entity_count", sa.Integer, True),
            ("success_count", sa.Integer, True), ("error_count", sa.Integer, True),
            ("started_at", sa.DateTime(timezone=True), True),
            ("completed_at", sa.DateTime(timezone=True), True),
            ("created_at", sa.DateTime(timezone=True), True),
        ],
        "conflict_logs": [
            ("id", postgresql.UUID, True), ("organization_id", postgresql.UUID, False),
            ("entity_type", sa.String(50), False), ("entity_id", postgresql.UUID, False),
            ("client_version", sa.Integer, False), ("server_version", sa.Integer, False),
            ("client_data", sa.JSON, True), ("server_data", sa.JSON, True),
            ("resolution", sa.String(50), True), ("resolved_by", sa.String(50), True),
            ("resolved_at", sa.DateTime(timezone=True), True),
            ("created_at", sa.DateTime(timezone=True), True),
        ],
        "sync_logs": [
            ("id", postgresql.UUID, True), ("organization_id", postgresql.UUID, False),
            ("entity_type", sa.String(50), False), ("entity_id", postgresql.UUID, True),
            ("action", sa.String(20), False), ("status", sa.String(20), False),
            ("details", sa.Text, True), ("created_at", sa.DateTime(timezone=True), True),
        ],
    }
    for tname, cols in tables.items():
        if not _exists(tname):
            op.create_table(tname, *[sa.Column(c[0], c[1], primary_key=(i == 0), nullable=not c[2] if i > 0 else False) for i, c in enumerate(cols)])


def downgrade():
    for t in ["sync_logs", "conflict_logs", "sync_batches", "entity_versions"]:
        if _exists(t): op.drop_table(t)
