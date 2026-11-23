"""Admin dashboard KPIs, analytics overview and bank-statement endpoints.

AsyncMock database routing on statement text; never touches Postgres.
"""
import json
import os
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import pytest

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")


def _res(scalar=None, rows=None):
    m = MagicMock()
    m.scalar.return_value = scalar
    sc = MagicMock()
    sc.all.return_value = rows or []
    m.scalars.return_value = sc
    m.all.return_value = rows or []
    return m


class _RouterDb(AsyncMock):
    """Routes execute() by statement text to canned results."""

    def __init__(self, routes, *a, **k):
        super().__init__(*a, **k)
        self._routes = routes
        self.added = []

    async def execute(self, stmt, *a, **k):
        s = str(stmt).lower()
        for needle, res in self._routes:
            if needle.lower() in s:
                return res() if callable(res) else res
        raise AssertionError(f"unrouted query: {s[:160]}")

    def add(self, row):
        self.added.append(row)

    async def commit(self):
        return None

    async def flush(self):
        return None


def _body(resp):
    return json.loads(resp.body)


def _counts_svc():
    svc = MagicMock()
    svc.counts = AsyncMock(return_value={
        "banners": 2, "active_banners": 1, "api_keys": 0, "currencies": 5,
    })
    return svc


@pytest.mark.asyncio
async def test_dashboard_stats_has_panel_keys():
    from app.api.v1 import admin as adm

    db = AsyncMock()
    db.execute.side_effect = [
        _res(scalar=9),    # users
        _res(scalar=4),    # orgs
        _res(scalar=3),    # active orgs
        _res(scalar=3),    # plans
        _res(scalar=1),    # notifications
        _res(scalar=2),    # pending requests
        _res(scalar=6),    # active subscriptions
        _res(scalar=8),    # trial subscriptions
        _res(scalar=1500),  # total revenue
        _res(rows=[("SAR", 1000), ("USD", 500)]),  # revenue by currency
        _res(scalar=0),    # trash
        _res(rows=[]),     # orgs for subscription truth (none here)
    ]
    with patch.object(adm, "_ensure_plans_seeded", new=AsyncMock(return_value=None)), \
         patch.object(adm, "_settings_svc", return_value=_counts_svc()):
        resp = await adm.dashboard_stats(db=db)
    d = _body(resp)["data"]
    assert d["total_users"] == 9
    assert d["active_subscriptions"] == 6
    assert d["pending_subscriptions"] == 2
    assert d["trial_subscriptions"] == 8
    assert d["total_revenue"] == 1500
    assert {"currency": "SAR", "amount": 1000} in d["revenue_by_currency"]
    # Legacy keys stay intact.
    assert d["subscription_requests_pending"] == 2
    # Org-based subscription truth keys exist (zero here — no org rows).
    assert d["subscriptions_total"] == 0
    assert d["subscriptions_active_total"] == 0
    assert d["subscriptions_expired_total"] == 0
    assert d["subscriptions_by_source"] == []


@pytest.mark.asyncio
async def test_analytics_overview_period_structure():
    from app.api.v1 import admin as adm

    db = AsyncMock()
    db.execute.side_effect = [
        _res(scalar=9),    # users total
        _res(scalar=0),    # users before period (cumulative base)
        _res(scalar=2),    # new users
        _res(scalar=1),    # prev users
        _res(scalar=1500),  # revenue total
        _res(scalar=400),  # revenue in period
        _res(scalar=200),  # revenue previous span
        _res(rows=[("SAR", 400)]),  # revenue by currency
        _res(rows=[]),     # orgs for subscription truth (none here)
        _res(rows=[("active", 6), ("trial", 8)]),  # subs breakdown
        _res(scalar=1),    # new active in period
        _res(rows=[("pending", 2)]),  # requests in period
        _res(rows=[]),     # user dates
        _res(rows=[]),     # revenue dates
    ]
    resp = await adm.analytics_overview(period="30d", db=db)
    d = _body(resp)["data"]
    assert d["period"] == "30d"
    assert d["users"]["total"] == 9
    assert d["users"]["new_in_period"] == 2
    assert "growth_pct" in d["users"]
    assert d["revenue"]["total"] == 1500
    assert d["revenue"]["by_currency"] == [{"currency": "SAR", "amount": 400.0}]
    assert len(d["users_trend"]) == 30
    assert len(d["revenue_trend"]) == 30
    assert any(s["status"] == "active" for s in d["subscriptions"]["breakdown"])
    # New keys: cumulative series + org-based totals + grain echo.
    assert all("cumulative" in b for b in d["users_trend"])
    assert d["grain"] == "day"
    assert d["subscriptions"]["total"] == 0
    assert d["subscriptions"]["active_total"] == 0
    assert d["subscriptions"]["expired_total"] == 0
    assert d["subscriptions"]["by_source"] == []


