"""Auth v2 schema installer for paths that do not run Alembic.

``init_db`` (create_all) only creates missing TABLES; it never adds columns
to an existing ``users`` table. This installer is idempotent and is called
from ``init_db`` and from the QA lab's schema hook (which skips ``init_db``
on a persistent sandbox).
"""

import sqlalchemy as sa


async def install(engine) -> None:
    import app.domain.entities.auth_entities  # noqa: F401
    from app.domain.entities import auth2_entities as m

    tables = [
        m.AuthIdentity.__table__, m.AuthDevice.__table__, m.AuthDeviceNonce.__table__,
        m.OtpChallenge.__table__, m.OtpDelivery.__table__, m.OtpEvent.__table__,
        m.OtpBudget.__table__, m.PrimaryTransfer.__table__,
    ]
    async with engine.begin() as conn:
        if conn.dialect.name == "postgresql":
            await conn.execute(sa.text(
                "ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_e164 VARCHAR(20)"))
            await conn.execute(sa.text(
                "ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_verified_at TIMESTAMPTZ"))
            await conn.execute(sa.text(
                "CREATE UNIQUE INDEX IF NOT EXISTS ix_users_phone_e164 ON users (phone_e164)"))

        def _create(sync_conn):
            for table in tables:
                table.create(bind=sync_conn, checkfirst=True)

        await conn.run_sync(_create)
