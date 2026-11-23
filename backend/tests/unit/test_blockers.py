"""Tests for the 3 production blockers:

Blocker 1 — Nginx /uploads/ auth bypass
Blocker 2 — Redis best-effort
Blocker 3 — Celery fanout idempotency
"""

import fnmatch
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine, async_sessionmaker

from app.core.database import Base, get_db
from app.core.security import create_access_token

import app.domain.entities.auth_entities  # noqa: F401
import app.domain.entities.admin_entities  # noqa: F401
import app.domain.entities.notification_entities  # noqa: F401


# ────────────────────────────────────────────────────────────────────
# Blocker 1 — Upload authorization tests
# ────────────────────────────────────────────────────────────────────

from app.api.v1.files import router as files_router
from app.api.v1 import files as files_mod


@pytest.fixture
def upload_app(tmp_path):
    app = FastAPI()
    app.include_router(files_router, prefix="/api/v1")
    files_mod.UPLOAD_ROOT = str(tmp_path)
    (tmp_path / "suggestion_images").mkdir()
    (tmp_path / "suggestion_images" / "testfile.jpg").write_bytes(b"\xff\xd8\xff")
    return app


def _mock_get_db_factory(mock_session):
    async def _dep():
        yield mock_session
    return _dep


_REAL_USER = uuid4()
_REAL_ADMIN = uuid4()
_REAL_SUGGESTION_OWNER = uuid4()
_REAL_SUGGESTION_STRANGER = uuid4()


