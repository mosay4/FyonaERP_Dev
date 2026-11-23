"""Stripe bank + currency separation + reports integration tests.

REAL database (scratch DB on local Postgres), REAL service functions, REAL
endpoint functions. No Stripe network calls: _book_stripe_revenue is called
directly with verified amounts (as confirm_stripe_payment / invoice.paid
would after Stripe verification).

The scratch database `fyona_test_banks` is created and dropped by the
module fixture — production/dev data is never touched.
"""
import os
import uuid
from datetime import datetime, timezone

import pytest
import pytest_asyncio

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")
os.environ.setdefault("CELERY_BROKER_URL", "redis://localhost:6379/1")
os.environ.setdefault("CELERY_RESULT_BACKEND", "redis://localhost:6379/2")

TEST_DB = "fyona_test_banks"


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
    # replace database name (last path segment, keep query string)
    head, _, tail = base.rpartition("/")
    dbpart, sep, query = tail.partition("?")
    out = f"{head}/{dbname}{sep}{query}" if sep else f"{head}/{dbname}"
    return out


def _raw_dsn_for(dbname):
    # asyncpg wants postgresql://, not the SQLAlchemy postgresql+asyncpg://
    return _dsn_for(dbname).replace("postgresql+asyncpg://", "postgresql://", 1)


import pytest

try:
    import pytest_asyncio
    _has_pa = True
except Exception:
    _has_pa = False
    pytest_asyncio = None


@pytest.fixture(scope="module")
def pg_url():
    """Create the scratch DB + schema once (own loop, closed after)."""
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
        admin = await asyncpg.connect(_raw_dsn_for("postgres"))
        try:
            # terminate backends so DROP succeeds
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
        for t in ("admin_operations", "subscription_revenues",
                  "subscription_invoices", "subscription_requests",
                  "platform_bank_accounts"):
            try:
                await db.execute(text(f'TRUNCATE "{t}" CASCADE'))
            except Exception:
                await db.rollback()
        await db.commit()
else:
    @pytest.fixture()
    def db(pg_url):
        pytest.skip("pytest-asyncio not installed")


async def _book(svc_db, amount, currency, pid, org_id=None, user_id=None):
    from app.domain.services.payment_service import PaymentService
    svc = PaymentService(svc_db)
    org = type("O", (), {"id": org_id or uuid.uuid4()})()
    await svc._book_stripe_revenue(
        org, user_id or uuid.uuid4(), "personal", "yearly",
        amount, currency, pid,
    )


@pytest.mark.asyncio
async def test_stripe_bank_created_once_and_protected(db):
    from app.api.v1 import admin as adm
    b1 = await adm.ensure_stripe_bank(db)
    await db.commit()
    b2 = await adm.ensure_stripe_bank(db)
    await db.commit()
    assert str(b1.id) == str(b2.id)
    assert b1.bank_name == "Stripe"
    assert b1.is_system is True
    assert b1.is_active is True
    # No currency pre-created
    assert not (b1.currencies or "").strip()


@pytest.mark.asyncio
async def test_first_usd_then_usd_again_same_balance(db):
    from app.api.v1 import admin as adm
    from app.domain.entities.admin_entities import SubscriptionRevenue
    from sqlalchemy import select, func
    await _book(db, 30.0, "USD", "pi_usd_1")
    await db.commit()
    await _book(db, 20.0, "USD", "pi_usd_2")
    await db.commit()
    bank = await adm.ensure_stripe_bank(db)
    curs = adm._bank_currency_list(bank)
    usd_rows = [c for c in curs if c["currency"] == "USD"]
    assert len(usd_rows) == 1, f"duplicate USD currency entries: {curs}"
    total = (await db.execute(
        select(func.coalesce(func.sum(SubscriptionRevenue.amount), 0)).where(
            SubscriptionRevenue.bank_account_id == bank.id,
            SubscriptionRevenue.currency == "USD",
        )
    )).scalar() or 0
    assert float(total) == 50.0


@pytest.mark.asyncio
async def test_sar_and_usd_never_merged(db):
    from app.api.v1 import admin as adm
    await _book(db, 30.0, "USD", "pi_mix_usd")
    await _book(db, 7000.0, "YER", "pi_mix_yer")
    await db.commit()
    bank = await adm.ensure_stripe_bank(db)
    payload = adm._bank_currencies_payload(
        bank, await adm._bank_currency_balances(db, bank.id),
        await adm._ops_by_currency(db, bank.id),
    )
    by_cur = {c["currency"]: c["balance"] for c in payload}
    assert by_cur.get("USD") == 30.0
    assert by_cur.get("YER") == 7000.0
    # No single mixed number anywhere in the payload
    assert all(isinstance(c["balance"], float) for c in payload)


