"""Section access, independent expiry, and mutually exclusive Premium.

Mutations run inside the caller's transaction, with its organization row locked.
Payment verification and invoice creation remain the payment service's concern.
"""
from datetime import datetime, timedelta, timezone

PAID_PLANS = frozenset({"personal", "business", "premium"})


def package_key(value):
    value = str(value or "").lower()
    if value in PAID_PLANS:
        return value
    personal = "personal" in value or "شخص" in value
    business = "business" in value or "أعمال" in value
    if "premium" in value or (personal and business) or "ذهبي" in value:
        return "premium"
    if business:
        return "business"
    if personal:
        return "personal"
    return value


def aware(value):
    if isinstance(value, str):
        value = datetime.fromisoformat(value)
    if value is not None and value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value


def subscriptions(org):
    stored = getattr(org, "section_subscriptions", None)
    if isinstance(stored, dict):
        return {key: dict(value) for key, value in stored.items()}
    plan = package_key(org.subscription_plan)
    end = org.subscription_end_date
    if plan in PAID_PLANS and end:
        return {plan: {
            "status": org.subscription_status,
            "start_date": org.subscription_start_date.isoformat() if org.subscription_start_date else None,
            "end_date": end.isoformat(),
        }}
    return {}


def active_subscriptions(org, now=None):
    now = now or datetime.now(timezone.utc)
    active = {}
    for key, value in subscriptions(org).items():
        end = aware(value.get("end_date"))
        if value.get("status") == "active" and end is not None and end > now:
            active[key] = value
    return active


def validate_purchase(org, plan, now=None):
    plan = package_key(plan)
    if plan not in PAID_PLANS:
        raise ValueError("Invalid subscription package")
    active = active_subscriptions(org, now)
    if plan != "premium" and "premium" in active:
        raise ValueError("Premium already includes Personal and Business; individual plans cannot be added")


def activate(org, plan, *, days=None, start=None, end=None, now=None):
    """Activate only the paid section; Premium replaces individual access.

    With days, renew the same section from its unexpired end date. Explicit
    dates are for verified provider periods and are never extended twice.
    """
    now = now or datetime.now(timezone.utc)
    plan = package_key(plan)
    validate_purchase(org, plan, now)
    entries = subscriptions(org)
    current = active_subscriptions(org, now).get(plan)
    if end is None:
        if days is None or days <= 0:
            raise ValueError("A positive subscription duration is required")
        start = aware(current.get("start_date")) if current else now
        base = aware(current["end_date"]) if current else now
        end = (base or now) + timedelta(days=days)
    start = aware(start) or now
    end = aware(end)
    assert end is not None
    if plan == "premium":
        for key in ("personal", "business"):
            if key in entries:
                entries[key] = {**entries[key], "status": "replaced", "replaced_at": now.isoformat()}
    entries[plan] = {"status": "active", "start_date": start.isoformat(), "end_date": end.isoformat()}
    org.section_subscriptions = entries
    # Compatibility projection for old readers, never the entitlement source.
    org.subscription_plan = plan
    org.subscription_status = "active"
    org.subscription_start_date = start
    org.subscription_end_date = end
    org.trial_end_date = None
    org.has_used_free_plan = True
    return start, end


def cancel(org, plan):
    entries = subscriptions(org)
    if plan in entries:
        entries[plan]["status"] = "cancelled"
    org.section_subscriptions = entries
    remaining = active_subscriptions(org)
    if remaining:
        key = "business" if "business" in remaining else next(iter(remaining))
        value = remaining[key]
        org.subscription_plan = key
        org.subscription_status = "active"
        org.subscription_start_date = aware(value.get("start_date"))
        org.subscription_end_date = aware(value["end_date"])
    else:
        org.subscription_status = "cancelled"


def access_snapshot(org, *, trial_allowed=True, now=None):
    now = now or datetime.now(timezone.utc)
    active = active_subscriptions(org, now)
    trial_end = aware(org.trial_end_date)
    trial = bool(not active and trial_allowed and trial_end and trial_end > now
                 and org.subscription_status not in ("cancelled", "rejected", "pending"))
    sections = {}
    for section in ("personal", "business"):
        key = "premium" if "premium" in active else section
        value = active.get(key)
        sections[section] = {
            "active": bool(value) or trial,
            "plan": key if value else ("trial" if trial else None),
            "end_date": value["end_date"] if value else (trial_end.isoformat() if trial and trial_end else None),
        }
    return {
        "sections": sections,
        "subscriptions": subscriptions(org),
        "default_section": "business" if sections["business"]["active"] else "personal",
        "business_setup_completed": bool(getattr(org, "business_setup_completed", False)),
    }
