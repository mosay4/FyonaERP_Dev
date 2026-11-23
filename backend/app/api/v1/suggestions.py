"""Suggestions API — any authenticated user submits; platform admins review.

Admin review endpoints are gated by `suggestions:read` / `suggestions:update`
permissions through the DB-backed permission system (require_admin_perm).
"""

import os
from typing import Optional
from uuid import UUID

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import FileResponse
from sqlalchemy import select, cast, String
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db
from app.api.deps import (
    get_current_user_uuid,
    get_current_org_id_optional,
    require_admin_perm,
    require_platform_admin,
)
from app.api.responses import ok
from app.domain.entities.suggestions_entities import Suggestion
from app.domain.entities.auth_entities import User, Organization
from app.domain.models.suggestions_models import SuggestionUpdate, SuggestionReplyCreate, SuggestionMessageEdit
from app.domain.services.suggestions_service import (
    SuggestionService,
    UPLOAD_DIR,
    VIDEO_DIR,
    AUDIO_DIR,
    save_image,
    save_video,
    save_audio,
)

router = APIRouter(tags=["Suggestions"])


@router.post("/suggestions", summary="Submit a suggestion (multipart)")
async def create_suggestion(
    title: str = Form(""),
    body: str = Form(""),
    images: Optional[list[UploadFile]] = File(default=[]),
    videos: Optional[list[UploadFile]] = File(default=[]),
    audios: Optional[list[UploadFile]] = File(default=[]),
    user_id: UUID = Depends(get_current_user_uuid),
    org_id: Optional[str] = Depends(get_current_org_id_optional),
    db: AsyncSession = Depends(get_db),
):
    # Defensive: when the endpoint is invoked directly (unit tests bypass
    # FastAPI's dependency resolution) the `File(default=[])` parameters are
    # the bare FieldInfo object instead of a list. Normalize before iterating.
    images = images if isinstance(images, list) else []
    videos = videos if isinstance(videos, list) else []
    audios = audios if isinstance(audios, list) else []
    saved_images = []
    for img in images or []:
        if img and img.filename:
            saved_images.append(await save_image(img))
    saved_videos = []
    for vid in videos or []:
        if vid and vid.filename:
            saved_videos.append(await save_video(vid))
    saved_audios = []
    for aud in audios or []:
        if aud and aud.filename:
            saved_audios.append(await save_audio(aud))
    service = SuggestionService(db)
    suggestion = await service.create(
        user_id=user_id,
        org_id=UUID(str(org_id)) if org_id else None,
        title=title,
        body=body,
        images=saved_images,
        videos=saved_videos,
        audios=saved_audios,
    )

    # Notify platform admins: in-app + FCM push (best effort).
    try:
        from app.domain.entities.auth_entities import User
        from app.domain.services import push_service
        admin_rows = (await db.execute(
            select(User).where(User.is_platform_admin.is_(True), User.status == "active")
        )).scalars().all()
        if admin_rows:
            from app.domain.entities.notification_entities import AppNotification
            for admin in admin_rows:
                db.add(AppNotification(
                    organization_id=admin.organization_id,
                    user_id=admin.id,
                    type="info",
                    title="اقتراح جديد 📮",
                    message=(title or body)[:1000],
                    action="open_screen",
                    action_payload="admin_suggestions",
                ))
            await db.commit()
            await push_service.notify_platform_admins(
                db,
                title="اقتراح جديد 📮",
                body=(title or body)[:200],
                action="open_screen",
                action_payload="admin_suggestions",
            )
    except Exception:  # noqa: BLE001 - best effort
        await db.rollback()

    return ok(suggestion.model_dump(), message="تم إرسال الاقتراح بنجاح")


