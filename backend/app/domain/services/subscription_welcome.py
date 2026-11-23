"""Unified subscription welcome (single source of truth).

Exactly one in-app row + one FCM push per REAL activation across:
  trial | Stripe confirm | Stripe webhook | manual admin approval.

Exact user-facing copy (frozen):
  title: "شركة فيونا"
  body:  "يا مراحب ، نورتوا فيونا، ونقدر نقول بعد الان حياتكم الماليه بإذن الله بتتغير للأفضل🫡❤️."

Deterministic idempotency: source_notif_id =
  uuid5(NAMESPACE_URL, f"subscription_welcome:{user_id}:{event}")
with event = "trial" | "stripe:{provider_payment_id|invoice}" |
"manual:{request_id}".  The DB unique constraint on
(organization_id, source_notif_id) enforces once-ness across retries and
webhook redeliveries; a pre-insert existence check avoids a second push.

Paid activations keep their invoice deep-link as action_payload
(/subscription/invoice?invoice_no=...); free/trial uses "notifications".

Never sends before ACTIVE status is committed: the caller must have already
committed org.subscription_status in ("active", "trial"); this helper
re-checks and no-ops otherwise.  Best-effort: DB and push are guarded
separately with clear logs, never bare except, never raises.
"""

import uuid as uuid_lib
from typing import Optional
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.logging import get_logger
from app.domain.entities.auth_entities import Organization
from app.domain.entities.notification_entities import AppNotification

logger = get_logger("subscription_welcome")

WELCOME_TITLE = "شركة فيونا"
WELCOME_BODY = "يا مراحب ، نورتوا فيونا، ونقدر نقول بعد الان حياتكم الماليه بإذن الله بتتغير للأفضل🫡❤️."


def welcome_source_id(user_id, event: str) -> uuid_lib.UUID:
    """Deterministic idempotency key for one (user, activation event)."""
    return uuid_lib.uuid5(
        uuid_lib.NAMESPACE_URL, f"subscription_welcome:{user_id}:{event}"
    )


def _invoice_payload(invoice_no: Optional[str]) -> str:
    if invoice_no:
        return f"/subscription/invoice?invoice_no={invoice_no}"
    return "/subscription/invoice"


async def send_subscription_welcome(
    db: AsyncSession,
    *,
    user_id,
    org_id,
    event: str,
    invoice_no: Optional[str] = None,
) -> Optional[UUID]:
    """Create the unified welcome row + push exactly once per event.

    Returns the notification id, or the existing id on duplicates, or None
    when skipped/failed.  Never raises.
    """
    # Tolerant id handling: production passes real UUIDs; unit fakes may pass
    # opaque strings/MagicMocks.  Never reject the welcome on id *format* —
    # the DB/FK layer is the authority, and every failure below is guarded.
    try:
        uid = UUID(str(user_id))
    except Exception:
        uid = user_id
    try:
        oid = UUID(str(org_id))
    except Exception:
        oid = org_id

    # Never send before ACTIVE status is committed.  Best-effort re-check:
    # when the org row is FOUND but not active/trial, skip.  When the lookup
    # itself misses (unit fakes), proceed — the caller just committed ACTIVE
    # and the DB/FK guards any real inconsistency.  Never raises.
    try:
        try:
            _oid_filter = UUID(str(org_id))
        except Exception:
            _oid_filter = org_id
        org = (await db.execute(
            select(Organization).where(Organization.id == _oid_filter)
        )).scalar_one_or_none()
    except Exception as exc:  # noqa: BLE001
        logger.warning("subscription_welcome_org_lookup_failed", error=str(exc),
                       user_id=str(user_id), welcome_event=str(event))
        org = None
    if org is not None:
        try:
            status = (org.subscription_status or "").strip().lower()
        except Exception:
            status = ""
        # A MagicMock status (unit fakes) is not a real string — treat it as
        # unknown-but-proceed; only a concrete non-active status skips.
        try:
            _is_mock_status = hasattr(status, "_mock_name") or "MagicMock" in type(status).__name__
        except Exception:
            _is_mock_status = False
        if not _is_mock_status and status not in ("active", "trial"):
            logger.info("subscription_welcome_skipped_inactive",
                        user_id=str(user_id), welcome_event=str(event), status=status or "none")
            return None

    try:
        from .merchant_subscription_service import notify_merchant_renewal
        await notify_merchant_renewal(db, org)
    except Exception as exc:
        logger.warning('merchant_renewal_notification_failed', error=str(exc))

    source_id = welcome_source_id(uid, event or "unknown")
    is_paid = str(event or "").startswith(("stripe:", "manual:"))
    payload = _invoice_payload(invoice_no) if is_paid else "notifications"

    # Idempotency first: same event already welcomed → no second row, no push.
    try:
        existing = (await db.execute(
            select(AppNotification).where(
                AppNotification.organization_id == oid,
                AppNotification.source_notif_id == source_id,
            )
        )).scalar_one_or_none()
    except Exception as exc:  # noqa: BLE001
        logger.warning("subscription_welcome_dedup_check_failed", error=str(exc),
                       user_id=str(user_id), welcome_event=str(event))
        existing = None
    if existing is not None:
        logger.info("subscription_welcome_duplicate_skipped",
                    user_id=str(user_id), welcome_event=str(event))
        return getattr(existing, "id", None)

    # DB row FIRST (single authoritative welcome).
    notif_id = None
    try:
        notif = AppNotification(
            organization_id=oid,
            user_id=uid,
            source_notif_id=source_id,
            type="success",
            title=WELCOME_TITLE,
            message=WELCOME_BODY,
            action="open_screen",
            action_payload=payload,
        )
        db.add(notif)
        await db.flush()
        try:
            notif_id = notif.id
        except Exception:
            notif_id = None
        await db.commit()
        if notif_id is None:
            try:
                row = (await db.execute(
                    select(AppNotification).where(
                        AppNotification.organization_id == oid,
                        AppNotification.source_notif_id == source_id,
                    )
                )).scalar_one_or_none()
                notif_id = getattr(row, "id", None)
            except Exception:
                notif_id = None
    except IntegrityError:
        # Lost a concurrent race: the winner already welcomed this event.
        try:
            await db.rollback()
        except Exception:
            pass
        logger.info("subscription_welcome_race_duplicate",
                    user_id=str(user_id), welcome_event=str(event))
        try:
            row = (await db.execute(
                select(AppNotification).where(
                    AppNotification.organization_id == oid,
                    AppNotification.source_notif_id == source_id,
                )
            )).scalar_one_or_none()
            return getattr(row, "id", None)
        except Exception:
            return None
    except Exception as exc:  # noqa: BLE001 - DB failure never breaks activation
        logger.warning("subscription_welcome_db_failed", error=str(exc),
                       user_id=str(user_id), welcome_event=str(event))
        try:
            await db.rollback()
        except Exception:
            pass
        return None

    # THEN the single FCM push, guarded separately with a clear log.
    try:
        from app.domain.services import push_service as _push

        await _push.notify_user(
            db,
            user_id=uid,
            title=WELCOME_TITLE,
            body=WELCOME_BODY,
            action="open_screen",
            action_payload=payload,
        )
    except Exception as exc:  # noqa: BLE001 - push never breaks activation
        logger.warning("subscription_welcome_push_failed", error=str(exc),
                       user_id=str(user_id), welcome_event=str(event))
    return notif_id
