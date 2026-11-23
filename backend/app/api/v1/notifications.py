from datetime import datetime
from typing import Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy import and_, select, func, or_, update
from sqlalchemy.ext.asyncio import AsyncSession

from ...core.database import get_db
from ...api.deps import get_current_org_id, get_current_user_uuid, require_permission
from ...api.responses import ok, created, no_content, ok_paginated
from ...domain.entities.notification_entities import (
    AppNotification, NotificationPreference, Reminder,
)
from ...domain.models.notification_models import (
    NotificationResponse, NotificationPreferencesUpdate, NotificationPreferencesResponse,
    ReminderCreate, ReminderUpdate, ReminderResponse,
)

async def _notification_access(request: Request,
    user_id: UUID = Depends(get_current_user_uuid), db: AsyncSession = Depends(get_db)):
    # The account's personal system center remains available after unlink.
    # Only a selected merchant workspace inherits its employee restrictions.
    if not request.headers.get('X-Branch-Token'):
        return
    from ...domain.services.employee_access_policy import member_policy, allowed
    policy = await member_policy(db, request, user_id)
    if policy is not None and not allowed(policy, 'notifications'):
        raise HTTPException(403, detail='لا تملك صلاحية الإشعارات')


router = APIRouter(tags=["Notifications"], dependencies=[Depends(_notification_access)])

DEFAULT_PREFERENCES = {
    "email_alerts": True,
    "invoice_alerts": True,
    "payment_alerts": True,
    "system_updates": True,
    "budget_alerts": True,
    "low_balance_alerts": True,
    "daily_report": False,
    "weekly_report": False,
    "monthly_report": False,
}


# ══════════════════════════════════════════════════════════
#  NOTIFICATIONS
# ══════════════════════════════════════════════════════════

def _visible_to_user(org_id: UUID, user_id: UUID):
    """Visibility scope for notification reads.

    A reader sees rows addressed to them plus org-wide broadcasts
    (user_id NULL, e.g. platform fan-out). Rows targeted at OTHER users
    (e.g. an admin's copy of a subscriber's payment) are never visible —
    they previously leaked into every member's bell/badge via org-only
    filtering.
    """
    return (
        or_(
            # A notification addressed to THIS user is always theirs — even
            # when it originates from a company they were invited to (branch
            # invitations/transfers must reach the personal bell too).
            AppNotification.user_id == user_id,
            and_(
                AppNotification.organization_id == org_id,
                AppNotification.user_id.is_(None),
            ),
        ),
        # Commercial-debt/chat notifications live ONLY in their isolated
        # center; never in the main app notifications.
        or_(
            AppNotification.domain.is_(None),
            AppNotification.domain != "commercial_debt",
        ),
    )


