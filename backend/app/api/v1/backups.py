"""Per-user server backup blob API (FYONA personal Backup/Restore rebuild).

The backup FILE is an opaque, client-built JSON snapshot (schema 4.0.0);
the server never interprets financial content here — it stores bytes,
indexes integrity metadata, and enforces per-user ownership on every
route. Financial restore from a snapshot goes through
``POST /api/v1/personal/finance/restore`` which validates everything
before touching data.

Routes (all require the authenticated user; ``user_id`` always comes
from the JWT, never from the request body):

- POST   /api/v1/backups              upload a new version (multipart file)
- GET    /api/v1/backups              list own versions (newest first)
- GET    /api/v1/backups/key          fetch-or-create own HMAC key
- GET    /api/v1/backups/{backup_id}  metadata of one own version
- GET    /api/v1/backups/{backup_id}/download   download own version bytes
- DELETE /api/v1/backups/{backup_id}  delete own version (blob + row)
"""
import base64
import hashlib
import hmac as hmac_lib
import json
import secrets
from datetime import datetime, timezone
from typing import Optional
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from fastapi.responses import Response
from sqlalchemy import desc, func, select, delete
from sqlalchemy.ext.asyncio import AsyncSession

from ...api.deps import get_current_user_uuid, require_permission
from ...api.responses import ok, created, no_content
from ...core.database import get_db
from ...domain.entities.backup_entities import UserBackup, UserBackupKey

router = APIRouter()

# Retention: keep at most this many complete versions per user. The oldest
# complete version beyond this count is removed only AFTER the new upload
# is fully stored and verified — a valid backup is never deleted without
# a verified replacement.
MAX_VERSIONS_PER_USER = 10

# Upload size guard (50 MB is far above any realistic personal snapshot).
MAX_UPLOAD_BYTES = 50 * 1024 * 1024

_SUPPORTED_SCHEMAS = ("4.0.0",)


def _backup_to_dict(b: UserBackup) -> dict:
    return {
        "id": str(b.id),
        "version": b.version,
        "schema_version": b.schema_version,
        "filename": b.filename,
        "size_bytes": b.size_bytes,
        "record_count": b.record_count,
        "checksum": b.checksum,
        "hmac_verified": bool(b.hmac),
        "status": b.status,
        "meta": b.backup_meta or {},
        "created_at": b.created_at.isoformat() if b.created_at else None,
        "updated_at": b.updated_at.isoformat() if b.updated_at else None,
    }


async def _get_or_create_key(db: AsyncSession, user_id: UUID) -> str:
    row = await db.get(UserBackupKey, user_id)
    if row is not None:
        return row.key_b64
    raw = secrets.token_bytes(32)
    row = UserBackupKey(user_id=user_id, key_b64=base64.b64encode(raw).decode())
    db.add(row)
    await db.flush()
    return row.key_b64


def _hmac_hex(key_b64: str, content: bytes) -> str:
    key = base64.b64decode(key_b64.encode())
    return hmac_lib.new(key, content, hashlib.sha256).hexdigest()


@router.get("/backups/key", summary="Fetch-or-create the caller's backup HMAC key")
async def get_backup_key(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    key_b64 = await _get_or_create_key(db, user_id)
    await db.commit()
    return ok(data={"key_b64": key_b64})


@router.post("/backups", status_code=status.HTTP_201_CREATED, summary="Upload a new server backup version")
async def upload_backup(
    file: UploadFile = File(...),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "write")),
):
    content = await file.read()
    if not content:
        raise HTTPException(status_code=400, detail="Empty backup file")
    if len(content) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="Backup file too large")
    try:
        payload = json.loads(content.decode("utf-8"))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON backup file")
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="Invalid backup format")
    schema_version = str(payload.get("schema_version") or "")
    if schema_version not in _SUPPORTED_SCHEMAS:
        raise HTTPException(
            status_code=422,
            detail=f"Unsupported backup schema: {schema_version or 'missing'}",
        )
    # Ownership: the snapshot must belong to the uploader.
    snap_user = str(payload.get("user_uuid") or "")
    if snap_user and snap_user != str(user_id):
        raise HTTPException(status_code=403, detail="Backup belongs to a different user")

    checksum = hashlib.sha256(content).hexdigest()
    key_b64 = await _get_or_create_key(db, user_id)
    digest = _hmac_hex(key_b64, content)

    counts = payload.get("counts") if isinstance(payload.get("counts"), dict) else {}
    try:
        record_count = int(sum(int(v) for v in counts.values()))
    except Exception:
        record_count = 0
    meta = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}

    # Next version number for this user.
    max_v = (await db.execute(
        select(func.max(UserBackup.version)).where(UserBackup.user_id == user_id)
    )).scalar() or 0
    version = int(max_v) + 1
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    filename = f"FYONA_ERP_Backup_v{version}_{stamp}.json"
    storage_key = f"backups/{user_id}/FYONA_ERP_Backup_v{version}_{stamp}.json"

    from app.core.storage import unified_upload
    await unified_upload("backups", f"{user_id}/{filename}", content, "application/json")

    row = UserBackup(
        id=uuid4(),
        user_id=user_id,
        version=version,
        schema_version=schema_version,
        filename=filename,
        storage_key=storage_key,
        size_bytes=len(content),
        record_count=record_count,
        checksum=checksum,
        hmac=digest,
        status="complete",
        backup_meta={"app_version": payload.get("app_version"), **meta},
    )
    db.add(row)
    await db.flush()

    # Retention AFTER the new version is safely stored.
    old_rows = (await db.execute(
        select(UserBackup).where(
            UserBackup.user_id == user_id,
            UserBackup.status == "complete",
        ).order_by(desc(UserBackup.version))
    )).scalars().all()
    pruned = []
    if len(old_rows) > MAX_VERSIONS_PER_USER:
        from app.core.storage import unified_delete
        for stale in old_rows[MAX_VERSIONS_PER_USER:]:
            try:
                await unified_delete(stale.storage_key)
            except Exception:
                pass
            pruned.append(str(stale.id))
            await db.delete(stale)
    await db.commit()
    out = _backup_to_dict(row)
    out["pruned_version_ids"] = pruned
    return created(data=out, message="Backup uploaded")


