"""Device sessions: hard cap (3 by default), kick, rename, primary order.

Same isolated SQLite harness as test_sessions.py (real routes).
"""
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import update

from app.core.config import settings
from app.domain.entities.auth_entities import UserSession
from app.core.database import get_db
from app.main import app

from tests.unit.test_sessions import (  # noqa: F401  (fixtures)
    PASSWORD,
    _dev_headers,
    _reset_rate_limit_buckets,
    client,
)


@pytest.fixture(autouse=True)
def _no_rate_limit(monkeypatch):
    """Rate limits are not under test here (and the in-memory fallback
    would leak across this module's many sign-ins)."""
    from app.core import rate_limiter

    async def _allow(self, *_a, **_k):
        return None

    monkeypatch.setattr(rate_limiter.RateLimiter, "check", _allow)


def _msg(resp):
    body = resp.json()
    return str(body.get("detail") or body.get("message") or "")


def _rows(resp):
    body = resp.json()
    return body.get("data", body) if isinstance(body, dict) else body


async def _login(client, model, fp=None, extra=None):
    headers = {**_dev_headers(model, "Android 14", fp=fp), **(extra or {})}
    return await client.post(
        "/auth/login",
        json={"email": client.email, "password": PASSWORD},
        headers=headers,
    )


async def _ok(client, model, fp=None, extra=None):
    r = await _login(client, model, fp=fp, extra=extra)
    assert r.status_code == 200, r.text
    data = _rows(r)
    return data["access_token"], data["refresh_token"]


async def _list(client, access, refresh):
    r = await client.get("/auth/sessions", headers={
        "Authorization": f"Bearer {access}", "X-Refresh-Token": refresh})
    assert r.status_code == 200, r.text
    return _rows(r)


def _auth(access, refresh):
    return {"Authorization": f"Bearer {access}", "X-Refresh-Token": refresh}


class TestSessionLimit:
    async def test_default_limit_is_three(self):
        assert settings.MAX_ACTIVE_SESSIONS == 3

    async def test_fourth_device_is_refused_with_arabic_message(self, client):
        a1, r1 = await _ok(client, "Galaxy S22", fp="fp-1")
        await _ok(client, "iPhone 15", fp="fp-2")
        await _ok(client, "Pixel 8", fp="fp-3")
        r = await _login(client, "Nokia X", fp="fp-4")
        assert r.status_code == 409, r.text
        assert "الحد الأقصى للأجهزة" in _msg(r)
        assert "3" in _msg(r)
        # Nothing was evicted: still exactly the three original devices.
        rows = await _list(client, a1, r1)
        assert len(rows) == 3
        assert {s["fingerprint"] for s in rows} == {"fp-1", "fp-2", "fp-3"}
        assert all(s["session_limit"] == 3 for s in rows)

    async def test_same_device_signing_in_again_keeps_its_slot(self, client):
        await _ok(client, "Galaxy S22", fp="fp-1")
        await _ok(client, "iPhone 15", fp="fp-2")
        a3, r3 = await _ok(client, "Pixel 8", fp="fp-3")
        # Device 2 signs in again (same fingerprint): reuses its row.
        a2, r2 = await _ok(client, "iPhone 15", fp="fp-2")
        rows = await _list(client, a2, r2)
        assert len(rows) == 3

    async def test_kick_frees_a_slot_and_kills_the_device(self, client):
        a1, r1 = await _ok(client, "Galaxy S22", fp="fp-1")
        a2, r2 = await _ok(client, "iPhone 15", fp="fp-2")
        await _ok(client, "Pixel 8", fp="fp-3")
        rows = await _list(client, a1, r1)
        victim = next(s for s in rows if s["fingerprint"] == "fp-2")
        r = await client.post("/auth/sessions/logout",
                              json={"session_id": victim["id"]},
                              headers=_auth(a1, r1))
        assert r.status_code == 200, r.text
        # The kicked device can no longer refresh: it is signed out.
        r = await client.post("/auth/refresh", json={"refresh_token": r2})
        assert r.status_code == 401
        # And the freed slot lets a new device in.
        await _ok(client, "Nokia X", fp="fp-4")
        rows = await _list(client, a1, r1)
        assert len(rows) == 3
        assert victim["id"] not in [s["id"] for s in rows]

    async def test_expired_sessions_do_not_count(self, client):
        await _ok(client, "Galaxy S22", fp="fp-1")
        await _ok(client, "iPhone 15", fp="fp-2")
        await _ok(client, "Pixel 8", fp="fp-3")
        gen = app.dependency_overrides[get_db]()
        db = await gen.__anext__()
        await db.execute(update(UserSession)
                         .where(UserSession.fingerprint == "fp-3")
                         .values(expires_at=datetime.now(timezone.utc) - timedelta(days=1)))
        await db.commit()
        await gen.aclose()
        a4, r4 = await _ok(client, "Nokia X", fp="fp-4")
        rows = await _list(client, a4, r4)
        assert {s["fingerprint"] for s in rows} == {"fp-1", "fp-2", "fp-4"}

    async def test_limit_is_configurable(self, client, monkeypatch):
        monkeypatch.setattr(settings, "MAX_ACTIVE_SESSIONS", 5)
        for i in range(5):
            await _ok(client, f"Phone {i}", fp=f"fp-{i}")
        r = await _login(client, "Phone 6", fp="fp-6")
        assert r.status_code == 409