@router.get("/notifications/unread-count", summary="Get unread notifications count")
async def get_unread_count(
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    scope = _visible_to_user(UUID(org_id), user_id)
    stmt = select(func.count(AppNotification.id)).where(
        *scope,
        ~AppNotification.is_read,
    )
    count = (await db.execute(stmt)).scalar() or 0
    return ok({"count": count}, "OK")


@router.get("/notifications", summary="List notifications")
async def list_notifications(
    page: int = Query(1, ge=1),
    per_page: int = Query(20, ge=1, le=100),
    unread_only: bool = False,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    scope = _visible_to_user(UUID(org_id), user_id)
    base = select(AppNotification).where(*scope)
    if unread_only:
        base = base.where(~AppNotification.is_read)

    count_q = select(func.count()).select_from(
        base.subquery()
    )
    total = (await db.execute(count_q)).scalar() or 0

    stmt = (
        base.order_by(AppNotification.created_at.desc())
        .offset((page - 1) * per_page)
        .limit(per_page)
    )
    items = (await db.execute(stmt)).scalars().all()
    return ok_paginated(
        [NotificationResponse.model_validate(i).model_dump() for i in items],
        total, page, per_page,
    )


@router.post("/notifications/{notification_id}/read", summary="Mark notification as read")
async def mark_notification_read(
    notification_id: UUID,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    scope = _visible_to_user(UUID(org_id), user_id)
    result = await db.execute(
        update(AppNotification)
        .where(
            AppNotification.id == notification_id,
            *scope,
        )
        .values(is_read=True)
    )
    if result.rowcount == 0:
        raise HTTPException(status_code=404, detail="الإشعار غير موجود")
    return ok(message="تم التحديد كمقروء")


@router.post("/notifications/read-all", summary="Mark all notifications as read")
async def mark_all_notifications_read(
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    scope = _visible_to_user(UUID(org_id), user_id)
    await db.execute(
        update(AppNotification)
        .where(
            *scope,
            ~AppNotification.is_read,
        )
        .values(is_read=True)
    )
    return ok(message="تم تحديد الكل كمقروء")


@router.post("/notifications/test", summary="Generate a test notification (for debugging)")
async def generate_test_notification(
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("notifications", "create")),
):
    from ...core.logging import get_logger as _get_logger

    _logger = _get_logger("notifications_api")
    notification = AppNotification(
        organization_id=UUID(org_id),
        user_id=user_id,
        type="info",
        title="إشعار تجريبي",
        message="هذا إشعار تجريبي للتأكد من عمل الإشعارات بشكل صحيح.",
        action="open_screen",
        action_payload="notifications",
    )
    db.add(notification)
    await db.flush()
    # Product rule: notification flows NEVER email (inbox + push only).
    # FCM push AFTER the DB row — guarded separately, never breaks creation.
    try:
        from ...domain.services import push_service as _push

        await _push.notify_user(
            db,
            user_id=user_id,
            title="إشعار تجريبي",
            body="هذا إشعار تجريبي للتأكد من عمل الإشعارات بشكل صحيح.",
            action="open_screen",
            action_payload="notifications",
        )
    except Exception as exc:  # noqa: BLE001
        _logger.warning("test_notification_push_failed", error=str(exc),
                        user_id=str(user_id), org_id=str(org_id))
    return created(message="تم إنشاء إشعار تجريبي")


# ══════════════════════════════════════════════════════════
#  NOTIFICATION PREFERENCES
# ══════════════════════════════════════════════════════════

@router.get("/notification-preferences", summary="Get notification preferences")
async def get_preferences(
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("notifications", "read")),
):
    stmt = select(NotificationPreference).where(
        NotificationPreference.organization_id == UUID(org_id)
    ).order_by(NotificationPreference.created_at.desc())
    pref = (await db.execute(stmt)).scalars().first()
    if pref is None:
        return ok(DEFAULT_PREFERENCES, "OK")
    return ok(
        NotificationPreferencesResponse.model_validate(pref).model_dump(),
        "OK",
    )


@router.put("/notification-preferences", summary="Update notification preferences")
async def update_preferences(
    data: NotificationPreferencesUpdate,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("notifications", "update")),
):
    stmt = select(NotificationPreference).where(
        NotificationPreference.organization_id == UUID(org_id)
    ).order_by(NotificationPreference.created_at.desc())
    pref = (await db.execute(stmt)).scalars().first()

    if pref is None:
        pref = NotificationPreference(
            organization_id=UUID(org_id),
            user_id=user_id,
            **DEFAULT_PREFERENCES,
        )
        db.add(pref)

    for field_name in DEFAULT_PREFERENCES:
        value = getattr(data, field_name)
        if value is not None:
            setattr(pref, field_name, value)

    await db.flush()
    return ok(
        NotificationPreferencesResponse.model_validate(pref).model_dump(),
        "تم حفظ الإعدادات",
    )


# ══════════════════════════════════════════════════════════
#  REMINDERS
# ══════════════════════════════════════════════════════════

@router.get("/reminders", summary="List reminders")
async def list_reminders(
    active_only: bool = False,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("notifications", "read")),
):
    base = select(Reminder).where(
        Reminder.organization_id == UUID(org_id)
    )
    if active_only:
        base = base.where(Reminder.is_active == True)  # noqa: E712
    stmt = base.order_by(Reminder.remind_at.asc())
    items = (await db.execute(stmt)).scalars().all()
    return ok(
        [ReminderResponse.model_validate(i).model_dump() for i in items],
        "OK",
    )


@router.post("/reminders", summary="Create reminder")
async def create_reminder(
    data: ReminderCreate,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("notifications", "create")),
):
    reminder = Reminder(
        organization_id=UUID(org_id),
        user_id=user_id,
        title=data.title,
        message=data.message,
        remind_at=data.remind_at,
        repeat=data.repeat,
    )
    db.add(reminder)
    await db.flush()
    return created(
        ReminderResponse.model_validate(reminder).model_dump(),
        "تم إنشاء التذكير",
    )


@router.patch("/reminders/{reminder_id}", summary="Update reminder")
async def update_reminder(
    reminder_id: UUID,
    data: ReminderUpdate,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("notifications", "update")),
):
    stmt = select(Reminder).where(
        Reminder.id == reminder_id,
        Reminder.organization_id == UUID(org_id),
    )
    reminder = (await db.execute(stmt)).scalars().first()
    if reminder is None:
        raise HTTPException(status_code=404, detail="التذكير غير موجود")

    if data.title is not None:
        reminder.title = data.title
    if data.message is not None:
        reminder.message = data.message
    if data.remind_at is not None:
        reminder.remind_at = data.remind_at
    if data.repeat is not None:
        reminder.repeat = data.repeat
    if data.is_active is not None:
        reminder.is_active = data.is_active

    await db.flush()
    return ok(
        ReminderResponse.model_validate(reminder).model_dump(),
        "تم تحديث التذكير",
    )


@router.delete("/reminders/{reminder_id}", summary="Delete reminder")
async def delete_reminder(
    reminder_id: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("notifications", "delete")),
):
    stmt = select(Reminder).where(
        Reminder.id == reminder_id,
        Reminder.organization_id == UUID(org_id),
    )
    reminder = (await db.execute(stmt)).scalars().first()
    if reminder is None:
        raise HTTPException(status_code=404, detail="التذكير غير موجود")
    await db.delete(reminder)
    return no_content("تم حذف التذكير")
