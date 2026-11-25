"""Stage 6: for a local Personal user the old Personal stores are closed —
old builds are told to update, writes/reads after the baseline export are
refused with a code the app understands; workers and admin hold no data."""
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

from app.core import personal_local_guard as guard
from app.core import personal_local_mode as mode
from app.core.security import create_access_token


def _request(method, path, user=None, protocol=True):
    headers = {}
    if user is not None:
        headers["Authorization"] = "Bearer " + create_access_token(str(user), str(uuid4()), "personal")
    if protocol:
        headers[mode.PROTOCOL_HEADER] = str(mode.PROTOCOL)
    return SimpleNamespace(method=method, url=SimpleNamespace(path=path), headers=headers)


async def _through(request):
    nxt = AsyncMock(return_value="next")
    out = await guard.guard(request, nxt)
    return out, nxt


def _body(response):
    return json.loads(response.body)


@pytest.fixture
def local(monkeypatch):
    monkeypatch.setattr(mode, "ENABLED", True)
    frozen = AsyncMock(return_value=False)
    monkeypatch.setattr(guard, "_frozen", frozen)
    return frozen


@pytest.mark.asyncio
async def test_old_build_is_told_to_update(local):
    out, nxt = await _through(_request("POST", "/api/v1/personal/finance/transactions",
                                       uuid4(), protocol=False))
    assert out.status_code == 409 and _body(out)["code"] == "update_required"
    nxt.assert_not_called()
    out, _ = await _through(_request("POST", "/api/v1/sync/pull", uuid4(), protocol=False))
    assert _body(out)["code"] == "update_required"


@pytest.mark.asyncio
async def test_current_build_may_drain_until_the_export_exists(local):
    out, nxt = await _through(_request("POST", "/api/v1/sync/push", uuid4()))
    assert out == "next"
    local.return_value = True
    out, _ = await _through(_request("POST", "/api/v1/sync/push", uuid4()))
    assert out.status_code == 409 and _body(out)["code"] == "personal_local"
    out, _ = await _through(_request("PATCH", "/api/v1/personal/finance/accounts/x", uuid4()))
    assert out.status_code == 409 and _body(out)["code"] == "personal_local"
    out, _ = await _through(_request("GET", "/api/v1/personal/finance/accounts", uuid4()))
    assert out.status_code == 410 and _body(out)["code"] == "personal_local"
    out, _ = await _through(_request("POST", "/api/v1/sync/pull", uuid4()))
    assert out.status_code == 410


@pytest.mark.asyncio
async def test_exempt_and_unrelated_paths_pass(local):
    local.return_value = True
    for path in ("/api/v1/personal-local/export", "/api/v1/personal-relay/push",
                 "/api/v1/invoices", "/api/v1/auth/me"):
        out, nxt = await _through(_request("POST", path, uuid4(), protocol=False))
        assert out == "next", path
    # No login: the route's own auth answers.
    out, _ = await _through(_request("POST", "/api/v1/sync/push", None))
    assert out == "next"


@pytest.mark.asyncio
async def test_guard_off_when_mode_off(monkeypatch):
    monkeypatch.setattr(mode, "ENABLED", False)
    out, _ = await _through(_request("POST", "/api/v1/sync/push", uuid4(), protocol=False))
    assert out == "next"


def test_qa_default_and_overrides(monkeypatch):
    from app.core import qa_directory
    monkeypatch.delenv("FYONA_QA_LOCAL_PERSONAL", raising=False)
    monkeypatch.setenv("FYONA_QA_REMOTE", "1")
    assert mode._flag() is True
    monkeypatch.setenv("FYONA_QA_LOCAL_PERSONAL", "0")
    assert mode._flag() is False
    monkeypatch.delenv("FYONA_QA_LOCAL_PERSONAL")
    monkeypatch.setenv("FYONA_QA_REMOTE", "0")
    monkeypatch.setattr(qa_directory, "INVITES", frozenset())
    assert mode._flag() is False


@pytest.mark.asyncio
async def test_workers_skip_personal_alerts_for_local_users(monkeypatch):
    from app.workers import tasks

    monkeypatch.setattr(mode, "ENABLED", True)
    seen = []

    class Session:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

        async def execute(self, stmt, *a, **k):
            seen.append(str(stmt))
            r = MagicMock()
            r.scalars.return_value.all.return_value = []
            return r

        async def commit(self):
            pass

    monkeypatch.setattr(tasks, "async_session_factory", lambda: Session())
    await tasks._check_low_balance()
    await tasks._check_budget_alerts()
    assert not any("personal_" in s for s in seen), seen


@pytest.mark.asyncio
async def test_admin_personal_is_counts_only_and_data_routes_are_gone():
    from fastapi.routing import APIRoute
    from app.api.v1 import admin_personal

    out = await admin_personal.list_personal_users(_user_id="a", _perm=True)
    assert out.status_code == 410 and _body(out)["code"] == "personal_local"
    gone = [r for r in admin_personal.router.routes
            if isinstance(r, APIRoute) and "/users/" in r.path]
    assert len(gone) == 13
    for route in gone:
        reply = await route.endpoint(_user_id="a", _perm=True)
        assert reply.status_code == 410
    # Stats never touch a Personal table.
    statements = []

    class Db:
        async def execute(self, stmt, *a, **k):
            statements.append(str(stmt))
            r = MagicMock()
            r.scalar.return_value = 3
            return r

        async def connection(self):
            conn = AsyncMock()
            conn.scalar.return_value = False
            return conn

    stats = await admin_personal.get_personal_stats(_user_id="a", _perm=True, db=Db())
    data = stats["data"] if isinstance(stats, dict) else json.loads(stats.body)["data"]
    assert data["total_users"] == 3 and data["data_location"] == "devices"
    assert "total_balance" not in data
    assert not any("personal_" in s for s in statements)
