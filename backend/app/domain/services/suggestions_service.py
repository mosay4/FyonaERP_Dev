"""Suggestion service — create, list mine, admin review workflow."""

import asyncio
import os
import time
import uuid as uuid_lib
from datetime import datetime, timezone
from typing import Optional
from uuid import UUID

from fastapi import HTTPException, UploadFile
from sqlalchemy import (
    JSON,
    String,
    Text,
    case,
    cast,
    desc,
    false,
    func,
    literal,
    null,
    or_,
    select,
    update,
)
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.paths import UPLOAD_ROOT
from app.core.storage import unified_upload
from app.core.logging import get_logger

logger = get_logger(__name__)
from app.domain.entities.auth_entities import User, Organization
from app.domain.entities.suggestions_entities import Suggestion, SuggestionReply
from app.domain.models.suggestions_models import (
    SuggestionResponse,
    SuggestionAdminResponse,
    SuggestionUpdate,
    SuggestionReplyResponse,
    SuggestionConversationItem,
)

UPLOAD_DIR = os.path.join(UPLOAD_ROOT, "suggestion_images")
VIDEO_DIR = os.path.join(UPLOAD_ROOT, "suggestion_videos")
AUDIO_DIR = os.path.join(UPLOAD_ROOT, "suggestion_audios")
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}
ALLOWED_VIDEO_EXTENSIONS = {".mp4", ".mov", ".mkv", ".avi", ".webm", ".3gp", ".m4v"}
ALLOWED_AUDIO_EXTENSIONS = {".mp3", ".wav", ".m4a", ".aac", ".ogg", ".amr", ".opus", ".webm"}
MAX_IMAGES = 5
MAX_VIDEOS = 2
MAX_AUDIOS = 3

_CONTENT_TYPES = {
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
    ".webp": "image/webp", ".gif": "image/gif", ".bmp": "image/bmp",
    ".mp4": "video/mp4", ".mov": "video/quicktime", ".mkv": "video/x-matroska",
    ".avi": "video/x-msvideo", ".webm": "video/webm", ".3gp": "video/3gpp",
    ".m4v": "video/x-m4v",
    ".mp3": "audio/mpeg", ".wav": "audio/wav", ".m4a": "audio/mp4",
    ".aac": "audio/aac", ".ogg": "audio/ogg", ".amr": "audio/amr",
    ".opus": "audio/opus", ".webm": "audio/webm",
}


def _extension(filename: str, allowed: Optional[set] = None, fallback: str = ".jpg") -> str:
    ext = os.path.splitext(filename or "")[1].lower()
    return ext if ext in (allowed or ALLOWED_EXTENSIONS) else fallback


# While object storage is unreachable, skip the mirror instantly instead of
# burning seconds on retries per file (local disk already guarantees delivery).
_storage_down_until: float = 0.0


async def _save_file(upload: UploadFile, category: str, allowed: set, fallback: str) -> str:
    """Persist one uploaded file via unified storage and return the storage key."""
    ext = _extension(upload.filename, allowed, fallback)
    filename = f"{uuid_lib.uuid4().hex}{ext}"
    content = upload.file.read() if hasattr(upload.file, "read") else upload.content
    content_type = _CONTENT_TYPES.get(ext, "application/octet-stream")

    # Persist to local disk FIRST (always works, never fails)
    local_dir = os.path.join(UPLOAD_ROOT, category)
    os.makedirs(local_dir, exist_ok=True)
    with open(os.path.join(local_dir, filename), "wb") as f:
        f.write(content)

    # Mirror to MinIO/S3 as best-effort with a hard cap (never break or
    # stall the request if object storage is down — local disk already has it)
    global _storage_down_until
    if time.monotonic() < _storage_down_until:
        logger.warning("minio_mirror_skipped_down", category=category, filename=filename)
        return filename
    try:
        await asyncio.wait_for(
            unified_upload(category, filename, content, content_type),
            timeout=8,
        )
    except Exception:
        _storage_down_until = time.monotonic() + 300
        logger.warning("minio_upload_skipped", category=category, filename=filename)

    return filename


async def save_image(image: UploadFile) -> str:
    """Persist one uploaded image and return its stored filename."""
    return await _save_file(image, "suggestion_images", ALLOWED_EXTENSIONS, ".jpg")


async def save_video(video: UploadFile) -> str:
    return await _save_file(video, "suggestion_videos", ALLOWED_VIDEO_EXTENSIONS, ".mp4")


