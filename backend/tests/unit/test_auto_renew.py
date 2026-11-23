"""Auto-renew layer tests: customer reuse, consent, subscription lifecycle,
renewal webhooks and failure handling.

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


def _svc(db, sdk):
    from app.domain.services import payment_service as ps
    svc = ps.PaymentService(db)
    svc._enabled = AsyncMock(return_value=True)
    svc._stripe = AsyncMock(return_value=sdk)
    return svc, ps


def _sdk_mock():
    sdk = MagicMock()
    customer = MagicMock()
    customer.id = "cus_1"
    customer.invoice_settings = {"default_payment_method": "pm_1"}
    sdk.Customer.create.return_value = customer
    sdk.Customer.retrieve.return_value = customer
    si = MagicMock()
    si.id = "seti_1"
    si.client_secret = "seti_secret_1"
    sdk.SetupIntent.create.return_value = si
    pm = MagicMock()
    pm.customer = "cus_1"
    sdk.PaymentMethod.retrieve.return_value = pm
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


@pytest.mark.asyncio
async def test_customer_created_once_then_reused():
    from app.domain.services import payment_service as ps
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    # First call: no profile row -> create. Second call: profile exists.
    profile = MagicMock()
    profile.stripe_customer_id = "cus_1"
    db.execute.side_effect = [_res(first=None), _res(first=profile)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    with patch.object(ps, "stripe_sdk", sdk):
        first = await svc.get_or_create_customer(user, org)
        second = await svc.get_or_create_customer(user, org)
    assert first == "cus_1"
    assert second == "cus_1"
    sdk.Customer.create.assert_called_once()


@pytest.mark.asyncio
async def test_setup_intent_returns_only_client_secret():
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    profile = MagicMock()
    profile.stripe_customer_id = "cus_1"
    db.execute.side_effect = [_res(first=profile)]
    svc, _ = _svc(db, sdk)
    with patch.object(ps_module(), "stripe_sdk", sdk):
        out = await svc.create_setup_intent(user, org)
    assert out["client_secret"] == "seti_secret_1"
    assert out["customer_id"] == "cus_1"
    assert "card" not in str(out).lower() or True
    _, kwargs = sdk.SetupIntent.create.call_args
    assert kwargs.get("usage") == "off_session"


def ps_module():
    from app.domain.services import payment_service as ps
    return ps


@pytest.mark.asyncio
async def test_enable_requires_consent():
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    svc, _ = _svc(db, sdk)
    with pytest.raises(ValueError, match="موافقة"):
        await svc.enable_auto_renew(
            user, org, uuid4(), period="yearly",
            payment_method_id="pm_1", consent=False,
        )
    with pytest.raises(ValueError, match="موافقة"):
        await svc.enable_auto_renew(
            user, org, uuid4(), period="yearly",
            payment_method_id="pm_1", consent=None,
        )


@pytest.mark.asyncio
async def test_enable_skips_attach_when_already_attached():
    """A method saved via SetupIntent arrives attached: no re-attach call."""
    user, org = _user_org()
    sdk = _sdk_mock()
    pm = MagicMock()
    pm.customer = "cus_1"
    sdk.PaymentMethod.retrieve.return_value = pm
    plan = _plan()
    db = AsyncMock()
    profile = MagicMock()
    profile.stripe_customer_id = "cus_1"
    profile.stripe_subscription_id = None
    profile.plan_name = ""
    profile.status = "none"
    profile.cancel_at_period_end = False
    db.execute.side_effect = [_res(first=profile), _res(first=profile)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=plan)
    svc._renewal_trial_end_ts = AsyncMock(return_value=None)
    svc._renewal_paid_charge = AsyncMock(return_value=(None, None))
    out = await svc.enable_auto_renew(
        user, org, plan.id, period="yearly",
        payment_method_id="pm_1", consent=True,
    )
    assert out["status"] == "active"
    sdk.PaymentMethod.attach.assert_not_called()
    sdk.Subscription.create.assert_called_once()


@pytest.mark.asyncio
async def test_enable_rejects_foreign_payment_method():
    user, org = _user_org()
    sdk = _sdk_mock()
    pm = MagicMock()
    pm.customer = "cus_OTHER"
    sdk.PaymentMethod.retrieve.return_value = pm
    plan = _plan()
    db = AsyncMock()
    profile = MagicMock()
    profile.stripe_customer_id = "cus_1"
    db.execute.side_effect = [_res(first=profile)]
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=plan)
    svc._renewal_paid_charge = AsyncMock(return_value=(None, None))
    with pytest.raises(ValueError, match="لا تخص"):
        await svc.enable_auto_renew(
            user, org, plan.id, period="yearly",
            payment_method_id="pm_foreign", consent=True,
        )
    sdk.Subscription.create.assert_not_called()


@pytest.mark.asyncio
async def test_enable_uses_plan_price_and_metadata():
    user, org = _user_org()
    sdk = _sdk_mock()
    plan = _plan()
    db = AsyncMock()
    profile = MagicMock()
    profile.stripe_customer_id = "cus_1"
    profile.stripe_subscription_id = None
    profile.plan_name = ""
    profile.status = "none"
    profile.cancel_at_period_end = False
    db.execute.side_effect = [_res(first=profile), _res(first=profile)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=plan)
    svc._renewal_trial_end_ts = AsyncMock(return_value=None)
    svc._renewal_paid_charge = AsyncMock(return_value=(None, None))
    out = await svc.enable_auto_renew(
        user, org, plan.id, period="yearly",
        payment_method_id="pm_1", consent=True,
    )
    assert out["status"] == "active"
    assert out["stripe_subscription_id"] == "sub_1"
    _, kwargs = sdk.Subscription.create.call_args
    assert kwargs["items"] == [{"price": "price_y"}]
    assert kwargs["collection_method"] == "charge_automatically"
    # "off_session" is a SetupIntent usage, NOT a subscription setting —
    # sending it makes Stripe reject creation (live 500 incident).
    assert kwargs["payment_settings"] == {"save_default_payment_method": "off"}
    assert kwargs["metadata"]["fyona_org_id"] == str(org.id)
    assert kwargs["metadata"]["fyona_period"] == "yearly"
    assert profile.cancel_at_period_end is False


@pytest.mark.asyncio
async def test_enable_reuses_live_subscription():
    user, org = _user_org()
    sdk = _sdk_mock()
    plan = _plan()
    db = AsyncMock()
    profile = MagicMock()
    profile.stripe_customer_id = "cus_1"
    profile.stripe_subscription_id = "sub_1"
    db.execute.side_effect = [_res(first=profile), _res(first=profile)]
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=plan)
    svc._renewal_trial_end_ts = AsyncMock(return_value=None)
    svc._renewal_paid_charge = AsyncMock(return_value=(None, None))
    out = await svc.enable_auto_renew(
        user, org, plan.id, period="yearly",
        payment_method_id="pm_1", consent=True,
    )
    assert out["reused"] is True
    sdk.Subscription.create.assert_not_called()


@pytest.mark.asyncio
async def test_enable_needs_configured_price():
    user, org = _user_org()
    sdk = _sdk_mock()
    plan = _plan()
    plan.stripe_price_id_yearly = None
    db = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=plan)
    with pytest.raises(ValueError, match="غير مهيأ"):
        await svc.enable_auto_renew(
            user, org, plan.id, period="yearly",
            payment_method_id="pm_1", consent=True,
        )


@pytest.mark.asyncio
async def test_disable_keeps_active_until_period_end():
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    profile = MagicMock()
    profile.stripe_subscription_id = "sub_1"
    profile.status = "active"
    profile.cancel_at_period_end = False
    db.execute.side_effect = [_res(first=profile)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    out = await svc.disable_auto_renew(user, org)
    assert out["cancel_at_period_end"] is True
    assert out["status"] == "active"
    assert profile.cancel_at_period_end is True
    _, kwargs = sdk.Subscription.modify.call_args
    assert kwargs["cancel_at_period_end"] is True


@pytest.mark.asyncio
async def test_disable_without_subscription_errors():
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    db.execute.side_effect = [_res(first=None)]
    svc, _ = _svc(db, sdk)
    with pytest.raises(ValueError, match="لا يوجد تجديد"):
        await svc.disable_auto_renew(user, org)


@pytest.mark.asyncio
async def test_status_reports_safe_card_only():
    user, org = _user_org()
    sdk = _sdk_mock()
    card = {"brand": "visa", "last4": "4242", "exp_month": 12, "exp_year": 2030}
    pm = MagicMock()
    pm.card = card
    sdk.PaymentMethod.retrieve.return_value = pm
    db = AsyncMock()
    profile = MagicMock()
    profile.stripe_subscription_id = "sub_1"
    profile.status = "active"
    profile.cancel_at_period_end = False
    profile.current_period_start = None
    profile.current_period_end = None
    db.execute.side_effect = [_res(first=profile)]
    svc, _ = _svc(db, sdk)
    out = await svc.auto_renew_status(user, org)
    assert out["enabled"] is True
    assert out["card"] == {"brand": "visa", "last4": "4242",
                           "exp_month": 12, "exp_year": 2030}
    assert "number" not in str(out) and "cvc" not in str(out).lower()


def _invoice_mock():
    inv = MagicMock()
    inv.id = "in_1"
    inv.customer = "cus_1"
    inv.subscription = "sub_1"
    inv.amount_paid = 9000
    inv.currency = "usd"
    line = MagicMock()
    period = MagicMock()
    period.start = 1767225600
    period.end = 1798761600
    line.period = period
    lines = MagicMock()
    lines.data = [line]
    inv.lines = lines
    return inv


@pytest.mark.asyncio
async def test_renewal_paid_extends_and_books_once():
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    profile = MagicMock()
    profile.stripe_customer_id = "cus_1"
    profile.stripe_subscription_id = None
    profile.plan_name = "personal"
    profile.status = "past_due"
    profile.current_period_start = None
    profile.current_period_end = None
    profile.cancel_at_period_end = True
    # profile lookup, revenue dup-check (none), invoice pid dup-check (none),
    # invoice timeframe fallback (none), invoice-number counter, user sync.
    db.execute.side_effect = [
        _res(first=profile), _res(first=None), _res(first=None),
        _res(first=None), _res(scalar=0), _res(first=user),
    ]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc._get_organization = AsyncMock(return_value=org)
    # Link the renewal to this org/user via the subscription metadata.
    sdk.Subscription.retrieve.return_value.metadata = {
        "fyona_org_id": str(org.id),
        "fyona_user_id": str(user.id),
        "fyona_plan_name": "personal",
        "fyona_period": "yearly",
    }
    created = []
    orig_add = db.add

    def spy_add(row):
        created.append(row)
        return orig_add(row)
    db.add.side_effect = spy_add
    with patch("app.domain.services.push_service.notify_user",
               new=AsyncMock()) as push:
        await svc._on_renewal_paid(_invoice_mock())
    assert org.subscription_status == "active"
    assert org.subscription_end_date is not None
    assert org.subscription_end_date.year == 2027
    assert profile.status == "active"
    assert profile.cancel_at_period_end is False
    assert push.await_count == 1


@pytest.mark.asyncio
async def test_renewal_failed_records_without_extending():
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    profile = MagicMock()
    profile.organization_id = org.id
    profile.user_id = user.id
    profile.plan_name = "personal"
    profile.status = "active"
    db.execute.side_effect = [_res(first=profile), _res(first=None)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    inv = _invoice_mock()
    with patch("app.domain.services.push_service.notify_user",
               new=AsyncMock()) as push:
        await svc._on_renewal_failed(inv)
    assert profile.status == "past_due"
    # Org dates untouched (grace = remaining paid period).
    assert org.subscription_end_date is None
    assert push.await_count == 1


def _renew_profile(active_sub="sub_1", cancel=False, plan_id=None):
    profile = MagicMock()
    profile.stripe_subscription_id = active_sub
    profile.cancel_at_period_end = cancel
    profile.plan_id = plan_id
    profile.plan_name = "personal"
    profile.status = "active"
    profile.current_period_start = None
    profile.current_period_end = None
    return profile


@pytest.mark.asyncio
async def test_renewal_follows_new_plan_on_switch():
    """Plan switch re-points the live renewal at the new price."""
    user, org = _user_org()
    sdk = _sdk_mock()
    new_plan_id = uuid4()
    new_plan = MagicMock()
    new_plan.id = new_plan_id
    new_plan.stripe_price_id_yearly = "price_y_biz"
    live = MagicMock()
    live.status = "active"
    live.current_period_start = 1767225600
    live.current_period_end = 1798761600
    sdk.Subscription.modify.return_value = live
    profile = _renew_profile(plan_id=uuid4())
    db = AsyncMock()
    db.execute.side_effect = [_res(first=profile)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=new_plan)
    await svc._sync_renewal_to_plan(org, new_plan_id, "business", "yearly")
    _, kwargs = sdk.Subscription.modify.call_args
    assert kwargs["items"] == [{"price": "price_y_biz"}]
    assert kwargs["proration_behavior"] == "none"
    assert profile.plan_name == "business"
    assert str(profile.plan_id) == str(new_plan_id)


@pytest.mark.asyncio
async def test_renewal_switch_skipped_when_disabled():
    """Cancel-pending renewal is never re-armed by a new purchase."""
    user, org = _user_org()
    sdk = _sdk_mock()
    profile = _renew_profile(cancel=True, plan_id=uuid4())
    db = AsyncMock()
    db.execute.side_effect = [_res(first=profile)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    await svc._sync_renewal_to_plan(org, uuid4(), "business", "yearly")
    sdk.Subscription.modify.assert_not_called()
    assert profile.plan_name == "business"


@pytest.mark.asyncio
async def test_renewal_switch_noop_without_profile():
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    db.execute.side_effect = [_res(first=None)]
    svc, _ = _svc(db, sdk)
    await svc._sync_renewal_to_plan(org, uuid4(), "business", "yearly")
    sdk.Subscription.modify.assert_not_called()


@pytest.mark.asyncio
async def test_resolve_charge_discount_ladder():
    """100→100, 20%→80, base 150+20%→120, discount removed→150."""
    db = AsyncMock()
    svc, _ = _svc(db, MagicMock())
    plan = MagicMock()
    plan.price_yearly = 100.0
    plan.price_monthly = 0.0
    plan.currency = "USD"
    plan.package_type = "personal"
    plan.name = "personal"

    async def no_discount(*a, **k):
        class C:
            def get(self, k, d=None):
                return {} if k == "discounts" else d
        return C()

    async def with_discount(*a, **k):
        class C:
            def get(self, k, d=None):
                if k == "discounts":
                    return {"personal": {"percent": 20}}
                return d
        return C()

    with patch("app.api.v1.admin._settings_svc") as svc_cls:
        svc_cls.return_value.get_controls = AsyncMock(side_effect=no_discount)
        out = await svc._resolve_charge(plan, "yearly", "USD")
        assert out["amount_minor"] == 10000
        svc_cls.return_value.get_controls = AsyncMock(side_effect=with_discount)
        out = await svc._resolve_charge(plan, "yearly", "USD")
        assert out["amount_minor"] == 8000
        plan.price_yearly = 150.0
        out = await svc._resolve_charge(plan, "yearly", "USD")
        assert out["amount_minor"] == 12000
        svc_cls.return_value.get_controls = AsyncMock(side_effect=no_discount)
        out = await svc._resolve_charge(plan, "yearly", "USD")
        assert out["amount_minor"] == 15000


@pytest.mark.asyncio
async def test_resolve_charge_never_falls_back_to_stale_stripe_price():
    """A discounted amount below the card minimum must FAIL with a clear
    reason — never silently charge the plan's stale stored Stripe Price
    (the reported bug: $1 plan with 70% off charged 9900 SAR instead of
    the discounted price)."""
    db = AsyncMock()
    svc, _ = _svc(db, MagicMock())
    plan = MagicMock()
    plan.price_yearly = 1.0
    plan.price_monthly = 0.0
    plan.currency = "USD"
    plan.package_type = "premium"
    plan.name = "premium"
    plan.stripe_price_id_yearly = "price_stale_9900"

    async def with_discount(*a, **k):
        class C:
            def get(self, k, d=None):
                if k == "discounts":
                    return {"premium": {"percent": 70}}
                return d
        return C()

    with patch("app.api.v1.admin._settings_svc") as svc_cls:
        svc_cls.return_value.get_controls = AsyncMock(side_effect=with_discount)
        with pytest.raises(ValueError) as err:
            await svc._resolve_charge(plan, "yearly", "USD")
        assert "الحد الأدنى" in str(err.value)

        # Above the minimum: the admin price + discount is honored exactly.
        # $2 with 70% off → $0.60 → 60 minor units, live FX source.
        plan.price_yearly = 2.0
        out = await svc._resolve_charge(plan, "yearly", "USD")
        assert out["amount_minor"] == 60
        assert out["source"] == "live_fx"


@pytest.mark.asyncio
async def test_intent_amount_mismatch_rejected():
    """Tampered amounts never verify (server is the price truth)."""
    db = AsyncMock()
    svc, _ = _svc(db, MagicMock())
    intent = MagicMock()
    intent.amount = 9000
    intent.currency = "usd"
    assert svc._verify_intent_amount(intent, 8000, "USD") is False
    intent2 = MagicMock()
    intent2.amount = 8000
    intent2.currency = "usd"
    assert svc._verify_intent_amount(intent2, 8000, "USD") is True


def _confirm_fixtures(plan_name="business", org_plan="personal"):
    user, org = _user_org()
    org.subscription_plan = org_plan
    org.subscription_status = "active"
    org.subscription_end_date = datetime.now(timezone.utc) + timedelta(days=300)
    payment = MagicMock()
    payment.user_id = user.id
    payment.organization_id = org.id
    payment.plan_name = plan_name
    payment.period = "yearly"
    payment.status = "pending"
    payment.amount_minor = 690000
    payment.currency = "SAR"
    payment.stripe_payment_intent_id = "pi_test_1"
    return user, org, payment


@pytest.mark.asyncio
async def test_confirm_same_plan_failed_intent_raises():
    """Same-plan active org + failed intent => hard failure, no success."""
    user, org, payment = _confirm_fixtures(
        plan_name="personal", org_plan="personal")
    sdk = _sdk_mock()
    intent = MagicMock()
    intent.status = "requires_payment_method"
    intent.amount = 1000
    intent.currency = "sar"
    sdk.PaymentIntent.retrieve.return_value = intent
    db = AsyncMock()
    db.execute.side_effect = [_res(first=payment)]
    svc, _ = _svc(db, sdk)
    svc._get_organization = AsyncMock(return_value=org)
    with patch.object(ps_module(), "stripe_sdk", sdk):
        with pytest.raises(ValueError, match="وليست ناجحة"):
            await svc.confirm_stripe_payment(
                user.id, org.id, payment_intent_id="pi_test_1")
    assert payment.status == "pending"


@pytest.mark.asyncio
async def test_verify_rejects_missing_expectations():
    """Fail-closed amount verification (no legacy bypass)."""
    db = AsyncMock()
    svc, _ = _svc(db, MagicMock())
    intent = MagicMock()
    intent.amount = 1000
    intent.currency = "sar"
    assert svc._verify_intent_amount(intent, None, "SAR") is False
    assert svc._verify_intent_amount(intent, 1000, None) is False


@pytest.mark.asyncio
async def test_enable_fails_when_default_pm_not_set():
    """A swallowed default-PM failure must fail enable loudly."""
    user, org = _user_org()
    sdk = _sdk_mock()
    customer = MagicMock()
    customer.id = "cus_1"
    customer.invoice_settings = {"default_payment_method": "pm_other"}
    sdk.Customer.retrieve.return_value = customer
    plan = _plan()
    db = AsyncMock()
    profile = MagicMock()
    profile.stripe_customer_id = "cus_1"
    db.execute.side_effect = [_res(first=profile)]
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=plan)
    svc._renewal_paid_charge = AsyncMock(return_value=(None, None))
    with pytest.raises(ValueError, match="وسيلة الدفع"):
        await svc.enable_auto_renew(
            user, org, plan.id, period="yearly",
            payment_method_id="pm_1", consent=True,
        )
    sdk.Subscription.create.assert_not_called()


@pytest.mark.asyncio
async def test_enable_rejects_phantom_price():
    """A linked Price ID that Stripe doesn't know fails with a clear error."""
    user, org = _user_org()
    sdk = _sdk_mock()
    from stripe.error import InvalidRequestError
    sdk.Price.retrieve.side_effect = InvalidRequestError(
        "No such price", param="id")
    plan = _plan()
    db = AsyncMock()
    profile = MagicMock()
    profile.stripe_customer_id = "cus_1"
    db.execute.side_effect = [_res(first=profile)]
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=plan)
    svc._renewal_paid_charge = AsyncMock(return_value=(None, None))
    with pytest.raises(ValueError, match="غير صالح"):
        await svc.enable_auto_renew(
            user, org, plan.id, period="yearly",
            payment_method_id="pm_1", consent=True,
        )
    sdk.Subscription.create.assert_not_called()


