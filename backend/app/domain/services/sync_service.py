from uuid import UUID
from typing import Optional, List, Tuple
from datetime import datetime, timedelta, timezone
from hashlib import sha256
import json

from app.domain.models.sync_models import (
    SyncPushRequest, SyncPullRequest, SyncResult, SyncEntity, SyncConflict,
    SyncStatusResponse, SyncHealthResponse,
)
from app.domain.entities.sync_entities import EntityVersion, SyncBatch, ConflictLog, SyncLog
from app.domain.repositories.sync_repository import (
    EntityVersionRepository, SyncBatchRepository, ConflictLogRepository, SyncLogRepository,
)


def _client_newer_than(client_updated_at, server_modified_at) -> bool:
    """True when the queued op's intent is newer than the server row.

    Missing or unparseable client timestamp defaults to True (apply), keeping
    legacy clients converging instead of wedging. All comparisons are
    timezone-aware (naive values are assumed UTC).
    """
    if not client_updated_at:
        return True
    try:
        client_dt = datetime.fromisoformat(
            str(client_updated_at).replace("Z", "+00:00"))
        if client_dt.tzinfo is None:
            client_dt = client_dt.replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return True
    try:
        server_dt = server_modified_at
        if server_dt is None:
            return True
        if getattr(server_dt, "tzinfo", None) is None:
            server_dt = server_dt.replace(tzinfo=timezone.utc)
        return client_dt >= server_dt
    except (TypeError, AttributeError):
        return True


