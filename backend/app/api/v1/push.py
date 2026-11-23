"""Push device registration API — register/unregister FCM tokens."""

from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user_uuid
from app.core.database import get_db
from app.api.responses import ok, no_content
from app.domain.services import push_service

router = APIRouter(tags=["Push"])


class DeviceRegister(BaseModel):
    token: str = Field(..., min_length=10, max_length=600)
    platform: str = "android"


@router.post("/push/devices", summary="Register an FCM device token")
async def register_device(
    payload: DeviceRegister,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await push_service.register_token(
        db, user_id=user_id, token=payload.token, platform=payload.platform
    )
    return ok(None, message="تم تسجيل الجهاز")


@router.delete("/push/devices/{token}", summary="Unregister an FCM device token")
async def unregister_device(
    token: str,
    _user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await push_service.unregister_token(db, token=token)
    return no_content(message="تم حذف الجهاز")