@pytest.mark.asyncio
async def test_webhook_repeat_books_once(db):
    from app.domain.entities.admin_entities import SubscriptionRevenue
    from sqlalchemy import select, func
    await _book(db, 49.0, "SAR", "pi_repeat_9")
    await db.commit()
    await _book(db, 49.0, "SAR", "pi_repeat_9")  # redelivery
    await db.commit()
    n = (await db.execute(
        select(func.count(SubscriptionRevenue.id)).where(
            SubscriptionRevenue.provider_payment_id == "pi_repeat_9")
    )).scalar() or 0
    assert n == 1


@pytest.mark.asyncio
async def test_stripe_bank_cannot_be_deleted_or_disabled_or_renamed(db):
    from fastapi import HTTPException
    from app.api.v1 import admin as adm
    from app.api.v1.admin import PlatformBankUpdate
    bank = await adm.ensure_stripe_bank(db)
    await db.commit()
    # delete
    with pytest.raises(HTTPException) as ei:
        await adm.delete_platform_bank(str(bank.id), db, None)
    assert ei.value.status_code == 400
    # deactivate
    with pytest.raises(HTTPException) as ei2:
        await adm.update_platform_bank(str(bank.id), PlatformBankUpdate(is_active=False), db, None)
    assert ei2.value.status_code == 400
    # rename
    with pytest.raises(HTTPException) as ei3:
        await adm.update_platform_bank(str(bank.id), PlatformBankUpdate(bank_name="Other"), db, None)
    assert ei3.value.status_code == 400
    # create impostor
    from app.api.v1.admin import PlatformBankCreate
    with pytest.raises(HTTPException) as ei4:
        await adm.create_platform_bank(PlatformBankCreate(bank_name="stripe"), db, None)
    assert ei4.value.status_code == 400
    # still there and active
    await db.refresh(bank)
    assert bank.is_active is True and bank.bank_name == "Stripe"


@pytest.mark.asyncio
async def test_withdraw_guard_is_per_currency(db):
    from fastapi import HTTPException
    from app.api.v1 import admin as adm
    from app.api.v1.admin import AdminOperationCreate
    await _book(db, 100.0, "USD", "pi_guard_usd")
    await db.commit()
    bank = await adm.ensure_stripe_bank(db)
    me = uuid.uuid4()
    # SAR withdrawal must fail despite 100 USD balance (no mixing)
    with pytest.raises(HTTPException) as ei:
        await adm.create_admin_operation(
            AdminOperationCreate(bank_account_id=str(bank.id), type="withdraw",
                                 amount=10, currency="SAR"), me, db, None)
    assert ei.value.status_code == 400
    # USD withdrawal within balance succeeds
    out = await adm.create_admin_operation(
        AdminOperationCreate(bank_account_id=str(bank.id), type="withdraw",
                             amount=40, currency="USD"), me, db, None)
    assert out is not None


@pytest.mark.asyncio
async def test_stats_have_no_mixed_total(db):
    from app.api.v1 import admin as adm
    await _book(db, 10.0, "USD", "pi_stat_1")
    await _book(db, 5.0, "SAR", "pi_stat_2")
    await db.commit()
    res = await adm.accounting_stats(db, None)
    body = res.body.decode() if hasattr(res, "body") else None
    import json as _json
    data = _by = None
    # `ok()` returns JSONResponse; parse it
    data = _json.loads(bytes(res.body).decode())
    payload = data["data"] if "data" in data else data
    assert "total_balance" not in payload, "mixed-currency total must be gone"
    assert "totals_by_currency" in payload
    by_cur = {x["currency"]: x["amount"] for x in payload["totals_by_currency"]}
    assert by_cur.get("USD", 0) >= 10.0
    assert by_cur.get("SAR", 0) >= 5.0