@pytest.mark.asyncio
async def test_operations_bank_filter_and_creator_name():
    from app.api.v1 import admin as adm

    admin_id = uuid4()
    bank_id = uuid4()
    op = MagicMock()
    op.id = uuid4()
    op.bank_account_id = bank_id
    op.bank_name = "الراجحي"
    op.type = "withdraw"
    op.amount = 500
    op.currency = "SAR"
    op.description = "مصاريف"
    op.person_name = None
    op.created_by = admin_id
    op.created_at = datetime(2026, 9, 20, 10, 0, tzinfo=timezone.utc)
    admin_user = MagicMock()
    admin_user.id = admin_id
    admin_user.full_name = "مدير النظام"
    admin_user.email = "a@x.com"

    seen = {}

    async def fake_execute(stmt, *a, **k):
        s = str(stmt)
        if "admin_operations" in s:
            seen["filtered"] = "bank_account_id" in s
            return _res(rows=[op])
        return _res(rows=[admin_user])

    db = AsyncMock()
    db.execute.side_effect = fake_execute
    resp = await adm.list_admin_operations(limit=100, bank_id=str(bank_id), db=db)
    d = _body(resp)["data"]
    assert seen["filtered"] is True
    assert d["operations"][0]["created_by_name"] == "مدير النظام"
    assert d["operations"][0]["amount"] == 500


@pytest.mark.asyncio
async def test_entries_bank_filter_and_names():
    from app.api.v1 import admin as adm

    bank_id = uuid4()
    org_id = uuid4()
    user_id = uuid4()
    entry = MagicMock()
    entry.id = uuid4()
    entry.request_id = None
    entry.organization_id = org_id
    entry.user_id = user_id
    entry.bank_account_id = bank_id
    entry.plan_name = "business"
    entry.period = "yearly"
    entry.amount = 900
    entry.currency = "SAR"
    entry.note = None
    entry.created_at = datetime(2026, 9, 20, 11, 0, tzinfo=timezone.utc)
    bank = MagicMock()
    bank.id = bank_id
    bank.bank_name = "الأهلي"
    org = MagicMock()
    org.id = org_id
    org.name = "شركة النور"
    usr = MagicMock()
    usr.id = user_id
    usr.full_name = "سارة"
    usr.email = "s@x.com"

    seen = {}

    async def fake_execute(stmt, *a, **k):
        s = str(stmt)
        if "subscription_revenues" in s and "GROUP BY" not in s:
            seen["filtered"] = "bank_account_id" in s
            return _res(rows=[entry])
        if "platform_bank_accounts" in s:
            return _res(rows=[bank])
        if "organizations" in s:
            return _res(rows=[org])
        if "FROM users" in s or s.strip().startswith("SELECT users"):
            return _res(rows=[usr])
        return _res(rows=[])

    db = AsyncMock()
    db.execute.side_effect = fake_execute
    resp = await adm.list_accounting_entries(limit=100, bank_id=str(bank_id), db=db)
    d = _body(resp)["data"]
    assert seen["filtered"] is True
    row = d["entries"][0]
    assert row["org_name"] == "شركة النور"
    assert row["user_name"] == "سارة"
    assert row["bank_name"] == "الأهلي"
