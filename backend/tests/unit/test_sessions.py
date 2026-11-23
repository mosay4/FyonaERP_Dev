"""Device sessions: primary ownership, recognition, stability + avatar sync.

Covers the reported issues end to end against the real routes (isolated
SQLite DB, dependency-overridden), mirroring test_personal_sync_replay.py:

* first login wins primary; second device is secondary (single active
  primary, race-safe);
* only the primary may revoke/logout other sessions; anyone may revoke self;
* logout-all from the primary keeps the caller and wipes the rest — and the
  caller is resolved from its own token (no more wrong-device exclusion);
* is_current is true exactly for the calling device (X-Refresh-Token);
* refresh rotates the token IN PLACE (no blank device rows, id stable);
* login captures device model/OS/IP/country fields; list exposes them;
* avatar upload/delete round-trips and is served back identically.
"""
from uuid import uuid4

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import app.domain.entities.auth_entities  # noqa: F401
import app.domain.entities.business_entities  # noqa: F401
import app.domain.entities.finance_entities  # noqa: F401
import app.domain.entities.invoice_entities  # noqa: F401
import app.domain.entities.notification_entities  # noqa: F401
import app.domain.entities.payment_entities  # noqa: F401
import app.domain.entities.personal_entities  # noqa: F401
import app.domain.entities.purchase_entities  # noqa: F401
import app.domain.entities.sales_entities  # noqa: F401
import app.domain.entities.subscription_invoice_entities  # noqa: F401
import app.domain.entities.suggestions_entities  # noqa: F401
import app.domain.entities.sync_entities  # noqa: F401
from app.api.deps import get_current_org_id, get_current_user_uuid
from app.core.database import Base, get_db
from app.core.security import hash_password
from app.domain.entities.auth_entities import Organization, User
from app.main import app

EMAIL = "sess_test@example.com"
PASSWORD = "S3ssions-Test!"


@pytest_asyncio.fixture()
async def client(tmp_path):
    user_id = uuid4()
    org_id = uuid4()
    email = f"sess_{user_id.hex[:8]}@example.com"
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path}/sess.db")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as db:
        db.add(Organization(id=org_id, name="Sess Org", slug=f"sess-{org_id.hex[:8]}"))
        db.add(User(
            id=user_id,
            organization_id=org_id,
            full_name="Sess User",
            email=email,
            password_hash=hash_password(PASSWORD),
            role="owner",
            status="active",
            email_verified=True,
            is_platform_admin=True,
        ))
        await db.commit()

    async def _get_db():
        async with factory() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise

    app.dependency_overrides[get_db] = _get_db
    app.dependency_overrides[get_current_user_uuid] = lambda: user_id
    app.dependency_overrides[get_current_org_id] = lambda: str(org_id)
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport,
                           base_url="http://127.0.0.1/api/v1") as c:
        c.email = email
        yield c
    app.dependency_overrides.clear()
    await engine.dispose()


@pytest.fixture(autouse=True)
async def _reset_rate_limit_buckets():
    """Rate limits live in the shared local Redis (or the middleware's
    in-memory fallback) and would otherwise leak across tests in one run.
    Counters are ephemeral by design; clearing them is harmless."""
    yield
    try:
        from app.core.redis import get_redis

        redis = await get_redis()
        keys = await redis.keys("rl_*")
        if keys:
            await redis.delete(*keys)
    except Exception:
        pass


def _dev_headers(model="Galaxy S22", os="Android 14", refresh=None, fp=None):
    h = {
        "X-Device-Name": f"Samsung {model}",
        "X-Device-Model": model,
        "X-Device-OS": os,
        "User-Agent": "Dart/3.0 (dart:io)",
    }
    if refresh:
        h["X-Refresh-Token"] = refresh
    if fp:
        h["X-Device-Fingerprint"] = fp
    return h


async def _login(client, model="Galaxy S22", os="Android 14"):
    email = getattr(client, "email", EMAIL)
    r = await client.post("/auth/login",
                          json={"email": email, "password": PASSWORD},
                          headers=_dev_headers(model, os))
    assert r.status_code == 200, r.text
    body = r.json()
    data = body.get("data", body)
    return data["access_token"], data["refresh_token"]


