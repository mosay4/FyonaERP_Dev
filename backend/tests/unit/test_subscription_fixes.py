"""Subscription/payment fix verification tests (§18).

Covers the fail-closed invoice fix, Stripe-amount trust, price validation,
renewal fail-closed behavior, and user-notification idempotency.

Stripe SDK + database are mocked; no network, no real charges.
"""
import os
from datetime import datetime, timezone, timedelta
from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import pytest

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")
os.environ.setdefault("CELERY_BROKER_URL", "redis://localhost:6379/1")
os.environ.setdefault("CELERY_RESULT_BACKEND", "redis://localhost:6379/2")


def _res(scalar=None, rows=None, first=None):
    m = MagicMock()
    m.scalar_one_or_none.return_value = first
    sc = MagicMock()
    sc.all.return_value = rows or []
    sc.first.return_value = first
    m.scalars.return_value = sc
    m.scalar.return_value = scalar
    return m


def _user_org():
    user = MagicMock()
    user.id = uuid4()
    user.email = "u@x.com"
    user.full_name = "User"
    org = MagicMock()
    org.id = uuid4()
    org.subscription_plan = "personal"
    org.subscription_status = None
    org.subscription_start_date = None
    org.subscription_end_date = None
    org.trial_end_date = None
    return user, org


def _plan():
    plan = MagicMock()
    plan.id = uuid4()
    plan.name = "personal"
    plan.stripe_price_id_monthly = "price_m"
    plan.stripe_price_id_yearly = "price_y"
    return plan


def _svc(db, sdk=None):
    from app.domain.services import payment_service as ps
    svc = ps.PaymentService(db)
    svc._enabled = AsyncMock(return_value=True)
    if sdk is not None:
        svc._stripe = AsyncMock(return_value=sdk)
    return svc, ps


def _sdk_mock():
    sdk = MagicMock()
    customer = MagicMock()
    customer.id = "cus_1"
    customer.invoice_settings = {"default_payment_method": "pm_1"}
    sdk.Customer.create.return_value = customer
    sdk.Customer.retrieve.return_value = customer
    pm = MagicMock()
    pm.customer = None
    sdk.PaymentMethod.retrieve.return_value = pm
    price = MagicMock()
    price.active = True
    price.unit_amount = 4900
    price.currency = "sar"
    sdk.Price.retrieve.return_value = price
    sub = MagicMock()
    sub.id = "sub_1"
    sub.status = "active"
    sub.current_period_start = 1700000000
    sub.current_period_end = 1731536000
    sub.cancel_at_period_end = False
    sub.metadata = {}
    sdk.Subscription.create.return_value = sub
    sdk.Subscription.retrieve.return_value = sub
    sdk.Subscription.modify.return_value = sub
    return sdk


def _pi_object(pi_id="pi_test123", amount_received=4900, currency="sar"):
    """A Stripe PaymentIntent SDK-like object (no `payment_intent` attr)."""
    pi = MagicMock()
    pi.id = pi_id
    pi.payment_intent = None  # PaymentIntents have no such attr; be explicit
    # Remove the auto-mocked attr so getattr returns real None behavior
    del pi.payment_intent
    pi.amount_received = amount_received
    pi.amount = amount_received
    pi.currency = currency
    pi.metadata = {
        "fyona_org_id": str(uuid4()),
        "fyona_plan_id": str(uuid4()),
        "fyona_plan_name": "personal",
        "fyona_period": "yearly",
        "fyona_user_id": str(uuid4()),
    }
    return pi


def _activate_db(payment=None):
    """Mock DB for _activate_subscription: first execute() returns the
    payment lookup (hit or miss); every later execute() returns empty.
    The invoice-number counter scalar defaults to None -> treated as 0."""
    empty = _res(first=None)
    hit = _res(first=payment)
    state = {"n": 0}

    async def fake_execute(*a, **k):
        state["n"] += 1
        if state["n"] == 1 and payment is not None:
            return hit
        return empty

    db = AsyncMock()
    db.execute.side_effect = fake_execute
    db.commit = AsyncMock()
    db.refresh = AsyncMock()
    db.add = MagicMock()
    db.flush = AsyncMock()
    return db


