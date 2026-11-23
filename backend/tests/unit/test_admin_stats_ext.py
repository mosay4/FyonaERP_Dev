"""Admin stats extensions: Stripe invoice filter + converted revenue.

Scratch DB `fyona_test_admin_stats` (created/dropped by module fixture).
FX engine is stubbed (no network): conversion math itself is the engine's
(tested elsewhere); here we prove wiring, ranges, totals and filters.
"""
import os
import uuid
import json
from datetime import datetime, timezone, timedelta
from unittest.mock import AsyncMock, MagicMock, patch

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

TEST_DB = "fyona_test_admin_stats"


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


def _body(res):
    data = json.loads(bytes(res.body).decode())
    return data["data"] if "data" in data else data


async def _mk_org_user(db, tag):
    from app.domain.entities.auth_entities import Organization, User
    oid, uid = uuid.uuid4(), uuid.uuid4()
    db.add(Organization(id=oid, name=f"O {tag}", slug=f"s-{oid.hex[:8]}"))
    db.add(User(id=uid, organization_id=oid, email=f"{tag}_{uid.hex[:8]}@x.com",
                full_name=f"U {tag}"))
    await db.flush()
    return oid, uid


class _FakeFX:
    """Stub engine: USD base, SAR=0.266 USD, YER unknown."""
    RATES = {"USD": 1.0, "SAR": 0.266, "EUR": 1.08}

    async def convert(self, amount, cur, target):
        cur, target = cur.upper(), target.upper()
        if cur == target:
            return float(amount)
        if cur in self.RATES and target in self.RATES:
            return round(float(amount) * self.RATES[cur] / self.RATES[target], 4)
        return None

    async def get_all_rates(self):
        return {"meta": {"global_source": "test",
                         "yemen_source": "test",
                         "fetched_at": "2026-01-01T00:00:00+00:00"}}


@pytest.mark.asyncio
async def test_invoice_payment_method_filter(db):
    from app.api.v1 import subscription_invoices as inv_api
    from app.domain.entities.subscription_invoice_entities import SubscriptionInvoice
    now = datetime.now(timezone.utc)
    oid, uid = await _mk_org_user(db, "flt")
    db.add_all([
        SubscriptionInvoice(invoice_number="F-S1", organization_id=oid, user_id=uid,
                            plan_name="business", period="yearly", amount=15,
                            currency="USD", status="paid", payment_method="stripe",
                            provider_payment_id="pi_f1",
                            subscription_start_date=now, subscription_end_date=now),
        SubscriptionInvoice(invoice_number="F-L1", organization_id=oid, user_id=uid,
                            plan_name="personal", period="yearly", amount=100,
                            currency="SAR", status="paid", payment_method="bank_transfer",
                            subscription_start_date=now, subscription_end_date=now),
    ])
    await db.commit()
    only_stripe = _body(await inv_api.admin_list_subscription_invoices(
        None, "paid", "stripe", db, None))
    assert [i["invoice_number"] for i in only_stripe] == ["F-S1"]
    assert only_stripe[0]["organization_id"] == str(oid)
    all_paid = _body(await inv_api.admin_list_subscription_invoices(
        None, "paid", None, db, None))
    assert {i["invoice_number"] for i in all_paid} == {"F-S1", "F-L1"}


@pytest.mark.asyncio
async def test_revenue_converted_total_and_lines(db):
    from app.api.v1 import admin as adm
    from app.domain.entities.admin_entities import SubscriptionRevenue
    now = datetime.now(timezone.utc)
    oid, uid = await _mk_org_user(db, "conv")
    db.add_all([
        SubscriptionRevenue(organization_id=oid, user_id=uid, plan_name="business",
                            period="yearly", amount=100, currency="SAR",
                            provider_payment_id="pi_c1"),
        SubscriptionRevenue(organization_id=oid, user_id=uid, plan_name="personal",
                            period="yearly", amount=15, currency="USD",
                            provider_payment_id="pi_c2"),
    ])
    await db.commit()
    # Patch the engine class used inside the endpoint (lazy import).
    import app.domain.services.currency_service as cs_mod
    with patch.object(cs_mod.CurrencyService, "get_instance",
                      return_value=_FakeFX()):
        payload = _body(await adm.analytics_revenue_converted(
            "USD", "30d", None, None, db, None))
    assert payload["target_currency"] == "USD"
    by_cur = {x["currency"]: x for x in payload["lines"]}
    assert by_cur["SAR"]["amount"] == 100
    assert by_cur["SAR"]["converted"] == round(100 * 0.266, 2)
    assert by_cur["USD"]["converted"] == 15
    assert payload["total"] == round(round(100 * 0.266, 2) + 15, 2)
    assert payload["unconverted"] == []
    assert payload["rates_meta"]["global_source"] == "test"


@pytest.mark.asyncio
async def test_revenue_converted_unconverted_and_range(db):
    from app.api.v1 import admin as adm
    from app.domain.entities.admin_entities import SubscriptionRevenue
    import app.domain.services.currency_service as cs_mod
    now = datetime.now(timezone.utc)
    oid, uid = await _mk_org_user(db, "conv2")
    old = SubscriptionRevenue(organization_id=oid, user_id=uid, plan_name="x",
                              period="yearly", amount=999, currency="USD",
                              provider_payment_id="pi_old")
    old.created_at = now - timedelta(days=60)
    new = SubscriptionRevenue(organization_id=oid, user_id=uid, plan_name="x",
                              period="yearly", amount=50, currency="XXX",
                              provider_payment_id="pi_new")
    db.add_all([old, new])
    await db.commit()
    with patch.object(cs_mod.CurrencyService, "get_instance",
                      return_value=_FakeFX()):
        payload = _body(await adm.analytics_revenue_converted(
            "SAR", "30d", None, None, db, None))
    # 60-day-old row excluded by the 30d window; XXX has no rate.
    by_cur = {x["currency"]: x for x in payload["lines"]}
    assert set(by_cur) == {"XXX"}
    assert by_cur["XXX"]["converted"] is None
    assert payload["total"] == 0
    assert payload["unconverted"] == [{"currency": "XXX", "amount": 50.0}]


@pytest.mark.asyncio
async def test_revenue_converted_custom_range(db):
    from app.api.v1 import admin as adm
    from app.domain.entities.admin_entities import SubscriptionRevenue
    import app.domain.services.currency_service as cs_mod
    oid, uid = await _mk_org_user(db, "conv3")
    r = SubscriptionRevenue(organization_id=oid, user_id=uid, plan_name="x",
                            period="yearly", amount=10, currency="USD",
                            provider_payment_id="pi_c3")
    r.created_at = datetime(2026, 1, 10, 12, 0, tzinfo=timezone.utc)
    db.add(r)
    await db.commit()
    with patch.object(cs_mod.CurrencyService, "get_instance",
                      return_value=_FakeFX()):
        inside = _body(await adm.analytics_revenue_converted(
            "USD", "custom", "2026-01-10", "2026-01-10", db, None))
        outside = _body(await adm.analytics_revenue_converted(
            "USD", "custom", "2026-01-11", "2026-01-11", db, None))
    assert inside["period"] == "custom"
    assert inside["total"] == 10
    assert outside["total"] == 0
    assert outside["lines"] == []
