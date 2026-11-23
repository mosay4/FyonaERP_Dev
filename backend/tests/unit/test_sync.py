import pytest
from uuid import uuid4
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock
from app.domain.models.sync_models import SyncPushRequest, SyncPullRequest, SyncEntity
from app.domain.services.sync_service import SyncService
from app.domain.entities.sync_entities import EntityVersion


@pytest.fixture
def org_id(): return uuid4()
@pytest.fixture
def user_id(): return uuid4()

@pytest.fixture
def svc():
    batch_repo = AsyncMock()
    # Idempotency lookup returns "not found" by default so pushes can proceed.
    batch_repo.get_by_org_batch.return_value = None
    return SyncService(AsyncMock(), batch_repo, AsyncMock(), AsyncMock())


class TestSyncService:
    async def test_push_new_entity(self, svc, org_id, user_id):
        svc._ver.get.return_value = None
        data = SyncPushRequest(batch_id="b1", entities=[SyncEntity(entity_type="customer", entity_id=uuid4(), data={"name": "test"}, version=1)])
        r = await svc.push(org_id, user_id, data)
        assert r.pushed == 1
        svc._ver.upsert.assert_called_once()

    async def test_push_conflict(self, svc, org_id, user_id):
        existing = MagicMock(spec=EntityVersion)
        existing.version = 5
        svc._ver.get.return_value = existing
        eid = uuid4()
        data = SyncPushRequest(batch_id="b1", entities=[SyncEntity(entity_type="customer", entity_id=eid, data={"name": "old"}, version=1)])
        r = await svc.push(org_id, user_id, data)
        assert len(r.conflicts) == 1
        assert r.conflicts[0].server_version == 5

    async def test_personal_stale_update_converges(self, svc, org_id, user_id):
        """A queued personal UPDATE newer than the server row is applied
        instead of wedging forever."""
        from datetime import timedelta
        existing = MagicMock(spec=EntityVersion)
        existing.version = 3
        existing.operation_id = "crud_contrib_old"
        existing.last_modified_at = datetime.now(timezone.utc) - timedelta(hours=2)
        svc._ver.get.return_value = existing
        eid = uuid4()
        fresh = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
        data = SyncPushRequest(batch_id="b1", entities=[SyncEntity(
            entity_type="personal_savings_goal", entity_id=eid,
            data={"name": "G"}, version=1, deleted=False,
            client_updated_at=fresh)])
        r = await svc.push(org_id, user_id, data)
        assert len(r.conflicts) == 0
        assert r.pushed == 1

    async def test_personal_stale_update_superseded_drops(self, svc, org_id, user_id):
        """A queued personal UPDATE older than the server row is reported as
        superseded (server wins) so the client drops it instead of reverting
        newer balances backwards on every retry."""
        from datetime import timedelta
        existing = MagicMock(spec=EntityVersion)
        existing.version = 3
        existing.operation_id = "crud_contrib_new"
        existing.last_modified_at = datetime.now(timezone.utc)
        svc._ver.get.return_value = existing
        eid = uuid4()
        stale = (datetime.now(timezone.utc) - timedelta(days=3)).isoformat()
        data = SyncPushRequest(batch_id="b1", entities=[SyncEntity(
            entity_type="personal_bank_account", entity_id=eid,
            data={"balance": 1}, version=1, deleted=False,
            client_updated_at=stale)])
        r = await svc.push(org_id, user_id, data)
        assert len(r.conflicts) == 1
        assert r.conflicts[0].server_data["superseded"] is True
        assert r.pushed == 0

    async def test_personal_stale_delete_still_wins(self, svc, org_id, user_id):
        existing = MagicMock(spec=EntityVersion)
        existing.version = 4
        existing.operation_id = "crud_upd_old"
        svc._ver.get.return_value = existing
        eid = uuid4()
        data = SyncPushRequest(batch_id="b1", entities=[SyncEntity(
            entity_type="personal_transaction", entity_id=eid,
            data={}, version=1, deleted=True)])
        r = await svc.push(org_id, user_id, data)
        assert len(r.conflicts) == 0
        assert existing.is_deleted is True

    async def test_push_force_overwrites(self, svc, org_id, user_id):
        existing = MagicMock(spec=EntityVersion)
        existing.version = 5
        svc._ver.get.return_value = existing
        data = SyncPushRequest(batch_id="b1", entities=[SyncEntity(entity_type="customer", entity_id=uuid4(), data={"name": "new"}, version=1)], force=True)
        r = await svc.push(org_id, user_id, data)
        assert r.pushed == 1

    async def test_batch_idempotency_replay(self, svc, org_id, user_id):
        """Re-posting a completed batch is a safe no-op (idempotent retry)."""
        completed = MagicMock()
        completed.status = "completed"
        completed.success_count = 2
        svc._batch.get_by_org_batch.return_value = completed
        data = SyncPushRequest(batch_id="b1", entities=[
            SyncEntity(entity_type="customer", entity_id=uuid4(), data={"name": "x"}, version=1),
        ])
        r = await svc.push(org_id, user_id, data)
        assert r.success is True
        assert r.pushed == 2  # confirms it's the previous run, not a double-apply

    async def test_operation_id_idempotency(self, svc, org_id, user_id):
        existing = MagicMock(spec=EntityVersion)
        existing.version = 2
        existing.operation_id = "op-123"
        svc._ver.get.return_value = existing
        data = SyncPushRequest(batch_id="b2", entities=[
            SyncEntity(entity_type="customer", entity_id=uuid4(), data={"name": "dup"}, version=3, operation_id="op-123"),
        ])
        r = await svc.push(org_id, user_id, data)
        # Same operation_id already applied = no-op (idempotent), not a conflict,
        # and NOT re-applied (version record stays untouched).
        assert r.pushed == 1
        assert len(r.conflicts) == 0
        svc._ver.upsert.assert_not_awaited()

    async def test_pull(self, svc, org_id):
        v = MagicMock(spec=EntityVersion)
        v.entity_type = "customer"; v.entity_id = uuid4(); v.version = 1; v.checksum = "abc"
        v.is_deleted = False; v.last_modified_at = datetime.now(timezone.utc)
        svc._ver.list_since.return_value = [v]
        entities, total = await svc.pull(org_id, SyncPullRequest(last_sync_at=datetime(2020, 1, 1, tzinfo=timezone.utc)))
        assert total == 1

    async def test_health(self, svc):
        h = await svc.health()
        assert h.sync_api_version == "1.0"
        assert h.max_batch_size == 500

    async def test_status(self, svc, org_id):
        svc._conflict.count_unresolved.return_value = 0
        svc._batch.get_last.return_value = None
        s = await svc.status(org_id)
        assert s.sync_enabled is True

    async def test_list_conflicts(self, svc, org_id):
        svc._conflict.list.return_value = ([], 0)
        items, total = await svc.list_conflicts(org_id)
        assert total == 0

    async def test_logs(self, svc, org_id):
        svc._log.list.return_value = ([], 0)
        items, total = await svc.list_logs(org_id)
        assert total == 0
