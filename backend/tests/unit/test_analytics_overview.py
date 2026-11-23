"""Analytics overview tests (real DB).

Proves the dashboard stats source fix on a scratch database:
- org-based subscription truth (local receipt + Stripe card alike),
- source split without duplicates,
- active / expired classification,
- preset periods + custom range (incl. single day, end-of-day bounds,
  Riyadh timezone), smart bucketing, cumulative series, growth.

Scratch DB `fyona_test_analytics` is created and dropped by the module
fixture — production/dev data is never touched.
"""
import os
import uuid
import json
from datetime import datetime, timedelta, timezone

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

TEST_DB = "fyona_test_analytics"


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
        import app.domain.entities.admin_entities  # noqa: F401
        import app.domain.entities.auth_entities  # noqa: F401
        import app.domain.entities.subscription_invoice_entities  # noqa: F401
        import app.domain.entities.payment_entities  # noqa: F401
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

    @pytest_asyncio.fixture(autouse=True)
    async def _clean(db):
        yield
        from sqlalchemy import text
        for t in ("subscription_revenues", "subscription_invoices",
                  "subscription_requests", "users", "organizations"):
            try:
                await db.execute(text(f'TRUNCATE "{t}" CASCADE'))
            except Exception:
                await db.rollback()
        await db.commit()
else:
    @pytest.fixture()
    def db(pg_url):
        pytest.skip("pytest-asyncio not installed")


def _payload(res):
    data = json.loads(bytes(res.body).decode())
    return data["data"] if "data" in data else data


async def _seed(db, now):
    """Two active subs (local + Stripe), one expired, one trial, one none;
    users spread across time. Returns dict of ids."""
    from app.domain.entities.auth_entities import Organization, User
    from app.domain.entities.subscription_invoice_entities import SubscriptionInvoice
    from app.domain.entities.admin_entities import SubscriptionRequest

    def org(name, status, start, end, plan="personal"):
        o = Organization(id=uuid.uuid4(), name=name, slug=f"s-{uuid.uuid4().hex[:8]}",
                         subscription_status=status, subscription_plan=plan,
                         subscription_start_date=start, subscription_end_date=end)
        db.add(o)
        return o

    o_local = org("Local", "active", now - timedelta(days=5), now + timedelta(days=360))
    o_stripe = org("Stripe", "active", now - timedelta(days=3), now + timedelta(days=362))
    o_exp = org("Expired", "expired", now - timedelta(days=400), now - timedelta(days=35))
    o_trial = org("Trial", "trial", now - timedelta(days=2), now + timedelta(days=12), plan="trial")
    o_none = org("None", "none", None, None, plan=None)
    await db.flush()

    def user(o, days_ago, tag):
        u = User(id=uuid.uuid4(), organization_id=o.id,
                 email=f"{tag}_{uuid.uuid4().hex[:8]}@x.com", full_name=f"U {tag}",
                 created_at=now - timedelta(days=days_ago))
        db.add(u)
        return u

    user(o_local, 5, "u-local")
    user(o_stripe, 3, "u-stripe")
    user(o_stripe, 3, "u-stripe2")  # second user, same day (no-dup check)
    user(o_exp, 400, "u-exp")
    user(o_trial, 40, "u-trial")
    user(o_none, 200, "u-none")
    await db.flush()

    inv1 = SubscriptionInvoice(
        invoice_number="A-1", organization_id=o_local.id, user_id=None,
        plan_name="personal", period="yearly", amount=100, currency="SAR",
        status="paid", payment_method="bank_transfer",
        subscription_start_date=now - timedelta(days=5),
        subscription_end_date=now + timedelta(days=360),
        created_at=now - timedelta(days=5))
    inv2 = SubscriptionInvoice(
        invoice_number="A-2", organization_id=o_stripe.id, user_id=None,
        plan_name="business", period="yearly", amount=15, currency="USD",
        status="paid", payment_method="stripe", provider_payment_id="pi_a2",
        subscription_start_date=now - timedelta(days=3),
        subscription_end_date=now + timedelta(days=362),
        created_at=now - timedelta(days=3))
    # Second Stripe invoice for the SAME org: must not duplicate the org.
    inv3 = SubscriptionInvoice(
        invoice_number="A-3", organization_id=o_stripe.id, user_id=None,
        plan_name="business", period="yearly", amount=15, currency="USD",
        status="paid", payment_method="stripe", provider_payment_id="pi_a3",
        subscription_start_date=now - timedelta(days=1),
        subscription_end_date=now + timedelta(days=364),
        created_at=now - timedelta(days=1))
    inv4 = SubscriptionInvoice(
        invoice_number="A-4", organization_id=o_exp.id, user_id=None,
        plan_name="personal", period="yearly", amount=13, currency="USD",
        status="paid", payment_method="stripe", provider_payment_id="pi_a4",
        subscription_start_date=now - timedelta(days=400),
        subscription_end_date=now - timedelta(days=35),
        created_at=now - timedelta(days=400))
    db.add_all([inv1, inv2, inv3, inv4])
    db.add(SubscriptionRequest(user_id=None, organization_id=o_local.id,
                               plan_id="personal", plan_name="personal",
                               status="approved", period="yearly",
                               created_at=now - timedelta(days=6)))
    db.add(SubscriptionRequest(user_id=None, organization_id=o_none.id,
                               plan_id="personal", plan_name="personal",
                               status="pending", period="yearly",
                               created_at=now - timedelta(days=1)))
    await db.commit()
    return {"local": o_local.id, "stripe": o_stripe.id}