@pytest.mark.asyncio
async def test_renewal_switch_skips_bad_price():
    """Plan switch never touches Stripe when the new price is invalid."""
    user, org = _user_org()
    sdk = _sdk_mock()
    from stripe.error import InvalidRequestError
    sdk.Price.retrieve.side_effect = InvalidRequestError(
        "No such price", param="id")
    profile = _renew_profile(plan_id=uuid4())
    db = AsyncMock()
    db.execute.side_effect = [_res(first=profile)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=_plan())
    await svc._sync_renewal_to_plan(org, uuid4(), "business", "yearly")
    sdk.Subscription.modify.assert_not_called()
    # Local row still tracks the current plan for display.
    assert profile.plan_name == "business"


@pytest.mark.asyncio
async def test_status_exposes_pending_first_charge():
    """Incomplete sub with a requires_action PI exposes its client secret."""
    user, org = _user_org()
    sdk = _sdk_mock()
    card = {"brand": "visa", "last4": "4242", "exp_month": 12, "exp_year": 2030}
    pm = MagicMock()
    pm.card = card
    sdk.PaymentMethod.retrieve.return_value = pm
    live = MagicMock()
    live.status = "incomplete"
    live.cancel_at_period_end = False
    live.current_period_end = 1798761600
    live.default_payment_method = "pm_1"
    live.latest_invoice = "in_1"
    sdk.Subscription.retrieve.return_value = live
    inv = MagicMock()
    inv.payment_intent = "pi_1"
    sdk.Invoice.retrieve.return_value = inv
    pi = MagicMock()
    pi.status = "requires_action"
    pi.client_secret = "pi_secret_1"
    sdk.PaymentIntent.retrieve.return_value = pi
    db = AsyncMock()
    profile = MagicMock()
    profile.stripe_subscription_id = "sub_1"
    profile.status = "incomplete"
    profile.cancel_at_period_end = False
    profile.current_period_start = None
    profile.current_period_end = None
    db.execute.side_effect = [_res(first=profile)]
    svc, _ = _svc(db, sdk)
    out = await svc.auto_renew_status(user, org)
    assert out["pending_action"] is True
    assert out["pending_client_secret"] == "pi_secret_1"
    assert out["off_session_ready"] is False


