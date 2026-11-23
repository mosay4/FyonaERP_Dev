"""One-time move of a branch's existing server Business data to its devices."""

import base64
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_org_id, get_current_user_uuid
from app.core import business_local_mode
from app.core.database import get_db
from app.domain.entities.auth_entities import User
from app.domain.entities.sale_entities import Branch
from app.domain.services import business_local_migration as migration

router = APIRouter()
_installed = False


def ok(data):
    return {"success": True, "message": "تم", "data": data}


class ExportBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    branch_id: UUID
    server: str = Field(max_length=200)


class AckBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    branch_id: UUID
    snapshot_id: UUID
    digest: str = Field(min_length=64, max_length=64)


async def _owner_branch(db: AsyncSession, org_id: str, user_id: UUID, branch_id: UUID):
    global _installed
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    branch = await db.get(Branch, branch_id)
    if (user is None or branch is None or str(branch.organization_id) != org_id
            or not await business_local_mode.whole_organization(db, user, branch)):
        raise HTTPException(403, "غير مصرح")
    conn = await db.connection()
    if not _installed:
        await migration.install(conn)
        _installed = True
    return conn


@router.get("/status", summary="هل لهذا الفرع بيانات قديمة على السيرفر؟")
async def status(branch_id: UUID, org_id: str = Depends(get_current_org_id),
                 user_id: UUID = Depends(get_current_user_uuid),
                 db: AsyncSession = Depends(get_db)):
    conn = await _owner_branch(db, org_id, user_id, branch_id)
    data = await migration.status(conn, org=UUID(org_id), branch=branch_id)
    await db.commit()
    return ok(data)


@router.post("/export", summary="تصدير بيانات الفرع القديمة إلى الجهاز")
async def export(body: ExportBody, org_id: str = Depends(get_current_org_id),
                 user_id: UUID = Depends(get_current_user_uuid),
                 db: AsyncSession = Depends(get_db)):
    conn = await _owner_branch(db, org_id, user_id, body.branch_id)
    try:
        data = await migration.export(conn, org=UUID(org_id), account=user_id,
                                      branch=body.branch_id, server=body.server)
    except migration.MigrationRejected as exc:
        raise HTTPException(409, str(exc)) from exc
    await db.commit()
    return ok({"snapshot_id": data["snapshot_id"], "digest": data["digest"],
               "body": base64.b64encode(data["body"]).decode()})


@router.post("/ack", summary="تأكيد استلام الجهاز للبيانات")
async def ack(body: AckBody, org_id: str = Depends(get_current_org_id),
              user_id: UUID = Depends(get_current_user_uuid),
              db: AsyncSession = Depends(get_db)):
    conn = await _owner_branch(db, org_id, user_id, body.branch_id)
    try:
        await migration.acknowledge(conn, org=UUID(org_id), branch=body.branch_id,
                                    snapshot_id=body.snapshot_id, digest=body.digest)
    except migration.MigrationRejected as exc:
        raise HTTPException(409, str(exc)) from exc
    await db.commit()
    return ok({})


@router.post("/purge", summary="حذف بيانات الفرع القديمة من السيرفر بعد استلام الجهاز")
async def purge(body: AckBody, org_id: str = Depends(get_current_org_id),
                user_id: UUID = Depends(get_current_user_uuid),
                db: AsyncSession = Depends(get_db)):
    conn = await _owner_branch(db, org_id, user_id, body.branch_id)
    try:
        removed = await migration.purge(conn, org=UUID(org_id), branch=body.branch_id,
                                        snapshot_id=body.snapshot_id, digest=body.digest)
    except migration.MigrationRejected as exc:
        raise HTTPException(409, str(exc)) from exc
    except Exception as exc:  # a database guard or reference refused it
        await db.rollback()
        raise HTTPException(409, "تعذّر حذف البيانات القديمة الآن") from exc
    await db.commit()
    return ok({"removed": removed})
