"""Stripe payment/subscription integration tests (real per-test SQLite + fake Stripe SDK).

Covers: auth gates, catalog, checkout (disabled / plan-missing / price-missing /
success), webhook signature rejection + idempotency + activation, and admin
settings persistence (encrypted, no plaintext secret).
"""
import json
from uuid import uuid4

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine, select
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

from app.main import app
from app.core.config import settings
from app.core.database import Base, get_db
from app.core.security import create_access_token
from app.domain.entities import auth_entities  # noqa: F401  (register tables)
from app.domain.entities import payment_entities  # noqa: F401  (registers plans+stripe tables)
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.admin_entities import Plan
from app.domain.entities.payment_entities import StripePayment, StripeSubscription, StripeWebhookEvent, AppSetting
from app.domain.services import payment_service as ps_mod

pytestmark = pytest.mark.asyncio

API = settings.API_PREFIX


# ── Per-test SQLite DB ─────────────────────────────────────────────────

@pytest.fixture()
def _sync_engine(tmp_path):
    db_file = str(tmp_path / "payments.db")
    eng = create_engine(f"sqlite:///{db_file}", connect_args={"check_same_thread": False})
    Base.metadata.create_all(eng)
    return eng


@pytest.fixture()
def _async_engine(_sync_engine):
    return create_async_engine(f"sqlite+aiosqlite:///{_sync_engine.url.database}")


@pytest.fixture()
def _session_factory(_async_engine):
    return async_sessionmaker(_async_engine, expire_on_commit=False)


@pytest.fixture()
async def db(_session_factory):
    async with _session_factory() as session:
        yield session


@pytest.fixture()
async def client(db, monkeypatch):
    monkeypatch.setattr(settings, "STRIPE_ENABLED", False)
    monkeypatch.setattr(settings, "STRIPE_SECRET_KEY", "")
    monkeypatch.setattr(settings, "STRIPE_WEBHOOK_SECRET", "whsec_test")
    monkeypatch.setattr(settings, "API_BASE_URL", "http://127.0.0.1:8001")
    app.dependency_overrides[get_db] = lambda: db
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://localhost") as ac:
        yield ac
    app.dependency_overrides.clear()


# ── Tenants ────────────────────────────────────────────────────────────

def _token(user_id, org_id, role):
    return create_access_token(str(user_id), str(org_id), role)


def _hdr(user):
    role = "owner"
    return {"Authorization": f"Bearer {_token(user.id, user.organization_id, role)}"}


@pytest.fixture()
async def org(db):
    o = Organization(id=uuid4(), name="Pmt Org", slug=f"org-{uuid4().hex[:8]}")
    db.add(o)
    await db.commit()
    return o


@pytest.fixture()
async def admin_user(db, org):
    u = User(id=uuid4(), organization_id=org.id, full_name="Admin",
             email=f"admin-{uuid4().hex[:8]}@test.com", password_hash="x",
             role="admin", is_platform_admin=True)
    db.add(u)
    await db.commit()
    return u


@pytest.fixture()
async def normal_user(db, org):
    u = User(id=uuid4(), organization_id=org.id, full_name="User",
             email=f"user-{uuid4().hex[:8]}@test.com", password_hash="x",
             role="employee", is_platform_admin=False)
    db.add(u)
    await db.commit()
    return u


# ── Fake Stripe ────────────────────────────────────────────────────────

class _FakeSession:
    def __init__(self, sid, url, metadata):
        self.id = sid
        self.url = url
        self.payment_intent = "pi_test_1"
        self.subscription = "sub_test_1"
        self.metadata = metadata


class _FakeCheckout:
    def __init__(self):
        self.created = []
        self.sessions = []
        self.Session = self  # service calls stripe.checkout.Session.create(...)

    def create(self, **kwargs):
        sid = f"cs_test_{len(self.sessions) + 1}"
        sess = _FakeSession(sid, "https://checkout.stripe.com/pay/cs_test_1", kwargs.get("metadata") or {})
        sess.amount_total = (kwargs.get("line_items") or [{}])[0].get("price_data", {}).get("unit_amount")
        sess.currency = (kwargs.get("line_items") or [{}])[0].get("price_data", {}).get("currency")
        self.sessions.append(sess)
        self.created.append(kwargs)
        return sess