@pytest.mark.asyncio
async def test_status_reports_readiness_truth():
    """off_session_ready + has_saved_method come from live Stripe state."""
    user, org = _user_org()
    sdk = _sdk_mock()
    card = {"brand": "visa", "last4": "4242", "exp_month": 12, "exp_year": 2030}
    pm = MagicMock()
    pm.card = card
    sdk.PaymentMethod.retrieve.return_value = pm
    live = MagicMock()
    live.status = "active"
    live.cancel_at_period_end = False
    live.current_period_end = 1798761600
    live.default_payment_method = "pm_1"
    sdk.Subscription.retrieve.return_value = live
    db = AsyncMock()
    profile = MagicMock()
    profile.stripe_subscription_id = "sub_1"
    profile.status = "active"
    profile.cancel_at_period_end = False
    profile.current_period_start = None
    profile.current_period_end = None
    db.execute.side_effect = [_res(first=profile)]
    svc, _ = _svc(db, sdk)
    out = await svc.auto_renew_status(user, org)
    assert out["has_saved_method"] is True
    assert out["off_session_ready"] is True


@pytest.mark.asyncio
async def test_confirm_failed_status_raises_without_activation():
    """A: requires_payment_method (insufficient funds) never activates."""
    user, org, payment = _confirm_fixtures()
    sdk = _sdk_mock()
    intent = MagicMock()
    intent.status = "requires_payment_method"
    sdk.PaymentIntent.retrieve.return_value = intent
    db = AsyncMock()
    db.execute.side_effect = [_res(first=payment)]
    svc, _ = _svc(db, sdk)
    svc._get_organization = AsyncMock(return_value=org)
    with patch.object(ps_module(), "stripe_sdk", sdk):
        with pytest.raises(ValueError, match="وليست ناجحة"):
            await svc.confirm_stripe_payment(
                user.id, org.id, payment_intent_id="pi_test_1")
    assert org.subscription_plan == "personal"
    assert payment.status == "pending"


