"""Protected serving of uploaded files.

Replaces the public `/uploads` static mount so uploaded content is only
reachable by authenticated users. Sensitive categories (e.g. subscription
proofs) additionally require platform-admin privileges.
"""

import mimetypes
import os
import hmac
from typing import Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse, Response
from sqlalchemy import select, cast, String
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user_uuid_optional
from app.core.config import settings
from app.core.database import get_db
from app.core.paths import UPLOAD_ROOT
from app.core.storage import unified_download
from app.domain.entities.auth_entities import User
from app.domain.entities.suggestions_entities import Suggestion

router = APIRouter(tags=["Files"])

_MASTER_HEADER = "X-Admin-Master-Key"


def _master_key_valid(request: Request) -> bool:
    configured = settings.ADMIN_MASTER_KEY or ""
    if not configured:
        return False
    supplied = request.headers.get(_MASTER_HEADER) or ""
    return hmac.compare_digest(supplied.encode(), configured.encode())


@router.get("/uploads/{file_path:path}")
async def serve_upload(
    file_path: str,
    request: Request,
    user_id: Optional[UUID] = Depends(get_current_user_uuid_optional),
    db: AsyncSession = Depends(get_db),
):
    if not file_path or file_path.startswith(("/", "\\")):
        raise HTTPException(status_code=400, detail="Invalid path")

    normalized = os.path.normpath(file_path).replace("\\", "/")
    if normalized.startswith("..") or ".." in normalized.split("/"):
        raise HTTPException(status_code=400, detail="Invalid path")

    full = os.path.abspath(os.path.join(UPLOAD_ROOT, normalized))
    if not full.startswith(UPLOAD_ROOT + os.sep):
        raise HTTPException(status_code=400, detail="Invalid path")

    file_bytes: bytes | None = None
    if os.path.isfile(full):
        pass
    else:
        # Disk miss — fall back to the object storage backend (MinIO/S3),
        # which is where unified_upload() primarily writes.
        try:
            file_bytes = await unified_download(normalized)
        except Exception:
            file_bytes = None
        if file_bytes is None:
            raise HTTPException(status_code=404, detail="الملف غير موجود")

    first_segment = normalized.split("/", 1)[0]
    # Promotional banner assets are PUBLIC (the mobile home screen shows them
    # without auth) — banners & banners_media are safe to serve openly.
    if first_segment in ("banners", "banners_media"):
        pass
    elif first_segment == "subscription_proofs":
        # Allow the external Admin Web App via the master API key, OR a
        # real platform-admin JWT.
        if _master_key_valid(request):
            pass
        elif user_id is None:
            # Authentication FIRST: never touch the DB for anonymous callers.
            raise HTTPException(
                status_code=401, detail="يجب تسجيل الدخول للوصول إلى هذا الملف"
            )
        else:
            user_result = await db.execute(select(User).where(User.id == user_id))
            user = user_result.scalar_one_or_none()
            if not user or not user.is_platform_admin:
                raise HTTPException(
                    status_code=403, detail="ليس لديك صلاحية للوصول إلى هذا الملف"
                )

    if first_segment == "avatars":
        # Profile pictures: any authenticated user, but only their OWN
        # (`avatars/{user_id}.jpg`). Every device of the same account
        # trivially passes; strangers learn nothing (UUID stems).
        if user_id is None:
            raise HTTPException(
                status_code=401, detail="يجب تسجيل الدخول للوصول إلى هذا الملف"
            )
        stem = os.path.splitext(os.path.basename(normalized))[0]
        if stem != str(user_id):
            raise HTTPException(
                status_code=403, detail="ليس لديك صلاحية للوصول إلى هذا الملف"
            )

    if first_segment == "suggestion_images":
        # Authentication FIRST: an anonymous/bad-token caller must be rejected
        # before any DB lookup (no existence leak, no work for anonymous).
        if user_id is None:
            raise HTTPException(
                status_code=401, detail="يجب تسجيل الدخول للوصول إلى هذا الملف"
            )
        filename = os.path.basename(normalized)
        result = await db.execute(
            select(Suggestion).where(
                cast(Suggestion.images, String).like(f"%{filename}%")
            )
        )
        suggestion = result.scalar_one_or_none()
        if not suggestion:
            raise HTTPException(status_code=404, detail="الملف غير موجود")
        user_result = await db.execute(select(User).where(User.id == user_id))
        user = user_result.scalar_one_or_none()
        if suggestion.user_id != user_id and not (user and user.is_platform_admin):
            raise HTTPException(
                status_code=403, detail="ليس لديك صلاحية للوصول إلى هذا الملف"
            )

    if file_bytes is not None:
        media_type = mimetypes.guess_type(normalized)[0] or "application/octet-stream"
        return Response(content=file_bytes, media_type=media_type)
    return FileResponse(full)