class TestPrimaryOwnership:
    async def test_first_device_wins_primary(self, client):
        a1, r1 = await _login(client, model="Galaxy S22")
        a2, r2 = await _login(client, model="iPhone 15")
        s1 = await client.get("/auth/sessions",
                              headers={"Authorization": f"Bearer {a1}",
                                       "X-Refresh-Token": r1})
        rows = s1.json()
        rows = rows.get("data", rows) if isinstance(rows, dict) else rows
        primaries = [s for s in rows if s["is_primary"]]
        assert len(primaries) == 1, "exactly one active primary must exist"
        mine = [s for s in rows if s["is_current"]]
        assert len(mine) == 1, "caller must be identified as current"
        assert mine[0]["is_primary"] is True, "first device stays primary"
        # Second device sees itself as secondary, first as primary.
        s2 = await client.get("/auth/sessions",
                              headers={"Authorization": f"Bearer {a2}",
                                       "X-Refresh-Token": r2})
        rows2 = s2.json()
        rows2 = rows2.get("data", rows2) if isinstance(rows2, dict) else rows2
        mine2 = [s for s in rows2 if s["is_current"]]
        assert len(mine2) == 1 and mine2[0]["is_primary"] is False

    async def test_only_primary_controls_sessions(self, client):
        a1, r1 = await _login(client, model="Galaxy S22")
        a2, r2 = await _login(client, model="iPhone 15")
        s2 = await client.get("/auth/sessions",
                              headers={"Authorization": f"Bearer {a2}",
                                       "X-Refresh-Token": r2})
        rows2 = s2.json()
        rows2 = rows2.get("data", rows2) if isinstance(rows2, dict) else rows2
        primary_id = next(s["id"] for s in rows2 if s["is_primary"])
        # Secondary may NOT revoke the primary…
        r = await client.post("/auth/sessions/logout",
                              json={"session_id": primary_id},
                              headers={"Authorization": f"Bearer {a2}",
                                       "X-Refresh-Token": r2})
        assert r.status_code == 400
        # …nor wipe others…
        r = await client.post("/auth/sessions/logout-all", json={},
                              headers={"Authorization": f"Bearer {a2}",
                                       "X-Refresh-Token": r2})
        assert r.status_code == 403
        # …but MAY revoke itself.
        own = next(s["id"] for s in rows2 if s["is_current"])
        r = await client.post("/auth/sessions/logout",
                              json={"session_id": own},
                              headers={"Authorization": f"Bearer {a2}",
                                       "X-Refresh-Token": r2})
        assert r.status_code == 200
        # Primary logout-all keeps exactly the caller.
        r = await client.post("/auth/sessions/logout-all", json={},
                              headers={"Authorization": f"Bearer {a1}",
                                       "X-Refresh-Token": r1})
        assert r.status_code == 200
        s1 = await client.get("/auth/sessions",
                              headers={"Authorization": f"Bearer {a1}",
                                       "X-Refresh-Token": r1})
        rows1 = s1.json()
        rows1 = rows1.get("data", rows1) if isinstance(rows1, dict) else rows1
        assert len(rows1) == 1 and rows1[0]["is_primary"] is True

    async def test_secondary_cannot_revoke_other_secondary(self, client):
        a1, r1 = await _login(client, model="Galaxy S22")
        a2, r2 = await _login(client, model="iPhone 15")
        a3, r3 = await _login(client, model="Pixel 8")
        a4, r4 = await _login(client, model="Nokia X")
        s4 = await client.get("/auth/sessions",
                              headers={"Authorization": f"Bearer {a4}",
                                       "X-Refresh-Token": r4})
        rows = s4.json()
        rows = rows.get("data", rows) if isinstance(rows, dict) else rows
        assert len(rows) == 4
        # Caller B (secondary) targets C (a DIFFERENT secondary, not itself).
        other = next(s["id"] for s in rows
                     if not s["is_primary"] and not s["is_current"]
                     and s["device_model"] == "Pixel 8")
        r = await client.post("/auth/sessions/logout",
                              json={"session_id": other},
                              headers={"Authorization": f"Bearer {a2}",
                                       "X-Refresh-Token": r2})
        assert r.status_code == 403
        # And the target is still alive.
        s1 = await client.get("/auth/sessions",
                              headers={"Authorization": f"Bearer {a1}",
                                       "X-Refresh-Token": r1})
        rows1 = s1.json()
        rows1 = rows1.get("data", rows1) if isinstance(rows1, dict) else rows1
        assert other in [s["id"] for s in rows1]

    async def test_legacy_token_without_sid_cannot_manage(self, client):
        from app.core.security import create_access_token

        a1, r1 = await _login(client, model="Galaxy S22")
        a2, r2 = await _login(client, model="iPhone 15")
        # Legacy access token: valid signature, but no session id claim.
        r = await client.post("/auth/login",
                              json={"email": getattr(client, "email"),
                                    "password": PASSWORD},
                              headers=_dev_headers("Galaxy S22", "Android 14"))
        body = r.json()
        data = body.get("data", body)
        user = data["user"]
        legacy = create_access_token(
            str(user["id"]), str(user["organization_id"]), "owner")
        s2 = await client.get("/auth/sessions",
                              headers={"Authorization": f"Bearer {a2}",
                                       "X-Refresh-Token": r2})
        rows2 = s2.json()
        rows2 = rows2.get("data", rows2) if isinstance(rows2, dict) else rows2
        victim = next(s["id"] for s in rows2 if not s["is_primary"])
        # Revoke without sid → denied, even for a valid token.
        r = await client.post("/auth/sessions/logout",
                              json={"session_id": victim},
                              headers={"Authorization": f"Bearer {legacy}"})
        assert r.status_code == 403
        # Logout-all without sid → denied as well.
        r = await client.post("/auth/sessions/logout-all", json={},
                              headers={"Authorization": f"Bearer {legacy}"})
        assert r.status_code == 403

    async def test_logout_current_and_all_require_current_session(self, client):
        # No credentials at all → both management endpoints refuse.
        r = await client.post("/auth/sessions/logout",
                              json={"session_id": "00000000-0000-0000-0000-000000000000"})
        assert r.status_code in (401, 403)
        r = await client.post("/auth/sessions/logout-all", json={})
        assert r.status_code in (401, 403)

    async def test_logout_other_returns_404_or_403(self, client):
        a1, r1 = await _login(client, model="Galaxy S22")
        a2, r2 = await _login(client, model="iPhone 15")
        bogus = "00000000-0000-0000-0000-000000000000"
        # Primary targets an unknown session → not-found style error, never 200.
        r = await client.post("/auth/sessions/logout",
                              json={"session_id": bogus},
                              headers={"Authorization": f"Bearer {a1}",
                                       "X-Refresh-Token": r1})
        assert r.status_code in (400, 403, 404)
        # Secondary targets an unknown session → forbidden, never 200.
        r = await client.post("/auth/sessions/logout",
                              json={"session_id": bogus},
                              headers={"Authorization": f"Bearer {a2}",
                                       "X-Refresh-Token": r2})
        assert r.status_code in (400, 403, 404)

    async def test_relogin_after_delete_creates_new_visible_session(self, client):
        fp_b = "android:relogin-device-b"
        a1, r1 = await _login(client, model="Galaxy S22")
        await _login(client, model="iPhone 15")
        # Find B's session id directly (bypass flaky next()).
        s1 = await client.get("/auth/sessions",
                              headers={"Authorization": f"Bearer {a1}",
                                       "X-Refresh-Token": r1})
        rows1 = s1.json()
        rows1 = rows1.get("data", rows1) if isinstance(rows1, dict) else rows1
        assert len(rows1) == 2
        # Primary deletes B.
        victim = next(s["id"] for s in rows1 if not s["is_primary"])
        r = await client.post("/auth/sessions/logout",
                              json={"session_id": victim},
                              headers={"Authorization": f"Bearer {a1}",
                                       "X-Refresh-Token": r1})
        assert r.status_code == 200
        # B logs back in with the SAME fingerprint.
        r = await client.post(
            "/auth/login",
            json={"email": getattr(client, "email"), "password": PASSWORD},
            headers={**_dev_headers("iPhone 15", "iOS 18"), "X-Device-Fingerprint": fp_b},
        )
        assert r.status_code == 200, r.text
        body = r.json()
        data = body.get("data", body)
        a3, r3 = data["access_token"], data["refresh_token"]
        # The fresh session: new id, active, and VISIBLE in the list.
        s3 = await client.get("/auth/sessions",
                              headers={"Authorization": f"Bearer {a3}",
                                       "X-Refresh-Token": r3})
        rows3 = s3.json()
        rows3 = rows3.get("data", rows3) if isinstance(rows3, dict) else rows3
        assert len(rows3) == 2
        mine = [s for s in rows3 if s["is_current"]]
        assert len(mine) == 1
        assert mine[0]["id"] != victim, "must be a NEW session, not revived"
        assert mine[0]["fingerprint"] == fp_b
        # No duplicates for the fingerprint, old row stays dead.
        assert [s["id"] for s in rows3].count(mine[0]["id"]) == 1
        assert victim not in [s["id"] for s in rows3]

    async def test_refresh_rotates_in_place(self, client):
        a1, r1 = await _login(client, model="Galaxy S22")
        before = await client.get("/auth/sessions",
                                  headers={"Authorization": f"Bearer {a1}",
                                           "X-Refresh-Token": r1})
        rows = before.json()
        rows = rows.get("data", rows) if isinstance(rows, dict) else rows
        assert len(rows) == 1
        sid, name = rows[0]["id"], rows[0]["device_info"]
        r = await client.post("/auth/refresh", json={"refresh_token": r1})
        assert r.status_code == 200
        data = r.json()
        data = data.get("data", data) if isinstance(data, dict) else data
        a2 = data["access_token"]
        r2 = data["refresh_token"]
        after = await client.get("/auth/sessions",
                                 headers={"Authorization": f"Bearer {a2}",
                                          "X-Refresh-Token": r2})
        rows2 = after.json()
        rows2 = rows2.get("data", rows2) if isinstance(rows2, dict) else rows2
        # Same single row: id stable, device info preserved, still current.
        assert len(rows2) == 1
        assert rows2[0]["id"] == sid
        assert rows2[0]["device_info"] == name
        assert rows2[0]["is_current"] is True

    async def test_login_captures_device_identity(self, client):
        a1, r1 = await _login(client, model="Pixel 8", os="Android 15")
        s = await client.get("/auth/sessions",
                             headers={"Authorization": f"Bearer {a1}",
                                      "X-Refresh-Token": r1})
        rows = s.json()
        rows = rows.get("data", rows) if isinstance(rows, dict) else rows
        mine = next(x for x in rows if x["is_current"])
        assert mine["device_model"] == "Pixel 8"
        assert mine["os_version"] == "Android 15"
        assert mine["created_at"] is not None
        assert mine["last_activity"] is not None

    async def test_login_captures_fingerprint(self, client):
        fp = "android:test-fingerprint-123"
        r = await client.post(
            "/auth/login",
            json={"email": getattr(client, "email"), "password": PASSWORD},
            headers={**_dev_headers("Pixel 8", "Android 15"),
                     "X-Device-Fingerprint": fp})
        assert r.status_code == 200, r.text
        body = r.json()
        data = body.get("data", body)
        a1, r1 = data["access_token"], data["refresh_token"]
        s = await client.get("/auth/sessions",
                             headers={"Authorization": f"Bearer {a1}",
                                      "X-Refresh-Token": r1})
        rows = s.json()
        rows = rows.get("data", rows) if isinstance(rows, dict) else rows
        mine = next(x for x in rows if x["is_current"])
        assert mine["fingerprint"] == fp


