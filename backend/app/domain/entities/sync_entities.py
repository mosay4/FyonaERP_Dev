import uuid
from datetime import datetime, timezone
from sqlalchemy import Column, String, Boolean, DateTime, ForeignKey, Text, Integer, JSON, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base


class EntityVersion(Base):
    __tablename__ = "entity_versions"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(UUID(as_uuid=True), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True)
    entity_type = Column(String(50), nullable=False)
    entity_id = Column(UUID(as_uuid=True), nullable=False)
    version = Column(Integer, nullable=False, default=1)
    checksum = Column(String(64))
    data_hash = Column(String(64))
    operation_id = Column(String(100), nullable=True, index=True)
    last_modified_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
    last_modified_by = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"))
    is_deleted = Column(Boolean, default=False)
    __table_args__ = (
        UniqueConstraint("organization_id", "entity_type", "entity_id", name="uq_ver_org_type_id"),
    )


class SyncBatch(Base):
    __tablename__ = "sync_batches"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(UUID(as_uuid=True), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True)
    batch_id = Column(String(100), nullable=False, index=True)
    direction = Column(String(10), nullable=False)
    status = Column(String(20), default="pending")
    entity_count = Column(Integer, default=0)
    success_count = Column(Integer, default=0)
    error_count = Column(Integer, default=0)
    started_at = Column(DateTime(timezone=True))
    completed_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
    __table_args__ = (
        UniqueConstraint("organization_id", "batch_id", "direction", name="uq_sync_batch_org_batch"),
    )


class ConflictLog(Base):
    __tablename__ = "conflict_logs"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(UUID(as_uuid=True), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True)
    entity_type = Column(String(50), nullable=False)
    entity_id = Column(UUID(as_uuid=True), nullable=False)
    client_version = Column(Integer, nullable=False)
    server_version = Column(Integer, nullable=False)
    client_data = Column(JSON)
    server_data = Column(JSON)
    resolution = Column(String(50), default="pending")
    resolved_by = Column(String(50))
    resolved_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))


class SyncLog(Base):
    __tablename__ = "sync_logs"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(UUID(as_uuid=True), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True)
    entity_type = Column(String(50), nullable=False)
    entity_id = Column(UUID(as_uuid=True))
    action = Column(String(20), nullable=False)
    status = Column(String(20), nullable=False)
    details = Column(Text)
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
