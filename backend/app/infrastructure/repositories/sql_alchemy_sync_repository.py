from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession
from app.domain.entities.sync_entities import EntityVersion, SyncBatch, ConflictLog, SyncLog
from app.domain.repositories.sync_repository import (
    EntityVersionRepository, SyncBatchRepository, ConflictLogRepository, SyncLogRepository,
)


class SQLEntityVersionRepo(EntityVersionRepository):
    def __init__(self, s: AsyncSession): self._s = s

    async def get(self, org_id, entity_type, entity_id):
        r = await self._s.execute(select(EntityVersion).where(
            EntityVersion.organization_id == org_id, EntityVersion.entity_type == entity_type, EntityVersion.entity_id == entity_id))
        return r.unique().scalar_one_or_none()

    async def upsert(self, ver):
        existing = await self.get(ver.organization_id, ver.entity_type, ver.entity_id)
        if existing:
            existing.version = ver.version; existing.checksum = ver.checksum; existing.data_hash = ver.data_hash
            existing.operation_id = ver.operation_id or existing.operation_id
            existing.last_modified_at = ver.last_modified_at; existing.last_modified_by = ver.last_modified_by
            existing.is_deleted = ver.is_deleted
        else:
            self._s.add(ver)
        await self._s.flush(); return ver

    async def list_since(self, org_id, since, types=None):
        q = select(EntityVersion).where(EntityVersion.organization_id == org_id, EntityVersion.last_modified_at > since)
        if types: q = q.where(EntityVersion.entity_type.in_(types))
        r = await self._s.execute(q.order_by(EntityVersion.last_modified_at)); return list(r.unique().scalars().all())

    async def list_all(self, org_id, types=None):
        q = select(EntityVersion).where(EntityVersion.organization_id == org_id)
        if types: q = q.where(EntityVersion.entity_type.in_(types))
        r = await self._s.execute(q.order_by(EntityVersion.entity_type, EntityVersion.entity_id)); return list(r.unique().scalars().all())

    async def get_next_version(self, org_id, entity_type, entity_id):
        existing = await self.get(org_id, entity_type, entity_id)
        return (existing.version + 1) if existing else 1


class SQLSyncBatchRepo(SyncBatchRepository):
    def __init__(self, s: AsyncSession): self._s = s
    async def create(self, b): self._s.add(b); await self._s.flush(); return b
    async def update(self, b): self._s.add(b); await self._s.flush(); return b
    async def get_last(self, org_id, direction):
        r = await self._s.execute(select(SyncBatch).where(SyncBatch.organization_id == org_id, SyncBatch.direction == direction).order_by(SyncBatch.created_at.desc()).limit(1))
        return r.unique().scalar_one_or_none()
    async def get_by_org_batch(self, org_id, batch_id, direction):
        r = await self._s.execute(select(SyncBatch).where(
            SyncBatch.organization_id == org_id, SyncBatch.batch_id == batch_id, SyncBatch.direction == direction))
        return r.unique().scalar_one_or_none()


class SQLConflictLogRepo(ConflictLogRepository):
    def __init__(self, s: AsyncSession): self._s = s
    async def create(self, c): self._s.add(c); await self._s.flush(); return c
    async def update(self, c): self._s.add(c); await self._s.flush(); return c
    async def list(self, org_id, unresolved_only=False, page=1, per_page=20):
        q = select(ConflictLog).where(ConflictLog.organization_id == org_id)
        cq = select(func.count(ConflictLog.id)).where(ConflictLog.organization_id == org_id)
        if unresolved_only: q, cq = q.where(ConflictLog.resolution == "pending"), cq.where(ConflictLog.resolution == "pending")
        total = (await self._s.execute(cq)).scalar() or 0
        r = await self._s.execute(q.order_by(ConflictLog.created_at.desc()).offset((page-1)*per_page).limit(per_page))
        return list(r.unique().scalars().all()), total
    async def count_unresolved(self, org_id):
        r = await self._s.execute(select(func.count(ConflictLog.id)).where(ConflictLog.organization_id == org_id, ConflictLog.resolution == "pending"))
        return r.scalar() or 0


class SQLSyncLogRepo(SyncLogRepository):
    def __init__(self, s: AsyncSession): self._s = s
    async def create(self, l): self._s.add(l); await self._s.flush(); return l
    async def list(self, org_id, page=1, per_page=50):
        total = (await self._s.execute(select(func.count(SyncLog.id)).where(SyncLog.organization_id == org_id))).scalar() or 0
        r = await self._s.execute(select(SyncLog).where(SyncLog.organization_id == org_id).order_by(SyncLog.created_at.desc()).offset((page-1)*per_page).limit(per_page))
        return list(r.unique().scalars().all()), total