# ── §8/M: PaymentIntent object finds its StripePayment via own pi_xxx id ──

@pytest.mark.asyncio
async def test_activate_finds_payment_by_pi_id():
    """Root-cause fix: a PaymentIntent object (id=pi_xxx) must resolve its
    StripePayment row via stripe_payment_intent_id — never via a checkout
    lookup that can only match cs_xxx ids."""
    from app.domain.services import payment_service as ps
    user, org = _user_org()
    sdk = _sdk_mock()
    payment = MagicMock()
    payment.amount_minor = 4900
    payment.currency = "sar"
    db = _activate_db(payment=payment)
    svc, _ = _svc(db, sdk)
    svc._get_organization = AsyncMock(return_value=org)
    svc._sync_user_subscription = AsyncMock()
    svc._sync_renewal_to_plan = AsyncMock()
    pi = _pi_object()
    # Fix metadata to match our org/user
    pi.metadata["fyona_org_id"] = str(org.id)
    pi.metadata["fyona_user_id"] = str(user.id)
    with patch.object(ps, "stripe_sdk", sdk):
        with patch("app.domain.services.push_service.notify_user", new=AsyncMock()):
            with patch("app.domain.services.push_service.platform_admin_ids", new=AsyncMock(return_value=[])):
                await svc._activate_subscription(pi)
    # Invoice must carry the REAL amount: 4900 minor units (SAR) -> 49.00
    created = [c.args[0] for c in db.add.call_args_list]
    invoices = [c for c in created if type(c).__name__ == "SubscriptionInvoice"]
    assert invoices, "no SubscriptionInvoice created"
    assert float(invoices[0].amount) == 49.0
    assert invoices[0].currency == "SAR"


@pytest.mark.asyncio
async def test_activate_falls_back_to_stripe_object_amount():
    """No local StripePayment row: the Stripe object's own amount_received /
    currency is the trusted source (cents-aware)."""
    from app.domain.services import payment_service as ps
    user, org = _user_org()
    sdk = _sdk_mock()
    db = _activate_db(payment=None)
    svc, _ = _svc(db, sdk)
    svc._get_organization = AsyncMock(return_value=org)
    svc._sync_user_subscription = AsyncMock()
    svc._sync_renewal_to_plan = AsyncMock()
    # 1500 cents USD -> 15.00 USD
    pi = _pi_object(pi_id="pi_usd15", amount_received=1500, currency="usd")
    pi.metadata["fyona_org_id"] = str(org.id)
    pi.metadata["fyona_user_id"] = str(user.id)
    with patch.object(ps, "stripe_sdk", sdk):
        with patch("app.domain.services.push_service.notify_user", new=AsyncMock()):
            with patch("app.domain.services.push_service.platform_admin_ids", new=AsyncMock(return_value=[])):
                await svc._activate_subscription(pi)
    created = [c.args[0] for c in db.add.call_args_list]
    invoices = [c for c in created if type(c).__name__ == "SubscriptionInvoice"]
    assert invoices, "no SubscriptionInvoice created"
    assert float(invoices[0].amount) == 15.0
    assert invoices[0].currency == "USD"


