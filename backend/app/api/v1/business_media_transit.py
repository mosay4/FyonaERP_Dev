"""Carry a branch picture or name to the account's other devices.

The server is only the road: the payload is deleted the moment every
destination device has stored it locally and acknowledged it.
"""

from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import (
    get_current_org_id,
    get_current_session_id,
    get_current_user_uuid,
)
from app.core.database import get_db
from app.domain.services import business_media_transit as transit

router = APIRouter()


def ok(data, message=None):
    return {"success": True, "message": message or "تم", "data": data}


class SubmitBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    branch_id: UUID
    kind: str = Field(pattern=r"^branch_update$")
    target_id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,64}$")
    payload: str = Field(min_length=1)


class AckBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: UUID


@router.post("", summary="تسليم حمولة إلى أجهزة الفرع")
async def submit(
    body: SubmitBody,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    session_id: UUID | None = Depends(get_current_session_id),
    db: AsyncSession = Depends(get_db),
):
    import base64

    from fastapi import HTTPException

    if session_id is None:
        raise HTTPException(403, "غير مصرح")
    try:
        payload = base64.b64decode(body.payload, validate=True)
        result = await transit.submit(
            await db.connection(),
            workspace_id=UUID(org_id), branch_id=body.branch_id,
            actor_id=user_id, session_id=session_id,
            kind=body.kind, target_id=body.target_id, payload=payload,
        )
    except transit.MediaAccessDenied as exc:
        raise HTTPException(403, "غير مصرح") from exc
    except (ValueError, TypeError) as exc:
        raise HTTPException(422, "حمولة غير صالحة") from exc
    await db.commit()
    return ok(result)


@router.get("", summary="الحمولات الموجّهة لهذا الجهاز")
async def poll(
    org_id: str = Depends(get_current_org_id),
    session_id: UUID | None = Depends(get_current_session_id),
    db: AsyncSession = Depends(get_db),
):
    if session_id is None:
        return ok({"items": []})
    items = await transit.poll(
        await db.connection(), workspace_id=UUID(org_id), session_id=session_id,
    )
    await db.commit()
    return ok({"items": items})


@router.post("/ack", summary="إقرار الحفظ المحلي للحمولة")
async def ack(
    body: AckBody,
    org_id: str = Depends(get_current_org_id),
    session_id: UUID | None = Depends(get_current_session_id),
    db: AsyncSession = Depends(get_db),
):
    from fastapi import HTTPException

    if session_id is None:
        raise HTTPException(403, "غير مصرح")
    try:
        done = await transit.ack(
            await db.connection(), workspace_id=UUID(org_id),
            session_id=session_id, payload_id=body.id,
        )
    except transit.MediaAccessDenied as exc:
        raise HTTPException(403, "غير مصرح") from exc
    await db.commit()
    return ok({"id": str(body.id), "delivered": done})