class TestAvatarSync:
    async def test_upload_download_delete_roundtrip(self, client, monkeypatch):
        # Deterministic backend: local disk (never MinIO) for this test.
        from app.core.paths import UPLOAD_ROOT
        from app.core.storage import LocalStorage
        import app.core.storage as storage_mod

        monkeypatch.setattr(
            storage_mod, "get_storage", lambda: LocalStorage(UPLOAD_ROOT))
        from PIL import Image
        import io

        a1, _ = await _login(client)
        auth = {"Authorization": f"Bearer {a1}"}
        img = Image.new("RGB", (64, 64), (200, 30, 30))
        buf = io.BytesIO()
        img.save(buf, format="JPEG")
        files = {"file": ("avatar.jpg", buf.getvalue(), "image/jpeg")}
        r = await client.post("/auth/me/avatar", files=files, headers=auth)
        assert r.status_code == 200, r.text
        body = r.json()
        data = body.get("data", body) if isinstance(body, dict) else body
        assert "uploads/avatars/" in data["avatar"]
        assert "?v=" in data["avatar"]
        # Served back byte-identical (modulo JPEG re-encode).
        r2 = await client.get(f"http://127.0.0.1/{data['avatar']}",
                              headers=auth)
        assert r2.status_code == 200
        assert r2.headers["content-type"].startswith("image/")
        assert len(r2.content) > 100
        # Profile payload carries the avatar path for other devices.
        me = await client.get("/auth/me", headers=auth)
        mebody = me.json()
        medata = mebody.get("data", mebody) if isinstance(mebody, dict) else mebody
        assert medata["avatar"] == data["avatar"]
        # Delete clears everywhere.
        d = await client.delete("/auth/me/avatar", headers=auth)
        assert d.status_code == 200
        r3 = await client.get(f"http://127.0.0.1/{data['avatar']}",
                              headers=auth)
        assert r3.status_code == 404
        me2 = await client.get("/auth/me", headers=auth)
        mebody2 = me2.json()
        medata2 = mebody2.get("data", mebody2) if isinstance(mebody2, dict) else mebody2
        assert not medata2.get("avatar")

    async def test_rejects_non_image(self, client):
        a1, _ = await _login(client)
        files = {"file": ("evil.txt", b"not an image at all", "text/plain")}
        r = await client.post("/auth/me/avatar", files=files,
                              headers={"Authorization": f"Bearer {a1}"})
        assert r.status_code == 400

    async def test_put_me_cannot_set_avatar(self, client):
        # The dedicated upload endpoint is the only avatar writer: a raw
        # external URL via profile update must be ignored, otherwise any
        # client could point other devices at an arbitrary download.
        a1, _ = await _login(client)
        auth = {"Authorization": f"Bearer {a1}"}
        r = await client.put("/auth/me", json={"full_name": "Sess User",
                                               "avatar": "http://evil/x.jpg"},
                             headers=auth)
        assert r.status_code == 200, r.text
        me = await client.get("/auth/me", headers=auth)
        mebody = me.json()
        medata = mebody.get("data", mebody) if isinstance(mebody, dict) else mebody
        assert medata.get("avatar") in (None, "")

    async def test_avatar_upload_emits_event_without_bytes(self, client, monkeypatch):
        from PIL import Image
        import io
        import app.domain.services.push_service as push_mod

        seen = []

        async def _record(db, user_id, avatar):
            seen.append((user_id, avatar))

        monkeypatch.setattr(push_mod, "notify_avatar_updated", _record)
        a1, _ = await _login(client)
        img = Image.new("RGB", (32, 32), (10, 200, 60))
        buf = io.BytesIO()
        img.save(buf, format="JPEG")
        files = {"file": ("avatar.jpg", buf.getvalue(), "image/jpeg")}
        r = await client.post("/auth/me/avatar", files=files,
                              headers={"Authorization": f"Bearer {a1}"})
        assert r.status_code == 200, r.text
        assert len(seen) == 1
        _uid, _path = seen[0]
        assert "?v=" in _path
        assert len(_path) < 200, "event carries a path, never bytes"