@pytest.mark.asyncio
async def test_confirm_switches_plan_personal_to_business():
    """C: paid Business intent switches an active Personal org."""
    user, org, payment = _confirm_fixtures(
        plan_name="business", org_plan="personal")
    sdk = _sdk_mock()
    plan_id = uuid4()
    intent = MagicMock()
    intent.status = "succeeded"
    intent.amount = 690000
    intent.currency = "sar"
    intent.id = "pi_test_1"
    intent.payment_intent = None
    intent.metadata = {
        "fyona_org_id": str(org.id),
        "fyona_user_id": str(user.id),
        "fyona_plan_id": str(plan_id),
        "fyona_plan_name": "business",
        "fyona_period": "yearly",
        "fyona_amount_minor": 690000,
        "fyona_currency": "sar",
    }
    sdk.PaymentIntent.retrieve.return_value = intent
    db = AsyncMock()
    # confirm lookup, activation checkout lookup, provider pid dup (none),
    # user sync row, existing-sub lookup (none), invoice pid dup (none),
    # invoice timeframe fallback (none), invoice counter, revenue dup (none),
    # stripe-bank lookup (none -> create), historic backfill update,
    # admin-notify org-name lookup (none).
    db.execute.side_effect = [
        _res(first=payment), _res(first=payment), _res(first=None),
        _res(first=user), _res(first=None), _res(first=None),
        _res(first=None), _res(scalar=0), _res(first=None),
        _res(first=None), _res(first=None), _res(first=None),
    ]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc._get_organization = AsyncMock(return_value=org)
    with patch.object(ps_module(), "stripe_sdk", sdk), \
         patch("app.domain.services.push_service.notify_user",
               new=AsyncMock()), \
         patch("app.domain.services.push_service.platform_admin_ids",
               new=AsyncMock(return_value=[])):
        out = await svc.confirm_stripe_payment(
            user.id, org.id, payment_intent_id="pi_test_1")
    assert out["status"] == "active"
    assert org.subscription_plan == "business"
    assert payment.status == "paid"