@pytest.mark.asyncio
async def test_upload_unauthenticated_rejected(upload_app):
    transport = ASGITransport(app=upload_app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        resp = await c.get("/api/v1/uploads/suggestion_images/testfile.jpg")
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_upload_bad_token_rejected(upload_app):
    transport = ASGITransport(app=upload_app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        resp = await c.get(
            "/api/v1/uploads/suggestion_images/testfile.jpg",
            headers={"Authorization": "Bearer invalid-token"},
        )
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_upload_subscription_proof_non_admin_forbidden(upload_app):
    token = create_access_token(user_id=str(_REAL_USER), org_id="org-1", role="user")
    import app.api.v1.files as fmod
    proof_dir = Path(fmod.UPLOAD_ROOT) / "subscription_proofs"
    proof_dir.mkdir(exist_ok=True)
    (proof_dir / "proof.png").write_bytes(b"\x89PNG")

    mock_user = MagicMock()
    mock_user.is_platform_admin = False
    mock_session = AsyncMock()
    mock_result = MagicMock()
    mock_result.scalar_one_or_none.return_value = mock_user
    mock_session.execute.return_value = mock_result

    upload_app.dependency_overrides[get_db] = _mock_get_db_factory(mock_session)
    transport = ASGITransport(app=upload_app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        resp = await c.get(
            "/api/v1/uploads/subscription_proofs/proof.png",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 403


@pytest.mark.asyncio
async def test_upload_subscription_proof_admin_allowed(upload_app):
    token = create_access_token(user_id=str(_REAL_ADMIN), org_id="org-1", role="admin")
    import app.api.v1.files as fmod
    proof_dir = Path(fmod.UPLOAD_ROOT) / "subscription_proofs"
    proof_dir.mkdir(exist_ok=True)
    (proof_dir / "proof.png").write_bytes(b"\x89PNG")

    mock_user = MagicMock()
    mock_user.is_platform_admin = True
    mock_session = AsyncMock()
    mock_result = MagicMock()
    mock_result.scalar_one_or_none.return_value = mock_user
    mock_session.execute.return_value = mock_result

    upload_app.dependency_overrides[get_db] = _mock_get_db_factory(mock_session)
    transport = ASGITransport(app=upload_app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        resp = await c.get(
            "/api/v1/uploads/subscription_proofs/proof.png",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_upload_suggestion_owner_allowed(upload_app):
    token = create_access_token(user_id=str(_REAL_SUGGESTION_OWNER), org_id="org-1", role="user")

    mock_user = MagicMock()
    mock_user.is_platform_admin = False
    mock_suggestion = MagicMock()
    mock_suggestion.user_id = _REAL_SUGGESTION_OWNER

    mock_session = AsyncMock()
    mock_result_suggestion = MagicMock()
    mock_result_suggestion.scalar_one_or_none.return_value = mock_suggestion
    mock_result_user = MagicMock()
    mock_result_user.scalar_one_or_none.return_value = mock_user
    # Auth dependency (no session_id): (1) tokens_valid_after lookup,
    # (2) active-session count fallback.
    mock_result_tva = MagicMock()
    mock_result_tva.scalar_one_or_none.return_value = None
    mock_result_sessions = MagicMock()
    mock_result_sessions.scalar.return_value = 1
    mock_session.execute.side_effect = [
        mock_result_tva,
        mock_result_sessions,
        mock_result_suggestion,
        mock_result_user,
    ]

    upload_app.dependency_overrides[get_db] = _mock_get_db_factory(mock_session)
    transport = ASGITransport(app=upload_app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        resp = await c.get(
            "/api/v1/uploads/suggestion_images/testfile.jpg",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_upload_suggestion_stranger_forbidden(upload_app):
    token = create_access_token(user_id=str(_REAL_SUGGESTION_STRANGER), org_id="org-1", role="user")

    mock_user = MagicMock()
    mock_user.is_platform_admin = False
    mock_suggestion = MagicMock()
    mock_suggestion.user_id = _REAL_SUGGESTION_OWNER

    mock_session = AsyncMock()
    mock_result_suggestion = MagicMock()
    mock_result_suggestion.scalar_one_or_none.return_value = mock_suggestion
    mock_result_user = MagicMock()
    mock_result_user.scalar_one_or_none.return_value = mock_user
    # Same auth-dependency lookups as the owner test above.
    mock_result_tva = MagicMock()
    mock_result_tva.scalar_one_or_none.return_value = None
    mock_result_sessions = MagicMock()
    mock_result_sessions.scalar.return_value = 1
    mock_session.execute.side_effect = [
        mock_result_tva,
        mock_result_sessions,
        mock_result_suggestion,
        mock_result_user,
    ]

    upload_app.dependency_overrides[get_db] = _mock_get_db_factory(mock_session)
    transport = ASGITransport(app=upload_app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        resp = await c.get(
            "/api/v1/uploads/suggestion_images/testfile.jpg",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 403


@pytest.mark.asyncio
async def test_upload_path_traversal_rejected(upload_app):
    token = create_access_token(user_id=str(_REAL_USER), org_id="org-1", role="user")
    mock_session = AsyncMock()
    upload_app.dependency_overrides[get_db] = _mock_get_db_factory(mock_session)
    transport = ASGITransport(app=upload_app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        resp = await c.get(
            "/api/v1/uploads/suggestion_images/..%2F..%2Fetc%2Fpasswd",
            headers={"Authorization": f"Bearer {token}"},
        )
    assert resp.status_code == 400


# ────────────────────────────────────────────────────────────────────
# Blocker 1 — Nginx config verification
# ────────────────────────────────────────────────────────────────────

NGINX_CONF = Path(__file__).resolve().parents[2] / "nginx" / "aaPanel-reverse-proxy.conf"


def test_nginx_no_uploads_static_block():
    content = NGINX_CONF.read_text(encoding="utf-8")
    assert "location /uploads/" not in content


def test_nginx_metrics_still_restricted():
    content = NGINX_CONF.read_text(encoding="utf-8")
    assert "location /metrics" in content
    assert "deny all" in content


# ────────────────────────────────────────────────────────────────────
# Blocker 2 — Redis best-effort tests
# ────────────────────────────────────────────────────────────────────

from app.core.redis import cache_get, cache_set, cache_delete, cache_delete_pattern
from app.core.cache import tenant_cache_get, tenant_cache_set, tenant_cache_invalidate


class _AsyncFailingRedis:
    async def get(self, *a, **kw):
        raise ConnectionError("Redis is down")
    async def setex(self, *a, **kw):
        raise ConnectionError("Redis is down")
    async def delete(self, *a, **kw):
        raise ConnectionError("Redis is down")
    async def keys(self, *a, **kw):
        raise ConnectionError("Redis is down")


@pytest.fixture
def patch_redis_down(monkeypatch):
    async def _fail():
        return _AsyncFailingRedis()
    monkeypatch.setattr("app.core.redis.get_redis", _fail)


@pytest.mark.asyncio
async def test_cache_get_redis_down_returns_none(patch_redis_down):
    assert await cache_get("some:key") is None

@pytest.mark.asyncio
async def test_cache_set_redis_down_no_crash(patch_redis_down):
    await cache_set("some:key", "some:value", expire=60)

@pytest.mark.asyncio
async def test_cache_delete_redis_down_no_crash(patch_redis_down):
    await cache_delete("some:key")

@pytest.mark.asyncio
async def test_cache_delete_pattern_redis_down_no_crash(patch_redis_down):
    await cache_delete_pattern("cache:*")

@pytest.mark.asyncio
async def test_tenant_cache_get_redis_down_returns_none(patch_redis_down):
    assert await tenant_cache_get("org-123", "kpi") is None

@pytest.mark.asyncio
async def test_tenant_cache_set_redis_down_no_crash(patch_redis_down):
    await tenant_cache_set("org-123", "kpi", {"value": 42}, ttl=60)

@pytest.mark.asyncio
async def test_tenant_cache_invalidate_redis_down_no_crash(patch_redis_down):
    await tenant_cache_invalidate("org-123", "kpi")


class _AsyncWorkingRedis:
    def __init__(self):
        self.store = {}
    async def get(self, key):
        return self.store.get(key)
    async def setex(self, key, expire, value):
        self.store[key] = value
    async def delete(self, *keys):
        for k in keys:
            self.store.pop(k, None)
    async def keys(self, pattern):
        return [k for k in self.store if fnmatch.fnmatch(k, pattern)]


@pytest.fixture
def patch_redis_up(monkeypatch):
    fake = _AsyncWorkingRedis()
    async def _ok():
        return fake
    monkeypatch.setattr("app.core.redis.get_redis", _ok)
    return fake


@pytest.mark.asyncio
async def test_cache_get_hit(patch_redis_up):
    patch_redis_up.store["test:key"] = "hello"
    assert await cache_get("test:key") == "hello"

@pytest.mark.asyncio
async def test_cache_get_miss(patch_redis_up):
    assert await cache_get("nonexistent:key") is None

@pytest.mark.asyncio
async def test_cache_set_and_get(patch_redis_up):
    await cache_set("k", "v", expire=300)
    assert await cache_get("k") == "v"

@pytest.mark.asyncio
async def test_tenant_cache_set_and_get(patch_redis_up):
    await tenant_cache_set("org-1", "kpi", {"revenue": 1000}, ttl=60)
    assert await tenant_cache_get("org-1", "kpi") == {"revenue": 1000}

@pytest.mark.asyncio
async def test_tenant_cache_isolation(patch_redis_up):
    await tenant_cache_set("org-A", "kpi", {"secret": "A"}, ttl=60)
    await tenant_cache_set("org-B", "kpi", {"secret": "B"}, ttl=60)
    assert (await tenant_cache_get("org-A", "kpi"))["secret"] == "A"
    assert (await tenant_cache_get("org-B", "kpi"))["secret"] == "B"

@pytest.mark.asyncio
async def test_tenant_cache_invalidate_removes_keys(patch_redis_up):
    await tenant_cache_set("org-1", "kpi", {"a": 1}, ttl=60)
    await tenant_cache_set("org-1", "kpi", {"a": 2}, ttl=60, extra="p2")
    await tenant_cache_invalidate("org-1", "kpi")
    assert await tenant_cache_get("org-1", "kpi") is None


# ────────────────────────────────────────────────────────────────────
# Blocker 3 — Celery fanout idempotency tests
# ────────────────────────────────────────────────────────────────────

from app.domain.entities.auth_entities import Organization
from app.domain.entities.admin_entities import PlatformNotification
from app.domain.entities.notification_entities import AppNotification


class _AsyncSessionCM:
    def __init__(self, session):
        self._session = session
    async def __aenter__(self):
        return self._session
    async def __aexit__(self, *args):
        pass


class _FakeSessionFactory:
    def __init__(self, session):
        self._session = session
    def __call__(self):
        return _AsyncSessionCM(self._session)


@pytest.fixture
async def async_engine_and_factory():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    factory = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    yield engine, factory
    await engine.dispose()


@pytest.mark.asyncio
async def test_fanout_first_execution_creates_notifications(monkeypatch, async_engine_and_factory):
    """Scenario 1 — First execution creates AppNotification with source_notif_id."""
    from app.workers.tasks import _fanout_platform_notification

    engine, factory = async_engine_and_factory
    org_id = uuid4()
    notif_id = uuid4()

    async with factory() as s:
        s.add(Organization(
            id=org_id, name="Org1", slug=f"org1-{org_id.hex[:8]}",
            subscription_status="active", is_active=True,
        ))
        s.add(PlatformNotification(id=notif_id, title="Alert One", message="Hello", type="info"))
        await s.commit()

    session = await factory().__aenter__()
    monkeypatch.setattr("app.workers.tasks.async_session_factory", _FakeSessionFactory(session))
    monkeypatch.setattr("app.workers.tasks.email_service.send_email", AsyncMock(return_value=True))

    result = await _fanout_platform_notification(str(notif_id))
    assert result["status"] == "completed"
    assert result["notifications_dispatched"] == 1
    assert result["skipped_duplicate"] == 0

    async with factory() as check:
        row = (await check.execute(
            select(AppNotification).where(
                AppNotification.organization_id == org_id,
                AppNotification.source_notif_id == notif_id,
            )
        )).scalars().first()
        assert row is not None
        assert row.title == "Alert One"


@pytest.mark.asyncio
async def test_fanout_same_notif_id_skips_on_retry(monkeypatch, async_engine_and_factory):
    """Scenario 3 — Same notif_id retried is idempotent (dedup by source_notif_id)."""
    from app.workers.tasks import _fanout_platform_notification

    engine, factory = async_engine_and_factory
    org_id = uuid4()
    notif_id = uuid4()

    async with factory() as s:
        s.add(Organization(
            id=org_id, name="Org1", slug=f"org1-{org_id.hex[:8]}",
            subscription_status="active", is_active=True,
        ))
        s.add(PlatformNotification(id=notif_id, title="Alert Two", message="Hello", type="info"))
        s.add(AppNotification(
            organization_id=org_id, user_id=None, type="info",
            source_notif_id=notif_id,
            title="Alert Two", message="Hello", action="open_screen",
            action_payload="notifications",
        ))
        await s.commit()

    session = await factory().__aenter__()
    monkeypatch.setattr("app.workers.tasks.async_session_factory", _FakeSessionFactory(session))
    monkeypatch.setattr("app.workers.tasks.email_service.send_email", AsyncMock(return_value=True))

    result = await _fanout_platform_notification(str(notif_id))
    assert result["status"] == "completed"
    assert result["skipped_duplicate"] == 1
    assert result["notifications_dispatched"] == 0

    async with factory() as check:
        count = (await check.execute(
            select(func.count(AppNotification.id)).where(
                AppNotification.organization_id == org_id,
                AppNotification.source_notif_id == notif_id,
            )
        )).scalar()
        assert count == 1


@pytest.mark.asyncio
async def test_fanout_two_notifications_same_title_type_both_created(monkeypatch, async_engine_and_factory):
    """Scenario 2 — Two legitimate PlatformNotifications with the same title+type
    within 24h MUST both produce AppNotifications (idempotency key is notif_id,
    NOT title+type)."""
    from app.workers.tasks import _fanout_platform_notification

    engine, factory = async_engine_and_factory
    org_id = uuid4()
    notif_a_id = uuid4()
    notif_b_id = uuid4()

    async with factory() as s:
        s.add(Organization(
            id=org_id, name="Org1", slug=f"org1-{org_id.hex[:8]}",
            subscription_status="active", is_active=True,
        ))
        s.add(PlatformNotification(id=notif_a_id, title="Maintenance", message="A", type="info"))
        s.add(PlatformNotification(id=notif_b_id, title="Maintenance", message="B", type="info"))
        await s.commit()

    session = await factory().__aenter__()
    monkeypatch.setattr("app.workers.tasks.async_session_factory", _FakeSessionFactory(session))
    monkeypatch.setattr("app.workers.tasks.email_service.send_email", AsyncMock(return_value=True))

    r1 = await _fanout_platform_notification(str(notif_a_id))
    assert r1["notifications_dispatched"] == 1
    assert r1["skipped_duplicate"] == 0

    r2 = await _fanout_platform_notification(str(notif_b_id))
    assert r2["notifications_dispatched"] == 1
    assert r2["skipped_duplicate"] == 0

    async with factory() as check:
        rows = (await check.execute(
            select(AppNotification).where(AppNotification.organization_id == org_id)
        )).scalars().all()
        assert len(rows) == 2
        source_ids = {r.source_notif_id for r in rows}
        assert source_ids == {notif_a_id, notif_b_id}


@pytest.mark.asyncio
async def test_fanout_multiple_orgs_idempotent(monkeypatch, async_engine_and_factory):
    """Scenario 1+3 combined — Fanout to multiple orgs, then retry skips all."""
    from app.workers.tasks import _fanout_platform_notification

    engine, factory = async_engine_and_factory
    org1_id = uuid4()
    org2_id = uuid4()
    notif_id = uuid4()

    async with factory() as s:
        s.add(Organization(
            id=org1_id, name="Org1", slug=f"org1-{org1_id.hex[:8]}",
            subscription_status="active", is_active=True,
        ))
        s.add(Organization(
            id=org2_id, name="Org2", slug=f"org2-{org2_id.hex[:8]}",
            subscription_status="active", is_active=True,
        ))
        s.add(PlatformNotification(id=notif_id, title="Multi Alert", message="Hi", type="info"))
        await s.commit()

    session = await factory().__aenter__()
    monkeypatch.setattr("app.workers.tasks.async_session_factory", _FakeSessionFactory(session))
    monkeypatch.setattr("app.workers.tasks.email_service.send_email", AsyncMock(return_value=True))

    r1 = await _fanout_platform_notification(str(notif_id))
    assert r1["notifications_dispatched"] == 2
    assert r1["skipped_duplicate"] == 0

    r2 = await _fanout_platform_notification(str(notif_id))
    assert r2["notifications_dispatched"] == 0
    assert r2["skipped_duplicate"] == 2

    async with factory() as check:
        c1 = (await check.execute(
            select(func.count(AppNotification.id)).where(
                AppNotification.organization_id == org1_id,
                AppNotification.source_notif_id == notif_id,
            )
        )).scalar()
        c2 = (await check.execute(
            select(func.count(AppNotification.id)).where(
                AppNotification.organization_id == org2_id,
                AppNotification.source_notif_id == notif_id,
            )
        )).scalar()
        assert c1 == 1
        assert c2 == 1


@pytest.mark.asyncio
async def test_fanout_concurrent_execution_no_duplicate(monkeypatch, async_engine_and_factory):
    """Scenario 4 — Two workers fan out the same notif concurrently.
    The UNIQUE partial index on (organization_id, source_notif_id) ensures
    no duplicate AppNotification is created."""
    from app.workers.tasks import _fanout_platform_notification

    engine, factory = async_engine_and_factory
    org_id = uuid4()
    notif_id = uuid4()

    async with factory() as s:
        s.add(Organization(
            id=org_id, name="Org1", slug=f"org1-{org_id.hex[:8]}",
            subscription_status="active", is_active=True,
        ))
        s.add(PlatformNotification(id=notif_id, title="Concurrent", message="C", type="info"))
        await s.commit()

    session_a = await factory().__aenter__()
    session_b = await factory().__aenter__()

    call_count = 0
    def _factory_switch():
        nonlocal call_count
        call_count += 1
        return _AsyncSessionCM(session_a if call_count % 2 == 1 else session_b)

    monkeypatch.setattr("app.workers.tasks.async_session_factory", _factory_switch)
    monkeypatch.setattr("app.workers.tasks.email_service.send_email", AsyncMock(return_value=True))

    r1 = await _fanout_platform_notification(str(notif_id))
    r2 = await _fanout_platform_notification(str(notif_id))

    total_dispatched = r1["notifications_dispatched"] + r2["notifications_dispatched"]
    total_skipped = r1["skipped_duplicate"] + r2["skipped_duplicate"]
    assert total_dispatched + total_skipped == 2

    async with factory() as check:
        count = (await check.execute(
            select(func.count(AppNotification.id)).where(
                AppNotification.organization_id == org_id,
                AppNotification.source_notif_id == notif_id,
            )
        )).scalar()
        assert count == 1

    await session_a.close()
    await session_b.close()
