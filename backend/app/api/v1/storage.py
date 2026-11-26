"""Cloudflare R2 access for devices — presigned URLs only, never file bytes.

The server decides the tenant from the caller's own credentials (never from
the request): a device can only ever reach

* ``t/o_<org>/…``  its active company (Business; the business path guard
  checks the branch token, live membership and subscription first),
* ``t/u_<user>/…`` its own Personal space,
* ``t/c_<link>/…`` a chat it takes part in.

Areas:  ``m`` = media (content-addressed by SHA-256; images, audio, video,
documents) and ``b`` = encrypted backups (Business backups: owner only).
URLs live 10 minutes (upload) / 5 minutes (download), and the upload URL
signs content-type and content-length so nothing else can be written there.
"""

from __future__ import annotations

import re
from typing import Literal, Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from ...core import r2
from ...core.database import get_db
from ...core.logging import get_logger
from ..deps import get_current_org_id, get_current_user_uuid

router = APIRouter(tags=["Storage"])
logger = get_logger("storage_api")

UPLOAD_TTL = 600
DOWNLOAD_TTL = 300
_SHA = re.compile(r"^[0-9a-f]{64}$")
_BACKUP_ID = re.compile(r"^[a-z0-9-]{8,64}$")
_PART = re.compile(r"^[a-z0-9._-]{1,80}$")

# Upper bounds per kind (bytes). Backups are uploaded in parts.
_LIMITS = {
    "image": 25 * 1024 * 1024,
    "audio": 60 * 1024 * 1024,
    "video": 400 * 1024 * 1024,
    "document": 60 * 1024 * 1024,
    "backup": 64 * 1024 * 1024,
}


def _kind(content_type: str) -> str:
    ct = (content_type or "").lower()
    for k in ("image", "audio", "video"):
        if ct.startswith(k + "/"):
            return k
    return "document"


class _Target(BaseModel):
    area: Literal["m", "b"]
    sha256: Optional[str] = None  # media
    backup_id: Optional[str] = None  # backup
    part: Optional[str] = None  # backup


class UploadIn(_Target):
    size: int = Field(gt=0)
    content_type: str = Field(default="application/octet-stream", max_length=120)


class DownloadIn(_Target):
    pass


def _cfg() -> r2.R2Config:
    try:
        return r2.R2Config.from_env()
    except r2.R2NotConfigured:
        raise HTTPException(503, detail={"code": "storage_unavailable",
                                         "message": "التخزين السحابي غير مهيأ"})


def _key(tenant: str, t: _Target) -> str:
    if t.area == "m":
        if not t.sha256 or not _SHA.match(t.sha256):
            raise HTTPException(422, detail={"code": "bad_sha256", "message": "بصمة غير صالحة"})
        return f"t/{tenant}/m/{t.sha256}"
    if not t.backup_id or not _BACKUP_ID.match(t.backup_id) or not t.part or not _PART.match(t.part):
        raise HTTPException(422, detail={"code": "bad_backup_ref", "message": "مرجع نسخة غير صالح"})
    return f"t/{tenant}/b/{t.backup_id}/{t.part}"


async def _upload(tenant: str, body: UploadIn) -> dict:
    kind = "backup" if body.area == "b" else _kind(body.content_type)
    if body.size > _LIMITS[kind]:
        raise HTTPException(413, detail={"code": "too_large", "message": "الملف أكبر من الحد المسموح",
                                         "limit": _LIMITS[kind]})
    cfg = _cfg()
    key = _key(tenant, body)
    if body.area == "m":
        # Content-addressed: the same file is never stored twice per tenant.
        try:
            existing = await r2.head(cfg, key)
        except Exception:
            existing = None
        if existing == body.size:
            return {"success": True, "data": {"exists": True, "key_ref": body.sha256}}
    headers = {"content-type": body.content_type, "content-length": str(body.size)}
    url = r2.presign(cfg, "PUT", key, expires=UPLOAD_TTL, headers=headers)
    return {"success": True, "data": {"exists": False, "url": url, "method": "PUT",
                                      "headers": headers, "expires_in": UPLOAD_TTL}}


async def _commit(tenant: str, body: UploadIn) -> dict:
    cfg = _cfg()
    size = await r2.head(cfg, _key(tenant, body))
    if size is None or size != body.size:
        raise HTTPException(409, detail={"code": "upload_incomplete",
                                         "message": "الرفع لم يكتمل", "stored": size})
    return {"success": True, "data": {"stored": size}}


async def _download(tenant: str, body: DownloadIn) -> dict:
    cfg = _cfg()
    url = r2.presign(cfg, "GET", _key(tenant, body), expires=DOWNLOAD_TTL)
    return {"success": True, "data": {"url": url, "expires_in": DOWNLOAD_TTL}}


