"""Hourly Personal maintenance: relay retention + purge of migrated rows.

Runs from Celery beat (purge_personal_relay / purge_personal_local) where a
beat exists, and in-process from the API lifespan ([scheduler]) so services
without a beat (the QA service) run it too. Both are idempotent.
"""

from __future__ import annotations

import asyncio

from app.core.database import async_session_factory
from app.core.logging import get_logger

logger = get_logger("personal_maintenance")


async def purge_local_once() -> dict:
    from app.domain.services import personal_local_migration as migration

    async with async_session_factory() as db:
        if db.get_bind().dialect.name != "postgresql":
            return {"users": 0, "rows": 0}
        conn = await db.connection()
        result = await migration.purge_due(conn)
        await db.commit()
        return result


async def purge_relay_once() -> int:
    from sqlalchemy import text

    from app.domain.services import personal_relay

    async with async_session_factory() as db:
        if db.get_bind().dialect.name != "postgresql":
            return 0
        conn = await db.connection()
        if not await conn.scalar(text("SELECT to_regclass('personal_relay_ops') IS NOT NULL")):
            return 0
        purged = await personal_relay.purge_expired(conn)
        await db.commit()
        return purged


async def scheduler(interval: float = 3600.0) -> None:
    await asyncio.sleep(90)
    while True:
        for name, job in (("personal_local_purge", purge_local_once),
                          ("personal_relay_purge", purge_relay_once)):
            try:
                result = await job()
                logger.info(name, result=str(result))
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # pragma: no cover - keep the loop alive
                logger.warning(f"{name}_failed", error=str(exc))
        await asyncio.sleep(interval)
