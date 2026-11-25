import asyncio
import threading
from datetime import datetime, timezone, timedelta
from decimal import Decimal

from sqlalchemy import select, update, func, and_
from sqlalchemy.dialects.postgresql import insert as pg_insert

from .celery_app import celery
from app.core.database import async_session_factory
from app.core.logging import get_logger
from app.domain.entities.notification_entities import (
    AppNotification, NotificationPreference, Reminder,
)
from app.domain.entities.admin_entities import PlatformNotification
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.finance_entities import BankAccount
from app.domain.entities.personal_entities import (
    PersonalBankAccount, PersonalBudget,
)
from app.core import email_service, email_templates

logger = get_logger("tasks")

_loop_local = threading.local()


def _get_loop() -> asyncio.AbstractEventLoop:
    loop = getattr(_loop_local, "loop", None)
    if loop is None or loop.is_closed():
        loop = asyncio.new_event_loop()
        _loop_local.loop = loop
    return loop


def _run_async(coro) -> any:
    """Run a coroutine on a single persistent loop per worker thread.

    Using asyncio.run() here creates a brand-new event loop per task, while the
    shared asyncpg engine binds its pooled connections to the first loop that
    touched them -> "Task attached to a different loop" failures on the next
    scheduled run. Reusing one loop per thread keeps the pool consistent.
    """
    return _get_loop().run_until_complete(coro)


def _utcnow():
    return datetime.now(timezone.utc)


async def _create_notification(session, org_id, user_id, type_, title, message,
                               action=None, action_payload=None):
    notification = AppNotification(
        organization_id=org_id,
        user_id=user_id,
        type=type_,
        title=title,
        message=message,
        action=action,
        action_payload=action_payload,
    )
    session.add(notification)
    # NOTE (product rule): notification flows NEVER email users. The inbox
    # row + device push are the delivery channels; email is reserved for
    # transactional auth mail (password/verify/signup) elsewhere.
    return notification


async def _has_notification_today(session, org_id, type_, payload_substring):
    today_start = _utcnow().replace(hour=0, minute=0, second=0, microsecond=0)
    stmt = select(func.count(AppNotification.id)).where(
        AppNotification.organization_id == org_id,
        AppNotification.type == type_,
        AppNotification.created_at >= today_start,
    )
    if payload_substring:
        stmt = stmt.where(AppNotification.action_payload.contains(payload_substring))
    count = (await session.execute(stmt)).scalar() or 0
    return count > 0


# ── Platform notification fan-out ──


_TYPE_MAP = {
    "info": "info",
    "warning": "warning",
    "success": "success",
    "error": "warning",
    "announcement": "info",
    "update": "info",
    "alert": "warning",
    "maintenance": "warning",
}