@pytest.mark.asyncio
async def test_activate_fails_closed_without_truthful_amount():
    """No payment row AND no Stripe amount: FAIL CLOSED — raise, never a
    $0 invoice."""
    from app.domain.services import payment_service as ps
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    db.execute.side_effect = [_res(first=None)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc._get_organization = AsyncMock(return_value=org)
    pi = MagicMock()
    pi.id = "pi_noamount"
    del pi.payment_intent
    pi.amount_received = None
    pi.amount = None
    pi.amount_total = None
    pi.currency = None
    pi.metadata = {
        "fyona_org_id": str(org.id),
        "fyona_plan_id": str(uuid4()),
        "fyona_plan_name": "personal",
        "fyona_period": "yearly",
        "fyona_user_id": str(user.id),
    }
    with patch.object(ps, "stripe_sdk", sdk):
        with pytest.raises(ValueError, match="مبلغ الدفع الحقيقي"):
            await svc._activate_subscription(pi)
    # Nothing financial may be written on the fail-closed path
    created = [c.args[0] for c in db.add.call_args_list]
    invoices = [c for c in created if type(c).__name__ == "SubscriptionInvoice"]
    assert not invoices


@pytest.mark.asyncio
async def test_activate_kwd_1000_minor_units():
    """1000-based currencies (KWD/BHD/OMR/JOD) divide by 1000, not 100."""
    from app.domain.services import payment_service as ps
    user, org = _user_org()
    sdk = _sdk_mock()
    db = _activate_db(payment=None)
    svc, _ = _svc(db, sdk)
    svc._get_organization = AsyncMock(return_value=org)
    svc._sync_user_subscription = AsyncMock()
    svc._sync_renewal_to_plan = AsyncMock()
    # 15000 fils KWD -> 15.000 KWD
    pi = _pi_object(pi_id="pi_kwd", amount_received=15000, currency="kwd")
    pi.metadata["fyona_org_id"] = str(org.id)
    pi.metadata["fyona_user_id"] = str(user.id)
    with patch.object(ps, "stripe_sdk", sdk):
        with patch("app.domain.services.push_service.notify_user", new=AsyncMock()):
            with patch("app.domain.services.push_service.platform_admin_ids", new=AsyncMock(return_value=[])):
                await svc._activate_subscription(pi)
    created = [c.args[0] for c in db.add.call_args_list]
    invoices = [c for c in created if type(c).__name__ == "SubscriptionInvoice"]
    assert invoices
    assert float(invoices[0].amount) == 15.0
    assert invoices[0].currency == "KWD"


# ── §16: zero recurring price rejected ──

@pytest.mark.asyncio
async def test_verified_price_rejects_zero_amount():
    user, org = _user_org()
    sdk = _sdk_mock()
    zero_price = MagicMock()
    zero_price.active = True
    zero_price.unit_amount = 0
    sdk.Price.retrieve.return_value = zero_price
    db = AsyncMock()
    svc, _ = _svc(db, sdk)
    with pytest.raises(ValueError, match="صفر"):
        svc._verified_price_id(sdk, "price_zero")


@pytest.mark.asyncio
async def test_verified_price_rejects_inactive():
    user, org = _user_org()
    sdk = _sdk_mock()
    dead_price = MagicMock()
    dead_price.active = False
    dead_price.unit_amount = 4900
    sdk.Price.retrieve.return_value = dead_price
    db = AsyncMock()
    svc, _ = _svc(db, sdk)
    with pytest.raises(ValueError, match="معطّل"):
        svc._verified_price_id(sdk, "price_dead")


# ── §6: renewal fail-closed ──

@pytest.mark.asyncio
async def test_renewal_paid_fails_closed_without_amount():
    """invoice.paid without amount_paid/currency: no extension, no invoice."""
    from app.domain.services import payment_service as ps
    user, org = _user_org()
    sdk = _sdk_mock()
    profile = MagicMock()
    profile.plan_name = "personal"
    profile.status = "active"
    profile.current_period_start = None
    profile.current_period_end = None
    profile.cancel_at_period_end = False
    profile.stripe_subscription_id = "sub_1"
    db = AsyncMock()
    db.execute.side_effect = [_res(first=profile)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc._get_organization = AsyncMock(return_value=org)
    invoice = MagicMock()
    invoice.customer = "cus_1"
    invoice.subscription = "sub_1"
    invoice.amount_paid = None
    invoice.currency = None
    invoice.id = "in_missing"
    live_sub = MagicMock()
    live_sub.metadata = {
        "fyona_org_id": str(org.id),
        "fyona_user_id": str(user.id),
        "fyona_plan_name": "personal",
        "fyona_period": "yearly",
    }
    live_sub.current_period_end = 1731536000
    sdk.Subscription.retrieve.return_value = live_sub
    with patch.object(ps, "stripe_sdk", sdk):
        await svc._on_renewal_paid(invoice)
    # Org must NOT be touched: no commit carrying an extension
    assert org.subscription_status != "active"


@pytest.mark.asyncio
async def test_renewal_paid_uses_stripe_amount():
    """invoice.paid with amount_paid=4900 SAR: extension + invoice at 49 SAR."""
    from app.domain.services import payment_service as ps
    user, org = _user_org()
    sdk = _sdk_mock()
    profile = MagicMock()
    profile.plan_name = "personal"
    profile.status = "active"
    profile.current_period_start = None
    profile.current_period_end = None
    profile.cancel_at_period_end = False
    profile.stripe_subscription_id = "sub_1"
    db = AsyncMock()
    db.execute.side_effect = [
        _res(first=profile),  # profile lookup
        _res(first=None),     # revenue idempotency
        _res(first=None),     # stripe-bank lookup (none -> create path)
        _res(first=None),     # historic backfill update
        _res(first=None),     # invoice idempotency
        _res(first=None),     # invoice fallback window
        _res(scalar=0),       # invoice number counter
        _res(first=None),     # user-notif dedup check
    ]
    db.commit = AsyncMock()
    db.add = MagicMock()
    db.flush = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc._get_organization = AsyncMock(return_value=org)
    svc._sync_user_subscription = AsyncMock()
    invoice = MagicMock()
    invoice.customer = "cus_1"
    invoice.subscription = "sub_1"
    invoice.amount_paid = 4900
    invoice.currency = "sar"
    invoice.id = "in_renew1"
    invoice.lines = MagicMock()
    invoice.lines.data = []
    live_sub = MagicMock()
    live_sub.metadata = {
        "fyona_org_id": str(org.id),
        "fyona_user_id": str(user.id),
        "fyona_plan_name": "personal",
        "fyona_period": "yearly",
    }
    live_sub.current_period_end = 1763592000
    sdk.Subscription.retrieve.return_value = live_sub
    notified = {}
    admin_notified = {}

    async def fake_notify(*a, **k):
        notified["called"] = True

    async def fake_admin_notify(*a, **k):
        admin_notified["called"] = True
        admin_notified["kind"] = k.get("kind")

    svc._notify_user_stripe_activation = fake_notify
    svc._notify_admins_stripe_payment = fake_admin_notify
    with patch.object(ps, "stripe_sdk", sdk):
        await svc._on_renewal_paid(invoice)
    assert org.subscription_status == "active"
    created = [c.args[0] for c in db.add.call_args_list]
    invoices = [c for c in created if type(c).__name__ == "SubscriptionInvoice"]
    assert invoices
    assert float(invoices[0].amount) == 49.0
    assert invoices[0].currency == "SAR"
    assert notified.get("called") is True
    assert admin_notified.get("called") is True
    assert admin_notified.get("kind") == "renewal"


# ── §10: user-notification idempotency ──

@pytest.mark.asyncio
async def test_user_activation_notif_skips_duplicate():
    """Same user + same exact payload: second call creates nothing."""
    user, org = _user_org()
    sdk = _sdk_mock()
    existing = MagicMock()
    db = AsyncMock()
    db.execute.side_effect = [_res(first=existing)]
    db.commit = AsyncMock()
    db.add = MagicMock()
    svc, _ = _svc(db, sdk)
    await svc._notify_user_stripe_activation(
        org.id, user.id, "personal", 49.0, "SAR", "yearly",
        datetime.now(timezone.utc), 365,
        provider_payment_id="pi_dup1", invoice_number="INV-20260101-0001",
    )
    db.add.assert_not_called()


@pytest.mark.asyncio
async def test_user_activation_notif_payload_has_invoice():
    """Authoritative notification deep-links the exact invoice (§13)."""
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    db.execute.side_effect = [_res(first=None)]
    db.commit = AsyncMock()
    db.flush = AsyncMock()
    added = []
    db.add = MagicMock(side_effect=lambda n: added.append(n))
    svc, _ = _svc(db, sdk)
    with patch("app.domain.services.push_service.notify_user", new=AsyncMock()):
        await svc._notify_user_stripe_activation(
            org.id, user.id, "personal", 49.0, "SAR", "yearly",
            datetime.now(timezone.utc), 365,
            provider_payment_id="pi_link1", invoice_number="INV-20260101-0042",
        )
    assert added, "no notification created"
    assert "INV-20260101-0042" in (added[0].action_payload or "")


@pytest.mark.asyncio
async def test_renewal_failed_notif_once_per_invoice():
    """Repeated payment_failed deliveries for one invoice: single notice."""
    user, org = _user_org()
    sdk = _sdk_mock()
    existing = MagicMock()
    db = AsyncMock()
    db.execute.side_effect = [_res(first=existing)]
    db.commit = AsyncMock()
    db.add = MagicMock()
    svc, _ = _svc(db, sdk)
    invoice = MagicMock()
    invoice.id = "in_fail1"
    invoice.amount_due = 4900
    invoice.currency = "sar"
    await svc._notify_renewal_failed(org.id, user.id, "personal", invoice)
    db.add.assert_not_called()


# ── §13/§9: invoice creation returns its number ──

@pytest.mark.asyncio
async def test_create_invoice_returns_number():
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    db.execute.side_effect = [
        _res(first=None),   # provider idempotency
        _res(first=None),   # fallback window
        _res(scalar=0),     # counter
    ]
    db.commit = AsyncMock()
    db.add = MagicMock()
    svc, _ = _svc(db, sdk)
    now = datetime.now(timezone.utc)
    number = await svc._create_stripe_invoice(
        org, user.id, "personal", "yearly", 49.0, "SAR",
        now, 365, "pi_num1", "visa",
    )
    assert number is not None and number.startswith("INV-")


@pytest.mark.asyncio
async def test_create_invoice_returns_existing_number_on_dup():
    """Duplicate provider payment: same invoice number back, no new row."""
    user, org = _user_org()
    sdk = _sdk_mock()
    existing = MagicMock()
    existing.invoice_number = "INV-20260101-0007"
    db = AsyncMock()
    db.execute.side_effect = [_res(first=existing)]
    db.commit = AsyncMock()
    db.add = MagicMock()
    svc, _ = _svc(db, sdk)
    now = datetime.now(timezone.utc)
    number = await svc._create_stripe_invoice(
        org, user.id, "personal", "yearly", 49.0, "SAR",
        now, 365, "pi_dup2", "visa",
    )
    assert number == "INV-20260101-0007"
    db.add.assert_not_called()


# ── §7/B/C/D: confirm rejects anything that is not Stripe "succeeded" ──

async def _confirm_with_status(status):
    from app.domain.services import payment_service as ps
    user, org = _user_org()
    sdk = _sdk_mock()
    payment = MagicMock()
    payment.user_id = user.id
    payment.organization_id = org.id
    payment.plan_name = "personal"
    payment.status = "pending"
    payment.amount_minor = 4900
    payment.currency = "sar"
    payment.stripe_payment_intent_id = "pi_status1"
    db = AsyncMock()
    db.execute.side_effect = [_res(first=payment)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc._get_organization = AsyncMock(return_value=org)
    intent = MagicMock()
    intent.id = "pi_status1"
    intent.status = status
    intent.amount = 4900
    intent.currency = "sar"
    sdk.PaymentIntent.retrieve.return_value = intent
    with patch.object(ps, "stripe_sdk", sdk):
        return await svc.confirm_stripe_payment(
            user.id, org.id,
            payment_intent_id="pi_status1", payment_id=None,
        )


@pytest.mark.asyncio
async def test_confirm_rejects_processing():
    with pytest.raises(ValueError, match="ليست ناجحة"):
        await _confirm_with_status("processing")


@pytest.mark.asyncio
async def test_confirm_rejects_requires_action():
    with pytest.raises(ValueError, match="ليست ناجحة"):
        await _confirm_with_status("requires_action")


@pytest.mark.asyncio
async def test_confirm_rejects_failed_declined():
    with pytest.raises(ValueError, match="ليست ناجحة"):
        await _confirm_with_status("failed")


@pytest.mark.asyncio
async def test_confirm_rejects_canceled():
    with pytest.raises(ValueError, match="ليست ناجحة"):
        await _confirm_with_status("canceled")