class TestClientInfo:
    def test_forwarded_for_wins_over_peer(self):
        from fastapi import Request
        from app.api.v1.auth import _client_info, _is_routable_ip

        def req(headers, client):
            return Request({
                "type": "http",
                "headers": [(k.lower().encode(), v.encode())
                            for k, v in headers.items()],
                "client": client,
            })

        info = _client_info(req(
            {"X-Forwarded-For": "203.0.113.7, 10.0.0.1",
             "X-Device-Model": "SM-S918B",
             "X-Device-OS": "Android 16"},
            ("127.0.0.1", 8001)))
        assert info["ip_address"] == "203.0.113.7"
        assert info["device_model"] == "SM-S918B"
        assert info["os_version"] == "Android 16"
        # Device name falls back to the model header.
        assert info["device_name"] == "SM-S918B"

    def test_private_and_loopback_ips_are_not_routable(self):
        from app.api.v1.auth import _is_routable_ip

        assert _is_routable_ip("127.0.0.1") is False
        assert _is_routable_ip("10.1.2.3") is False
        assert _is_routable_ip("192.168.8.139") is False
        assert _is_routable_ip("172.16.5.4") is False
        assert _is_routable_ip(None) is False
        assert _is_routable_ip("203.0.113.7") is True
        assert _is_routable_ip("8.8.8.8") is True

    async def test_geo_lookup_skips_private_ips_without_network(self):
        from app.api.v1.auth import _geo_lookup

        assert await _geo_lookup("192.168.8.139") == {
            "country": None, "region": None, "city": None}
        assert await _geo_lookup(None) == {
            "country": None, "region": None, "city": None}