async def _fanout_platform_notification(notif_id, is_system: bool = True, send_email: bool = False, action_payload: str = "notifications"):
    """Copy a platform admin notification to organizations per its target.

    Target enforcement (reads ``PlatformNotification.target``):
    - ``all`` (or empty/unknown): every active org (legacy behavior).
    - ``users``: only orgs with at least one active NON-platform-admin member
      ("user orgs"); emails go to regular members only.
    - ``admins``: only orgs with at least one active platform-admin member
      ("admin orgs"); emails go to platform admins only.
    A SPECIFIC target never falls back to notifying everyone.

    Idempotency: uses source_notif_id (the originating PlatformNotification.id)
    as the identity key.  A unique constraint on
    (organization_id, source_notif_id) guarantees that re-executing or
    concurrently executing the fanout for the same notification + org cannot
    produce duplicate AppNotification records.

    ``send_email=False`` (the default — product rule: notification flows
    NEVER email users) creates only the in-app rows. Email stays reserved
    for transactional auth mail elsewhere. The ``send_email`` flag remains
    for explicit opt-in callers only.

    ``action_payload`` (e.g. 'maintenance-feature' / 'maintenance-section')
    is stamped on every row so the app can distinguish in-app-only rows from
    device-visible ones.
    """
    import uuid as _uuid

    try:
        nid = _uuid.UUID(str(notif_id))
    except (ValueError, AttributeError):
        return {"status": "invalid_id", "notif_id": str(notif_id)}

    dispatched = 0
    emailed = 0
    skipped = 0
    async with async_session_factory() as session:
        stmt = select(PlatformNotification).where(PlatformNotification.id == nid)
        notif = (await session.execute(stmt)).scalars().first()
        if notif is None:
            return {"status": "not_found", "notif_id": str(notif_id)}

        type_ = _TYPE_MAP.get(notif.type or "info", "info")
        try:
            target = str(notif.target or "all").strip().lower()
        except Exception:
            target = "all"
        if target not in ("all", "users", "admins"):
            target = "all"

        all_orgs = (await session.execute(
            select(Organization).where(Organization.is_active == True)  # noqa: E712
        )).scalars().all()

        # Map the target to orgs via the Organization/admin schema:
        # an "admin org" hosts ≥1 active platform admin; a "user org" hosts
        # ≥1 active regular member.  An org with both audiences receives both
        # broadcasts; a pure-user org never receives admins-only.
        if target == "admins":
            try:
                admin_org_rows = await session.execute(
                    select(User.organization_id).where(
                        User.is_platform_admin.is_(True),
                        User.status == "active",
                    ).distinct()
                )
                wanted = {r for r in admin_org_rows.scalars().all() if r is not None}
            except Exception as exc:  # noqa: BLE001
                logger.warning("fanout_admin_orgs_lookup_failed", error=str(exc))
                wanted = set()
            orgs = [o for o in all_orgs if o.id in wanted]
        elif target == "users":
            try:
                user_org_rows = await session.execute(
                    select(User.organization_id).where(
                        User.is_platform_admin.is_not(True),
                        User.status == "active",
                    ).distinct()
                )
                wanted = {r for r in user_org_rows.scalars().all() if r is not None}
            except Exception as exc:  # noqa: BLE001
                logger.warning("fanout_user_orgs_lookup_failed", error=str(exc))
                wanted = set()
            orgs = [o for o in all_orgs if o.id in wanted]
        else:
            orgs = list(all_orgs)

        for org in orgs:
            existing = (await session.execute(
                select(func.count(AppNotification.id)).where(
                    AppNotification.organization_id == org.id,
                    AppNotification.source_notif_id == nid,
                )
            )).scalar() or 0
            if existing > 0:
                skipped += 1
                continue

            insert_stmt = pg_insert(AppNotification).values(
                organization_id=org.id,
                user_id=None,
                source_notif_id=nid,
                type=type_,
                title=notif.title,
                message=notif.message,
                action="open_screen",
                action_payload=action_payload,
                is_system=is_system,
            ).on_conflict_do_nothing(
                index_elements=["organization_id", "source_notif_id"]
            )
            await session.execute(insert_stmt)
            dispatched += 1

            # Audience-scoped email recipients: admins-only reaches platform
            # admins, users-only reaches regular members, all reaches everyone.
            _user_stmt = select(User).where(
                User.organization_id == org.id,
                User.email_verified == True,  # noqa: E712
                User.status == "active",
            )
            if target == "admins":
                _user_stmt = _user_stmt.where(User.is_platform_admin.is_(True))
            elif target == "users":
                _user_stmt = _user_stmt.where(User.is_platform_admin.is_not(True))
            users = (await session.execute(_user_stmt)).scalars().all()
            if send_email:
                for u in users:
                    try:
                        await email_service.send_email(
                            to=u.email,
                            subject=f"Fyona ERP — {notif.title}",
                            html=email_templates.notification_email(
                                notif.title, notif.message or ""
                            ),
                            text=notif.message or notif.title,
                        )
                        emailed += 1
                    except Exception as exc:  # noqa: BLE001
                        logger.warning("fanout_email_failed", error=str(exc),
                                       org_id=str(org.id))

        await session.commit()
    return {
        "status": "completed",
        "target": target,
        "notifications_dispatched": dispatched,
        "emails_sent": emailed,
        "skipped_duplicate": skipped,
    }


# ── Reminders ──