@pytest.mark.asyncio
async def test_overview_30d_counts_and_sources(db):
    from app.api.v1 import admin as adm
    now = datetime.now(timezone.utc)
    await _seed(db, now)
    d = _payload(await adm.analytics_overview("30d", None, None, db, None))
    subs = d["subscriptions"]
    assert subs["total"] == 4, subs  # local + stripe + expired + trial
    assert subs["active_total"] == 2
    assert subs["expired_total"] == 1
    by_src = {x["source"]: x["count"] for x in subs["by_source"]}
    assert by_src.get("international") == 2  # stripe-active + stripe-expired
    assert by_src.get("local") == 1
    assert subs["new_in_period"] == 3  # starts 5d + 3d ago + trial 2d ago
    assert d["users"]["new_in_period"] == 3  # 5d + two 3d users
    # cumulative consistency: before + trend == total
    trend = d["users_trend"]
    assert trend[-1]["cumulative"] == d["users"]["total"]
    assert trend[-1]["cumulative"] == d["users"]["total_before_period"] + sum(
        b["count"] for b in trend)


@pytest.mark.asyncio
async def test_overview_7d_90d_12m_grains(db):
    from app.api.v1 import admin as adm
    now = datetime.now(timezone.utc)
    await _seed(db, now)
    d7 = _payload(await adm.analytics_overview("7d", None, None, db, None))
    assert d7["grain"] == "day" and d7["days"] == 7
    assert d7["users"]["new_in_period"] == 3
    d90 = _payload(await adm.analytics_overview("90d", None, None, db, None))
    assert d90["grain"] == "week"
    assert d90["users"]["new_in_period"] == 4  # +40d user
    d12 = _payload(await adm.analytics_overview("12m", None, None, db, None))
    assert d12["grain"] == "month" and len(d12["users_trend"]) == 12
    assert d12["users"]["new_in_period"] == 5  # all but the 400d user


@pytest.mark.asyncio
async def test_custom_range_single_day_and_bounds(db):
    from app.api.v1 import admin as adm
    from zoneinfo import ZoneInfo
    from app.domain.entities.auth_entities import Organization, User
    riyadh = ZoneInfo("Asia/Riyadh")
    # Fixed Riyadh midday seeds: immune to UTC-midnight boundary flakes.
    noon = datetime(2026, 3, 15, 12, 0, tzinfo=riyadh).astimezone(timezone.utc)
    o = Organization(id=uuid.uuid4(), name="Single", slug=f"s-{uuid.uuid4().hex[:8]}",
                     subscription_status="active", subscription_plan="business",
                     subscription_start_date=noon,
                     subscription_end_date=noon + timedelta(days=365))
    db.add(o)
    await db.flush()
    for i in range(2):
        db.add(User(id=uuid.uuid4(), organization_id=o.id,
                    email=f"sd{i}_{uuid.uuid4().hex[:6]}@x.com",
                    full_name=f"SD{i}", created_at=noon))
    await db.commit()
    d = _payload(await adm.analytics_overview("custom", "2026-03-15", "2026-03-15", db, None))
    assert d["period"] == "custom"
    assert d["grain"] == "day"
    assert len(d["users_trend"]) == 1  # exactly one bucket
    assert d["users"]["new_in_period"] == 2
    assert d["subscriptions"]["new_in_period"] == 1
    assert d["users_trend"][0]["cumulative"] == 2