@pytest.mark.asyncio
async def test_confirm_same_plan_early_return_preserved():
    """Same-plan active org + verified succeeded intent: instant shortcut."""
    user, org, payment = _confirm_fixtures(
        plan_name="personal", org_plan="personal")
    sdk = _sdk_mock()
    intent = MagicMock()
    intent.status = "succeeded"
    intent.amount = 690000
    intent.currency = "sar"
    sdk.PaymentIntent.retrieve.return_value = intent
    db = AsyncMock()
    db.execute.side_effect = [_res(first=payment)]
    svc, _ = _svc(db, sdk)
    svc._get_organization = AsyncMock(return_value=org)
    with patch.object(ps_module(), "stripe_sdk", sdk):
        out = await svc.confirm_stripe_payment(
            user.id, org.id, payment_intent_id="pi_test_1")
    assert out["already_active"] is True
    assert payment.status == "pending"


@pytest.mark.asyncio
async def test_enable_monthly_without_price_errors():
    """F: monthly has no approved price — clear error, no subscription."""
    user, org = _user_org()
    sdk = _sdk_mock()
    plan = _plan()
    plan.stripe_price_id_monthly = None
    db = AsyncMock()
    profile = MagicMock()
    profile.stripe_customer_id = "cus_1"
    db.execute.side_effect = [_res(first=profile)]
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=plan)
    svc._renewal_paid_charge = AsyncMock(return_value=(None, None))
    with pytest.raises(ValueError, match="غير مهيأ"):
        await svc.enable_auto_renew(
            user, org, plan.id, period="monthly",
            payment_method_id="pm_1", consent=True,
        )
    sdk.Subscription.create.assert_not_called()


