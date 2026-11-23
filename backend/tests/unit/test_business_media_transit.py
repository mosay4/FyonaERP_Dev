from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

import pytest
from sqlalchemy import select, text

from app.domain.entities.auth_entities import UserSession
from app.domain.services import business_media_transit as media
from tests.unit.test_qa_business_ledger import engine, _seed  # noqa: F401


async def _devices(engine, owner, count):
    from sqlalchemy.ext.asyncio import async_sessionmaker

    expires = datetime.now(timezone.utc) + timedelta(hours=1)
    sessions = [uuid4() for _ in range(count)]
    async with async_sessionmaker(engine, expire_on_commit=False).begin() as db:
        for session in sessions:
            db.add(UserSession(id=session, user_id=owner,
                               refresh_token=str(uuid4()), expires_at=expires))
    return sessions


@pytest.mark.asyncio
async def test_the_server_drops_the_payload_once_every_device_stored_it(engine):
    from sqlalchemy.ext.asyncio import async_sessionmaker

    email = f"signup-{uuid4().hex[:24]}@example.test"
    org, owner, branch, _other = await _seed(engine, email)
    first, second, third = await _devices(engine, owner, 3)

    async with engine.begin() as conn:
        await conn.run_sync(media.metadata.create_all)

    async with engine.begin() as conn:
        sent = await media.submit(
            conn, workspace_id=org, branch_id=branch, actor_id=owner,
            session_id=first, kind="branch_update", target_id=str(branch),
            payload=b"the picture stays on the devices",
        )
        assert set(sent["destinations"]) == {str(second), str(third)}
        # The sender never receives its own payload back.
        assert await media.poll(conn, workspace_id=org, session_id=first) == []
        for device in (second, third):
            items = await media.poll(conn, workspace_id=org, session_id=device)
            assert len(items) == 1 and items[0]["target_id"] == str(branch)
        # One device storing it is not enough to drop it from the road.
        assert await media.ack(conn, workspace_id=org, session_id=second,
                               payload_id=UUID(sent["id"])) is False
        assert len(await media.poll(conn, workspace_id=org, session_id=third)) == 1
        assert await media.poll(conn, workspace_id=org, session_id=second) == []
        # The last device storing it removes the payload from the server.
        assert await media.ack(conn, workspace_id=org, session_id=third,
                               payload_id=UUID(sent["id"])) is True
        for device in (second, third):
            assert await media.poll(conn, workspace_id=org, session_id=device) == []
        assert (await conn.execute(text(
            "SELECT COUNT(*) FROM business_media_transit"
        ))).scalar() == 0


@pytest.mark.asyncio
async def test_a_payload_for_another_account_is_refused_and_nothing_is_kept(engine):
    from sqlalchemy.ext.asyncio import async_sessionmaker

    email = f"signup-{uuid4().hex[:24]}@example.test"
    org, owner, branch, _other = await _seed(engine, email)
    alone = await _devices(engine, owner, 1)
    stranger = uuid4()
    async with engine.begin() as conn:
        await conn.run_sync(media.metadata.create_all)
    async with async_sessionmaker(engine, expire_on_commit=False).begin() as db:
        from app.domain.entities.auth_entities import Organization, User

        other_org = uuid4()
        db.add(Organization(id=other_org, slug=f"ledger-qa-{other_org.hex}",
                            name="Another account"))
        await db.flush()
        db.add(User(id=stranger, organization_id=other_org, role="owner",
                    full_name="Other account", email=f"signup-{uuid4().hex[:24]}@example.test"))
        await db.flush()
        db.add(UserSession(id=stranger, user_id=stranger,
                           refresh_token=str(uuid4()),
                           expires_at=datetime.now(timezone.utc) + timedelta(hours=1)))
    async with engine.begin() as conn:
        with pytest.raises(media.MediaAccessDenied):
            await media.submit(conn, workspace_id=org, branch_id=branch,
                               actor_id=stranger, session_id=stranger,
                               kind="branch_update", target_id=str(branch),
                               payload=b"not mine")
    async with engine.begin() as conn:
        # A single device has nobody to carry the payload to: it is dropped.
        sent = await media.submit(conn, workspace_id=org, branch_id=branch,
                                  actor_id=owner, session_id=alone[0],
                                  kind="branch_update", target_id=str(branch),
                                  payload=b"only me")
        assert sent["destinations"] == []
        assert (await conn.execute(text(
            "SELECT COUNT(*) FROM business_media_transit"
        ))).scalar() == 0