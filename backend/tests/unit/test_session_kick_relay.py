"""Kicking a device retires its Business relay replica (PostgreSQL only)."""

from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.api.v1.auth import _retire_relay_devices
from app.domain.entities.auth_entities import UserSession
from app.domain.services import business_relay as relay
from tests.unit.test_qa_business_ledger import engine, _seed  # noqa: F401


@pytest.mark.asyncio
async def test_kicked_session_replica_is_retired_others_untouched(engine):
    org, owner, _branch, _ = await _seed(engine, f"kick-{uuid4().hex[:20]}@example.test")
    async with engine.begin() as conn:
        await relay.install(conn)
    kicked, kept = uuid4(), uuid4()
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker.begin() as db:
        for sid in (kicked, kept):
            db.add(UserSession(id=sid, user_id=owner, refresh_token=sid.hex,
                               expires_at=datetime.now(timezone.utc) + timedelta(days=1),
                               is_active=True))
    ra, rb = uuid4(), uuid4()
    async with engine.begin() as conn:
        await relay.register(conn, org=org, user=owner, session=kicked, replica_id=ra)
        await relay.register(conn, org=org, user=owner, session=kept, replica_id=rb)
    async with maker.begin() as db:
        await _retire_relay_devices(db, [kicked])
    async with engine.begin() as conn:
        rows = dict((await conn.execute(text(
            "SELECT id, retired FROM business_relay_replicas WHERE organization_id = :o"
        ), {"o": org})).all())
    assert rows[ra] is True
    assert rows[rb] is False