class _FakePaymentIntent:
    def __init__(self, pid, client_secret, amount=None, currency=None, metadata=None):
        self.id = pid
        self.client_secret = client_secret
        self.amount = amount
        self.currency = currency
        self.metadata = metadata or {}

    def retrieve(self, intent_id):
        return self


class _FakePaymentIntents:
    def __init__(self):
        self.created = []
        self.intents = []
        self.PaymentIntent = self

    def create(self, **kwargs):
        pid = f"pi_test_{len(self.intents) + 1}"
        intent = _FakePaymentIntent(
            pid,
            client_secret=f"{pid}_secret",
            amount=kwargs.get("amount"),
            currency=kwargs.get("currency"),
            metadata=kwargs.get("metadata"),
        )
        self.intents.append(intent)
        self.created.append(kwargs)
        return intent

    def retrieve(self, intent_id):
        return _FakePaymentIntent(intent_id, f"{intent_id}_secret")


class _FakeStripe:
    def __init__(self):
        self.api_key = None
        self.checkout = _FakeCheckout()
        self.PaymentIntent = _FakePaymentIntents()

        # Minimal Price stub (used as FX fallback when live FX is unavailable).
        class _P:
            def retrieve(self, price_id):
                return _FakeObj(unit_amount=700000, currency="sar")

        self.Price = _P()

        outer = self

        class _W:
            def construct_event(self, payload, sig_header, secret, tolerance=None):
                if sig_header != "good":
                    raise ValueError("Invalid Stripe signature")
                sess = outer.checkout.sessions[-1] if outer.checkout.sessions else _FakeSession("cs_x", "", {})
                return _FakeEvent(id="evt_test_1", type="checkout.session.completed",
                                  data=_FakeObj(object=sess))

        self.Webhook = _W()
        self.Account = type("A", (), {"retrieve": staticmethod(lambda *a, **k: None)})()
        self.balances = type("B", (), {"Balance": type("C", (), {"retrieve": staticmethod(lambda *a, **k: {})})()})()


class _FakeEvent:
    def __init__(self, id, type, data):
        self.id = id
        self.type = type
        self.data = data


class _FakeObj:
    def __init__(self, **kw):
        self.__dict__.update(kw)


@pytest.fixture()
def fake_stripe(monkeypatch):
    fake = _FakeStripe()
    monkeypatch.setattr(ps_mod, "stripe_sdk", fake)
    return fake


@pytest.fixture()
def stripe_enabled(monkeypatch, fake_stripe):
    monkeypatch.setattr(settings, "STRIPE_ENABLED", True)
    monkeypatch.setattr(settings, "STRIPE_SECRET_KEY", "sk_test_xxx")
    return fake_stripe


@pytest.fixture()
def fx_stub(monkeypatch):
    """Deterministic FX for hermetic quote/payment tests (no network)."""
    class _FakeRates:
        async def get_all_rates(self, force_refresh=False):
            return {
                "global": {"USD": 1.0, "SAR": 3.75, "EUR": 0.92, "AED": 3.67},
                "yemen": {"sanaa": {"USD": {"average": 1542.0}}},
            }

    monkeypatch.setattr(
        "app.domain.services.currency_service.CurrencyService.get_instance",
        staticmethod(lambda: _FakeRates()),
    )
    return None


@pytest.fixture()
async def paid_plan(db):
    p = Plan(
        id=uuid4(), name="باقة أعمال", name_en="Business Plan",
        price_monthly=0, price_yearly=7000, currency="SAR",
        features='["a","b"]', color="#1565C0", icon="business", is_active=True,
        stripe_product_id="prod_test", stripe_price_id_monthly="price_m",
        stripe_price_id_yearly="price_y",
    )
    db.add(p)
    await db.commit()
    return p


# ── Tests: auth & catalog ──────────────────────────────────────────────

class TestPaymentsAuth:
    async def test_plans_requires_auth(self, client):
        r = await client.get(f"{API}/payments/stripe/plans")
        assert r.status_code in (401, 403)

    async def test_plans_returns_catalog(self, client, admin_user):
        r = await client.get(f"{API}/payments/stripe/plans", headers=_hdr(admin_user))
        assert r.status_code == 200, r.text
        plans = r.json()["data"]["plans"]
        assert isinstance(plans, list) and len(plans) >= 3

    async def test_admin_list_requires_admin(self, client, normal_user):
        r = await client.get(f"{API}/payments/stripe/payments", headers=_hdr(normal_user))
        assert r.status_code in (401, 403)