class SyncService:
    SUPPORTED_ENTITIES = {
        "customer", "supplier", "product", "category", "inventory_movement",
        "invoice", "payment",
        "sales_order", "sales_return", "sales_quote", "delivery_note",
        "purchase_order", "purchase_receipt", "purchase_return", "supplier_bill",
        "account", "journal_entry",
        "employee", "department", "position", "attendance", "leave", "payroll",
        "personal_transaction", "personal_savings_goal", "personal_bank_account",
        "personal_debt", "personal_budget", "personal_recurring_transaction",
    }

    # User-scoped personal entities (single-user offline-first): stale queued
    # UPDATEs converge via last-push-wins instead of permanent conflicts.
    PERSONAL_SYNC_TYPES = {
        "personal_transaction", "personal_savings_goal", "personal_bank_account",
        "personal_debt", "personal_budget", "personal_recurring_transaction",
    }

    def __init__(self, ver_repo: EntityVersionRepository, batch_repo: SyncBatchRepository,
                 conflict_repo: ConflictLogRepository, log_repo: SyncLogRepository):
        self._ver = ver_repo; self._batch = batch_repo; self._conflict = conflict_repo; self._log = log_repo

    @staticmethod
    def _checksum(data: dict) -> str:
        return sha256(json.dumps(data, sort_keys=True, default=str).encode()).hexdigest()[:16]

    @staticmethod
    def _now(): return datetime.now(timezone.utc)

    # ═══ Push ═══

    async def push(self, org_id: UUID, user_id: UUID, data: SyncPushRequest) -> SyncResult:
        # Idempotency: a retried batch (same org + batch_id + direction) was
        # already applied — return a success result without re-applying.
        existing_batch = await self._batch.get_by_org_batch(org_id, data.batch_id, "push")
        if existing_batch is not None and (existing_batch.success_count or 0) >= 0:
            # If a PREVIOUS attempt already completed, treat replay as success
            # (the client's queue is then safe to clear).
            if existing_batch.status == "completed":
                return SyncResult(batch_id=data.batch_id, success=True, pushed=existing_batch.success_count or 0)
            # In-progress / failed re-send: still mark this replay as in-progress
            existing_batch.status = "in_progress"
            await self._batch.update(existing_batch)
            return SyncResult(batch_id=data.batch_id, success=True, pushed=0)

        batch = SyncBatch(organization_id=org_id, batch_id=data.batch_id, direction="push",
                          status="in_progress", entity_count=len(data.entities), started_at=self._now())
        await self._batch.create(batch)
        pushed = 0; conflicts: List[SyncConflict] = []; errors: List[str] = []

        for entity in data.entities:
            if entity.entity_type not in self.SUPPORTED_ENTITIES:
                errors.append(f"Unsupported entity type: {entity.entity_type}"); continue
            try:
                conflict = await self._resolve_entity(org_id, user_id, entity, data.force)
                if conflict:
                    conflicts.append(conflict)
                    await self._conflict.create(ConflictLog(
                        organization_id=org_id, entity_type=entity.entity_type, entity_id=entity.entity_id,
                        client_version=entity.version, server_version=conflict.server_version,
                        client_data=entity.data, server_data=conflict.server_data,
                    ))
                else:
                    pushed += 1
                await self._log.create(SyncLog(organization_id=org_id, entity_type=entity.entity_type,
                    entity_id=entity.entity_id, action="push", status="conflict" if conflict else "success", details="conflict" if conflict else ""))
            except Exception as e:
                errors.append(f"{entity.entity_type}/{entity.entity_id}: {str(e)}")
                await self._log.create(SyncLog(organization_id=org_id, entity_type=entity.entity_type,
                    entity_id=entity.entity_id, action="push", status="error", details=str(e)))

        batch.status = "completed"; batch.success_count = pushed; batch.error_count = len(errors); batch.completed_at = self._now()
        await self._batch.update(batch)
        return SyncResult(batch_id=data.batch_id, success=len(errors) == 0, pushed=pushed, conflicts=conflicts, errors=errors)

    async def _resolve_entity(self, org_id: UUID, user_id: UUID, entity: SyncEntity, force: bool) -> Optional[SyncConflict]:
        existing = await self._ver.get(org_id, entity.entity_type, entity.entity_id)
        if not existing:
            ch = self._checksum(entity.data)
            ver = EntityVersion(organization_id=org_id, entity_type=entity.entity_type, entity_id=entity.entity_id,
                version=1, checksum=ch, data_hash=ch, operation_id=entity.operation_id,
                last_modified_at=self._now(), last_modified_by=user_id, is_deleted=entity.deleted)
            await self._ver.upsert(ver); return None

        # Idempotency: same operation arriving twice (network retry after the
        # server already applied it) is a no-op — never applied twice.
        if entity.operation_id and existing.operation_id == entity.operation_id:
            return None

        # A DELETE is a terminal operation — always apply the tombstone
        # regardless of version ordering. Without this, an offline delete
        # with baseVersion=0 (sends version=1) would conflict with the
        # server's version≥1 and the EntityVersion.is_deleted flag would
        # never be set, causing the transaction to "resurrect" on the next pull.
        if entity.deleted:
            if entity.version > existing.version:
                existing.version = entity.version
            if entity.operation_id:
                existing.operation_id = entity.operation_id
            existing.checksum = self._checksum(entity.data or {})
            existing.data_hash = existing.checksum
            existing.is_deleted = True
            existing.last_modified_at = self._now()
            existing.last_modified_by = user_id
            await self._ver.upsert(existing)
            return None

        if force or entity.version > existing.version:
            ch = self._checksum(entity.data)
            existing.version = entity.version; existing.checksum = ch; existing.data_hash = ch
            if entity.operation_id:
                existing.operation_id = entity.operation_id
            existing.last_modified_at = self._now(); existing.last_modified_by = user_id; existing.is_deleted = entity.deleted
            await self._ver.upsert(existing); return None

        if entity.version == existing.version:
            existing.last_modified_at = self._now()
            await self._ver.upsert(existing); return None

        # Personal finance is single-user offline-first: a queued UPDATE that
        # arrives with a STALE version (client < server, bumped by an
        # interleaved CRUD write) must still converge. Ordering is by
        # wall-clock intent (client_updated_at vs the row's last modification):
        #   - client newer  -> apply the queued intent (last-writer-wins);
        #   - client older  -> server wins; report `superseded` so the client
        #     DROPS the op instead of retrying forever (a blind apply here
        #     would silently revert newer server-side balances backwards).
        # A frozen outbox row shields the local mirror from all later pulls
        # and refreshes, which is what made online UPDATE/DELETE appear to
        # "do nothing". Either branch unfreezes it.
        # Business (multi-user) entities keep strict conflict behavior below.
        if not entity.deleted and entity.entity_type in self.PERSONAL_SYNC_TYPES:
            if _client_newer_than(entity.client_updated_at,
                                  existing.last_modified_at):
                if entity.operation_id:
                    existing.operation_id = entity.operation_id
                existing.checksum = self._checksum(entity.data or {})
                existing.data_hash = existing.checksum
                existing.last_modified_at = self._now()
                existing.last_modified_by = user_id
                await self._ver.upsert(existing); return None
            return SyncConflict(entity_type=entity.entity_type, entity_id=entity.entity_id,
                client_version=entity.version, server_version=existing.version,
                client_data=None,
                server_data={"superseded": True,
                             "reason": "server row is newer; queued op dropped"})

        return SyncConflict(entity_type=entity.entity_type, entity_id=entity.entity_id,
            client_version=entity.version, server_version=existing.version,
            client_data=entity.data, server_data=None)

    # ═══ Pull ═══

    # Re-read a small window BEFORE the client cursor. A concurrent write may
    # commit a row whose `last_modified_at` was stamped before the previous
    # pull's cutoff but only became visible afterwards; without the overlap
    # that row would be skipped forever. Re-sent rows are idempotent upserts.
    PULL_SAFETY_OVERLAP = timedelta(seconds=15)

    async def pull(self, org_id: UUID, data: SyncPullRequest) -> Tuple[List[dict], int]:
        since = data.last_sync_at
        if since is not None:
            since = since - self.PULL_SAFETY_OVERLAP
        else:
            since = datetime(2000, 1, 1, tzinfo=timezone.utc)
        versions = await self._ver.list_since(org_id, since, data.entity_types) if not data.full_sync else await self._ver.list_all(org_id, data.entity_types)
        entities = []
        for v in versions:
            entities.append({
                "entity_type": v.entity_type, "entity_id": str(v.entity_id),
                "version": v.version, "checksum": v.checksum, "deleted": v.is_deleted,
                "last_modified_at": v.last_modified_at.isoformat() if v.last_modified_at else None,
            })
        return entities, len(entities)

    # ═══ Status ═══

    async def status(self, org_id: UUID) -> SyncStatusResponse:
        last_batch = await self._batch.get_last(org_id, "push")
        pending = await self._conflict.count_unresolved(org_id)
        total = (await self._conflict.list(org_id))[1]
        return SyncStatusResponse(
            last_sync_at=last_batch.completed_at if last_batch else None,
            pending_pushes=0,  # server side doesn't track client pending
            total_conflicts=total, unresolved_conflicts=pending,
        )

    async def health(self) -> SyncHealthResponse:
        return SyncHealthResponse(server_time=self._now())

    # ═══ Conflicts ═══

    async def list_conflicts(self, org_id: UUID, unresolved_only: bool = False, page: int = 1, per_page: int = 20) -> Tuple[List[ConflictLog], int]:
        return await self._conflict.list(org_id, unresolved_only, page, per_page)

    async def resolve_conflict(self, org_id: UUID, conflict_id: UUID, resolution: str, resolved_by: str = "manual") -> None:
        c = await self._conflict.list(org_id, unresolved_only=False)
        for item, _ in [c]:
            if item.id == conflict_id:
                item.resolution = resolution; item.resolved_by = resolved_by; item.resolved_at = self._now()
                await self._conflict.update(item); return
        raise ValueError("Conflict not found")

    # ═══ Logs ═══

    async def list_logs(self, org_id: UUID, page: int = 1, per_page: int = 50) -> Tuple[List, int]:
        return await self._log.list(org_id, page, per_page)