class TestPrimaryAndRename:
    async def test_primary_listed_first_and_cannot_be_kicked(self, client):
        a1, r1 = await _ok(client, "Galaxy S22", fp="fp-1")
        a2, r2 = await _ok(client, "iPhone 15", fp="fp-2")
        a3, r3 = await _ok(client, "Pixel 8", fp="fp-3")
        rows = await _list(client, a3, r3)
        assert rows[0]["is_primary"] is True
        assert rows[0]["fingerprint"] == "fp-1"
        # Remaining devices oldest first.
        assert [s["fingerprint"] for s in rows] == ["fp-1", "fp-2", "fp-3"]
        r = await client.post("/auth/sessions/logout",
                              json={"session_id": rows[0]["id"]},
                              headers=_auth(a1, r1))
        assert r.status_code == 400
        assert "الرئيسي" in _msg(r)

    async def test_primary_gone_oldest_device_becomes_primary(self, client):
        a1, r1 = await _ok(client, "Galaxy S22", fp="fp-1")
        a2, r2 = await _ok(client, "iPhone 15", fp="fp-2")
        a3, r3 = await _ok(client, "Pixel 8", fp="fp-3")
        # The primary signs itself out.
        r = await client.post("/auth/logout", headers=_auth(a1, r1))
        assert r.status_code == 204
        rows = await _list(client, a3, r3)
        assert len(rows) == 2
        assert rows[0]["fingerprint"] == "fp-2" and rows[0]["is_primary"] is True
        assert sum(1 for s in rows if s["is_primary"]) == 1

    async def test_rename_rules(self, client):
        a1, r1 = await _ok(client, "Galaxy S22", fp="fp-1")
        a2, r2 = await _ok(client, "iPhone 15", fp="fp-2")
        rows = await _list(client, a1, r1)
        primary = next(s for s in rows if s["is_primary"])
        second = next(s for s in rows if not s["is_primary"])
        # A secondary renames itself.
        r = await client.put(f"/auth/sessions/{second['id']}/name",
                             json={"custom_name": "  هاتف   المحل "},
                             headers=_auth(a2, r2))
        assert r.status_code == 200, r.text
        # …but not another device.
        r = await client.put(f"/auth/sessions/{primary['id']}/name",
                             json={"custom_name": "x"}, headers=_auth(a2, r2))
        assert r.status_code == 403
        # The primary may rename any device.
        r = await client.put(f"/auth/sessions/{primary['id']}/name",
                             json={"custom_name": "جهازي الرئيسي"},
                             headers=_auth(a1, r1))
        assert r.status_code == 200
        rows = {s["id"]: s for s in await _list(client, a2, r2)}
        assert rows[second["id"]]["custom_name"] == "هاتف المحل"
        assert rows[primary["id"]]["custom_name"] == "جهازي الرئيسي"
        # Too long is refused; empty clears the name.
        r = await client.put(f"/auth/sessions/{second['id']}/name",
                             json={"custom_name": "x" * 61}, headers=_auth(a2, r2))
        assert r.status_code == 400
        r = await client.put(f"/auth/sessions/{second['id']}/name",
                             json={"custom_name": ""}, headers=_auth(a2, r2))
        assert r.status_code == 200
        rows = {s["id"]: s for s in await _list(client, a2, r2)}
        assert not rows[second["id"]]["custom_name"]

    async def test_app_version_and_platform_are_reported(self, client):
        a1, r1 = await _ok(client, "Galaxy S22", fp="fp-1",
                           extra={"X-App-Version": "2.4.1+77",
                                  "X-Device-Platform": "android"})
        rows = await _list(client, a1, r1)
        assert rows[0]["app_version"] == "2.4.1+77"
        assert rows[0]["platform"] == "android"
        # Refresh with a newer app keeps the row and updates the version.
        r = await client.post("/auth/refresh", json={"refresh_token": r1},
                              headers={"X-App-Version": "2.5.0",
                                       "X-Device-Platform": "android"})
        assert r.status_code == 200
        data = _rows(r)
        rows = await _list(client, data["access_token"], data["refresh_token"])
        assert len(rows) == 1 and rows[0]["app_version"] == "2.5.0"


def test_parse_app_agent():
    from app.domain.services.auth_service import parse_app_agent
    assert parse_app_agent("FyonaERP/1.2.3+4 (ios) Dart/3.5") == ("1.2.3+4", "ios")
    assert parse_app_agent("FyonaERP/1.0") == ("1.0", None)
    assert parse_app_agent("Dart/3.5 (dart:io)") == (None, None)
    assert parse_app_agent(None) == (None, None)
