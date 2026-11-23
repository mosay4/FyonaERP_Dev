"""Notification visibility scoping tests (real DB).

Proves the source fix for admin-type notifications leaking into a
subscriber's bell/badge:
- a subscriber sees ONLY their own rows + org broadcasts,
- an admin still sees their own admin rows,
- unread-count / read / read-all are scoped the same way,
- the activation payload carries the exact invoice number (tap target).

Scratch DB `fyona_test_notifs` is created and dropped by the module
fixture — production/dev data is never touched.
"""
import os
import uuid
import json
from datetime import datetime, timezone

import pytest

try:
    import pytest_asyncio
    _has_pa = True
except Exception:
    _has_pa = False
    pytest_asyncio = None

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")
os.environ.setdefault("CELERY_BROKER_URL", "redis://localhost:6379/1")
os.environ.setdefault("CELERY_RESULT_BACKEND", "redis://localhost:6379/2")

TEST_DB = "fyona_test_notifs"


def _dev_dsn():
    url = None
    for f in ("backend/.env", ".env"):
        try:
            for line in open(f, encoding="utf-8", errors="ignore"):
                if line.strip().startswith("DATABASE_URL"):
                    url = line.split("=", 1)[1].strip().strip('"').strip("'")
        except Exception:
            pass
    return url


def _dsn_for(dbname):
    base = _dev_dsn()
    assert base, "no dev DATABASE_URL found for scratch DB"
    head, _, tail = base.rpartition("/")
    dbpart, sep, query = tail.partition("?")
    out = f"{head}/{dbname}{sep}{query}" if sep else f"{head}/{dbname}"
    return out


def _raw_dsn_for(dbname):
    return _dsn_for(dbname).replace("postgresql+asyncpg://", "postgresql://", 1)


@pytest.fixture(scope="module")
def pg_url():
    import asyncio
    try:
        import asyncpg
    except Exception:
        pytest.skip("asyncpg not installed")

    async def _setup():
        try:
            admin = await asyncpg.connect(_raw_dsn_for("postgres"))
        except Exception as exc:
            return f"SKIP:local postgres unreachable: {exc}"
        try:
            await admin.execute(f'DROP DATABASE IF EXISTS "{TEST_DB}"')
            await admin.execute(f'CREATE DATABASE "{TEST_DB}"')
        finally:
            await admin.close()
        from sqlalchemy.ext.asyncio import create_async_engine
        from app.core.database import Base
        # Register the same complete model metadata as the application. Partial
        # imports leave employee/branch foreign keys unresolved after the HR upgrade.
        import app.main  # noqa: F401
        import app.domain.entities.notification_entities  # noqa: F401
        import app.domain.entities.auth_entities  # noqa: F401
        engine = create_async_engine(_dsn_for(TEST_DB))
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        await engine.dispose()
        return _dsn_for(TEST_DB)

    url = asyncio.run(_setup())
    if url.startswith("SKIP:"):
        pytest.skip(url[5:])
    yield url

    async def _teardown():
        import asyncpg
        admin = await asyncpg.connect(_raw_dsn_for("postgres"))
        try:
            try:
                await admin.execute(
                    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                    f"WHERE datname = '{TEST_DB}' AND pid <> pg_backend_pid()"
                )
            except Exception:
                pass
            await admin.execute(f'DROP DATABASE IF EXISTS "{TEST_DB}"')
        finally:
            await admin.close()

    asyncio.run(_teardown())


if _has_pa:
    @pytest_asyncio.fixture()
    async def db(pg_url):
        from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
        engine = create_async_engine(pg_url)
        maker = async_sessionmaker(engine, expire_on_commit=False)
        async with maker() as s:
            yield s
            await s.rollback()
        await engine.dispose()
else:
    @pytest.fixture()
    def db(pg_url):
        pytest.skip("pytest-asyncio not installed")


def _body(res):
    data = json.loads(bytes(res.body).decode())
    return data["data"] if "data" in data else data


