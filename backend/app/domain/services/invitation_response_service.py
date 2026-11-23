"""Transactional system notification and post-commit push for invite replies."""
from uuid import NAMESPACE_URL, uuid5

from sqlalchemy import select

from app.domain.entities.auth_entities import User
from app.domain.entities.notification_entities import AppNotification
from app.domain.entities.branch_entities import BranchMember
import logging
from app.domain.services import push_service


async def emit(db, *, org_id, inviter_id, event_id, message, route):
    if not inviter_id:
        return None
    inviter = (await db.execute(select(User).where(
        User.id == inviter_id, User.status == 'active',
    ))).scalar_one_or_none()
    if inviter is None:
        return None
    if inviter.organization_id != org_id:
        member = (await db.execute(select(BranchMember).where(
            BranchMember.organization_id == org_id, BranchMember.user_id == inviter_id,
            BranchMember.status == 'active'))).scalar_one_or_none()
        if member is None: return None
    source_id = uuid5(NAMESPACE_URL, f"fyona:{event_id}:{inviter_id}")
    existing = (await db.execute(select(AppNotification.id).where(
        AppNotification.user_id == inviter_id,
        AppNotification.source_notif_id == source_id,
    ))).scalar_one_or_none()
    if existing:
        return None
    title = "رد على دعوتك"
    db.add(AppNotification(
        organization_id=inviter.organization_id or org_id, user_id=inviter_id,
        source_notif_id=source_id, event_id=event_id, domain="main",
        is_system=True, type="info", title=title, message=message,
        action="open_screen", action_payload=route, route=route,
    ))
    await db.flush()
    return {"user_id": inviter_id, "title": title, "body": message,
            "action_payload": route}


async def deliver(db, push):
    if push:
        result = await push_service.push_to_users_now(db, [push['user_id']], title=push['title'],
            body=push['body'], action_payload=push['action_payload'], log_type='invitation_response')
        logging.getLogger('invitation.delivery').info('invitation_response_delivery sent=%s failed=%s',
            (result or {}).get('sent', 0), (result or {}).get('failed', 0))
