"""Live merchant entitlement and idempotent employee renewal notifications."""
from uuid import NAMESPACE_URL, uuid5

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from ..entities.auth_entities import Organization, User
from ..entities.branch_entities import BranchMember
from ..entities.employee_workspace_entities import EmployeeWorkspace
from ..entities.employee_workspace_entities import EmployeeInvitation
from ..entities.notification_entities import AppNotification
from .section_entitlements import access_snapshot, subscriptions
from .push_service import notify_user


def owner_subscription_fields(org, *, trial_allowed=True):
    section = access_snapshot(org, trial_allowed=trial_allowed)['sections']['business']
    entries = subscriptions(org)
    plan = section['plan'] or ('premium' if 'premium' in entries else 'business')
    entry = entries.get(plan, {})
    end = section['end_date'] or entry.get('end_date')
    return {
        'owner_subscription_status': entry.get('status', org.subscription_status),
        'owner_subscription_plan': plan if plan in entries or section['active'] else org.subscription_plan,
        'owner_subscription_end_date': end or (org.subscription_end_date.isoformat() if org.subscription_end_date else None),
        'owner_expired': not section['active'],
    }


def require_merchant_subscription(org, *, trial_allowed=True):
    if org is None or owner_subscription_fields(org, trial_allowed=trial_allowed)['owner_expired']:
        raise HTTPException(403, detail={
            'code': 'merchant_subscription_expired',
            'message': 'اشتراك مالك المتجر منتهٍ أو غير نشط؛ يرجى تجديد الاشتراك للعودة إلى مساحة العمل',
        })


async def notify_merchant_renewal(db, org):
    """Call after activation commit; one row/push per employee and paid period.

    The existing source-id unique constraint protects concurrent activation
    callbacks. A savepoint leaves the caller's transaction intact on a race.
    """
    if not isinstance(org, Organization) or owner_subscription_fields(org)['owner_expired']:
        return
    section = access_snapshot(org)['sections']['business']
    from .merchant_identity_service import business_identity
    identity = await business_identity(db, org.id)
    members = (await db.execute(select(EmployeeWorkspace, User).join(
        User, User.id == EmployeeWorkspace.linked_user_id).join(BranchMember,
        (BranchMember.user_id == User.id) &
        (BranchMember.organization_id == EmployeeWorkspace.organization_id)).where(
        EmployeeWorkspace.organization_id == org.id,
        BranchMember.status == 'active', User.status == 'active'))).all()
    for workspace, user in members:
        source = uuid5(NAMESPACE_URL, f'merchant-renewal:{org.id}:{user.id}:{section["end_date"]}')
        if await db.scalar(select(AppNotification.id).where(
                AppNotification.organization_id == user.organization_id,
                AppNotification.source_notif_id == source)):
            continue
        invitation = (await db.execute(select(EmployeeInvitation).where(
            EmployeeInvitation.employee_id == workspace.employee_id,
            EmployeeInvitation.invited_user_id == user.id,
            EmployeeInvitation.status == 'accepted').order_by(EmployeeInvitation.created_at.desc()))).scalars().first()
        route = f'/job-requests?invite={invitation.id}' if invitation else '/job-requests'
        title = 'تم تجديد اشتراك المتجر'
        body = f'تم تفعيل اشتراك {identity["name"]}؛ يمكنك العودة إلى مساحة العمل'
        try:
            async with db.begin_nested():
                db.add(AppNotification(organization_id=user.organization_id,
                    user_id=user.id, source_notif_id=source, event_id=f'merchant-renewal:{source}',
                    title=title, message=body, type='success', is_system=True, domain='main',
                    action='open_screen', action_payload=route, route=route,
                    image_url=identity['photo_url']))
                await db.flush()
        except IntegrityError:
            continue
        await db.commit()
        await notify_user(db, user_id=user.id, title=title, body=body,
                          action='open_screen', action_payload=route, image_url=identity['photo_url'])
