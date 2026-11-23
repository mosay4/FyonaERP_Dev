"""Live session check for the opt-in Business transports."""

from datetime import datetime, timezone
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import load_only

from app.domain.entities.auth_entities import User, UserSession


SESSION_STATE = (UserSession.id, UserSession.user_id, UserSession.is_active,
                 UserSession.created_at, UserSession.expires_at)


def session_disabled(session, user, actor: UUID) -> bool:
    return (
        session is None or session.user_id != actor or not session.is_active
        or user is None or user.status != "active"
        or (user.tokens_valid_after is not None
            and (session.created_at is None or session.created_at < user.tokens_valid_after))
    )


async def lock_live_user(db: AsyncSession, actor: UUID, sid: UUID | None) -> User | None:
    if sid is None:
        return None
    lock = {"with_for_update": {"read": True}, "populate_existing": True}
    # Auth sign-out with a global kick writes the session before the user.
    session = (await db.execute(select(*SESSION_STATE).where(
        UserSession.id == sid,
    ).with_for_update(read=True))).one_or_none()
    user = await db.get(User, actor, options=[load_only(
        User.id, User.status, User.tokens_valid_after, User.email, User.role, User.organization_id,
    )], **lock)
    if session_disabled(session, user, actor) or session.expires_at <= datetime.now(timezone.utc):
        return None
    return user
