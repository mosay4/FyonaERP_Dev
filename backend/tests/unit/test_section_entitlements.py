from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest

from app.domain.services.section_entitlements import (
    access_snapshot, activate, active_subscriptions, cancel, subscriptions,
    validate_purchase,
)

NOW = datetime(2026, 10, 2, tzinfo=timezone.utc)


def org():
    return SimpleNamespace(subscription_plan=None, subscription_status="none",
        subscription_start_date=None, subscription_end_date=None,
        section_subscriptions=None, trial_end_date=None, has_used_free_plan=False,
        business_setup_completed=False)


@pytest.mark.parametrize("first,second", [("personal", "business"), ("business", "personal")])
def test_individual_packages_keep_separate_expiries(first, second):
    account = org()
    activate(account, first, days=10, now=NOW)
    first_end = subscriptions(account)[first]["end_date"]
    activate(account, second, days=30, now=NOW)
    assert subscriptions(account)[first]["end_date"] == first_end
    assert set(active_subscriptions(account, NOW)) == {"personal", "business"}
    after_expiry = access_snapshot(account, now=NOW + timedelta(days=10))
    assert not after_expiry["sections"][first]["active"]
    assert after_expiry["sections"][second]["active"]


def test_premium_replaces_both_and_does_not_resurrect_them_after_expiry():
    account = org()
    activate(account, "personal", days=365, now=NOW)
    activate(account, "business", days=365, now=NOW)
    activate(account, "premium", days=30, now=NOW)
    assert set(active_subscriptions(account, NOW)) == {"premium"}
    assert all(v["active"] for v in access_snapshot(account, now=NOW)["sections"].values())
    for plan in ("personal", "business"):
        with pytest.raises(ValueError, match="Premium"):
            validate_purchase(account, plan, NOW)
    assert not active_subscriptions(account, NOW + timedelta(days=30))
    activate(account, "business", days=10, now=NOW + timedelta(days=31))
    assert set(active_subscriptions(account, NOW + timedelta(days=31))) == {"business"}


def test_pending_or_rejected_second_payment_keeps_first_paid_access():
    account = org()
    activate(account, "personal", days=30, now=NOW)
    for state in ("pending", "rejected"):
        account.subscription_plan = "business"
        account.subscription_status = state
        account.subscription_end_date = None
        access = access_snapshot(account, now=NOW)
        assert access["sections"]["personal"]["active"]
        assert not access["sections"]["business"]["active"]


def test_trial_unlocks_both_only_until_configured_expiry():
    account = org()
    account.subscription_status = "trial"
    account.trial_end_date = NOW + timedelta(hours=3)
    assert all(v["active"] for v in access_snapshot(account, now=NOW)["sections"].values())
    assert not any(v["active"] for v in access_snapshot(account, now=NOW + timedelta(hours=3))["sections"].values())
    assert not any(v["active"] for v in access_snapshot(account, now=NOW, trial_allowed=False)["sections"].values())


def test_existing_legacy_personal_period_survives_business_activation():
    account = org()
    account.subscription_plan = "personal"
    account.subscription_status = "active"
    account.subscription_start_date = NOW - timedelta(days=2)
    account.subscription_end_date = NOW + timedelta(days=20)
    activate(account, "business", days=30, now=NOW)
    assert subscriptions(account)["personal"]["end_date"] == (NOW + timedelta(days=20)).isoformat()


def test_renewal_extends_only_its_own_section():
    account = org()
    activate(account, "personal", days=20, now=NOW)
    activate(account, "business", days=30, now=NOW)
    activate(account, "personal", days=10, now=NOW + timedelta(days=1))
    assert subscriptions(account)["personal"]["end_date"] == (NOW + timedelta(days=30)).isoformat()
    assert subscriptions(account)["business"]["end_date"] == (NOW + timedelta(days=30)).isoformat()


def test_cancel_one_section_does_not_cancel_other():
    account = org()
    now = datetime.now(timezone.utc)
    activate(account, "personal", days=20, now=now)
    activate(account, "business", days=30, now=now)
    cancel(account, "business")
    assert set(active_subscriptions(account)) == {"personal"}
    assert account.subscription_status == "active"


@pytest.mark.asyncio
async def test_status_separates_pending_request_from_existing_access():
    from app.api.v1.subscription import _calc_status
    account = org()
    activate(account, "personal", days=30)
    account.subscription_plan = "business"
    with patch("app.api.v1.subscription._calc_legacy_status", AsyncMock(return_value={"status": "pending"})), \
         patch("app.api.v1.subscription._controls_trial_allowed", AsyncMock(return_value=(True, False, {}))):
        result = await _calc_status(account, AsyncMock())
    assert result["status"] == "active"
    assert result["request_status"] == "pending"
    assert result["sections"]["personal"]["active"]
    assert not result["sections"]["business"]["active"]
