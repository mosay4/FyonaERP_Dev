"""Persist employment events in the main system notification center."""
from uuid import UUID
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from ..entities.auth_entities import User
from ..entities.notification_entities import AppNotification


async def save_employment_event(db: AsyncSession, *, recipient_id: UUID,
                                event_id: str, title: str, body: str,
                                route: str, image_url: str | None = None) -> AppNotification:
    recipient = (await db.execute(select(User).where(User.id == recipient_id))).scalar_one()
    row = (await db.execute(select(AppNotification).where(
        AppNotification.user_id == recipient_id,
        AppNotification.event_id == event_id))).scalar_one_or_none()
    if row is None:
        row = AppNotification(organization_id=recipient.organization_id,
            user_id=recipient_id, event_id=event_id)
        db.add(row)
    row.type = 'info'
    row.is_system = True
    row.domain = 'main'
    row.title = title
    row.message = body
    row.route = route
    row.image_url = image_url
    row.action = 'open_screen'
    row.action_payload = route
    row.is_read = False
    await db.flush()
    return row