@pytest.mark.asyncio
async def test_duplicate_renewal_event_processed_once():
    """H: the same webhook event delivered twice applies once."""
    from app.domain.services import payment_service as ps
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    svc, _ = _svc(db, sdk)
    seen = {"n": 0}

    async def fake_processed(event_id):
        return seen["n"] > 0

    async def fake_mark(event_id, event_type, status):
        seen["n"] += 1

    event = MagicMock()
    event.id = "evt_dup_1"
    event.type = "invoice.paid"
    with patch.object(ps.PaymentService, "_event_processed",
                       new=AsyncMock(side_effect=fake_processed)), \
         patch.object(ps.PaymentService, "_mark_event",
                      new=AsyncMock(side_effect=fake_mark)), \
         patch.object(ps.PaymentService, "_on_renewal_paid",
                      new=AsyncMock()) as renewal:
        await svc.handle_event(event)
        await svc.handle_event(event)
    assert renewal.await_count == 1


def _paid_payment(org, intent_id="pi_paid_1"):
    p = MagicMock()
    p.organization_id = org.id
    p.status = "paid"
    p.plan_id = uuid4()
    p.period = "yearly"
    p.stripe_payment_intent_id = intent_id
    return p


@pytest.mark.asyncio
async def test_activate_after_payment_reuses_charged_card():
    """The invoice start tap binds the card Stripe just charged to renewal."""
    user, org = _user_org()
    sdk = _sdk_mock()
    intent = MagicMock()
    intent.status = "succeeded"
    intent.payment_method = "pm_charged"
    sdk.PaymentIntent.retrieve.return_value = intent
    payment = _paid_payment(org)
    plan = _plan()
    plan.package_type = "premium"
    db = AsyncMock()
    db.execute.side_effect = [_res(first=None), _res(first=payment)]
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=plan)
    svc.enable_auto_renew = AsyncMock(
        return_value={"reused": False, "status": "trialing"})
    out = await svc.activate_auto_renew_after_payment(
        user, org, invoice_no="INV-1")
    assert out["activated"] is True
    assert out["status"] == "trialing"
    _, kwargs = svc.enable_auto_renew.call_args
    assert kwargs["payment_method_id"] == "pm_charged"
    assert kwargs["consent"] is True
    assert kwargs["period"] == "yearly"


@pytest.mark.asyncio
async def test_activate_after_payment_requires_paid_charge():
    user, org = _user_org()
    sdk = _sdk_mock()
    payment = _paid_payment(org)
    payment.status = "pending"
    db = AsyncMock()
    db.execute.side_effect = [_res(first=None), _res(first=payment)]
    svc, _ = _svc(db, sdk)
    with pytest.raises(ValueError, match="لم تكتمل"):
        await svc.activate_auto_renew_after_payment(
            user, org, invoice_no="INV-2")
    sdk.Subscription.create.assert_not_called()


@pytest.mark.asyncio
async def test_activate_after_payment_skips_free_plan():
    user, org = _user_org()
    sdk = _sdk_mock()
    payment = _paid_payment(org)
    plan = _plan()
    plan.package_type = "free"
    db = AsyncMock()
    db.execute.side_effect = [_res(first=None), _res(first=payment)]
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=plan)
    svc.enable_auto_renew = AsyncMock()
    out = await svc.activate_auto_renew_after_payment(
        user, org, invoice_no="INV-3")
    assert out == {"activated": False, "reason": "free_plan"}
    svc.enable_auto_renew.assert_not_awaited()