async def _process_due_reminders():
    now = _utcnow()
    created = 0
    push_jobs: list[dict] = []
    async with async_session_factory() as session:
        stmt = select(Reminder).where(
            Reminder.is_active == True,  # noqa: E712
            Reminder.remind_at <= now,
        ).limit(500)
        reminders = (await session.execute(stmt)).scalars().all()

        for r in reminders:
            _title = f"تذكير: {r.title}"
            _body = r.message or r.title
            await _create_notification(
                session, r.organization_id, r.user_id,
                type_="reminder",
                title=_title,
                message=_body,
                action="open_screen",
                action_payload="reminders",
            )
            r.last_triggered_at = now
            if r.repeat == "none":
                r.is_active = False
            elif r.repeat == "daily":
                r.remind_at = r.remind_at + timedelta(days=1)
            elif r.repeat == "weekly":
                r.remind_at = r.remind_at + timedelta(weeks=1)
            elif r.repeat == "monthly":
                next_month = r.remind_at + timedelta(days=30)
                r.remind_at = next_month
            created += 1
            # Existing user/org context reused for the push; the dedup guard
            # above (due + repeat state) already decided this fires.
            push_jobs.append({
                "org_id": r.organization_id,
                "user_id": r.user_id,
                "title": _title,
                "body": _body,
                "action_payload": "reminders",
            })

        await session.commit()

        # FCM pushes AFTER the DB rows are durable — each guarded separately
        # with a clear log, never bare except, never breaking the batch.
        # Awaited (not fire-and-forget): the worker loop owns this coroutine.
        for job in push_jobs:
            try:
                from app.domain.services import push_service as _push

                if job["user_id"]:
                    await _push.push_to_users_now(
                        session, [job["user_id"]],
                        title=job["title"], body=job["body"],
                        action="open_screen",
                        action_payload=job["action_payload"],
                        log_type="reminder",
                    )
                else:
                    await _push.push_to_org_now(
                        session, job["org_id"],
                        title=job["title"], body=job["body"],
                        action="open_screen",
                        action_payload=job["action_payload"],
                        log_type="reminder",
                    )
            except Exception as exc:  # noqa: BLE001
                logger.warning("reminder_push_failed", error=str(exc),
                               type="reminder")
    return {"status": "completed", "reminders_triggered": created}


# ── Periodic Reports ──


async def _get_report_subscribers(session, field_name):
    stmt = select(NotificationPreference.organization_id).where(
        getattr(NotificationPreference, field_name) == True  # noqa: E712
    )
    return list((await session.execute(stmt)).scalars().unique())