async def _list_backups(tenant: str) -> dict:
    cfg = _cfg()
    rows = await r2.list_prefix(cfg, f"t/{tenant}/b/")
    backups: dict[str, dict] = {}
    for key, size in rows:
        parts = key.split("/")
        if len(parts) < 5:
            continue
        b = backups.setdefault(parts[3], {"backup_id": parts[3], "parts": 0, "bytes": 0, "complete": False})
        b["parts"] += 1
        b["bytes"] += size
        if parts[4] == "manifest.enc":
            b["complete"] = True
    return {"success": True, "data": {"backups": sorted(backups.values(), key=lambda b: b["backup_id"])}}


async def _delete_backup(tenant: str, backup_id: str) -> dict:
    if not _BACKUP_ID.match(backup_id):
        raise HTTPException(422, detail={"code": "bad_backup_ref", "message": "مرجع نسخة غير صالح"})
    cfg = _cfg()
    rows = await r2.list_prefix(cfg, f"t/{tenant}/b/{backup_id}/")
    for key, _ in rows:
        await r2.delete(cfg, key)
    return {"success": True, "data": {"deleted": len(rows)}}


# ── Personal + chat (/storage) ────────────────────────────────────────────

class ScopeIn(BaseModel):
    section: Literal["personal", "chat"] = "personal"
    link_id: Optional[UUID] = None


async def _personal_tenant(db: AsyncSession, user_id: UUID, scope: ScopeIn, area: str) -> str:
    if scope.section == "personal":
        return f"u_{user_id.hex}"
    if area != "m" or scope.link_id is None:
        raise HTTPException(422, detail={"code": "bad_scope", "message": "نطاق غير صالح"})
    from ...domain.services import chat_service
    try:
        await chat_service.conversation_info(db, user_id, scope.link_id)
    except ValueError:
        raise HTTPException(403, detail={"code": "forbidden", "message": "لا تملك صلاحية هذه المحادثة"})
    return f"c_{scope.link_id.hex}"


class PUploadIn(UploadIn, ScopeIn):
    pass


class PDownloadIn(DownloadIn, ScopeIn):
    pass


@router.post("/storage/upload-url")
async def personal_upload(body: PUploadIn, user_id: UUID = Depends(get_current_user_uuid),
                          db: AsyncSession = Depends(get_db)):
    return await _upload(await _personal_tenant(db, user_id, body, body.area), body)


@router.post("/storage/commit")
async def personal_commit(body: PUploadIn, user_id: UUID = Depends(get_current_user_uuid),
                          db: AsyncSession = Depends(get_db)):
    return await _commit(await _personal_tenant(db, user_id, body, body.area), body)


@router.post("/storage/download-url")
async def personal_download(body: PDownloadIn, user_id: UUID = Depends(get_current_user_uuid),
                            db: AsyncSession = Depends(get_db)):
    return await _download(await _personal_tenant(db, user_id, body, body.area), body)


@router.get("/storage/backups")
async def personal_backups(user_id: UUID = Depends(get_current_user_uuid)):
    return await _list_backups(f"u_{user_id.hex}")


@router.delete("/storage/backups/{backup_id}")
async def personal_backup_delete(backup_id: str, user_id: UUID = Depends(get_current_user_uuid)):
    return await _delete_backup(f"u_{user_id.hex}", backup_id)


# ── Business (/business-storage — behind the business path guard) ─────────

async def _business_tenant(db: AsyncSession, user_id: UUID, org_id: str, area: str) -> str:
    if area == "b":
        # A Business backup holds every branch: the owner only.
        from ...domain.services.branch_service import require_owner
        await require_owner(db, user_id, org_id)
    return f"o_{UUID(str(org_id)).hex}"


@router.post("/business-storage/upload-url")
async def business_upload(body: UploadIn, org_id: str = Depends(get_current_org_id),
                          user_id: UUID = Depends(get_current_user_uuid),
                          db: AsyncSession = Depends(get_db)):
    return await _upload(await _business_tenant(db, user_id, org_id, body.area), body)


@router.post("/business-storage/commit")
async def business_commit(body: UploadIn, org_id: str = Depends(get_current_org_id),
                          user_id: UUID = Depends(get_current_user_uuid),
                          db: AsyncSession = Depends(get_db)):
    return await _commit(await _business_tenant(db, user_id, org_id, body.area), body)


@router.post("/business-storage/download-url")
async def business_download(body: DownloadIn, org_id: str = Depends(get_current_org_id),
                            user_id: UUID = Depends(get_current_user_uuid),
                            db: AsyncSession = Depends(get_db)):
    return await _download(await _business_tenant(db, user_id, org_id, body.area), body)


@router.get("/business-storage/backups")
async def business_backups(org_id: str = Depends(get_current_org_id),
                           user_id: UUID = Depends(get_current_user_uuid),
                           db: AsyncSession = Depends(get_db)):
    return await _list_backups(await _business_tenant(db, user_id, org_id, "b"))


@router.delete("/business-storage/backups/{backup_id}")
async def business_backup_delete(backup_id: str, org_id: str = Depends(get_current_org_id),
                                 user_id: UUID = Depends(get_current_user_uuid),
                                 db: AsyncSession = Depends(get_db)):
    return await _delete_backup(await _business_tenant(db, user_id, org_id, "b"), backup_id)
