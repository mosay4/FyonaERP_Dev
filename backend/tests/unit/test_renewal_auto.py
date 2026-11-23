"""Automatic renewal model tests: trial-at-expiry creation, reuse realign,
custom retry schedule, top-up/final notices.

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


def _user_org(end=None):
    user = MagicMock()
    user.id = uuid4()
    user.email = "u@x.com"
    user.full_name = "User"
    org = MagicMock()
    org.id = uuid4()
    org.subscription_plan = "personal"
    org.subscription_status = "active"
    org.subscription_start_date = datetime.now(timezone.utc) - timedelta(days=10)
    org.subscription_end_date = end
    org.trial_end_date = None
    return user, org


def _plan():
    plan = MagicMock()
    plan.id = uuid4()
    plan.name = "personal"
    plan.stripe_price_id_monthly = "price_m"
    plan.stripe_price_id_yearly = "price_y"
    return plan


def _sdk_base():
    sdk = MagicMock()
    customer = MagicMock()
    customer.id = "cus_1"
    customer.invoice_settings = {"default_payment_method": "pm_1"}
    sdk.Customer.create.return_value = customer
    sdk.Customer.retrieve.return_value = customer
    sdk.Customer.modify.return_value = customer
    pm = MagicMock()
    pm.customer = None
    sdk.PaymentMethod.retrieve.return_value = pm
    price = MagicMock()
    price.active = True
    price.unit_amount = 4900
    sdk.Price.retrieve.return_value = price
    return sdk


def _svc(db, sdk):
    from app.domain.services import payment_service as ps
    svc = ps.PaymentService(db)
    svc._enabled = AsyncMock(return_value=True)
    svc._stripe = AsyncMock(return_value=sdk)
    return svc, ps


def _profile(sub_id="sub_1", status="past_due", count=0, nxt=None):
    p = MagicMock()
    p.stripe_subscription_id = sub_id
    p.stripe_customer_id = "cus_1"
    p.status = status
    p.plan_name = "personal"
    p.plan_id = uuid4()
    p.organization_id = uuid4()
    p.user_id = uuid4()
    p.cancel_at_period_end = False
    p.renewal_retry_count = count
    p.renewal_next_retry_at = nxt
    return p


def _live_sub(sdk, status="past_due", inv=None):
    live = MagicMock()
    live.status = status
    live.id = "sub_1"
    live.latest_invoice = inv
    live.cancel_at_period_end = False
    live.current_period_end = 1798761600
    sdk.Subscription.retrieve.return_value = live
    return live


def _open_invoice(inv_id="in_1", amount_due=4900, currency="sar", status="open"):
    inv = MagicMock()
    inv.id = inv_id
    inv.status = status
    inv.amount_due = amount_due
    inv.currency = currency
    return inv


# ── trial-at-expiry creation ──

@pytest.mark.asyncio
async def test_enable_sets_trial_end_at_org_expiry():
    user, org = _user_org(end=datetime.now(timezone.utc) + timedelta(days=355))
    sdk = _sdk_base()
    sub = MagicMock()
    sub.id = "sub_new"
    sub.status = "trialing"
    sdk.Subscription.create.return_value = sub
    sub.latest_invoice = None
    db = AsyncMock()
    db.execute.side_effect = [_res(first=None), _res(first=None), _res(first=None)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=_plan())
    svc._get_organization = AsyncMock(return_value=org)
    out = await svc.enable_auto_renew(
        user, org, uuid4(), period="yearly",
        payment_method_id="pm_1", consent=True)
    assert out["status"] == "trialing"
    _, kwargs = sdk.Subscription.create.call_args
    assert kwargs["trial_end"] == int(org.subscription_end_date.timestamp())
    assert kwargs["collection_method"] == "charge_automatically"
    assert "trial_end" in kwargs


@pytest.mark.asyncio
async def test_enable_omits_trial_when_no_future_end():
    user, org = _user_org(end=None)
    sdk = _sdk_base()
    sub = MagicMock()
    sub.id = "sub_new2"
    sub.status = "incomplete"
    sub.latest_invoice = None
    sdk.Subscription.create.return_value = sub
    db = AsyncMock()
    db.execute.side_effect = [_res(first=None), _res(first=None), _res(first=None)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=_plan())
    svc._get_organization = AsyncMock(return_value=org)
    await svc.enable_auto_renew(
        user, org, uuid4(), period="yearly",
        payment_method_id="pm_1", consent=True)
    _, kwargs = sdk.Subscription.create.call_args
    assert "trial_end" not in kwargs


@pytest.mark.asyncio
async def test_enable_reuse_realigns_trial_end():
    user, org = _user_org(end=datetime.now(timezone.utc) + timedelta(days=300))
    sdk = _sdk_base()
    live = MagicMock()
    live.status = "trialing"
    live.id = "sub_old"
    sdk.Subscription.retrieve.return_value = live
    profile = _profile(sub_id="sub_old", status="trialing")
    db = AsyncMock()
    db.execute.side_effect = [_res(first=None), _res(first=profile), _res(first=profile)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=_plan())
    svc._get_organization = AsyncMock(return_value=org)
    out = await svc.enable_auto_renew(
        user, org, uuid4(), period="yearly",
        payment_method_id="pm_1", consent=True)
    assert out["reused"] is True
    sdk.Subscription.create.assert_not_called()
    sdk.Subscription.modify.assert_called_once()
    _, kwargs = sdk.Subscription.modify.call_args
    assert kwargs["trial_end"] == int(org.subscription_end_date.timestamp())


# ── locked-to-paid renewal price ──

def _paid_row(minor, currency):
    row = MagicMock()
    row.amount_minor = minor
    row.currency = currency
    return row


def _plan_with_product():
    plan = _plan()
    plan.stripe_product_id = "prod_1"
    return plan


@pytest.mark.asyncio
async def test_renewal_locks_discounted_paid_amount():
    """$10 plan with 20% off → user pays $8 → renewal locked at $8 USD."""
    user, org = _user_org(end=datetime.now(timezone.utc) + timedelta(days=355))
    sdk = _sdk_base()
    sdk.Price.list.return_value = MagicMock(data=[])
    created = MagicMock()
    created.id = "price_locked_8"
    sdk.Price.create.return_value = created
    sub = MagicMock()
    sub.id = "sub_lock"
    sub.status = "trialing"
    sub.latest_invoice = None
    sdk.Subscription.create.return_value = sub
    profile = MagicMock()
    profile.stripe_customer_id = "cus_1"
    profile.stripe_subscription_id = None
    db = AsyncMock()
    db.execute.side_effect = [
        _res(first=_paid_row(800, "usd")),  # latest paid charge: $8.00
        _res(first=profile),                # customer profile
        _res(first=profile),                # reuse-check profile
    ]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=_plan_with_product())
    svc._get_organization = AsyncMock(return_value=org)
    out = await svc.enable_auto_renew(
        user, org, uuid4(), period="yearly",
        payment_method_id="pm_1", consent=True)
    assert out["stripe_subscription_id"] == "sub_lock"
    _, ck = sdk.Price.create.call_args
    assert ck["unit_amount"] == 800
    assert ck["currency"] == "usd"
    assert ck["recurring"] == {"interval": "year"}
    assert ck["product"] == "prod_1"
    assert "800usd" in ck["lookup_key"]
    _, sk = sdk.Subscription.create.call_args
    assert sk["items"] == [{"price": "price_locked_8"}]


@pytest.mark.asyncio
async def test_renewal_reuses_matching_locked_price():
    user, org = _user_org(end=datetime.now(timezone.utc) + timedelta(days=355))
    sdk = _sdk_base()
    existing = MagicMock()
    existing.id = "price_locked_8"
    existing.active = True
    existing.unit_amount = 800
    existing.currency = "usd"
    existing.recurring = {"interval": "year"}
    sdk.Price.list.return_value = MagicMock(data=[existing])
    sub = MagicMock()
    sub.id = "sub_lock2"
    sub.status = "trialing"
    sub.latest_invoice = None
    sdk.Subscription.create.return_value = sub
    profile = MagicMock()
    profile.stripe_customer_id = "cus_1"
    profile.stripe_subscription_id = None
    db = AsyncMock()
    db.execute.side_effect = [
        _res(first=_paid_row(800, "usd")),
        _res(first=profile),
        _res(first=profile),
    ]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=_plan_with_product())
    svc._get_organization = AsyncMock(return_value=org)
    out = await svc.enable_auto_renew(
        user, org, uuid4(), period="yearly",
        payment_method_id="pm_1", consent=True)
    assert out["stripe_subscription_id"] == "sub_lock2"
    sdk.Price.create.assert_not_called()
    _, sk = sdk.Subscription.create.call_args
    assert sk["items"] == [{"price": "price_locked_8"}]


@pytest.mark.asyncio
async def test_renewal_zero_paid_falls_back_to_plan_price():
    user, org = _user_org(end=datetime.now(timezone.utc) + timedelta(days=355))
    sdk = _sdk_base()
    sub = MagicMock()
    sub.id = "sub_fb"
    sub.status = "trialing"
    sub.latest_invoice = None
    sdk.Subscription.create.return_value = sub
    profile = MagicMock()
    profile.stripe_customer_id = "cus_1"
    profile.stripe_subscription_id = None
    db = AsyncMock()
    db.execute.side_effect = [
        _res(first=_paid_row(0, "usd")),  # $0 promo receipt
        _res(first=profile),
        _res(first=profile),
    ]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=_plan_with_product())
    svc._get_organization = AsyncMock(return_value=org)
    await svc.enable_auto_renew(
        user, org, uuid4(), period="yearly",
        payment_method_id="pm_1", consent=True)
    sdk.Price.create.assert_not_called()
    _, sk = sdk.Subscription.create.call_args
    assert sk["items"] == [{"price": "price_y"}]


@pytest.mark.asyncio
async def test_sync_relocks_to_just_paid_amount():
    """Plan switch re-points renewal at the just-paid charge, not list."""
    from app.domain.services import payment_service as ps
    user, org = _user_org(end=datetime.now(timezone.utc) + timedelta(days=355))
    sdk = _sdk_base()
    sdk.Price.list.return_value = MagicMock(data=[])
    created = MagicMock()
    created.id = "price_locked_new"
    sdk.Price.create.return_value = created
    live = MagicMock()
    live.status = "trialing"
    live.current_period_start = 1767225600
    live.current_period_end = 1798761600
    sdk.Subscription.modify.return_value = live
    new_plan = MagicMock()
    new_plan.id = uuid4()
    new_plan.name = "business"
    new_plan.stripe_price_id_yearly = "price_y_biz"
    new_plan.stripe_product_id = "prod_biz"
    profile = MagicMock()
    profile.stripe_subscription_id = "sub_1"
    profile.plan_id = uuid4()
    profile.plan_name = "personal"
    profile.status = "trialing"
    profile.cancel_at_period_end = False
    profile.current_period_start = None
    profile.current_period_end = None
    db = AsyncMock()
    db.execute.side_effect = [
        _res(first=profile),              # sync profile lookup
        _res(first=_paid_row(1500, "usd")),  # just-paid $15 charge
    ]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=new_plan)
    await svc._sync_renewal_to_plan(org, new_plan.id, "business", "yearly")
    _, mk = sdk.Subscription.modify.call_args
    assert mk["items"] == [{"price": "price_locked_new"}]
    _, ck = sdk.Price.create.call_args
    assert ck["unit_amount"] == 1500 and ck["currency"] == "usd"

@pytest.mark.asyncio
async def test_retry_gaps_escalate():
    from app.domain.services.payment_service import PaymentService
    gaps = PaymentService.RENEWAL_RETRY_GAPS
    assert gaps[0] == 1 and gaps[1] == 2 and gaps[2] == 3
    assert list(gaps) == sorted(gaps)
    assert len(gaps) == 7


@pytest.mark.asyncio
async def test_retry_recovers_live_active():
    sdk = _sdk_base()
    _live_sub(sdk, status="active")
    profile = _profile(status="past_due", count=4)
    db = AsyncMock()
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    out = await svc.retry_renewal_charge(profile)
    assert out["outcome"] == "recovered"
    assert profile.renewal_retry_count == 0
    assert profile.renewal_next_retry_at is None


@pytest.mark.asyncio
async def test_retry_stops_live_canceled():
    sdk = _sdk_base()
    _live_sub(sdk, status="canceled")
    profile = _profile(status="past_due", count=2)
    db = AsyncMock()
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    out = await svc.retry_renewal_charge(profile)
    assert out["outcome"] == "stopped"
    assert profile.renewal_next_retry_at is None
    sdk.Invoice.pay.assert_not_called()


@pytest.mark.asyncio
async def test_retry_pays_open_invoice():
    sdk = _sdk_base()
    inv = _open_invoice()
    _live_sub(sdk, status="past_due", inv=inv)
    paid = MagicMock()
    paid.status = "paid"
    sdk.Invoice.pay.return_value = paid
    profile = _profile(status="past_due", count=1)
    db = AsyncMock()
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    out = await svc.retry_renewal_charge(profile)
    assert out["outcome"] == "paid"
    sdk.Invoice.pay.assert_called_once_with("in_1")
    assert profile.renewal_retry_count == 0
    assert profile.renewal_next_retry_at is None


@pytest.mark.asyncio
async def test_retry_failure_schedules_next_gap():
    sdk = _sdk_base()
    inv = _open_invoice()
    _live_sub(sdk, status="past_due", inv=inv)
    sdk.Invoice.pay.side_effect = Exception("card_declined")
    profile = _profile(status="past_due", count=0)
    db = AsyncMock()
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    before = datetime.now(timezone.utc)
    out = await svc.retry_renewal_charge(profile)
    assert out["outcome"] == "failed"
    assert out["attempt"] == 1
    assert out["next_in_days"] == 2  # gaps[1]: daily, then +2d
    assert profile.renewal_retry_count == 1
    delta = profile.renewal_next_retry_at - before
    assert timedelta(days=1, hours=23) < delta < timedelta(days=2, hours=1)


@pytest.mark.asyncio
async def test_retry_balance_notice_at_second_failure():
    from app.domain.services import payment_service as ps
    sdk = _sdk_base()
    inv = _open_invoice()
    _live_sub(sdk, status="past_due", inv=inv)
    sdk.Invoice.pay.side_effect = Exception("insufficient_funds")
    profile = _profile(status="past_due", count=1)
    db = AsyncMock()
    db.commit = AsyncMock()
    db.add = MagicMock()
    db.execute.side_effect = [_res(first=None)]
    svc, _ = _svc(db, sdk)
    with patch("app.domain.services.push_service.notify_user", new=AsyncMock()):
        out = await svc.retry_renewal_charge(profile)
    assert out["outcome"] == "failed"
    assert out["attempt"] == 2
    assert out["kind"] == "insufficient"
    created = [c.args[0] for c in db.add.call_args_list]
    notes = [c for c in created if type(c).__name__ == "AppNotification"
             and "renewal_balance=" in (c.action_payload or "")]
    assert len(notes) == 1
    assert "n=2" in (notes[0].action_payload or "")
    assert "رصيد" in (notes[0].message or "")
    assert "invoice" in (notes[0].action_payload or "")


@pytest.mark.asyncio
async def test_retry_exhaustion_final_notice_and_stop():
    from app.domain.services import payment_service as ps
    sdk = _sdk_base()
    inv = _open_invoice()
    _live_sub(sdk, status="past_due", inv=inv)
    sdk.Invoice.pay.side_effect = Exception("insufficient_funds")
    profile = _profile(status="past_due", count=6)
    db = AsyncMock()
    db.commit = AsyncMock()
    db.add = MagicMock()
    db.execute.side_effect = [_res(first=None)]
    svc, _ = _svc(db, sdk)
    with patch("app.domain.services.push_service.notify_user", new=AsyncMock()):
        out = await svc.retry_renewal_charge(profile)
    assert out["outcome"] == "exhausted"
    assert out["attempt"] == 7
    assert profile.renewal_next_retry_at is None
    created = [c.args[0] for c in db.add.call_args_list]
    finals = [c for c in created if type(c).__name__ == "AppNotification"
              and "final=1" in (c.action_payload or "")]
    assert len(finals) == 1


def _decline_error(decline_code):
    err = Exception("card declined")
    err.decline_code = decline_code
    return err


@pytest.mark.asyncio
async def test_retry_expired_card_notice_links_update_screen():
    from app.domain.services import payment_service as ps
    sdk = _sdk_base()
    inv = _open_invoice()
    _live_sub(sdk, status="past_due", inv=inv)
    sdk.Invoice.pay.side_effect = _decline_error("expired_card")
    profile = _profile(status="past_due", count=1)
    db = AsyncMock()
    db.commit = AsyncMock()
    db.add = MagicMock()
    db.execute.side_effect = [_res(first=None)]
    svc, _ = _svc(db, sdk)
    with patch("app.domain.services.push_service.notify_user", new=AsyncMock()):
        out = await svc.retry_renewal_charge(profile)
    assert out["outcome"] == "failed"
    assert out["attempt"] == 2
    assert out["kind"] == "expired"
    created = [c.args[0] for c in db.add.call_args_list]
    notes = [c for c in created if type(c).__name__ == "AppNotification"]
    assert len(notes) == 1
    assert (notes[0].action_payload or "").startswith("/subscription/update-card")
    assert "منتهية" in (notes[0].title or "")


@pytest.mark.asyncio
async def test_retry_expired_detected_by_card_date():
    """Expired by exp date even when Stripe reports a generic error."""
    sdk = _sdk_base()
    inv = _open_invoice()
    live = _live_sub(sdk, status="past_due", inv=inv)
    live.default_payment_method = "pm_old"
    old_pm = MagicMock()
    old_pm.card = {"brand": "visa", "last4": "9999", "exp_month": 1, "exp_year": 2020}
    sdk.PaymentMethod.retrieve.return_value = old_pm
    sdk.Invoice.pay.side_effect = Exception("do_not_honor")
    profile = _profile(status="past_due", count=1)
    db = AsyncMock()
    db.commit = AsyncMock()
    db.add = MagicMock()
    db.execute.side_effect = [_res(first=None)]
    svc, _ = _svc(db, sdk)
    with patch("app.domain.services.push_service.notify_user", new=AsyncMock()):
        out = await svc.retry_renewal_charge(profile)
    assert out["kind"] == "expired"
    created = [c.args[0] for c in db.add.call_args_list]
    assert any((c.action_payload or "").startswith("/subscription/update-card")
               for c in created if type(c).__name__ == "AppNotification")


@pytest.mark.asyncio
async def test_retry_milestone_payloads_differ_and_dedup():
    from app.domain.services import payment_service as ps
    sdk = _sdk_base()
    inv = _open_invoice()
    _live_sub(sdk, status="past_due", inv=inv)
    sdk.Invoice.pay.side_effect = Exception("insufficient_funds")
    db = AsyncMock()
    db.commit = AsyncMock()
    db.add = MagicMock()
    # attempt #2 -> n=2 payload; attempt #4 -> n=4 payload; repeat #4 -> dup
    db.execute.side_effect = [_res(first=None), _res(first=None),
                              _res(first="DUP"), _res(first=None)]
    svc, _ = _svc(db, sdk)
    with patch("app.domain.services.push_service.notify_user", new=AsyncMock()):
        r2 = await svc.retry_renewal_charge(_profile(status="past_due", count=1))
        r4 = await svc.retry_renewal_charge(_profile(status="past_due", count=3))
        r4dup = await svc.retry_renewal_charge(_profile(status="past_due", count=3))
    assert r2["attempt"] == 2 and r4["attempt"] == 4 and r4dup["attempt"] == 4
    created = [c.args[0] for c in db.add.call_args_list]
    notes = [c for c in created if type(c).__name__ == "AppNotification"]
    payloads = [c.action_payload for c in notes]
    assert any("n=2" in (p or "") for p in payloads)
    assert sum(1 for p in payloads if "n=4" in (p or "")) == 1


@pytest.mark.asyncio
async def test_classify_renewal_failure():
    from app.domain.services.payment_service import PaymentService as PS
    assert PS._classify_renewal_failure("expired_card", "", False) == "expired"
    assert PS._classify_renewal_failure("insufficient_funds", "", False) == "insufficient"
    assert PS._classify_renewal_failure(None, "generic error", False) == "other"
    assert PS._classify_renewal_failure(None, "", True) == "expired"
    assert PS._classify_renewal_failure(None, "Your card has insufficient funds.", False) == "insufficient"
    assert PS._classify_renewal_failure(None, None, None) == "other"


@pytest.mark.asyncio
async def test_first_event_expired_links_update_card():
    from app.domain.services import payment_service as ps
    sdk = _sdk_base()
    profile = MagicMock()
    profile.organization_id = uuid4()
    profile.user_id = uuid4()
    profile.plan_name = "personal"
    profile.status = "active"
    db = AsyncMock()
    db.execute.side_effect = [_res(first=None)]  # dedup check only (direct call)
    db.commit = AsyncMock()
    db.add = MagicMock()
    svc, _ = _svc(db, sdk)
    inv = MagicMock()
    inv.id = "in_exp1"
    inv.customer = "cus_1"
    inv.subscription = "sub_1"
    inv.amount_due = 4900
    inv.currency = "sar"
    inv.last_payment_error = {"decline_code": "expired_card", "code": "card_declined"}
    with patch("app.domain.services.push_service.notify_user", new=AsyncMock()):
        await svc._notify_renewal_failed(
            profile.organization_id, profile.user_id, "personal", inv)
    created = [c.args[0] for c in db.add.call_args_list]
    assert len(created) == 1
    assert (created[0].action_payload or "").startswith("/subscription/update-card")
    assert "منتهية" in (created[0].title or "")


@pytest.mark.asyncio
async def test_enable_past_due_attempts_immediate_charge():
    """Card replaced on a past-due renewal: charge attempted at once."""
    sdk = _sdk_base()
    customer = MagicMock()
    customer.id = "cus_1"
    customer.invoice_settings = {"default_payment_method": "pm_new"}
    sdk.Customer.retrieve.return_value = customer
    live = MagicMock()
    live.status = "past_due"
    live.id = "sub_pd"
    live.cancel_at_period_end = False
    open_inv = MagicMock()
    open_inv.id = "in_pd"
    open_inv.status = "open"
    live.latest_invoice = open_inv
    sdk.Subscription.retrieve.return_value = live
    paid = MagicMock()
    paid.status = "paid"
    sdk.Invoice.pay.return_value = paid
    plan = _plan()
    profile = MagicMock()
    profile.stripe_customer_id = "cus_1"
    profile.stripe_subscription_id = "sub_pd"
    profile.status = "past_due"
    profile.plan_name = "personal"
    profile.cancel_at_period_end = False
    db = AsyncMock()
    db.execute.side_effect = [_res(first=profile), _res(first=profile)]
    db.commit = AsyncMock()
    svc, _ = _svc(db, sdk)
    svc.get_plan = AsyncMock(return_value=plan)
    svc._renewal_trial_end_ts = AsyncMock(return_value=None)
    svc._renewal_paid_charge = AsyncMock(return_value=(None, None))
    out = await svc.enable_auto_renew(
        user=MagicMock(id=uuid4()), org=MagicMock(id=uuid4()),
        plan_id=plan.id, period="yearly",
        payment_method_id="pm_new", consent=True)
    assert out["reused"] is True
    sdk.Invoice.pay.assert_called_once_with("in_pd")
    assert out["renewal_charged"] is True
    sdk.Subscription.create.assert_not_called()
