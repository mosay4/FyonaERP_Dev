"""Chat attachments live in Cloudflare R2 (encrypted on the device), not on
the server disk: the old upload endpoint is retired, and a purged message
takes its attachments out of R2 — only those of its own chat."""

import asyncio
import json
from uuid import uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api import deps
from app.api.v1 import chat
from app.core import r2
from app.domain.services import chat_service as cs

SHA1, SHA2, SHA3 = "a" * 64, "b" * 64, "c" * 64
KEY = "k" * 43


def test_the_old_disk_upload_is_retired_and_writes_nothing(tmp_path, monkeypatch):
    from app.core import paths
    monkeypatch.setattr(paths, "UPLOAD_ROOT", str(tmp_path))
    app = FastAPI()
    app.include_router(chat.router, prefix="/api/v1")
    app.dependency_overrides[deps.get_current_user_uuid] = lambda: uuid4()
    r = TestClient(app).post(f"/api/v1/chat/{uuid4()}/media",
                             files={"file": ("a.jpg", b"\xff\xd8\xff" * 100, "image/jpeg")})
    assert r.status_code == 410
    assert r.json()["detail"]["code"] == "chat_media_moved"
    assert list(tmp_path.rglob("*")) == []


def test_only_this_chats_cloud_references_are_collected():
    link, other = uuid4(), uuid4()
    album = json.dumps([{"url": f"fyc:{link}/{SHA2}.jpg#{KEY}"},
                        {"url": f"fyc:{other}/{SHA3}.jpg#{KEY}"},
                        {"url": "uploads/chat/old.jpg"}, "junk"])
    keys = cs.cloud_media_keys(link, f"fyc:{link}/{SHA1}.mp4#{KEY}", album)
    assert keys == [f"t/c_{link.hex}/m/{SHA1}", f"t/c_{link.hex}/m/{SHA2}"]
    assert cs.cloud_media_keys(link, None, "not json") == []
    assert cs.cloud_media_keys(link, "fyc:../../x", None) == []


class _Rows:
    def __init__(self, rows):
        self._rows = rows

    def all(self):
        return self._rows


class _Db:
    def __init__(self, rows):
        self.rows = rows
        self.statements = []

    async def execute(self, stmt):
        self.statements.append(stmt)
        return _Rows(self.rows if len(self.statements) == 1 else [])


@pytest.mark.asyncio
async def test_a_purged_message_takes_its_attachments_out_of_r2(monkeypatch):
    link = uuid4()
    deleted = []

    async def fake_delete(cfg, key):
        deleted.append(key)

    monkeypatch.setattr(r2.R2Config, "from_env", classmethod(lambda cls: r2.R2Config("a", "b", "c", "d")))
    monkeypatch.setattr(r2, "delete", fake_delete)
    db = _Db([(f"fyc:{link}/{SHA1}.m4a#{KEY}", None),
              (None, json.dumps([{"url": f"fyc:{link}/{SHA2}.jpg#{KEY}"}])),
              ("uploads/chat/legacy.jpg", None)])
    await cs.purge_delivered(db, link)
    for _ in range(20):
        if len(deleted) == 2:
            break
        await asyncio.sleep(0.01)
    assert sorted(deleted) == sorted([f"t/c_{link.hex}/m/{SHA1}", f"t/c_{link.hex}/m/{SHA2}"])
    assert len(db.statements) == 2  # the select, then the delete of the rows


@pytest.mark.asyncio
async def test_no_storage_configured_purge_still_works(monkeypatch):
    def no_env(cls):
        raise r2.R2NotConfigured("none")

    monkeypatch.setattr(r2.R2Config, "from_env", classmethod(no_env))
    db = _Db([(f"fyc:{uuid4()}/{SHA1}#{KEY}", None)])
    await cs.purge_delivered(db, uuid4())
    await asyncio.sleep(0.01)
    assert len(db.statements) == 2
