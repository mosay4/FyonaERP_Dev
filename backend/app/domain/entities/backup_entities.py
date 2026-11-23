"""Per-user backup storage metadata (FYONA personal Backup/Restore rebuild).

Two tables, both strictly scoped by ``user_id``:

- ``UserBackup``: one row per uploaded server backup version. The backup
  FILE bytes live in object storage (``storage.py::unified_upload`` under
  the ``backups`` category); this table is the queryable index with
  integrity metadata (checksum + HMAC).
- ``UserBackupKey``: the per-user HMAC key used for backup authenticity.
  Generated server-side on first use, cached by the device, and re-fetched
  after reinstall — never bound to a device keystore so restore keeps
  working after the app is deleted.

Neither table is ever touched by the sync engine.
"""
import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    Column, String, Boolean, DateTime, ForeignKey, Text, Integer, BigInteger, JSON
)
from sqlalchemy.dialects.postgresql import UUID

from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class UserBackup(Base):
    __tablename__ = "user_backups"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    version = Column(Integer, nullable=False, default=1)
    schema_version = Column(String(20), nullable=False, default="4.0.0")
    filename = Column(String(255), nullable=False)
    storage_key = Column(String(500), nullable=False)
    size_bytes = Column(BigInteger, nullable=False, default=0)
    record_count = Column(Integer, nullable=False, default=0)
    checksum = Column(String(128), nullable=False, default="")
    hmac = Column(String(256), nullable=False, default="")
    status = Column(String(30), nullable=False, default="complete")
    backup_meta = Column(JSON, default=dict)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class UserBackupKey(Base):
    __tablename__ = "user_backup_keys"

    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    key_b64 = Column(Text, nullable=False)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