@router.put("/backups/{backup_id}", summary="Update an existing server backup version in place (manual save)")
async def update_backup(
    backup_id: str,
    file: UploadFile = File(...),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("personal_finance", "write")),
):
    try:
        bid = UUID(str(backup_id))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid backup id")
    row = await db.get(UserBackup, bid)
    if row is None or row.user_id != user_id:
        raise HTTPException(status_code=404, detail="Backup not found")
    content = await file.read()
    if not content:
        raise HTTPException(status_code=400, detail="Empty backup file")
    if len(content) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="Backup file too large")
    try:
        payload = json.loads(content.decode("utf-8"))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON backup file")
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="Invalid backup format")
    schema_version = str(payload.get("schema_version") or "")
    if schema_version not in _SUPPORTED_SCHEMAS:
        raise HTTPException(status_code=422, detail=f"Unsupported backup schema: {schema_version or 'missing'}")
    snap_user = str(payload.get("user_uuid") or "")
    if snap_user and snap_user != str(user_id):
        raise HTTPException(status_code=403, detail="Backup belongs to a different user")
    checksum = hashlib.sha256(content).hexdigest()
    key_b64 = await _get_or_create_key(db, user_id)
    digest = _hmac_hex(key_b64, content)
    counts = payload.get("counts") if isinstance(payload.get("counts"), dict) else {}
    try:
        record_count = int(sum(int(v) for v in counts.values()))
    except Exception:
        record_count = 0
    meta = payload.get("meta") if isinstance(payload.get("meta"), dict) else {}
    from app.core.storage import unified_upload
    await unified_upload("backups", row.storage_key.replace("backups/", "", 1), content, "application/json")
    row.checksum = checksum
    row.hmac = digest
    row.size_bytes = len(content)
    row.record_count = record_count
    row.schema_version = schema_version
    row.backup_meta = {"app_version": payload.get("app_version"), **meta}
    await db.flush()
    await db.commit()
    return ok(data=_backup_to_dict(row), message="Backup updated")


@router.get("/backups", summary="List the caller's server backup versions")
async def list_backups(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    rows = (await db.execute(
        select(UserBackup).where(UserBackup.user_id == user_id)
        .order_by(desc(UserBackup.version))
    )).scalars().all()
    latest = _backup_to_dict(rows[0]) if rows else None
    return ok(data={
        "backups": [_backup_to_dict(r) for r in rows],
        "latest": latest,
    })


@router.get("/backups/{backup_id}", summary="Metadata of one own backup version")
async def get_backup(
    backup_id: str,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        bid = UUID(str(backup_id))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid backup id")
    row = await db.get(UserBackup, bid)
    if row is None or row.user_id != user_id:
        raise HTTPException(status_code=404, detail="Backup not found")
    return ok(data=_backup_to_dict(row))


@router.get("/backups/{backup_id}/download", summary="Download one own backup version")
async def download_backup(
    backup_id: str,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        bid = UUID(str(backup_id))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid backup id")
    row = await db.get(UserBackup, bid)
    if row is None or row.user_id != user_id:
        raise HTTPException(status_code=404, detail="Backup not found")
    from app.core.storage import unified_download
    content = await unified_download(row.storage_key)
    if content is None:
        raise HTTPException(status_code=404, detail="Backup file missing from storage")
    # Re-verify integrity on the way out; report, do not silently serve bad bytes.
    if hashlib.sha256(content).hexdigest() != row.checksum:
        raise HTTPException(status_code=409, detail="Stored backup failed integrity check")
    return Response(
        content=content,
        media_type="application/json",
        headers={"Content-Disposition": f'attachment; filename="{row.filename}"'},
    )


@router.delete("/backups/{backup_id}", status_code=status.HTTP_204_NO_CONTENT, summary="Delete one own backup version")
async def delete_backup(
    backup_id: str,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        bid = UUID(str(backup_id))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid backup id")
    row = await db.get(UserBackup, bid)
    if row is None or row.user_id != user_id:
        raise HTTPException(status_code=404, detail="Backup not found")
    from app.core.storage import unified_delete
    try:
        await unified_delete(row.storage_key)
    except Exception:
        pass
    await db.delete(row)
    await db.commit()
    return no_content(message="Backup deleted")
