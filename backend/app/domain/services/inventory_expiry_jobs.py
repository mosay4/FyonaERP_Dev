"""Daily, server-side expiry-notification job.

Runs in the backend (not on the phone): once a day it finds products whose
expiry falls within the organization's warn window, sends a push to the org's
devices, and records a dedup marker so the same product never alerts twice in
the same day.
"""
import asyncio
import logging
from datetime import date, timedelta

from sqlalchemy import select

from app.core.database import async_session_factory
from app.domain.entities.business_entities import (
    ExpiryNotification,
    Product,
    WarehouseSetting,
)

logger = logging.getLogger("fyona")


async def run_expiry_notifications_once() -> int:
    from app.domain.services.push_service import push_to_org_now

    today = date.today()
    sent = 0
    async with async_session_factory() as db:
        configs = (
            await db.execute(
                select(WarehouseSetting).where(
                    WarehouseSetting.expiry_enabled.is_(True)
                )
            )
        ).scalars().all()
        for cfg in configs:
            warn = cfg.expiry_warn_days or 60
            hi = today + timedelta(days=warn)
            products = (
                await db.execute(
                    select(Product).where(
                        Product.organization_id == cfg.organization_id,
                        Product.is_deleted.is_(False),
                        Product.is_active.is_(True),
                        Product.expiry_date.isnot(None),
                        Product.expiry_date >= today,
                        Product.expiry_date <= hi,
                    )
                )
            ).scalars().all()
            for p in products:
                exists = (
                    await db.execute(
                        select(ExpiryNotification.id).where(
                            ExpiryNotification.organization_id
                            == cfg.organization_id,
                            ExpiryNotification.product_id == p.id,
                            ExpiryNotification.notified_on == today,
                        )
                    )
                ).scalar_one_or_none()
                if exists:
                    continue
                db.add(
                    ExpiryNotification(
                        organization_id=cfg.organization_id,
                        product_id=p.id,
                        notified_on=today,
                    )
                )
                try:
                    await db.commit()
                except Exception:
                    await db.rollback()
                    continue
                days = (p.expiry_date - today).days
                # Also record an in-app notification (org-broadcast) so it shows
                # in the notifications bell, not only as a push.
                try:
                    from app.domain.entities.notification_entities import (
                        AppNotification,
                    )

                    db.add(
                        AppNotification(
                            organization_id=cfg.organization_id,
                            user_id=None,
                            type="warning",
                            title="قرب انتهاء الصلاحية",
                            message=(
                                f"منتج {p.name} قرب تنتهي صلاحيته بعد {days} يوم"
                            ),
                            action="open_screen",
                            action_payload="inventory",
                            is_system=True,
                        )
                    )
                    await db.commit()
                except Exception:
                    await db.rollback()
                await push_to_org_now(
                    db,
                    cfg.organization_id,
                    title="قرب انتهاء الصلاحية",
                    body=f"منتج {p.name} قرب تنتهي صلاحيته بعد {days} يوم",
                    action_payload="inventory",
                    log_type="expiry",
                )
                sent += 1
    return sent


async def expiry_scheduler() -> None:
    await asyncio.sleep(30)
    while True:
        try:
            n = await run_expiry_notifications_once()
            if n:
                logger.info("expiry_notifications_sent", count=n)
        except Exception as exc:  # pragma: no cover
            logger.warning("expiry_job_failed", error=str(exc))
        await asyncio.sleep(24 * 3600)
