"""In-process background loop (QA runs no Celery beat).

Every tick: due OTP actions (WhatsApp retries, deadline fallbacks, queued
sends after a restart), expiry sweep, due primary-device transfers, and an
hourly purge of old OTP rows / nonces. Safe with several API processes on
PostgreSQL (row locks with SKIP LOCKED + compare-and-set SMS guard).
"""

from __future__ import annotations

import asyncio
from datetime import timedelta

from sqlalchemy import delete

from app.core.config import settings
from app.core.logging import get_logger

from . import engine

logger = get_logger("otp_worker")
RETENTION_DAYS = 30


async def purge_old() -> None:
    from app.domain.entities.auth2_entities import (
        AuthDeviceNonce, OtpChallenge, OtpEvent)

    now = engine.utcnow()
    cutoff = now - timedelta(days=RETENTION_DAYS)
    async with engine._factory() as db:
        await db.execute(delete(AuthDeviceNonce).where(AuthDeviceNonce.expires_at < now))
        await db.execute(delete(OtpEvent).where(OtpEvent.created_at < cutoff))
        # Deliveries cascade with their challenge (cost ledger: 30 days live;
        # metrics older than that are not needed for daily/monthly budgets
        # beyond the current month, which is < 31 days).
        await db.execute(delete(OtpChallenge).where(OtpChallenge.created_at < cutoff
                                                    - timedelta(days=2)))
        await db.commit()


async def scheduler() -> None:
    interval = max(float(settings.AUTH_OTP_WORKER_INTERVAL_SECONDS or 1.0), 0.2)
    ticks = 0
    while True:
        try:
            await engine.run_due()
            if ticks % 10 == 0:
                from app.domain.services.auth2_service import apply_due_primary_transfers

                await apply_due_primary_transfers()
            if ticks % 3600 == 0:
                await purge_old()
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            logger.warning("otp_worker_tick_failed", error=type(exc).__name__)
        ticks += 1
        await asyncio.sleep(interval)
