"""Backup keys: derived on the server from a master secret (never stored
with the backups), per account, owner-only for a business; Personal server
backups are encrypted by the device and kept in Cloudflare R2, never on
this server's disk."""

from uuid import uuid4

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

import app.main  # noqa: F401 — every model registered (UserBackup relations)
from app.api import deps
from app.api.v1 import backups, storage
from app.core import backup_keys, r2
from app.core.database import get_db


def test_keys_are_per_account_stable_and_need_the_master(monkeypatch):
    monkeypatch.setenv("FYONA_BACKUP_MASTER_KEY", "m" * 48)
    u, v = uuid4(), uuid4()
    assert backup_keys.account_key("u", u) == backup_keys.account_key("u", u)
    assert backup_keys.account_key("u", u) != backup_keys.account_key("u", v)
    assert backup_keys.account_key("u", u) != backup_keys.account_key("o", u)
    monkeypatch.setenv("FYONA_BACKUP_MASTER_KEY", "n" * 48)
    other = backup_keys.account_key("u", u)
    monkeypatch.setenv("FYONA_BACKUP_MASTER_KEY", "m" * 48)
    assert other != backup_keys.account_key("u", u)
    monkeypatch.delenv("FYONA_BACKUP_MASTER_KEY")
    try:
        backup_keys.account_key("u", u)
        raise AssertionError("no master must refuse")
    except HTTPException as e:
        assert e.status_code == 503


def test_business_key_is_owner_only(monkeypatch):
    monkeypatch.setenv("FYONA_BACKUP_MASTER_KEY", "m" * 48)
    org = uuid4()
    app = FastAPI()
    app.include_router(storage.router, prefix="/api/v1")
    app.dependency_overrides[deps.get_current_user_uuid] = lambda: uuid4()
    app.dependency_overrides[deps.get_current_org_id] = lambda: str(org)
    app.dependency_overrides[get_db] = lambda: None
    owner = {"ok": True}

    async def fake_owner(db, user_id, org_id):
        if not owner["ok"]:
            raise HTTPException(403, detail="owner only")

    from app.domain.services import branch_service
    monkeypatch.setattr(branch_service, "require_owner", fake_owner)
    c = TestClient(app)
    r = c.get("/api/v1/business-storage/account-key")
    assert r.status_code == 200 and r.json()["data"]["key"] == backup_keys.account_key("o", org)
    owner["ok"] = False
    assert c.get("/api/v1/business-storage/account-key").status_code == 403


class _Row:
    pass


class _Db:
    def __init__(self):
        self.added = []

    def add(self, row):
        self.added.append(row)

    async def flush(self):
        pass

    async def commit(self):
        pass

    async def get(self, model, key):
        return None

    async def execute(self, stmt):
        class R:
            def scalar(self):
                return 0

            def scalars(self):
                class S:
                    def all(self):
                        return []
                return S()
        return R()


def test_encrypted_personal_backup_goes_to_r2_not_disk(monkeypatch, tmp_path):
    monkeypatch.setenv("FYONA_BACKUP_MASTER_KEY", "m" * 48)
    user = uuid4()
    put = {}

    async def fake_put(cfg, key, body, content_type="application/octet-stream"):
        put[key] = body

    async def fake_key(db, uid):
        return "a2V5"

    monkeypatch.setattr(r2.R2Config, "from_env", classmethod(lambda cls: r2.R2Config("a", "b", "c", "d")))
    monkeypatch.setattr(r2, "put", fake_put)
    monkeypatch.setattr(backups, "_get_or_create_key", fake_key)
    from app.core import storage as local_storage

    async def no_disk(*a, **k):
        raise AssertionError("must not write to the server disk")

    monkeypatch.setattr(local_storage, "unified_upload", no_disk)
    db = _Db()
    app = FastAPI()
    app.include_router(backups.router, prefix="/api/v1")
    app.dependency_overrides[deps.get_current_user_uuid] = lambda: user
    app.dependency_overrides[get_db] = lambda: db
    # The permission check is not what this test is about: allow.
    for route in app.routes:
        for d in getattr(route, "dependant", None).dependencies if getattr(route, "dependant", None) else []:
            if d.call and getattr(d.call, "__name__", "") not in ("get_current_user_uuid", "get_db"):
                app.dependency_overrides[d.call] = lambda: None
    c = TestClient(app)
    sealed = b"FYBK" + b"\x02" + b"x" * 100
    r = c.post("/api/v1/backups", files={"file": ("b.fybk", sealed, "application/octet-stream")},
               data={"encrypted": "true", "schema_version": "4.0.0", "record_count": "7", "meta": "{}"})
    assert r.status_code == 201, r.text
    assert r.json()["data"]["encrypted"] is True
    assert list(put) and list(put)[0].startswith(f"t/u_{user.hex}/b/personal-v1/")
    assert put[list(put)[0]] == sealed
    # Not a FYBK container: refused.
    bad = c.post("/api/v1/backups", files={"file": ("b.fybk", b"{}", "application/octet-stream")},
                 data={"encrypted": "true", "schema_version": "4.0.0"})
    assert bad.status_code == 400
    k = c.get("/api/v1/backups/account-key")
    assert k.status_code == 200 and k.json()["data"]["key"] == backup_keys.account_key("u", user)