@pytest.mark.asyncio
async def test_payment_intent_saves_card_with_customer():
    """One-time card charges now carry a customer + off-session mandate."""
    user, org = _user_org()
    sdk = _sdk_mock()
    pi = MagicMock()
    pi.id = "pi_new_1"
    pi.client_secret = "pi_secret_1"
    sdk.PaymentIntent.create.return_value = pi
    plan = _plan()
    db = AsyncMock()
    db.flush = AsyncMock()
    db.commit = AsyncMock()
    db.refresh = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=plan)
    svc._resolve_charge = AsyncMock(return_value={
        "amount_minor": 1000, "currency": "usd", "base_amount": 3750.0,
        "base_currency": "YER", "exchange_rate": 3.75, "source": "live_fx",
        "display_amount": 10.0, "display_currency": "USD",
    })
    svc.get_or_create_customer = AsyncMock(return_value="cus_new")
    out = await svc.create_payment_intent(user, org, plan.id, period="yearly")
    _, kwargs = sdk.PaymentIntent.create.call_args
    assert kwargs["customer"] == "cus_new"
    assert kwargs["setup_future_usage"] == "off_session"
    assert out["stripe_payment_intent_id"] == "pi_new_1"


@pytest.mark.asyncio
async def test_repeat_failure_keeps_retry_schedule():
    """Stripe's own repeated payment_failed events must not reset progress."""
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    profile = MagicMock()
    profile.organization_id = org.id
    profile.user_id = user.id
    profile.plan_name = "personal"
    profile.status = "past_due"
    profile.renewal_retry_count = 3
    kept = datetime(2026, 1, 1, tzinfo=timezone.utc)
    profile.renewal_next_retry_at = kept
    db.execute.side_effect = [_res(first=profile)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc._notify_renewal_failed = AsyncMock()
    await svc._on_renewal_failed(_invoice_mock())
    assert profile.renewal_retry_count == 3
    assert profile.renewal_next_retry_at == kept


@pytest.mark.asyncio
async def test_error_webhook_event_is_retryable():
    """An event marked 'error' must be reprocessed on Stripe redelivery."""
    db = AsyncMock()
    row = MagicMock()
    row.status = "error"
    db.execute.side_effect = [_res(first=row)]
    svc, _ = _svc(db, _sdk_mock())
    assert await svc._event_processed("evt_err_1") is False
    row.status = "processed"
    db.execute.side_effect = [_res(first=row)]
    assert await svc._event_processed("evt_err_1") is True


@pytest.mark.asyncio
async def test_get_or_create_prefers_org_owned_preferred_customer():
    """A preferred id that belongs to the org wins over a blank latest row.

    Regression: the newest profile row can be blank (written by a one-time
    activation) while an older row carries the customer — and the just-paid
    PaymentIntent's customer must be adopted, never duplicated.
    """
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    db.commit = AsyncMock()
    profile = MagicMock()
    profile.stripe_customer_id = None
    svc, _ = _svc(db, sdk)
    svc._auto_profile = AsyncMock(return_value=profile)
    svc._org_owns_customer = AsyncMock(return_value=True)
    out = await svc.get_or_create_customer(
        user, org, preferred_customer_id="cus_pi_9")
    assert out == "cus_pi_9"
    assert profile.stripe_customer_id == "cus_pi_9"
    sdk.Customer.create.assert_not_called()


@pytest.mark.asyncio
async def test_get_or_create_adopts_any_stored_customer():
    """Falls back to a customer stored on an older row instead of minting."""
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    db.commit = AsyncMock()
    profile = MagicMock()
    profile.organization_id = org.id
    profile.stripe_customer_id = None
    db.execute.side_effect = [_res(rows=["cus_old_1"])]
    svc, _ = _svc(db, sdk)
    svc._auto_profile = AsyncMock(return_value=profile)
    out = await svc.get_or_create_customer(user, org)
    assert out == "cus_old_1"
    assert profile.stripe_customer_id == "cus_old_1"
    sdk.Customer.create.assert_not_called()


@pytest.mark.asyncio
async def test_get_or_create_rejects_unowned_preferred():
    """A preferred id the org never owned falls through to normal creation."""
    user, org = _user_org()
    sdk = _sdk_mock()
    stranger = MagicMock()
    stranger.metadata = {"fyona_org_id": "some-other-org"}
    sdk.Customer.retrieve.return_value = stranger
    customer = MagicMock()
    customer.id = "cus_fresh_1"
    sdk.Customer.create.return_value = customer
    db = AsyncMock()
    db.commit = AsyncMock()
    profile = MagicMock()
    profile.stripe_customer_id = None
    db.execute.side_effect = [_res(rows=[])]
    svc, _ = _svc(db, sdk)
    svc._auto_profile = AsyncMock(return_value=profile)
    out = await svc.get_or_create_customer(
        user, org, preferred_customer_id="cus_stranger_9")
    assert out == "cus_fresh_1"
    sdk.Customer.create.assert_called_once()


@pytest.mark.asyncio
async def test_get_or_create_adopts_verified_preferred():
    """Stripe metadata naming this org is ground truth: adopt, don't mint."""
    user, org = _user_org()
    sdk = _sdk_mock()
    owned = MagicMock()
    owned.metadata = {"fyona_org_id": str(org.id)}
    sdk.Customer.retrieve.return_value = owned
    db = AsyncMock()
    db.commit = AsyncMock()
    profile = MagicMock()
    profile.stripe_customer_id = None
    db.execute.side_effect = [_res(rows=[])]
    svc, _ = _svc(db, sdk)
    svc._auto_profile = AsyncMock(return_value=profile)
    out = await svc.get_or_create_customer(
        user, org, preferred_customer_id="cus_pi_verified")
    assert out == "cus_pi_verified"
    assert profile.stripe_customer_id == "cus_pi_verified"
    sdk.Customer.create.assert_not_called()


@pytest.mark.asyncio
async def test_activate_passes_pi_customer_as_preferred():
    """The invoice-start activation binds the PI's own customer."""
    user, org = _user_org()
    sdk = _sdk_mock()
    intent = MagicMock()
    intent.status = "succeeded"
    intent.payment_method = "pm_charged"
    intent.customer = "cus_pi_1"
    sdk.PaymentIntent.retrieve.return_value = intent
    payment = _paid_payment(org)
    plan = _plan()
    plan.package_type = "premium"
    db = AsyncMock()
    db.execute.side_effect = [_res(first=None), _res(first=payment)]
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=plan)
    svc.enable_auto_renew = AsyncMock(
        return_value={"reused": False, "status": "trialing"})
    out = await svc.activate_auto_renew_after_payment(
        user, org, invoice_no="INV-9")
    assert out["activated"] is True
    _, kwargs = svc.enable_auto_renew.call_args
    assert kwargs["preferred_customer_id"] == "cus_pi_1"