@pytest.mark.asyncio
async def test_payment_report_splits_channels(db):
    from app.api.v1 import admin as adm
    from app.domain.entities.subscription_invoice_entities import SubscriptionInvoice
    from app.domain.entities.auth_entities import Organization, User
    now = datetime.now(timezone.utc)
    org_ids = [uuid.uuid4() for _ in range(3)]
    user_ids = [uuid.uuid4() for _ in range(3)]
    for i, oid in enumerate(org_ids):
        db.add(Organization(id=oid, name=f"Test Org {i}", slug=f"test-org-{oid.hex[:8]}"))
    await db.flush()
    for i, (uid, oid) in enumerate(zip(user_ids, org_ids)):
        db.add(User(id=uid, organization_id=oid, email=f"tuser{i}_{uid.hex[:8]}@x.com",
                    full_name=f"Test User {i}"))
    await db.flush()
    rows = [
        SubscriptionInvoice(invoice_number="T-INV-1", organization_id=org_ids[0],
                            user_id=user_ids[0], plan_name="personal", period="yearly",
                            amount=100, currency="SAR", status="paid",
                            payment_method="bank_transfer", subscription_start_date=now,
                            subscription_end_date=now),
        SubscriptionInvoice(invoice_number="T-INV-2", organization_id=org_ids[1],
                            user_id=user_ids[1], plan_name="business", period="yearly",
                            amount=15, currency="USD", status="paid",
                            payment_method="stripe", provider_payment_id="pi_rep_1",
                            subscription_start_date=now, subscription_end_date=now),
        SubscriptionInvoice(invoice_number="T-INV-3", organization_id=org_ids[2],
                            user_id=user_ids[2], plan_name="business", period="yearly",
                            amount=49, currency="SAR", status="paid",
                            payment_method="stripe", provider_payment_id="pi_rep_2",
                            subscription_start_date=now, subscription_end_date=now),
    ]
    db.add_all(rows)
    await db.commit()
    res = await adm.subscription_payment_report(None, None, db, None)
    import json as _json
    payload = _json.loads(bytes(res.body).decode())
    payload = payload["data"] if "data" in payload else payload
    assert payload["local_paid_count"] >= 1
    assert payload["international_paid_count"] >= 2
    intl = {x["currency"]: x["amount"] for x in payload["international_by_currency"]}
    assert intl.get("USD", 0) >= 15
    assert intl.get("SAR", 0) >= 49
    plans = {x["plan"]: x["count"] for x in payload["plan_distribution"]}
    assert plans.get("business", 0) >= 2
    assert len(payload["recent_payments"]) >= 3


@pytest.mark.asyncio
async def test_requests_default_is_pending(db):
    from app.api.v1 import admin as adm
    from app.domain.entities.admin_entities import SubscriptionRequest
    import json as _json
    db.add_all([
        SubscriptionRequest(user_id=uuid.uuid4(), organization_id=uuid.uuid4(),
                            plan_id="personal", plan_name="personal", status="pending"),
        SubscriptionRequest(user_id=uuid.uuid4(), organization_id=uuid.uuid4(),
                            plan_id="business", plan_name="business", status="approved"),
    ])
    await db.commit()

    def _payload(res):
        d = _json.loads(bytes(res.body).decode())
        return d["data"] if "data" in d else d

    # Absent status param -> pending only
    only_pending = _payload(await adm.list_subscription_requests(None, None, None, db, None))
    assert only_pending["total"] >= 1
    assert all(r["status"] == "pending" for r in only_pending["requests"])
    # Explicit all -> everything
    everything = _payload(await adm.list_subscription_requests("all", None, None, db, None))
    assert everything["total"] >= 2


@pytest.mark.asyncio
async def test_legacy_stripe_revenues_backfilled(db):
    from app.api.v1 import admin as adm
    from app.domain.entities.admin_entities import SubscriptionRevenue
    from sqlalchemy import select
    db.add(SubscriptionRevenue(
        organization_id=uuid.uuid4(), user_id=uuid.uuid4(),
        bank_account_id=None, plan_name="personal", period="yearly",
        amount=13, currency="USD", provider_payment_id="pi_legacy_1",
        note="legacy stripe row",
    ))
    await db.commit()
    bank = await adm.ensure_stripe_bank(db)
    await db.commit()
    row = (await db.execute(
        select(SubscriptionRevenue).where(
            SubscriptionRevenue.provider_payment_id == "pi_legacy_1")
    )).scalar_one()
    assert row.bank_account_id is not None and str(row.bank_account_id) == str(bank.id)
