"""Auth v2 on real PostgreSQL (disposable fixture socket only):
schema installer on an existing users table, row locks + the SMS guard."""

import asyncio
import os

import pytest
import pytest_asyncio
from sqlalchemy import URL, func, select, text
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.domain.services import local_business_cutover as cutover

from tests.unit.auth2_support import FakeProvider


@pytest_asyncio.fixture
async def pg():
    socket = os.environ.get("FYONA_TEST_CUTOVER_SOCKET")
    if socket is None:
        pytest.skip("A disposable PostgreSQL fixture socket is required")
    if not cutover.SOCKET_PATH.fullmatch(socket):
        pytest.fail("Refusing to connect to a non-fixture database")
    db = create_async_engine(URL.create(
        "postgresql+asyncpg", username="root", database=cutover.FIXTURE_DB,
        query={"host": socket}))
    try:
        from app.domain.entities import auth2_entities as m
        from app.domain.entities.auth_entities import Organization, User

        tables = [Organization.__table__, User.__table__, m.AuthIdentity.__table__,
                  m.AuthDevice.__table__, m.AuthDeviceNonce.__table__, m.OtpChallenge.__table__,
                  m.OtpDelivery.__table__, m.OtpEvent.__table__, m.OtpBudget.__table__,
                  m.PrimaryTransfer.__table__]
        async with db.begin() as conn:
            await cutover._require_socket(conn, socket)
            await conn.run_sync(lambda c: [t.create(c, checkfirst=True) for t in tables])
        yield db
    finally:
        await db.dispose()


async def test_installer_adds_columns_and_tables_idempotently(pg):
    from app.core import auth2_schema

    async with pg.begin() as conn:
        for t in ("auth_primary_transfers", "otp_budgets", "otp_events", "otp_deliveries",
                  "otp_challenges", "auth_device_nonces", "auth_devices", "auth_identities"):
            await conn.execute(text(f"DROP TABLE IF EXISTS {t} CASCADE"))
        await conn.execute(text("DROP INDEX IF EXISTS ix_users_phone_e164"))
        await conn.execute(text("ALTER TABLE users DROP COLUMN IF EXISTS phone_e164"))
        await conn.execute(text("ALTER TABLE users DROP COLUMN IF EXISTS phone_verified_at"))
    await auth2_schema.install(pg)
    await auth2_schema.install(pg)
    async with pg.connect() as conn:
        cols = set((await conn.execute(text(
            "SELECT column_name FROM information_schema.columns WHERE table_name='users'"
        ))).scalars())
        assert {"phone_e164", "phone_verified_at"} <= cols
        for t in ("otp_challenges", "otp_deliveries", "auth_devices", "auth_identities"):
            assert await conn.scalar(text(f"SELECT to_regclass('public.{t}') IS NOT NULL"))
        idx = await conn.scalar(text(
            "SELECT indexdef FROM pg_indexes WHERE indexname='uq_otp_deliveries_one_sms'"))
        assert "UNIQUE" in idx and "sms" in idx


async def test_parallel_fallbacks_send_one_sms_on_postgres(pg, monkeypatch):
    from app.domain.entities.auth2_entities import OtpDelivery
    from app.domain.services.otp import engine, providers
    from app.domain.services.otp.providers import SendResult

    factory = async_sessionmaker(pg, expire_on_commit=False)
    wa = FakeProvider("whatsapp", "whatsapp_cloud")
    sms = FakeProvider("sms", "smsto")
    wa.results = [SendResult(ok=False, error_code="131026", permanent=True)]
    providers.register(wa)
    providers.register(sms)
    monkeypatch.setattr(engine, "session_factory", factory)
    monkeypatch.setattr(engine, "kick_enabled", False)
    try:
        async with factory() as db:
            ch = await engine.start(db, purpose="signup", phone_e164="+966501234567",
                                    ip="192.0.2.10", device_id="dev-pg0000000000",
                                    country="SA")
            await db.commit()
            cid = ch.id

        async def direct():
            async with factory() as db:
                await engine._send_sms(db, cid)

        await asyncio.gather(*(engine.process(cid) for _ in range(5)))
        await asyncio.gather(*(direct() for _ in range(5)),
                             *(engine.process(cid) for _ in range(5)))
        async with factory() as db:
            n = (await db.execute(select(func.count()).select_from(OtpDelivery).where(
                OtpDelivery.challenge_id == cid, OtpDelivery.channel == "sms"))).scalar()
            ch = await engine.get(db, cid)
        assert len(wa.sent) == 1
        assert len(sms.sent) == 1 and n == 1 and ch.sms_sent
    finally:
        providers.reset_defaults()