# ── Tests: checkout ────────────────────────────────────────────────────

class TestCheckout:
    async def test_requires_stripe_enabled(self, client, admin_user, paid_plan):
        r = await client.post(
            f"{API}/payments/stripe/create-checkout-session",
            json={"plan_id": str(paid_plan.id), "period": "yearly"}, headers=_hdr(admin_user),
        )
        assert r.status_code == 403

    async def test_invalid_plan(self, client, admin_user, stripe_enabled):
        r = await client.post(
            f"{API}/payments/stripe/create-checkout-session",
            json={"plan_id": str(uuid4()), "period": "yearly"}, headers=_hdr(admin_user),
        )
        assert r.status_code == 400

    async def test_plan_missing_price(self, client, admin_user, stripe_enabled, db):
        p = Plan(id=uuid4(), name="باقة شخصية", name_en="Personal",
                 price_yearly=5000, currency="SAR", features="[]", is_active=True)
        db.add(p)
        await db.commit()
        r = await client.post(
            f"{API}/payments/stripe/create-checkout-session",
            json={"plan_id": str(p.id), "period": "yearly"}, headers=_hdr(admin_user),
        )
        assert r.status_code == 400

    async def test_creates_session(self, client, admin_user, stripe_enabled, paid_plan, db):
        r = await client.post(
            f"{API}/payments/stripe/create-checkout-session",
            json={"plan_id": str(paid_plan.id), "period": "yearly"}, headers=_hdr(admin_user),
        )
        assert r.status_code == 200, r.text
        d = r.json()["data"]
        assert d["checkout_url"].startswith("https://checkout.stripe.com")
        assert d["plan_id"] == str(paid_plan.id)
        row = (await db.execute(select(StripePayment).where(StripePayment.plan_id == paid_plan.id))).scalar_one_or_none()
        assert row is not None and row.status == "pending"

    async def test_payment_intent_with_currency_and_idempotency(self, client, admin_user, stripe_enabled, fx_stub, paid_plan, db):
        r1 = await client.post(
            f"{API}/payments/stripe/create-payment-intent",
            json={"plan_id": str(paid_plan.id), "period": "yearly",
                  "target_currency": "usd", "idempotency_key": "idem-1"},
            headers=_hdr(admin_user),
        )
        assert r1.status_code == 200, r1.text
        d1 = r1.json()["data"]
        assert d1["currency"] == "USD"
        assert d1["client_secret"]
        # Retry with the same idempotency key reuses the same pending payment.
        r2 = await client.post(
            f"{API}/payments/stripe/create-payment-intent",
            json={"plan_id": str(paid_plan.id), "period": "yearly",
                  "target_currency": "usd", "idempotency_key": "idem-1"},
            headers=_hdr(admin_user),
        )
        assert r2.status_code == 200, r2.text
        d2 = r2.json()["data"]
        assert d2["payment_id"] == d1["payment_id"]
        rows = (await db.execute(
            select(StripePayment).where(StripePayment.idempotency_key == "idem-1")
        )).scalars().all()
        assert len(rows) == 1
        assert rows[0].currency == "USD"
        assert rows[0].base_currency in ("YER", "SAR")
        assert rows[0].idempotency_key == "idem-1"
        assert rows[0].amount_minor and rows[0].amount_minor > 0

    async def test_quote_plans_by_currency(self, client, admin_user, stripe_enabled, fx_stub, paid_plan):
        r = await client.get(f"{API}/payments/stripe/plans?currency=usd", headers=_hdr(admin_user))
        assert r.status_code == 200, r.text
        plans = r.json()["data"]["plans"]
        target = next((p for p in plans if p["id"] == str(paid_plan.id)), None)
        assert target is not None
        assert target["quote_currency"] == "USD"
        assert target["quote_amount_yearly"] and target["quote_amount_yearly"] > 0
        assert target["quote_fx_source"] in ("live_fx", "stripe_price")

    async def test_webhook_rejects_amount_mismatch(self, client, admin_user, stripe_enabled, fx_stub, paid_plan, db):
        await client.post(
            f"{API}/payments/stripe/create-checkout-session",
            json={"plan_id": str(paid_plan.id), "period": "yearly"}, headers=_hdr(admin_user),
        )
        # Tamper with the recorded expectation so the webhook's amount check fails.
        row = (await db.execute(select(StripePayment).where(StripePayment.plan_id == paid_plan.id))).scalar_one_or_none()
        row.amount_minor = (row.amount_minor or 1) + 7_000_000
        await db.commit()
        r = await client.post(
            f"{API}/payments/stripe/webhook",
            content=b'{"type":"checkout.session.completed"}',
            headers={"stripe-signature": "good", "content-type": "application/json"},
        )
        assert r.status_code == 200, r.text
        pay = (await db.execute(select(StripePayment).where(StripePayment.plan_id == paid_plan.id))).scalar_one_or_none()
        assert pay.status == "failed"
        org = (await db.execute(select(Organization).where(Organization.id == admin_user.organization_id))).scalar_one()
        assert org.subscription_status != "active"