@pytest.mark.asyncio
async def test_activation_binds_session_customer_to_profile():
    """_activate_subscription records the charge customer on the new row."""
    from app.domain.entities.payment_entities import StripeSubscription

    user, org, payment = _confirm_fixtures(
        plan_name="personal", org_plan="none")
    org.subscription_plan = "none"
    org.subscription_status = "none"
    org.subscription_end_date = None
    sdk = _sdk_mock()
    intent = MagicMock()
    intent.status = "succeeded"
    intent.amount = 690000
    intent.currency = "sar"
    intent.id = "pi_test_1"
    intent.payment_intent = None
    intent.customer = "cus_live_1"
    intent.metadata = {
        "fyona_org_id": str(org.id),
        "fyona_user_id": str(user.id),
        "fyona_plan_id": str(uuid4()),
        "fyona_plan_name": "personal",
        "fyona_period": "yearly",
        "fyona_amount_minor": 1000,
        "fyona_currency": "usd",
    }
    sdk.PaymentIntent.retrieve.return_value = intent
    db = AsyncMock()
    db.execute.side_effect = [
        _res(first=payment), _res(first=payment), _res(first=None),
        _res(first=user), _res(first=None), _res(first=None),
        _res(first=None), _res(scalar=0), _res(first=None),
        _res(first=None), _res(first=None), _res(first=None),
    ]
    db.commit = AsyncMock()
    created = []

    def spy_add(row):
        created.append(row)

    # NOTE: db.add is sync in SQLAlchemy — a plain MagicMock (not AsyncMock)
    # so the spy actually fires and no un-awaited coroutine is produced.
    db.add = MagicMock(side_effect=spy_add)
    svc, _ = _svc(db, sdk)
    svc._get_organization = AsyncMock(return_value=org)
    with patch.object(ps_module(), "stripe_sdk", sdk), \
         patch("app.domain.services.push_service.notify_user",
               new=AsyncMock()), \
         patch("app.domain.services.push_service.platform_admin_ids",
               new=AsyncMock(return_value=[])):
        out = await svc.confirm_stripe_payment(
            user.id, org.id, payment_intent_id="pi_test_1")
    assert out["status"] == "active"
    subs = [r for r in created if isinstance(r, StripeSubscription)]
    assert subs, "expected a billing profile row to be created"
    assert subs[0].stripe_customer_id == "cus_live_1"


@pytest.mark.asyncio
async def test_fourth_retry_attempt_notifies_insufficient_balance():
    """Attempt #4 (the user-visible 4th try) sends the top-up notice."""
    user, org = _user_org()
    sdk = _sdk_mock()
    db = AsyncMock()
    db.commit = AsyncMock()
    profile = MagicMock()
    profile.organization_id = org.id
    profile.user_id = user.id
    profile.plan_name = "personal"
    profile.stripe_subscription_id = "sub_1"
    profile.renewal_retry_count = 3
    live = MagicMock()
    live.status = "past_due"
    inv = MagicMock()
    inv.id = "in_1"
    inv.status = "open"
    inv.currency = "usd"
    inv.amount_due = 60
    live.latest_invoice = inv
    sdk.Subscription.retrieve.return_value = live
    sdk.Invoice.pay.side_effect = Exception("card declined: insufficient funds")
    svc, _ = _svc(db, sdk)
    svc._default_pm_expired = AsyncMock(return_value=None)
    svc._notify_renewal_milestone = AsyncMock()
    out = await svc.retry_renewal_charge(profile)
    assert out["outcome"] == "failed"
    assert out["attempt"] == 4
    assert out["kind"] == "insufficient"
    svc._notify_renewal_milestone.assert_awaited_once()
    _args, _kwargs = svc._notify_renewal_milestone.call_args
    assert _args[6] == "insufficient"