async def _seed(db):
    from app.domain.entities.notification_entities import AppNotification
    from app.domain.entities.auth_entities import Organization
    org = uuid.uuid4()
    sub = uuid.uuid4()
    adm = uuid.uuid4()
    db.add(Organization(id=org, name="Notif Org", slug=f"notif-{org.hex[:8]}"))
    await db.flush()
    now = datetime.now(timezone.utc)
    rows = [
        AppNotification(organization_id=org, user_id=sub, type="success",
                        title="تم تفعيل اشتراكك في باقة أعمال + شخصي",
                        message="msg", action="open_screen",
                        action_payload="/subscription/invoice?invoice_no=INV-9"),
        AppNotification(organization_id=org, user_id=adm, type="success",
                        title="اشتراك جديد — دفع إلكتروني",
                        message="admin msg", action="open_screen",
                        action_payload="/subscription"),
        AppNotification(organization_id=org, user_id=None, type="info",
                        title="إعلان عام",
                        message="broadcast", action="open_screen",
                        action_payload="notifications"),
    ]
    db.add_all(rows)
    await db.commit()
    return org, sub, adm


@pytest.mark.asyncio
async def test_subscriber_never_sees_admin_rows(db):
    from app.api.v1 import notifications as nt
    org, sub, adm = await _seed(db)
    payload = _body(await nt.list_notifications(1, 20, False, str(org), sub, db))
    titles = [i["title"] for i in payload["items"]]
    assert any("تم تفعيل اشتراكك" in t for t in titles)
    assert any(t == "إعلان عام" for t in titles)
    assert not any("اشتراك جديد" in t for t in titles), titles


@pytest.mark.asyncio
async def test_admin_still_sees_own_admin_rows(db):
    from app.api.v1 import notifications as nt
    org, sub, adm = await _seed(db)
    payload = _body(await nt.list_notifications(1, 20, False, str(org), adm, db))
    titles = [i["title"] for i in payload["items"]]
    assert any("اشتراك جديد" in t for t in titles)
    assert not any("تم تفعيل اشتراكك" in t for t in titles), titles


@pytest.mark.asyncio
async def test_unread_count_scoped_per_user(db):
    from app.api.v1 import notifications as nt
    org, sub, adm = await _seed(db)
    sub_count = _body(await nt.get_unread_count(str(org), sub, db))["count"]
    adm_count = _body(await nt.get_unread_count(str(org), adm, db))["count"]
    assert sub_count == 2  # own activation + broadcast
    assert adm_count == 2  # own admin copy + broadcast


@pytest.mark.asyncio
async def test_read_all_does_not_touch_other_users_rows(db):
    from app.api.v1 import notifications as nt
    from app.domain.entities.notification_entities import AppNotification
    from sqlalchemy import select
    org, sub, adm = await _seed(db)
    await nt.mark_all_notifications_read(str(org), sub, db)
    rows = (await db.execute(
        select(AppNotification).where(AppNotification.organization_id == org)
    )).scalars().all()
    by_title = {}
    for r in rows:
        by_title.setdefault(r.title, []).append(r.is_read)
    assert all(by_title["تم تفعيل اشتراكك في باقة أعمال + شخصي"])
    assert all(by_title["إعلان عام"])
    # admin's copy stays unread for the admin
    assert not any(by_title["اشتراك جديد — دفع إلكتروني"])


@pytest.mark.asyncio
async def test_cannot_mark_other_users_row_read(db):
    from fastapi import HTTPException
    from app.api.v1 import notifications as nt
    from app.domain.entities.notification_entities import AppNotification
    from sqlalchemy import select
    org, sub, adm = await _seed(db)
    admin_row = (await db.execute(
        select(AppNotification).where(AppNotification.title.like("اشتراك جديد%"))
    )).scalars().first()
    assert admin_row is not None
    with pytest.raises(HTTPException) as ei:
        await nt.mark_notification_read(admin_row.id, str(org), sub, db)
    assert ei.value.status_code == 404


@pytest.mark.asyncio
async def test_activation_payload_targets_exact_invoice(db):
    """Tap target: the user row payload deep-links its own invoice number."""
    from app.api.v1 import notifications as nt
    org, sub, adm = await _seed(db)
    payload = _body(await nt.list_notifications(1, 20, False, str(org), sub, db))
    act = [i for i in payload["items"] if "تم تفعيل اشتراكك" in i["title"]]
    assert len(act) == 1
    assert act[0]["action_payload"] == "/subscription/invoice?invoice_no=INV-9"