@pytest.mark.asyncio
async def test_custom_range_end_of_day_riyadh(db):
    """A payment at 23:30 Riyadh on the `to` day must be included; a payment
    2h later (next day Riyadh) must not."""
    from app.api.v1 import admin as adm
    from zoneinfo import ZoneInfo
    from app.domain.entities.auth_entities import Organization, User
    riyadh = ZoneInfo("Asia/Riyadh")
    o = Organization(id=uuid.uuid4(), name="Edge", slug=f"e-{uuid.uuid4().hex[:8]}",
                     subscription_status="active", subscription_plan="personal",
                     subscription_start_date=datetime(2026, 1, 10, 20, 0, tzinfo=timezone.utc),
                     subscription_end_date=datetime(2027, 1, 10, tzinfo=timezone.utc))
    db.add(o)
    await db.flush()
    # 2026-01-10 23:30 Riyadh == 20:30 UTC (inside) ; 2026-01-11 01:30 Riyadh == 22:30 UTC 10th (outside day 10? no:
    # 22:30 UTC Jan10 == 01:30 Riyadh Jan11 -> belongs to Jan 11, must be excluded from a Jan-10 single-day filter)
    db.add(User(id=uuid.uuid4(), organization_id=o.id, email=f"e1_{uuid.uuid4().hex[:6]}@x.com",
                full_name="E1", created_at=datetime(2026, 1, 10, 20, 30, tzinfo=timezone.utc)))
    db.add(User(id=uuid.uuid4(), organization_id=o.id, email=f"e2_{uuid.uuid4().hex[:6]}@x.com",
                full_name="E2", created_at=datetime(2026, 1, 10, 22, 30, tzinfo=timezone.utc)))
    await db.commit()
    d = _payload(await adm.analytics_overview("custom", "2026-01-10", "2026-01-10", db, None))
    assert d["users"]["new_in_period"] == 1
    d2 = _payload(await adm.analytics_overview("custom", "2026-01-10", "2026-01-11", db, None))
    assert d2["users"]["new_in_period"] == 2


@pytest.mark.asyncio
async def test_custom_range_mixed_sources_and_growth(db):
    from app.api.v1 import admin as adm
    now = datetime.now(timezone.utc)
    await _seed(db, now)
    frm = (now - timedelta(days=10)).date().isoformat()
    to = now.date().isoformat()
    d = _payload(await adm.analytics_overview("custom", frm, to, db, None))
    assert d["grain"] == "day"
    by_src = {x["source"]: x["count"] for x in d["subscriptions"]["by_source"]}
    assert by_src.get("international", 0) >= 1 and by_src.get("local", 0) >= 1
    # growth compares against the previous equal-length window
    assert isinstance(d["users"]["growth_pct"], (int, float))
    assert d["subscriptions"]["total"] == 4  # totals are current-state, not range-bound


@pytest.mark.asyncio
async def test_dashboard_stats_totals(db):
    from app.api.v1 import admin as adm
    now = datetime.now(timezone.utc)
    await _seed(db, now)
    d = _payload(await adm.dashboard_stats(db, None))
    assert d["subscriptions_total"] == 4
    assert d["subscriptions_active_total"] == 2
    assert d["subscriptions_expired_total"] == 1
    by_src = {x["source"]: x["count"] for x in d["subscriptions_by_source"]}
    assert by_src.get("international") == 2
    assert by_src.get("local") == 1
