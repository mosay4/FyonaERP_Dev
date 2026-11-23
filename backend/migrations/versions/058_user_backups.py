"""Per-user backup storage (FYONA personal Backup/Restore rebuild).

- user_backups (id, user_id FK CASCADE, version, schema_version, filename,
  storage_key, size_bytes, record_count, checksum, hmac, status,
  backup_meta JSON, created_at, updated_at): versioned server backup index.
- user_backup_keys (user_id PK FK CASCADE, key_b64, created_at,
  updated_at): per-user HMAC key for backup authenticity.

Additive-only; no data is dropped or rewritten. Cascades keep user
deletion cleaning up that user's backups automatically.

Revision ID: 058
Revises: 057
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import UUID as PG_UUID

revision: str = "058"
down_revision: Union[str, None] = "057"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "user_backups",
        sa.Column("id", PG_UUID(as_uuid=True), primary_key=True),
        sa.Column("user_id", PG_UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="CASCADE"),
                  nullable=False, index=True),
        sa.Column("version", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("schema_version", sa.String(20), nullable=False,
                  server_default="4.0.0"),
        sa.Column("filename", sa.String(255), nullable=False),
        sa.Column("storage_key", sa.String(500), nullable=False),
        sa.Column("size_bytes", sa.BigInteger(), nullable=False,
                  server_default="0"),
        sa.Column("record_count", sa.Integer(), nullable=False,
                  server_default="0"),
        sa.Column("checksum", sa.String(128), nullable=False, server_default=""),
        sa.Column("hmac", sa.String(256), nullable=False, server_default=""),
        sa.Column("status", sa.String(30), nullable=False,
                  server_default="complete"),
        sa.Column("backup_meta", sa.JSON(), server_default="{}"),
        sa.Column("created_at", sa.DateTime(timezone=True)),
        sa.Column("updated_at", sa.DateTime(timezone=True)),
    )
    op.create_table(
        "user_backup_keys",
        sa.Column("user_id", PG_UUID(as_uuid=True),
                  sa.ForeignKey("users.id", ondelete="CASCADE"),
                  primary_key=True),
        sa.Column("key_b64", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True)),
        sa.Column("updated_at", sa.DateTime(timezone=True)),
    )


def downgrade() -> None:
    op.drop_table("user_backup_keys")
    op.drop_table("user_backups")