async def save_audio(audio: UploadFile) -> str:
    return await _save_file(audio, "suggestion_audios", ALLOWED_AUDIO_EXTENSIONS, ".m4a")


class SuggestionService:
    def __init__(self, db: AsyncSession):
        self._db = db

    # ── create ────────────────────────────────────────────────────────────
    async def create(self, *, user_id: UUID, org_id: Optional[UUID],
                     title: str, body: str, images: list,
                     videos: Optional[list] = None,
                     audios: Optional[list] = None) -> SuggestionResponse:
        body = (body or "").strip()
        title = (title or "").strip()
        if not body and not images and not (videos or []) and not (audios or []):
            raise HTTPException(status_code=400, detail="اكتب وصف الاقتراح أو أرفق ملفاً أولاً")
        if len(images) > MAX_IMAGES:
            raise HTTPException(status_code=400, detail="الحد الأقصى 5 صور")
        if len(videos or []) > MAX_VIDEOS:
            raise HTTPException(status_code=400, detail="الحد الأقصى فيديوهين")
        if len(audios or []) > MAX_AUDIOS:
            raise HTTPException(status_code=400, detail="الحد الأقصى 3 تسجيلات صوتية")

        suggestion = Suggestion(
            user_id=user_id,
            organization_id=org_id,
            title=title[:200],
            body=body[:5000],
            images=images,
            videos=list(videos or []),
            audios=list(audios or []),
            status="pending",
        )
        self._db.add(suggestion)
        await self._db.commit()
        await self._db.refresh(suggestion)
        return SuggestionResponse.from_entity(suggestion)

    # ── user's own suggestions ────────────────────────────────────────────
    async def list_mine(self, *, user_id: UUID) -> list:
        stmt = (
            select(Suggestion)
            .where(Suggestion.user_id == UUID(str(user_id)), ~Suggestion.is_deleted)
            .order_by(Suggestion.created_at.desc())
        )
        result = await self._db.execute(stmt)
        return [SuggestionResponse.from_entity(s) for s in result.scalars().all()]

    # ── admin: list all with user/org info ────────────────────────────────
    async def admin_list(self, *, status_filter: Optional[str] = None,
                         search: Optional[str] = None,
                         page: int = 1, per_page: int = 20) -> dict:
        conditions = [~Suggestion.is_deleted]
        if status_filter:
            conditions.append(Suggestion.status == status_filter)
        if search:
            conditions.append(
                Suggestion.body.ilike(f"%{search}%")
                | Suggestion.title.ilike(f"%{search}%")
            )

        total = (await self._db.execute(
            select(func.count()).select_from(Suggestion).where(*conditions)
        )).scalar_one()

        stmt = (
            select(Suggestion)
            .where(*conditions)
            .order_by(Suggestion.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        rows = (await self._db.execute(stmt)).scalars().all()

        # Collect referenced users + orgs in one query each.
        user_ids = {s.user_id for s in rows}
        org_ids = {s.organization_id for s in rows if s.organization_id}
        users = {}
        if user_ids:
            urows = (await self._db.execute(
                select(User).where(User.id.in_(user_ids))
            )).scalars().all()
            users = {u.id: u for u in urows}
        orgs = {}
        if org_ids:
            orows = (await self._db.execute(
                select(Organization).where(Organization.id.in_(org_ids))
            )).scalars().all()
            orgs = {o.id: o for o in orows}

        items = []
        for s in rows:
            u = users.get(s.user_id)
            org = orgs.get(s.organization_id) if s.organization_id else None
            r = SuggestionAdminResponse.from_entity(s)
            r.user_name = u.full_name if u else ""
            r.user_email = u.email if u else ""
            r.organization_name = org.name if org else None
            items.append(r.model_dump())

        return {
            "items": items,
            "total": total,
            "page": page,
            "per_page": per_page,
            "total_pages": max(1, (total + per_page - 1) // per_page),
        }

    # ── admin: update status/note ─────────────────────────────────────────
    async def admin_update(self, *, suggestion_id: UUID, update: SuggestionUpdate) -> SuggestionResponse:
        stmt = select(Suggestion).where(Suggestion.id == UUID(str(suggestion_id)), ~Suggestion.is_deleted)
        suggestion = (await self._db.execute(stmt)).scalar_one_or_none()
        if not suggestion:
            raise HTTPException(status_code=404, detail="الاقتراح غير موجود")
        suggestion.status = update.status
        if update.admin_note is not None:
            suggestion.admin_note = update.admin_note[:1000]
        await self._db.commit()
        await self._db.refresh(suggestion)
        return SuggestionResponse.from_entity(suggestion)

    # ── conversations (admin, grouped per user) ───────────────────────────
    async def admin_conversations(
        self, *, search: Optional[str] = None, page: int = 1,
        per_page: int = 20, status: Optional[str] = None,
    ) -> dict:
        """List conversation previews — one row per user (the owner of the
        suggestions), sorted by the most recent activity (suggestion or reply)."""
        sugg_dates_base = (
            select(
                Suggestion.user_id.label("user_id"),
                func.max(Suggestion.created_at).label("max_sugg"),
            )
            .where(~Suggestion.is_deleted)
            .group_by(Suggestion.user_id)
        )

        if search:
            s = f"%{search}%"
            matched = (
                select(User.id.label("id"))
                .where(or_(User.full_name.ilike(s), User.email.ilike(s)))
                .union(
                    select(Suggestion.user_id.label("id")).where(
                        ~Suggestion.is_deleted,
                        or_(Suggestion.title.ilike(s), Suggestion.body.ilike(s)),
                    )
                )
                .subquery()
            )
            sugg_dates_base = sugg_dates_base.where(
                Suggestion.user_id.in_(select(matched.c.id))
            )

        if status:
            # Keep only conversations whose user has at least one suggestion in
            # the requested status (used by the admin filter chips).
            status_sub = (
                select(Suggestion.user_id.label("id"))
                .where(~Suggestion.is_deleted, Suggestion.status == status)
                .subquery()
            )
            sugg_dates_base = sugg_dates_base.where(
                Suggestion.user_id.in_(select(status_sub.c.id))
            )

        sugg_dates = sugg_dates_base.subquery()

        reply_dates = (
            select(
                SuggestionReply.user_id.label("user_id"),
                func.max(SuggestionReply.created_at).label("max_rep"),
            )
            .where(~SuggestionReply.is_deleted)
            .group_by(SuggestionReply.user_id)
            .subquery()
        )

        unread_counts = (
            select(
                Suggestion.user_id.label("user_id"),
                func.count().label("unread_count"),
            )
            .where(~Suggestion.is_deleted, Suggestion.admin_read_at.is_(None))
            .group_by(Suggestion.user_id)
            .subquery()
        )

        unread_expr = func.coalesce(unread_counts.c.unread_count, 0)
        base = (
            select(
                sugg_dates.c.user_id.label("user_id"),
                # Portable GREATEST(max_sugg, coalesce(max_rep, max_sugg)):
                # SQLite lacks GREATEST so we express it as CASE.
                case(
                    (reply_dates.c.max_rep.is_(None), sugg_dates.c.max_sugg),
                    (
                        reply_dates.c.max_rep >= sugg_dates.c.max_sugg,
                        reply_dates.c.max_rep,
                    ),
                    else_=sugg_dates.c.max_sugg,
                ).label("last_ts"),
                unread_expr.label("unread_count"),
            )
            .outerjoin(reply_dates, reply_dates.c.user_id == sugg_dates.c.user_id)
            .outerjoin(unread_counts, unread_counts.c.user_id == sugg_dates.c.user_id)
            # Unread conversations float to the top, then by most recent activity.
            .order_by(
                case((unread_expr > 0, 1), else_=0).desc(),
                desc("last_ts"),
            )
        )

        total = (await self._db.execute(select(func.count()).select_from(base.subquery()))).scalar_one()
        rows = (await self._db.execute(base.offset((page - 1) * per_page).limit(per_page))).all()

        uuids = [r.user_id for r in rows]
        if not uuids:
            return {"items": [], "total": 0, "page": page, "per_page": per_page, "total_pages": 1}

        users = {}
        urows = (await self._db.execute(select(User).where(User.id.in_(uuids)))).scalars().all()
        users = {u.id: u for u in urows}

        latest_sugs = {}
        if uuids:
            max_sugg = (
                select(
                    Suggestion.user_id.label("user_id"),
                    func.max(Suggestion.created_at).label("max_ts"),
                )
                .where(Suggestion.user_id.in_(uuids), ~Suggestion.is_deleted)
                .group_by(Suggestion.user_id)
                .subquery()
            )
            ls_rows = (
                await self._db.execute(
                    select(Suggestion)
                    .join(
                        max_sugg,
                        (Suggestion.user_id == max_sugg.c.user_id)
                        & (Suggestion.created_at == max_sugg.c.max_ts),
                    )
                    .where(Suggestion.user_id.in_(uuids), ~Suggestion.is_deleted)
                )
            ).scalars().all()
            latest_sugs = {s.user_id: s for s in ls_rows}

        latest_reps = {}
        if uuids:
            max_rep = (
                select(
                    SuggestionReply.user_id.label("user_id"),
                    func.max(SuggestionReply.created_at).label("max_ts"),
                )
                .where(SuggestionReply.user_id.in_(uuids), ~SuggestionReply.is_deleted)
                .group_by(SuggestionReply.user_id)
                .subquery()
            )
            lr_rows = (
                await self._db.execute(
                    select(SuggestionReply)
                    .join(
                        max_rep,
                        (SuggestionReply.user_id == max_rep.c.user_id)
                        & (SuggestionReply.created_at == max_rep.c.max_ts),
                    )
                    .where(SuggestionReply.user_id.in_(uuids), ~SuggestionReply.is_deleted)
                )
            ).scalars().all()
            latest_reps = {r.user_id: r for r in lr_rows}

        counts = dict(
            (await self._db.execute(
                select(Suggestion.user_id, func.count())
                .where(Suggestion.user_id.in_(uuids), ~Suggestion.is_deleted)
                .group_by(Suggestion.user_id)
            )).all()
        )
        replied = set(
            (await self._db.execute(
                select(SuggestionReply.user_id)
                .where(SuggestionReply.user_id.in_(uuids), ~SuggestionReply.is_deleted)
                .distinct()
            )).scalars().all()
        )

        org_ids = {u.organization_id for u in users.values() if u.organization_id}
        orgs = {}
        if org_ids:
            orows = (await self._db.execute(select(Organization).where(Organization.id.in_(org_ids)))).scalars().all()
            orgs = {o.id: o for o in orows}

        items = []
        for r in rows:
            uid = r.user_id
            u = users.get(uid)
            last_s = latest_sugs.get(uid)
            last_r = latest_reps.get(uid)
            s_ts = last_s.created_at if last_s else None
            r_ts = last_r.created_at if last_r else None
            if r_ts is not None and (s_ts is None or r_ts >= s_ts):
                last_message = last_r.body or ""
                last_is_admin = True
                last_ts = r_ts
            else:
                last_message = (last_s.title or last_s.body) if last_s else ""
                last_is_admin = False
                last_ts = s_ts
            org_name = None
            if u and u.organization_id and orgs.get(u.organization_id):
                org_name = orgs[u.organization_id].name
            items.append(
                SuggestionConversationItem(
                    user_id=str(uid),
                    user_name=u.full_name if u else "",
                    user_email=u.email if u else "",
                    organization_name=org_name,
                    last_message=last_message,
                    last_is_from_admin=last_is_admin,
                    last_message_at=last_ts.isoformat() if last_ts else None,
                    unread_count=int(r.unread_count or 0),
                    has_reply=uid in replied,
                    suggestions_count=int(counts.get(uid, 0)),
                    last_status=last_s.status if last_s else "pending",
                )
            )

        return {
            "items": [i.model_dump() for i in items],
            "total": total,
            "page": page,
            "per_page": per_page,
            "total_pages": max(1, (total + per_page - 1) // per_page),
        }

    async def conversation_messages(
        self, *, user_id: UUID, page: int = 1, per_page: int = 20
    ) -> dict:
        """Merged chronological stream of the user's suggestions + admin replies."""
        uid = UUID(str(user_id))
        sugg_stmt = (
            select(
                Suggestion.id.label("id"),
                literal("suggestion").label("kind"),
                Suggestion.user_id.label("user_id"),
                Suggestion.id.label("suggestion_id"),
                Suggestion.title.label("title"),
                Suggestion.body.label("body"),
                Suggestion.images.label("images"),
                Suggestion.videos.label("videos"),
                Suggestion.audios.label("audios"),
                Suggestion.status.label("status"),
                Suggestion.admin_note.label("admin_note"),
                false().label("is_from_admin"),
                Suggestion.created_at.label("created_at"),
                Suggestion.created_at.label("updated_at"),
                false().label("is_edited"),
            )
            .where(Suggestion.user_id == uid, ~Suggestion.is_deleted)
        )
        reply_stmt = (
            select(
                SuggestionReply.id.label("id"),
                literal("reply").label("kind"),
                SuggestionReply.user_id.label("user_id"),
                SuggestionReply.suggestion_id.label("suggestion_id"),
                cast(null(), String).label("title"),
                SuggestionReply.body.label("body"),
                SuggestionReply.images.label("images"),
                SuggestionReply.videos.label("videos"),
                SuggestionReply.audios.label("audios"),
                literal("pending").label("status"),
                cast(null(), Text).label("admin_note"),
                (SuggestionReply.admin_id.isnot(None)).label("is_from_admin"),
                SuggestionReply.created_at.label("created_at"),
                SuggestionReply.updated_at.label("updated_at"),
                SuggestionReply.is_edited.label("is_edited"),
            )
            .where(SuggestionReply.user_id == uid, ~SuggestionReply.is_deleted)
        )
        merged = sugg_stmt.union_all(reply_stmt).subquery()
        total = (await self._db.execute(select(func.count()).select_from(merged))).scalar_one()
        rows = (
            await self._db.execute(
                select(merged)
                .order_by(desc(merged.c.created_at))
                .offset((page - 1) * per_page)
                .limit(per_page)
            )
        ).all()

        items = []
        for row in rows:
            items.append(
                {
                    "id": str(row.id),
                    "kind": row.kind,
                    "user_id": str(row.user_id),
                    "suggestion_id": str(row.suggestion_id),
                    "title": row.title or "",
                    "body": row.body or "",
                    "images": list(row.images or []),
                    "videos": list(row.videos or []),
                    "audios": list(row.audios or []),
                    "status": row.status or "pending",
                    "admin_note": row.admin_note,
                    "is_from_admin": bool(row.is_from_admin),
                    "created_at": row.created_at.isoformat() if row.created_at else None,
                    "updated_at": (row.updated_at or row.created_at).isoformat()
                    if (row.updated_at or row.created_at) else None,
                    "is_edited": bool(row.is_edited),
                }
            )

        return {
            "items": items,
            "total": total,
            "page": page,
            "per_page": per_page,
            "total_pages": max(1, (total + per_page - 1) // per_page),
        }

    async def mark_conversation_read(self, *, user_id: UUID) -> None:
        """Mark all suggestions of this user as read by the admin."""
        from datetime import datetime, timezone

        uid = UUID(str(user_id))
        await self._db.execute(
            update(Suggestion)
            .where(
                Suggestion.user_id == uid,
                ~Suggestion.is_deleted,
                Suggestion.admin_read_at.is_(None),
            )
            .values(admin_read_at=datetime.now(timezone.utc))
        )
        await self._db.commit()

    async def latest_suggestion(self, *, user_id: UUID) -> Optional[Suggestion]:
        """The most recent non-deleted suggestion of a user (used to pick the
        suggestion that a reply should attach to)."""
        stmt = (
            select(Suggestion)
            .where(Suggestion.user_id == UUID(str(user_id)), ~Suggestion.is_deleted)
            .order_by(Suggestion.created_at.desc())
            .limit(1)
        )
        return (await self._db.execute(stmt)).scalar_one_or_none()

    async def resolve_reply_target(self, *, user_id: UUID,
                                   suggestion_id: Optional[str] = None) -> Suggestion:
        """The ticket an admin reply attaches to: the explicitly selected
        ticket when given (and owned by this user), else the latest one."""
        if suggestion_id:
            try:
                sid = UUID(str(suggestion_id))
            except (ValueError, TypeError, AttributeError):
                raise HTTPException(status_code=400, detail="معرف التذكرة غير صالح")
            stmt = select(Suggestion).where(
                Suggestion.id == sid,
                Suggestion.user_id == UUID(str(user_id)),
                ~Suggestion.is_deleted,
            )
            suggestion = (await self._db.execute(stmt)).scalar_one_or_none()
            if not suggestion:
                raise HTTPException(status_code=404, detail="التذكرة غير موجودة")
            return suggestion
        suggestion = await self.latest_suggestion(user_id=user_id)
        if not suggestion:
            raise HTTPException(status_code=404, detail="لا توجد اقتراحات لهذا المستخدم")
        return suggestion

    # ── replies ──────────────────────────────────────────────────────────
    async def add_reply(self, *, suggestion_id: UUID, user_id: UUID,
                        admin_id: Optional[UUID], body: str,
                        images: Optional[list] = None,
                        videos: Optional[list] = None,
                        audios: Optional[list] = None) -> SuggestionReplyResponse:
        stmt = select(Suggestion).where(
            Suggestion.id == UUID(str(suggestion_id)), ~Suggestion.is_deleted
        )
        suggestion = (await self._db.execute(stmt)).scalar_one_or_none()
        if not suggestion:
            raise HTTPException(status_code=404, detail="الاقتراح غير موجود")
        body = (body or "").strip()
        if not body and not images and not videos and not audios:
            raise HTTPException(status_code=400, detail="اكتب نص الرد أو أرفق ملفاً أولاً")
        reply = SuggestionReply(
            suggestion_id=UUID(str(suggestion_id)),
            user_id=UUID(str(user_id)),
            admin_id=UUID(str(admin_id)) if admin_id else None,
            body=body[:5000],
            images=images or [],
            videos=videos or [],
            audios=audios or [],
        )
        suggestion.admin_read_at = suggestion.admin_read_at or datetime.now(timezone.utc)
        self._db.add(reply)
        await self._db.commit()
        await self._db.refresh(reply)
        return SuggestionReplyResponse.from_entity(reply)

    async def list_replies(self, *, suggestion_id: UUID) -> list:
        stmt = (
            select(SuggestionReply)
            .where(
                SuggestionReply.suggestion_id == UUID(str(suggestion_id)),
                ~SuggestionReply.is_deleted,
            )
            .order_by(SuggestionReply.created_at.asc())
        )
        rows = (await self._db.execute(stmt)).scalars().all()
        return [SuggestionReplyResponse.from_entity(r) for r in rows]

    # ── edit / delete messages ───────────────────────────────────────
    EDIT_WINDOW_SECONDS = 24 * 3600

    def _edit_window_open(self, created_at) -> bool:
        if not created_at:
            return False
        now = datetime.now(timezone.utc)
        ts = created_at
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        return (now - ts).total_seconds() <= self.EDIT_WINDOW_SECONDS

    async def edit_reply(self, *, message_id: UUID, user_id: UUID,
                         body: str, is_admin: bool) -> SuggestionReplyResponse:
        """Edit a message's text. Owners may edit their own messages within
        24h; platform admins may edit any message (moderation, no window)."""
        from app.domain.entities.suggestions_entities import SuggestionReply as ReplyEntity
        stmt = select(ReplyEntity).where(
            ReplyEntity.id == UUID(str(message_id)),
            ~ReplyEntity.is_deleted,
        )
        reply = (await self._db.execute(stmt)).scalar_one_or_none()
        if not reply:
            raise HTTPException(status_code=404, detail="الرسالة غير موجودة")
        body = (body or "").strip()
        if not body:
            raise HTTPException(status_code=400, detail="نص الرسالة فارغ")
        if not is_admin:
            if reply.user_id != UUID(str(user_id)):
                raise HTTPException(status_code=403, detail="لا يمكنك تعديل رسالة ليست لك")
            if not self._edit_window_open(reply.created_at):
                raise HTTPException(
                    status_code=403,
                    detail="انتهت مهلة التعديل (24 ساعة من إرسال الرسالة)",
                )
        reply.body = body[:5000]
        reply.is_edited = True
        reply.updated_at = datetime.now(timezone.utc)
        await self._db.commit()
        await self._db.refresh(reply)
        return SuggestionReplyResponse.from_entity(reply)

    async def delete_reply(self, *, message_id: UUID, user_id: UUID,
                           is_admin: bool) -> None:
        """Hard-delete a message so it disappears on both sides. Owners may
        delete their own messages within 24h; platform admins anytime."""
        from app.domain.entities.suggestions_entities import SuggestionReply as ReplyEntity
        stmt = select(ReplyEntity).where(
            ReplyEntity.id == UUID(str(message_id)),
            ~ReplyEntity.is_deleted,
        )
        reply = (await self._db.execute(stmt)).scalar_one_or_none()
        if not reply:
            raise HTTPException(status_code=404, detail="الرسالة غير موجودة")
        if not is_admin:
            if reply.user_id != UUID(str(user_id)):
                raise HTTPException(status_code=403, detail="لا يمكنك حذف رسالة ليست لك")
            if not self._edit_window_open(reply.created_at):
                raise HTTPException(
                    status_code=403,
                    detail="انتهت مهلة الحذف (24 ساعة من إرسال الرسالة)",
                )
        await self._db.delete(reply)
        await self._db.commit()
