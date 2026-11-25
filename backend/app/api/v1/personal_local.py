"""One-time move of the user's existing server Personal data to their devices.

GET  /status  → {local, needed, imported, rows, snapshot_id?, digest?, purge_after?, purged?}
POST /export  → {snapshot_id, digest, body: base64 canonical JSON} (same bytes on retry)
POST /ack     {snapshot_id, digest} → {imported_at, purge_after}
See app.domain.services.personal_local_migration.
"""

import base64
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user_uuid
from app.core import personal_local_mode
from app.core.database import get_db
from app.domain.services import personal_local_migration as migration

router = APIRouter()
_installed = False


def ok(data):
    return {"success": True, "message": "تم", "data": data}


class AckBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    snapshot_id: UUID
    digest: str = Field(min_length=64, max_length=64)


async def _ready(db: AsyncSession, user_id: UUID):
    global _installed
    if not personal_local_mode.enabled_for_id(user_id):
        raise HTTPException(404, "غير متاح")
    conn = await db.connection()
    if not _installed:
        await migration.install(conn)
        _installed = True
    return conn


@router.get("/status", summary="هل للمستخدم بيانات شخصية قديمة على السيرفر؟")
async def status(user_id: UUID = Depends(get_current_user_uuid),
                 db: AsyncSession = Depends(get_db)):
    conn = await _ready(db, user_id)
    data = await migration.status(conn, user=user_id)
    await db.commit()
    return ok(data)


@router.post("/export", summary="تصدير البيانات الشخصية القديمة إلى الجهاز")
async def export(user_id: UUID = Depends(get_current_user_uuid),
                 db: AsyncSession = Depends(get_db)):
    conn = await _ready(db, user_id)
    try:
        data = await migration.export(conn, user=user_id)
    except migration.MigrationRejected as exc:
        raise HTTPException(410, str(exc)) from exc
    await db.commit()
    return ok({"snapshot_id": data["snapshot_id"], "digest": data["digest"],
               "body": base64.b64encode(data["body"]).decode()})


@router.post("/ack", summary="تأكيد حفظ الجهاز للبيانات")
async def ack(body: AckBody, user_id: UUID = Depends(get_current_user_uuid),
              db: AsyncSession = Depends(get_db)):
    conn = await _ready(db, user_id)
    try:
        data = await migration.acknowledge(conn, user=user_id,
                                           snapshot_id=body.snapshot_id,
                                           digest=body.digest)
    except migration.MigrationRejected as exc:
        raise HTTPException(409, str(exc)) from exc
    await db.commit()
    return ok(data)