@router.post("/suggestions/{suggestion_id}/messages", summary="Owner: send a message inside their own suggestion ticket (multipart)")
async def user_reply_to_suggestion(
    suggestion_id: UUID,
    body: str = Form(""),
    images: Optional[list[UploadFile]] = File(default=[]),
    videos: Optional[list[UploadFile]] = File(default=[]),
    audios: Optional[list[UploadFile]] = File(default=[]),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    """Append a message (text and/or media) to an existing suggestion ticket.

    Lets the user carry on a dedicated conversation per suggestion — each
    message becomes a `SuggestionReply` row with ``admin_id=None`` so it is
    not confused with an admin reply and unread state stays correct.
    """
    images = images if isinstance(images, list) else []
    videos = videos if isinstance(videos, list) else []
    audios = audios if isinstance(audios, list) else []
    stmt = select(Suggestion).where(
        Suggestion.id == suggestion_id, ~Suggestion.is_deleted
    )
    suggestion = (await db.execute(stmt)).scalar_one_or_none()
    if not suggestion:
        raise HTTPException(status_code=404, detail="الاقتراح غير موجود")
    if suggestion.user_id != user_id:
        raise HTTPException(status_code=403, detail="لا يمكنك الرد على اقتراح ليس لك")
    saved_images = []
    for img in images or []:
        if img and img.filename:
            saved_images.append(await save_image(img))
    saved_videos = []
    for vid in videos or []:
        if vid and vid.filename:
            saved_videos.append(await save_video(vid))
    saved_audios = []
    for aud in audios or []:
        if aud and aud.filename:
            saved_audios.append(await save_audio(aud))

    service = SuggestionService(db)
    reply = await service.add_reply(
        suggestion_id=suggestion_id,
        user_id=user_id,
        admin_id=None,
        body=body,
        images=saved_images,
        videos=saved_videos,
        audios=saved_audios,
    )
    # A new user message marks the ticket as unread for the admin.
    suggestion.admin_read_at = None
    await db.commit()

    # Notify platform admins: in-app + FCM push (best effort).
    try:
        from app.domain.entities.auth_entities import User as _User
        from app.domain.entities.notification_entities import AppNotification
        from app.domain.services import push_service
        admin_rows = (await db.execute(
            select(_User).where(_User.is_platform_admin.is_(True), _User.status == "active")
        )).scalars().all()
        if admin_rows:
            for admin in admin_rows:
                db.add(AppNotification(
                    organization_id=admin.organization_id,
                    user_id=admin.id,
                    type="info",
                    title="رسالة جديدة على اقتراح 📮",
                    message=(body or "أرسل المستخدم ملفات/رسالة صوتية")[:1000],
                    action="open_screen",
                    action_payload="admin_suggestions",
                ))
            await db.commit()
            await push_service.notify_platform_admins(
                db,
                title="رسالة جديدة على اقتراح 📮",
                body=(body or "أرسل المستخدم ملفات/رسالة صوتية على اقتراحه")[:200],
                action="open_screen",
                action_payload="admin_suggestions",
            )
    except Exception:  # noqa: BLE001 - best effort
        await db.rollback()

    return ok(reply.model_dump(), message="تم إرسال الرسالة")


@router.get("/suggestions/mine", summary="List my suggestions")
async def list_mine(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    service = SuggestionService(db)
    items = await service.list_mine(user_id=user_id)
    return ok([s.model_dump() for s in items])


@router.get("/suggestions", summary="Admin: list all suggestions")
async def admin_list_suggestions(
    status_filter: Optional[str] = Query(None, alias="status"),
    search: Optional[str] = Query(None),
    page: int = Query(1, ge=1),
    per_page: int = Query(20, ge=1, le=100),
    _: bool = Depends(require_admin_perm("suggestions", "read")),
    db: AsyncSession = Depends(get_db),
):
    service = SuggestionService(db)
    data = await service.admin_list(
        status_filter=status_filter, search=search, page=page, per_page=per_page
    )
    return ok(data)


@router.get("/suggestions/conversations", summary="Admin: list conversations (grouped by user)")
async def admin_list_conversations(
    search: Optional[str] = None,
    status: Optional[str] = None,
    page: int = Query(1, ge=1),
    per_page: int = Query(20, ge=1, le=100),
    _: bool = Depends(require_admin_perm("suggestions", "read")),
    db: AsyncSession = Depends(get_db),
):
    service = SuggestionService(db)
    data = await service.admin_conversations(
        search=search, page=page, per_page=per_page, status=status
    )
    return ok(data)


@router.get("/suggestions/conversations/{user_id}/messages", summary="Admin: conversation messages for a user")
async def admin_conversation_messages(
    user_id: UUID,
    page: int = Query(1, ge=1),
    per_page: int = Query(20, ge=1, le=100),
    _: bool = Depends(require_admin_perm("suggestions", "read")),
    db: AsyncSession = Depends(get_db),
):
    service = SuggestionService(db)
    data = await service.conversation_messages(user_id=user_id, page=page, per_page=per_page)
    return ok(data)


@router.post("/suggestions/conversations/{user_id}/read", summary="Admin: mark a conversation as read")
async def admin_mark_conversation_read(
    user_id: UUID,
    _: bool = Depends(require_admin_perm("suggestions", "read")),
    db: AsyncSession = Depends(get_db),
):
    service = SuggestionService(db)
    await service.mark_conversation_read(user_id=user_id)
    return ok({"read": True})


@router.delete("/suggestions/messages/{message_id}", summary="Delete a suggestion message")
async def delete_suggestion_message(
    message_id: UUID,
    request: Request,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    """Delete a message so it disappears on both sides.

    Owners may delete their own messages within 24h; platform admins
    (suggestions:update) may delete any message.
    """
    from app.api.deps import _master_key_valid, require_platform_admin
    from app.infrastructure.repositories.sql_alchemy_auth_repository import (
        SQLAlchemyRoleRepository,
    )
    service = SuggestionService(db)
    if await _is_msg_owner(db, message_id, user_id):
        try:
            await service.delete_reply(
                message_id=message_id, user_id=user_id, is_admin=False)
        except HTTPException:
            raise
        return ok({"deleted": True})
    # Not the owner → previous admin gate (master key or suggestions:update).
    if _master_key_valid(request):
        await require_platform_admin(user_id=user_id, db=db)
        is_admin = True
    else:
        await require_platform_admin(user_id=user_id, db=db)
        role_repo = SQLAlchemyRoleRepository(db)
        if not await role_repo.user_has_admin_permission(user_id, "suggestions", "update"):
            raise HTTPException(
                status_code=403, detail="ليس لديك صلاحية للقيام بهذه العملية")
        is_admin = True
    await service.delete_reply(
        message_id=message_id, user_id=user_id, is_admin=is_admin)
    return ok({"deleted": True})


async def _is_msg_owner(db: AsyncSession, message_id: UUID, user_id: UUID) -> bool:
    """True when the caller owns a non-deleted, non-admin message."""
    from app.domain.entities.suggestions_entities import SuggestionReply
    stmt = select(SuggestionReply).where(
        SuggestionReply.id == message_id,
        ~SuggestionReply.is_deleted,
    )
    reply = (await db.execute(stmt)).scalar_one_or_none()
    return bool(
        reply is not None
        and reply.admin_id is None
        and reply.user_id == user_id
    )


@router.patch("/suggestions/messages/{message_id}", summary="Edit a suggestion message")
async def edit_suggestion_message(
    message_id: UUID,
    body: SuggestionMessageEdit,
    request: Request,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    """Edit a message's text (edited badge shows on both sides).

    Owners may edit their own messages within 24h; platform admins
    (suggestions:update) may edit any message.
    """
    from app.api.deps import _master_key_valid, require_platform_admin
    from app.infrastructure.repositories.sql_alchemy_auth_repository import (
        SQLAlchemyRoleRepository,
    )
    service = SuggestionService(db)
    is_admin = False
    if await _is_msg_owner(db, message_id, user_id):
        pass
    else:
        if _master_key_valid(request):
            await require_platform_admin(user_id=user_id, db=db)
        else:
            await require_platform_admin(user_id=user_id, db=db)
            role_repo = SQLAlchemyRoleRepository(db)
            if not await role_repo.user_has_admin_permission(user_id, "suggestions", "update"):
                raise HTTPException(
                    status_code=403, detail="ليس لديك صلاحية للقيام بهذه العملية")
        is_admin = True
    reply = await service.edit_reply(
        message_id=message_id, user_id=user_id,
        body=body.body, is_admin=is_admin)
    return ok(reply.model_dump(), message="تم تعديل الرسالة")


@router.post("/suggestions/conversations/{user_id}/reply", summary="Admin: reply inside a conversation")
async def admin_conversation_reply(
    user_id: UUID,
    body: SuggestionReplyCreate,
    admin_id: UUID = Depends(get_current_user_uuid),
    _: bool = Depends(require_admin_perm("suggestions", "update")),
    db: AsyncSession = Depends(get_db),
):
    service = SuggestionService(db)
    suggestion = await service.resolve_reply_target(
        user_id=user_id, suggestion_id=body.suggestion_id)
    reply = await service.add_reply(
        suggestion_id=suggestion.id,
        user_id=user_id,
        admin_id=admin_id,
        body=body.body,
    )
    # Notify the suggestion owner in-app (best effort).
    try:
        from app.domain.entities.notification_entities import AppNotification
        org_id = suggestion.organization_id
        if org_id is None:
            org_row = (await db.execute(
                select(Organization).join(User, User.organization_id == Organization.id)
                .where(User.id == user_id).limit(1)
            )).scalar_one_or_none()
            org_id = org_row.id if org_row else None
        if org_id is not None:
            db.add(AppNotification(
                organization_id=org_id,
                user_id=user_id,
                type="info",
                title="رد جديد على اقتراحك",
                message=body.body[:1000],
                action="open_screen",
                action_payload="suggestions",
            ))
            await db.commit()
        from app.domain.services import push_service
        await push_service.notify_user(
            db,
            user_id=user_id,
            title="رد جديد على اقتراحك",
            body="لديك رسالة جديدة من الإدارة على اقتراحك في تطبيق فيونا — اضغط هنا للمشاهدة.",
            action="open_screen",
            action_payload="suggestions",
        )
    except Exception:  # noqa: BLE001
        await db.rollback()
    return ok(reply.model_dump(), message="تم إرسال الرد")


@router.post("/suggestions/conversations/{user_id}/reply-media", summary="Admin: reply with media (multipart)")
async def admin_conversation_reply_media(
    user_id: UUID,
    body: str = Form(""),
    suggestion_id: str = Form(""),
    images: Optional[list[UploadFile]] = File(default=[]),
    videos: Optional[list[UploadFile]] = File(default=[]),
    audios: Optional[list[UploadFile]] = File(default=[]),
    admin_id: UUID = Depends(get_current_user_uuid),
    _: bool = Depends(require_admin_perm("suggestions", "update")),
    db: AsyncSession = Depends(get_db),
):
    """Reply inside a conversation with optional attachments (images/videos/audio).

    Reuses the same file-save helpers as the user-facing submit so media paths
    are stored consistently and served via /uploads/suggestion_images.
    """
    images = images if isinstance(images, list) else []
    videos = videos if isinstance(videos, list) else []
    audios = audios if isinstance(audios, list) else []
    saved_images = []
    for img in images or []:
        if img and img.filename:
            saved_images.append(await save_image(img))
    saved_videos = []
    for vid in videos or []:
        if vid and vid.filename:
            saved_videos.append(await save_video(vid))
    saved_audios = []
    for aud in audios or []:
        if aud and aud.filename:
            saved_audios.append(await save_audio(aud))

    service = SuggestionService(db)
    suggestion = await service.resolve_reply_target(
        user_id=user_id, suggestion_id=suggestion_id or None)
    reply = await service.add_reply(
        suggestion_id=suggestion.id,
        user_id=user_id,
        admin_id=admin_id,
        body=body,
        images=saved_images,
        videos=saved_videos,
        audios=saved_audios,
    )
    # Notify the suggestion owner in-app (best effort).
    try:
        from app.domain.entities.notification_entities import AppNotification
        from app.domain.entities.auth_entities import Organization as _Org
        org_id = suggestion.organization_id
        if org_id is None:
            org_row = (await db.execute(
                select(_Org).join(User, User.organization_id == _Org.id)
                .where(User.id == user_id).limit(1)
            )).scalar_one_or_none()
            org_id = org_row.id if org_row else None
        if org_id is not None:
            db.add(AppNotification(
                organization_id=org_id,
                user_id=user_id,
                type="info",
                title="رد جديد على اقتراحك",
                message=(body or "أرفقت الإدارة ملفات على اقتراحك")[:1000],
                action="open_screen",
                action_payload="suggestions",
            ))
            await db.commit()
        from app.domain.services import push_service
        await push_service.notify_user(
            db,
            user_id=user_id,
            title="رد جديد على اقتراحك",
            body="لديك رسالة جديدة من الإدارة على اقتراحك في تطبيق فيونا — اضغط هنا للمشاهدة.",
            action="open_screen",
            action_payload="suggestions",
        )
    except Exception:  # noqa: BLE001
        await db.rollback()
    return ok(reply.model_dump(), message="تم إرسال الرد")


@router.patch("/suggestions/{suggestion_id}", summary="Admin: review a suggestion")
async def admin_update_suggestion(
    suggestion_id: UUID,
    update: SuggestionUpdate,
    _: bool = Depends(require_admin_perm("suggestions", "update")),
    db: AsyncSession = Depends(get_db),
):
    service = SuggestionService(db)
    suggestion = await service.admin_update(suggestion_id=suggestion_id, update=update)
    return ok(suggestion.model_dump(), message="تم تحديث حالة الاقتراح")


@router.post("/suggestions/{suggestion_id}/reply", summary="Admin: reply to a suggestion")
async def reply_to_suggestion(
    suggestion_id: UUID,
    body: SuggestionReplyCreate,
    admin_id: UUID = Depends(get_current_user_uuid),
    _: bool = Depends(require_admin_perm("suggestions", "update")),
    db: AsyncSession = Depends(get_db),
):
    service = SuggestionService(db)
    # Locate the suggestion to resolve its owner (user_id).
    stmt = select(Suggestion).where(Suggestion.id == suggestion_id, ~Suggestion.is_deleted)
    suggestion = (await db.execute(stmt)).scalar_one_or_none()
    if not suggestion:
        raise HTTPException(status_code=404, detail="الاقتراح غير موجود")

    reply = await service.add_reply(
        suggestion_id=suggestion_id,
        user_id=suggestion.user_id,
        admin_id=admin_id,
        body=body.body,
    )

    # Notify the suggestion owner in-app (best effort).
    try:
        from app.domain.entities.notification_entities import AppNotification
        from app.domain.entities.auth_entities import Organization
        org_id = suggestion.organization_id
        if org_id is None:
            org_row = (await db.execute(
                select(Organization).join(User, User.organization_id == Organization.id)
                .where(User.id == suggestion.user_id).limit(1)
            )).scalar_one_or_none()
            org_id = org_row.id if org_row else None
        if org_id is not None:
            notif = AppNotification(
                organization_id=org_id,
                user_id=suggestion.user_id,
                type="info",
                title="رد جديد على اقتراحك",
                message=body.body[:1000],
                action="open_screen",
                action_payload="suggestions",
            )
            db.add(notif)
            await db.commit()
        # FCM push to the suggestion owner (best effort).
        from app.domain.services import push_service
        await push_service.notify_user(
            db,
            user_id=suggestion.user_id,
            title="رد جديد على اقتراحك",
            body=body.body[:200],
            action="open_screen",
            action_payload="suggestions",
        )
    except Exception:  # noqa: BLE001
        await db.rollback()

    return ok(reply.model_dump(), message="تم إرسال الرد")


@router.get("/suggestions/{suggestion_id}/replies", summary="List replies for a suggestion")
async def list_suggestion_replies(
    suggestion_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    stmt = select(Suggestion).where(Suggestion.id == suggestion_id, ~Suggestion.is_deleted)
    suggestion = (await db.execute(stmt)).scalar_one_or_none()
    if not suggestion:
        raise HTTPException(status_code=404, detail="الاقتراح غير موجود")
    if suggestion.user_id != user_id:
        await require_platform_admin(user_id=user_id, db=db)
    service = SuggestionService(db)
    items = await service.list_replies(suggestion_id=suggestion_id)
    return ok([r.model_dump() for r in items])


@router.get("/suggestions/image/{filename}", summary="Serve a suggestion image")
async def serve_suggestion_image(
    filename: str,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    return await _serve_suggestion_file("image", filename, user_id, db)


@router.get("/suggestions/file/{kind}/{filename}", summary="Serve a suggestion media file (image/video/audio)")
async def serve_suggestion_file(
    kind: str,
    filename: str,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    return await _serve_suggestion_file(kind, filename, user_id, db)


async def _serve_suggestion_file(kind: str, filename: str, user_id: UUID, db: AsyncSession):
    dirs = {"image": UPLOAD_DIR, "video": VIDEO_DIR, "audio": AUDIO_DIR}
    cols = {
        "image": Suggestion.images,
        "video": Suggestion.videos,
        "audio": Suggestion.audios,
    }
    if kind not in dirs:
        raise HTTPException(status_code=400, detail="نوع الملف غير صالح")
    safe = os.path.basename(filename)
    if safe != filename:
        raise HTTPException(status_code=400, detail="Invalid filename")
    path = os.path.join(dirs[kind], safe)
    if not os.path.isfile(path):
        raise HTTPException(status_code=404, detail="الملف غير موجود")

    stmt = select(Suggestion).where(
        cast(cols[kind], String).like(f"%{safe}%")
    )
    suggestion = (await db.execute(stmt)).scalar_one_or_none()
    owner_id = suggestion.user_id if suggestion is not None else None
    if owner_id is None:
        # Admin replies store their media on SuggestionReply rows — without
        # this, user apps get 404 for every admin-sent image/video/audio.
        from app.domain.entities.suggestions_entities import SuggestionReply
        rcols = {
            "image": SuggestionReply.images,
            "video": SuggestionReply.videos,
            "audio": SuggestionReply.audios,
        }
        rstmt = select(SuggestionReply).where(
            cast(rcols[kind], String).like(f"%{safe}%")
        )
        reply = (await db.execute(rstmt)).scalar_one_or_none()
        if reply is None:
            raise HTTPException(status_code=404, detail="الملف غير موجود")
        owner_id = reply.user_id
    if owner_id != user_id:
        await require_platform_admin(user_id=user_id, db=db)

    return FileResponse(path)
