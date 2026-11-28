"""Storage API (Cloudflare R2 presigned URLs): tenant isolation, owner-only
Business backups, chat participation, limits — plus a REAL R2 round trip when
the server has R2 keys (skipped otherwise; never in CI logs)."""

import hashlib
import os
from urllib.parse import urlparse
from uuid import uuid4

import httpx
import pytest
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from app.api import deps
from app.api.v1 import storage
from app.core import r2
from app.core.database import get_db

FAKE = r2.R2Config("acct", "AKID", "SECRET", "bucket")
SHA = hashlib.sha256(b"x").hexdigest()


def _app(user, org=None, *, owner=True, chat_ok=True, heads=None, monkeypatch=None):
    app = FastAPI()
    app.include_router(storage.router, prefix="/api/v1")
    app.dependency_overrides[deps.get_current_user_uuid] = lambda: user
    app.dependency_overrides[get_db] = lambda: None
    if org is not None:
        app.dependency_overrides[deps.get_current_org_id] = lambda: str(org)

    async def fake_owner(db, user_id, org_id):
        if not owner:
            raise HTTPException(403, detail="owner only")

    async def fake_chat(db, user_id, link_id):
        if not chat_ok:
            raise ValueError("not a participant")

    async def fake_head(cfg, key):
        return (heads or {}).get(key)

    monkeypatch.setattr(storage, "_cfg", lambda: FAKE)
    monkeypatch.setattr(r2, "head", fake_head)
    from app.domain.services import branch_service, chat_service
    monkeypatch.setattr(branch_service, "require_owner", fake_owner)
    monkeypatch.setattr(chat_service, "conversation_info", fake_chat)
    return TestClient(app)


def _path(url):
    return urlparse(url).path


def test_personal_media_goes_to_the_callers_own_space(monkeypatch):
    user = uuid4()
    c = _app(user, monkeypatch=monkeypatch)
    r = c.post("/api/v1/storage/upload-url", json={
        "area": "m", "sha256": SHA, "size": 10, "content_type": "image/jpeg"})
    assert r.status_code == 200, r.text
    d = r.json()["data"]
    assert _path(d["url"]) == f"/bucket/t/u_{user.hex}/m/{SHA}"
    assert d["headers"] == {"content-type": "image/jpeg", "content-length": "10"}
    assert "X-Amz-Signature=" in d["url"] and "X-Amz-Expires=600" in d["url"]


def test_existing_media_is_not_uploaded_twice(monkeypatch):
    user = uuid4()
    key = f"t/u_{user.hex}/m/{SHA}"
    c = _app(user, heads={key: 10}, monkeypatch=monkeypatch)
    r = c.post("/api/v1/storage/upload-url", json={
        "area": "m", "sha256": SHA, "size": 10, "content_type": "image/png"})
    assert r.json()["data"] == {"exists": True, "key_ref": SHA}


def test_chat_needs_participation(monkeypatch):
    link = uuid4()
    ok = _app(uuid4(), chat_ok=True, monkeypatch=monkeypatch).post("/api/v1/storage/upload-url", json={
        "section": "chat", "link_id": str(link), "area": "m", "sha256": SHA, "size": 5,
        "content_type": "audio/m4a"})
    assert _path(ok.json()["data"]["url"]) == f"/bucket/t/c_{link.hex}/m/{SHA}"
    denied = _app(uuid4(), chat_ok=False, monkeypatch=monkeypatch).post("/api/v1/storage/upload-url", json={
        "section": "chat", "link_id": str(link), "area": "m", "sha256": SHA, "size": 5})
    assert denied.status_code == 403
    # Chat has no backup area.
    bad = _app(uuid4(), monkeypatch=monkeypatch).post("/api/v1/storage/upload-url", json={
        "section": "chat", "link_id": str(link), "area": "b", "backup_id": "abcdefgh1",
        "part": "p0001", "size": 5})
    assert bad.status_code == 422


def test_business_scope_comes_from_the_token_not_the_request(monkeypatch):
    org = uuid4()
    c = _app(uuid4(), org, monkeypatch=monkeypatch)
    r = c.post("/api/v1/business-storage/upload-url", json={
        "area": "m", "sha256": SHA, "size": 9, "content_type": "image/webp",
        "org_id": str(uuid4()), "tenant": "o_someone_else"})
    assert _path(r.json()["data"]["url"]) == f"/bucket/t/o_{org.hex}/m/{SHA}"


def test_business_backups_are_owner_only(monkeypatch):
    org = uuid4()
    body = {"area": "b", "backup_id": "bk-2026-11-26-a1", "part": "p00001.enc", "size": 1000}
    emp = _app(uuid4(), org, owner=False, monkeypatch=monkeypatch)
    assert emp.post("/api/v1/business-storage/upload-url", json=body).status_code == 403
    # An employee may still upload product images (media area).
    assert emp.post("/api/v1/business-storage/upload-url", json={
        "area": "m", "sha256": SHA, "size": 9, "content_type": "image/jpeg"}).status_code == 200
    own = _app(uuid4(), org, owner=True, monkeypatch=monkeypatch)
    r = own.post("/api/v1/business-storage/upload-url", json=body)
    assert _path(r.json()["data"]["url"]) == f"/bucket/t/o_{org.hex}/b/bk-2026-11-26-a1/p00001.enc"


@pytest.mark.parametrize("body", [
    {"area": "m", "sha256": "../../etc/passwd", "size": 1},
    {"area": "m", "sha256": "A" * 64, "size": 1},
    {"area": "b", "backup_id": "../x", "part": "p", "size": 1},
    {"area": "b", "backup_id": "abcdefgh", "part": "../manifest", "size": 1},
])
def test_refs_are_validated(monkeypatch, body):
    assert _app(uuid4(), monkeypatch=monkeypatch).post("/api/v1/storage/upload-url", json=body).status_code == 422


