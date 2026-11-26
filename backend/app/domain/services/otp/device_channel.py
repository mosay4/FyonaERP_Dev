"""new_device approvals over the trusted-device channel.

FCM DATA message ``{type: 'login_approval', approval_id}`` (never the code;
the client renders a private notification) + an in-app notification row
with route ``/security/approvals?id=…``. The code itself is fetched by a
trusted device with a fresh key proof (POST /auth2/approvals/{id}/code).
"""

from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.auth2_entities import OtpChallenge
from app.domain.entities.auth_entities import User
from app.domain.entities.notification_entities import AppNotification


async def notify_approval(db: AsyncSession, ch: OtpChallenge) -> None:
    if ch.user_id is None:
        return
    org_id = (await db.execute(
        select(User.organization_id).where(User.id == ch.user_id))).scalar_one_or_none()
    if org_id is not None:
        event_id = f"login_approval:{ch.id}:{ch.resend_count}"
        exists = (await db.execute(select(AppNotification.id).where(
            AppNotification.organization_id == org_id,
            AppNotification.event_id == event_id))).first()
        if not exists:
            db.add(AppNotification(
                organization_id=org_id, user_id=ch.user_id, type="warning",
                title="محاولة تسجيل دخول من جهاز جديد",
                message="افتح التطبيق على جهازك الموثوق لعرض رمز الموافقة. "
                        "لا تشارك الرمز مع أي شخص.",
                action="open_screen", action_payload="security_approvals",
                is_system=True, is_read=False, domain="main",
                event_id=event_id, route=f"/security/approvals?id={ch.id}",
            ))
            await db.flush()
    from app.domain.services import push_service

    tokens = await push_service.tokens_for_users(db, [ch.user_id])
    if tokens:
        result = await push_service._send_data_push_bounded(
            tokens, data={"type": "login_approval", "approval_id": str(ch.id)})
        invalid = (result or {}).get("invalid_tokens") or []
        if invalid:
            await push_service.deactivate_tokens(db, invalid)
