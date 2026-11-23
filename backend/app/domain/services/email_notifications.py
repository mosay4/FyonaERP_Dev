"""Dispatch in-app notifications to email when the org enables email alerts."""

import re
from typing import Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.notification_entities import (
    AppNotification,
    NotificationPreference,
)
from app.domain.entities.auth_entities import User
from app.core import email_service, email_templates
from app.core.logging import get_logger

logger = get_logger("email_notifications")

_BLOCKED_DOMAINS = {"fyona.erp", "example.com", "test.com", "localhost"}


def _mail_ok(email: str) -> bool:
    """Quick sanity check: must look like a deliverable email address."""
    if not email or not isinstance(email, str):
        return False
    e = email.strip().lower()
    if not re.match(r'^[^@\s]+@[^@\s]+\.[a-zA-Z]{2,}$', e):
        return False
    domain = e.split('@')[-1]
    if domain in _BLOCKED_DOMAINS:
        return False
    return True


async def _email_enabled(db: AsyncSession, org_id) -> bool:
    stmt = (
        select(NotificationPreference)
        .where(NotificationPreference.organization_id == org_id)
        .order_by(NotificationPreference.created_at.desc())
    )
    pref = (await db.execute(stmt)).scalars().first()
    if pref is None:
        return True  # default: email alerts enabled
    return bool(pref.email_alerts)


async def _recipient_email(db: AsyncSession, user_id) -> Optional[str]:
    if user_id is None:
        return None
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalars().first()
    if not user or not user.email:
        return None
    if not _mail_ok(user.email):
        logger.warning("invalid_user_email_skipped", user_id=str(user_id), email=user.email)
        return None
    return user.email


async def dispatch_notification_email(
    db: AsyncSession, notification: AppNotification
) -> None:
    """Send an email copy of a notification if the org opted in.

    Non-fatal: failures are logged, never raised (email must not break
    the notification creation flow).
    """
    if not email_service.email_config.get("is_configured"):
        return
    email = await _recipient_email(db, notification.user_id)
    if not email:
        return
    if not await _email_enabled(db, notification.organization_id):
        return
    await email_service.send_email(
        to=email,
        subject=f"Fyona ERP — {notification.title}",
        html=email_templates.notification_email(
            notification.title, notification.message or ""
        ),
        text=notification.message or notification.title,
    )