def test_limits(monkeypatch):
    c = _app(uuid4(), monkeypatch=monkeypatch)
    too_big = c.post("/api/v1/storage/upload-url", json={
        "area": "m", "sha256": SHA, "size": 26 * 1024 * 1024, "content_type": "image/jpeg"})
    assert too_big.status_code == 413
    video = c.post("/api/v1/storage/upload-url", json={
        "area": "m", "sha256": SHA, "size": 26 * 1024 * 1024, "content_type": "video/mp4"})
    assert video.status_code == 200


def test_commit_checks_the_stored_size(monkeypatch):
    user = uuid4()
    key = f"t/u_{user.hex}/m/{SHA}"
    c = _app(user, heads={key: 7}, monkeypatch=monkeypatch)
    ok = c.post("/api/v1/storage/commit", json={"area": "m", "sha256": SHA, "size": 7})
    assert ok.status_code == 200
    short = c.post("/api/v1/storage/commit", json={"area": "m", "sha256": SHA, "size": 8})
    assert short.status_code == 409


def test_presign_is_deterministic_and_signs_headers():
    import datetime as dt
    now = dt.datetime(2026, 11, 26, 12, 0, tzinfo=dt.timezone.utc)
    a = r2.presign(FAKE, "PUT", "t/u_x/m/" + SHA, headers={"content-length": "5"}, now=now)
    b = r2.presign(FAKE, "PUT", "t/u_x/m/" + SHA, headers={"content-length": "5"}, now=now)
    c = r2.presign(FAKE, "PUT", "t/u_x/m/" + SHA, headers={"content-length": "6"}, now=now)
    assert a == b and a != c
    assert "X-Amz-SignedHeaders=content-length%3Bhost" in a
    with pytest.raises(ValueError):
        r2.presign(FAKE, "GET", "/etc/passwd")


# ── Real Cloudflare R2 (only where the server holds the keys) ───────────────

_REAL = all(os.environ.get(k) for k in
            ("CLOUDFLARE_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_BUCKET"))


@pytest.mark.skipif(not _REAL, reason="no R2 keys in this environment")
def test_real_r2_round_trip_through_the_api(monkeypatch):
    user = uuid4()
    app = FastAPI()
    app.include_router(storage.router, prefix="/api/v1")
    app.dependency_overrides[deps.get_current_user_uuid] = lambda: user
    app.dependency_overrides[get_db] = lambda: None
    c = TestClient(app)
    data = os.urandom(64 * 1024)
    sha = hashlib.sha256(data).hexdigest()
    up = c.post("/api/v1/storage/upload-url", json={
        "area": "m", "sha256": sha, "size": len(data), "content_type": "image/jpeg"}).json()["data"]
    assert up["exists"] is False
    assert httpx.put(up["url"], content=data, headers=up["headers"], timeout=30).status_code == 200
    assert c.post("/api/v1/storage/commit", json={"area": "m", "sha256": sha, "size": len(data)}).status_code == 200
    again = c.post("/api/v1/storage/upload-url", json={
        "area": "m", "sha256": sha, "size": len(data), "content_type": "image/jpeg"}).json()["data"]
    assert again["exists"] is True
    dl = c.post("/api/v1/storage/download-url", json={"area": "m", "sha256": sha}).json()["data"]
    got = httpx.get(dl["url"], timeout=30)
    assert got.status_code == 200 and hashlib.sha256(got.content).hexdigest() == sha
    # Another user's space is never reachable with these URLs.
    assert f"/u_{user.hex}/" in urlparse(dl["url"]).path
    import asyncio
    asyncio.run(r2.delete(r2.R2Config.from_env(), f"t/u_{user.hex}/m/{sha}"))


def test_backup_list_follows_every_page(monkeypatch):
    """A business backup with thousands of parts (product pictures): the
    size and the set itself come from every listing page, not the first 1000."""
    import asyncio

    keys = [f"t/o/b/bk-20261128-170200-aaaaaa/m-{i:05d}" for i in range(2499)]
    keys.append("t/o/b/bk-20261128-170200-aaaaaa/manifest.enc")
    pages = [keys[i:i + 1000] for i in range(0, len(keys), 1000)]

    class _R:
        def __init__(self, text):
            self.text = text

        def raise_for_status(self):
            pass

    async def fake_request(cfg, method, key, q=None, **kw):
        n = int(q.get("continuation-token", "0"))
        body = "".join(f"<Contents><Key>{k}</Key><LastModified>2026-11-28T17:0{n}:00.000Z</LastModified>"
                       f"<Size>1000</Size></Contents>" for k in pages[n])
        more = n + 1 < len(pages)
        tail = f"<IsTruncated>{'true' if more else 'false'}</IsTruncated>"
        if more:
            tail += f"<NextContinuationToken>{n + 1}</NextContinuationToken>"
        return _R(f"<ListBucketResult>{body}{tail}</ListBucketResult>")

    monkeypatch.setattr(r2, "_request", fake_request)
    monkeypatch.setattr(storage, "_cfg", lambda: FAKE)
    out = asyncio.run(storage._list_backups("o"))["data"]["backups"]
    assert len(out) == 1
    assert out[0]["parts"] == 2500 and out[0]["bytes"] == 2_500_000
    assert out[0]["complete"] is True
    assert out[0]["updated"] == "2026-11-28T17:02:00.000Z"