# ── Tests: webhook ────────────────────────────────────────────────────

class TestWebhook:
    async def test_invalid_signature(self, client, fake_stripe):
        r = await client.post(
            f"{API}/payments/stripe/webhook",
            content=b'{"type":"x"}',
            headers={"stripe-signature": "bad", "content-type": "application/json"},
        )
        assert r.status_code == 400

    async def test_completes_payment_and_activates(self, client, admin_user, stripe_enabled, paid_plan, db):
        await client.post(
            f"{API}/payments/stripe/create-checkout-session",
            json={"plan_id": str(paid_plan.id), "period": "yearly"}, headers=_hdr(admin_user),
        )
        r = await client.post(
            f"{API}/payments/stripe/webhook",
            content=b'{"type":"checkout.session.completed"}',
            headers={"stripe-signature": "good", "content-type": "application/json"},
        )
        assert r.status_code == 200, r.text
        pay = (await db.execute(select(StripePayment).where(StripePayment.status == "paid"))).scalar_one_or_none()
        assert pay is not None
        subs = (await db.execute(
            select(StripeSubscription).where(StripeSubscription.organization_id == admin_user.organization_id)
        )).scalars().all()
        assert subs and subs[0].status == "active"
        org = (await db.execute(select(Organization).where(Organization.id == admin_user.organization_id))).scalar_one()
        assert org.subscription_status == "active"

    async def test_idempotent_duplicate(self, client, admin_user, stripe_enabled, paid_plan, db):
        await client.post(
            f"{API}/payments/stripe/create-checkout-session",
            json={"plan_id": str(paid_plan.id), "period": "yearly"}, headers=_hdr(admin_user),
        )
        body = b'{"type":"checkout.session.completed"}'
        hdrs = {"stripe-signature": "good", "content-type": "application/json"}
        r1 = await client.post(f"{API}/payments/stripe/webhook", content=body, headers=hdrs)
        r2 = await client.post(f"{API}/payments/stripe/webhook", content=body, headers=hdrs)
        assert r1.status_code == 200 and r2.status_code == 200
        logged = (await db.execute(select(StripeWebhookEvent).where(StripeWebhookEvent.event_id == "evt_test_1"))).scalar_one_or_none()
        assert logged is not None and logged.status == "processed"


# ── Tests: admin ──────────────────────────────────────────────────────

class TestAdminSettings:
    async def test_settings_no_secret_leak(self, client, admin_user):
        r = await client.get(f"{API}/payments/stripe/settings", headers=_hdr(admin_user))
        assert r.status_code == 200, r.text
        blob = json.dumps(r.json()["data"])
        # Publishable key (public) may travel; the actual *secret* value must not.
        assert "sk_test_secret" not in blob
        assert r.json()["data"]["secret_key_configured"] is False

    async def test_save_settings_encrypts_secret(self, client, admin_user, db):
        r = await client.post(
            f"{API}/payments/stripe/settings",
            json={"stripe_enabled": True, "stripe_mode": "test",
                  "stripe_publishable_key": "pk_test_xxx",
                  "stripe_secret_key": "sk_test_secret",
                  "stripe_webhook_secret": "whsec_test"},
            headers=_hdr(admin_user),
        )
        assert r.status_code == 200, r.text
        row = (await db.execute(select(AppSetting).where(AppSetting.key == "stripe_secret_key"))).scalar_one_or_none()
        assert row is not None
        assert "sk_test_secret" not in row.value_encrypted