async def _generate_report(kind: str):
    field_name = f"{kind}_report"
    push_jobs: list[dict] = []
    async with async_session_factory() as session:
        orgs = await _get_report_subscribers(session, field_name)
        produced = 0
        for org_id in orgs:
            if await _has_notification_today(session, org_id, "report", f"report:{kind}"):
                continue
            _title = "تقريرك المالي الدوري"
            _body = f"جهّزنا لك تقرير {kind} المالي. افتحه من شاشة التقارير."
            _payload = f"report:{kind}"
            await _create_notification(
                session, org_id, None,
                type_="report",
                title=_title,
                message=_body,
                action="open_screen",
                action_payload=_payload,
            )
            produced += 1
            push_jobs.append({
                "org_id": org_id, "title": _title, "body": _body,
                "action_payload": _payload,
            })
        await session.commit()

        for job in push_jobs:
            try:
                from app.domain.services import push_service as _push

                await _push.push_to_org_now(
                    session, job["org_id"],
                    title=job["title"], body=job["body"],
                    action="open_screen",
                    action_payload=job["action_payload"],
                    log_type="report",
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("report_push_failed", error=str(exc),
                               type="report", kind=str(kind))
    return {"status": "completed", "reports_generated": produced}


# ── Low Balance Alerts ──


async def _check_low_balance():
    now = _utcnow()
    triggered = 0
    push_jobs: list[dict] = []
    async with async_session_factory() as session:
        # Personal accounts
        pstmt = select(PersonalBankAccount).where(PersonalBankAccount.is_deleted == False)  # noqa: E712
        paccounts = (await session.execute(pstmt)).scalars().all()
        for acc in paccounts:
            if acc.balance is not None and Decimal(str(acc.balance)) <= 0:
                if await _has_notification_today(session, acc.user_id, "warning", str(acc.id)):
                    continue
                _title = "رصيد منخفض"
                _body = f"رصيد حسابك ({acc.bank_name}) وصل إلى 0 ريال أو أقل."
                _payload = str(acc.id)
                await _create_notification(
                    session, acc.user_id, acc.user_id,
                    type_="warning",
                    title=_title,
                    message=_body,
                    action="open_screen",
                    action_payload=_payload,
                )
                triggered += 1
                push_jobs.append({
                    "kind": "user", "user_id": acc.user_id,
                    "title": _title, "body": _body,
                    "action_payload": _payload,
                })

        # Business accounts
        bstmt = select(BankAccount).where(BankAccount.is_deleted == False)  # noqa: E712
        baccounts = (await session.execute(bstmt)).scalars().all()
        for acc in baccounts:
            if acc.balance is not None and Decimal(str(acc.balance)) <= 0:
                if await _has_notification_today(session, acc.organization_id, "warning", str(acc.id)):
                    continue
                _title = "رصيد بنكي منخفض"
                _body = f"رصيد الحساب البنكي ({acc.account_name}) وصل إلى 0 أو أقل."
                _payload = str(acc.id)
                await _create_notification(
                    session, acc.organization_id, None,
                    type_="warning",
                    title=_title,
                    message=_body,
                    action="open_screen",
                    action_payload=_payload,
                )
                triggered += 1
                push_jobs.append({
                    "kind": "org", "org_id": acc.organization_id,
                    "title": _title, "body": _body,
                    "action_payload": _payload,
                })

        await session.commit()

        for job in push_jobs:
            try:
                from app.domain.services import push_service as _push

                if job.get("kind") == "user":
                    await _push.push_to_users_now(
                        session, [job["user_id"]],
                        title=job["title"], body=job["body"],
                        action="open_screen",
                        action_payload=job["action_payload"],
                        log_type="low_balance",
                    )
                else:
                    await _push.push_to_org_now(
                        session, job["org_id"],
                        title=job["title"], body=job["body"],
                        action="open_screen",
                        action_payload=job["action_payload"],
                        log_type="low_balance",
                    )
            except Exception as exc:  # noqa: BLE001
                logger.warning("low_balance_push_failed", error=str(exc),
                               type="low_balance")
    return {"status": "completed", "alerts_triggered": triggered}


# ── Budget Alerts ──


async def _check_budget_alerts():
    now = _utcnow()
    triggered = 0
    push_jobs: list[dict] = []
    async with async_session_factory() as session:
        budgets = (await session.execute(
            select(PersonalBudget).where(PersonalBudget.is_deleted == False)  # noqa: E712
        )).scalars().all()
        for b in budgets:
            if b.spent is None or b.amount is None:
                continue
            if Decimal(str(b.spent)) >= Decimal(str(b.amount)):
                if await _has_notification_today(session, b.user_id, "warning", str(b.id)):
                    continue
                _title = "تجاوز الميزانية"
                _body = f"استهلكت ميزانية فئة ({b.category}) بالكامل لهذا الشهر."
                _payload = str(b.id)
                await _create_notification(
                    session, b.user_id, b.user_id,
                    type_="warning",
                    title=_title,
                    message=_body,
                    action="open_screen",
                    action_payload=_payload,
                )
                triggered += 1
                push_jobs.append({
                    "user_id": b.user_id, "title": _title, "body": _body,
                    "action_payload": _payload,
                })
        await session.commit()

        for job in push_jobs:
            try:
                from app.domain.services import push_service as _push

                await _push.push_to_users_now(
                    session, [job["user_id"]],
                    title=job["title"], body=job["body"],
                    action="open_screen",
                    action_payload=job["action_payload"],
                    log_type="budget",
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("budget_push_failed", error=str(exc),
                               type="budget")
    return {"status": "completed", "budget_alerts": triggered}


# ══════════════════════════════════════════════════════════
#  CELERY TASKS
# ══════════════════════════════════════════════════════════

# ── Email Tasks ──


@celery.task(bind=True, name="send_email", max_retries=3, default_retry_delay=60)
def send_email(self, to: str, subject: str, body: str) -> dict:
    """Send an HTML email via the configured SMTP provider."""
    from app.core.email_service import send_email as _send

    try:
        ok = _run_async(_send(to=to, subject=subject, html=body))
    except Exception as exc:
        raise self.retry(exc=exc, countdown=60 * (2 ** self.request.retries))
    return {
        "status": "sent" if ok else "failed",
        "to": to,
        "subject": subject,
    }


# ── Report Tasks ──


@celery.task(bind=True, name="generate_report")
def generate_report(self, report_type: str, org_id: str, user_id: str) -> dict:
    """Generate report task (implementation pending)."""
    return {"status": "pending", "report_type": report_type}


# ── AI Tasks ──


@celery.task(bind=True, name="ai_suggestion")
def ai_suggestion(self, user_id: str, query: str) -> dict:
    """AI suggestion task (implementation pending)."""
    return {"status": "pending", "user_id": user_id}


# ── Scheduled / Recurring Tasks ──


@celery.task(bind=True, name="process_recurring_invoices")
def process_recurring_invoices(self) -> dict:
    """Generate recurring invoices (scheduled daily)."""
    return {"status": "completed", "invoices_created": 0}


@celery.task(bind=True, name="cleanup_expired_sessions")
def cleanup_expired_sessions(self) -> dict:
    """Clean expired sessions (scheduled hourly)."""
    return {"status": "completed", "sessions_cleaned": 0}


@celery.task(bind=True, name="sync_pending_data")
def sync_pending_data(self) -> dict:
    """Sync offline pending data from clients."""
    return {"status": "completed", "items_synced": 0}


# ── Notifications & Reminders Tasks ──


@celery.task(bind=True, name="fanout_platform_notification", max_retries=3, default_retry_delay=120)
def fanout_platform_notification(self, notif_id: str) -> dict:
    """Copy a platform notification to every org and email users."""
    try:
        return _run_async(_fanout_platform_notification(notif_id))
    except Exception as exc:
        raise self.retry(exc=exc, countdown=120 * (2 ** self.request.retries))


@celery.task(bind=True, name="process_due_reminders")
def process_due_reminders(self) -> dict:
    """Trigger notifications for due reminders (scheduled every minute)."""
    return _run_async(_process_due_reminders())


@celery.task(bind=True, name="generate_daily_report")
def generate_daily_report(self) -> dict:
    """Generate daily financial report notifications."""
    return _run_async(_generate_report("daily"))


@celery.task(bind=True, name="generate_weekly_report")
def generate_weekly_report(self) -> dict:
    """Generate weekly financial report notifications."""
    return _run_async(_generate_report("weekly"))


@celery.task(bind=True, name="generate_monthly_report")
def generate_monthly_report(self) -> dict:
    """Generate monthly financial report notifications."""
    return _run_async(_generate_report("monthly"))


@celery.task(bind=True, name="check_low_balance")
def check_low_balance(self) -> dict:
    """Alert users about accounts with zero or negative balance."""
    return _run_async(_check_low_balance())


@celery.task(bind=True, name="check_budget_alerts")
def check_budget_alerts(self) -> dict:
    """Alert users when a budget category is fully consumed."""
    return _run_async(_check_budget_alerts())


# ── Sessions Maintenance ──


@celery.task(name="cleanup_expired_sessions")
def cleanup_expired_sessions() -> dict:
    """Purge sessions that expired, or were killed over 7 days ago."""
    from datetime import datetime, timedelta, timezone

    from sqlalchemy import delete, or_

    from app.domain.entities.auth_entities import UserSession

    async def _run() -> int:
        now = datetime.now(timezone.utc)
        cutoff = now - timedelta(days=7)
        async with async_session_factory() as db:
            res = await db.execute(
                delete(UserSession).where(
                    or_(
                        UserSession.expires_at < now,
                        (UserSession.is_active.is_(False)) & (UserSession.created_at < cutoff),
                    )
                )
            )
            await db.commit()
            return res.rowcount or 0

    deleted = _run_async(_run())
    return {"status": "ok", "deleted": deleted}


# ── Personal relay maintenance ──


@celery.task(name="purge_personal_relay")
def purge_personal_relay() -> dict:
    """Drop Personal relay operations older than the retention (their missing
    destinations are flagged for a snapshot) and old delivery tombstones."""
    from sqlalchemy import text as _text

    from app.domain.services import personal_relay

    async def _run() -> int:
        async with async_session_factory() as db:
            conn = await db.connection()
            if db.get_bind().dialect.name != "postgresql":
                return 0
            present = await conn.scalar(
                _text("SELECT to_regclass('personal_relay_ops') IS NOT NULL"))
            if not present:
                return 0
            purged = await personal_relay.purge_expired(conn)
            await db.commit()
            return purged

    return {"status": "ok", "purged": _run_async(_run())}


# ── Subscription renewal retries (custom off-session schedule) ──


async def _retry_renewal_charges():
    """Run due renewal collection retries (past-due subscriptions whose
    next attempt is due). Each profile is handled independently — one
    failure never aborts the rest."""
    from sqlalchemy import or_ as _or
    from app.domain.entities.payment_entities import StripeSubscription
    from app.domain.services.payment_service import PaymentService

    now = _utcnow()
    outcomes = {"attempted": 0, "paid": 0, "failed": 0, "recovered": 0,
                "stopped": 0, "exhausted": 0, "skipped": 0, "error": 0}
    async with async_session_factory() as session:
        rows = (
            await session.execute(
                select(StripeSubscription).where(
                    StripeSubscription.status == "past_due",
                    StripeSubscription.stripe_subscription_id.isnot(None),
                    _or_(StripeSubscription.renewal_next_retry_at.is_(None),
                         StripeSubscription.renewal_next_retry_at <= now),
                )
            )
        ).scalars().all()
        svc = PaymentService(session)
        for profile in rows:
            try:
                res = await svc.retry_renewal_charge(profile)
                outcomes["attempted"] += 1
                key = res.get("outcome", "error")
                if key in outcomes:
                    outcomes[key] += 1
                else:
                    outcomes["error"] += 1
            except Exception:
                outcomes["attempted"] += 1
                outcomes["error"] += 1
    outcomes["status"] = "completed"
    return outcomes


@celery.task(bind=True, name="retry_renewal_charges")
def retry_renewal_charges(self) -> dict:
    """Retry past-due subscription renewals on the custom schedule (daily)."""
    return _run_async(_retry_renewal_charges())
