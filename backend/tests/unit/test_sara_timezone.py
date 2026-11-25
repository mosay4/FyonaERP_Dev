"""Sara timezone ranges (P1 fix): user-tz wall edges → UTC query bounds.

Storage is never rewritten: only window edges move. Sources used are the
app's existing ones (`users.timezone`, default Asia/Riyadh); otherwise UTC.
No network, no real DB (mocked AsyncSession).
"""
import os
from datetime import datetime, timezone, timedelta
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")
os.environ.setdefault("CELERY_BROKER_URL", "redis://localhost:6379/1")
os.environ.setdefault("CELERY_RESULT_BACKEND", "redis://localhost:6379/2")

RIYADH = "Asia/Riyadh"  # UTC+3, no DST — deterministic
NY = "America/New_York"  # UTC-4 in May (DST) — deterministic


def _mod():
    from app.domain.services import sara_analytics as mod
    return mod


def Z(y, mo, d, h=0, mi=0):
    return datetime(y, mo, d, h, mi, tzinfo=timezone.utc)


# ── 1: today before/after user midnight ─────────────────────────────────────

def test_today_after_user_midnight():
    mod = _mod()
    # 00:30 in Riyadh = 21:30Z previous day → today is May 15 locally.
    now = Z(2026, 5, 14, 21, 30)
    s, e, _, _, label = mod.resolve_period("today", now=now, tz=RIYADH)
    assert label == "today"
    assert s == Z(2026, 5, 14, 21, 0)  # May15 00:00+03 in UTC
    assert e == Z(2026, 5, 15, 21, 0)
    assert s.tzinfo == timezone.utc  # query bounds stay UTC


def test_today_before_user_midnight():
    mod = _mod()
    # 23:30 in Riyadh = 20:30Z same day → today is May 14 locally
    # (naive UTC math would wrongly say May 14 either way here, but the
    # window edges differ: local midnight, not UTC midnight).
    now = Z(2026, 5, 14, 20, 30)
    s, e, _, _, _ = mod.resolve_period("today", now=now, tz=RIYADH)
    assert s == Z(2026, 5, 13, 21, 0)  # May14 00:00+03 in UTC
    assert e == Z(2026, 5, 14, 21, 0)


# ── 2-3: month / year boundaries ────────────────────────────────────────────

def test_month_boundary_user_tz():
    mod = _mod()
    # Jun 1 00:30+03 = May 31 21:30Z → user's month is already June.
    now = Z(2026, 5, 31, 21, 30)
    s, e, _, _, label = mod.resolve_period("this_month", now=now, tz=RIYADH)
    assert label == "this_month"
    assert s == Z(2026, 5, 31, 21, 0)  # Jun1 00:00+03, NOT Jun1 00:00Z
    assert e == Z(2026, 6, 30, 21, 0)  # Jul1 00:00+03


def test_year_boundary_user_tz():
    mod = _mod()
    # Jan 1 00:30+03 = Dec 31 21:30Z → user's year is already 2026.
    now = Z(2025, 12, 31, 21, 30)
    s, e, _, _, label = mod.resolve_period("this_year", now=now, tz=RIYADH)
    assert label == "this_year"
    assert s == Z(2025, 12, 31, 21, 0)
    assert e == Z(2026, 12, 31, 21, 0)


# ── 4-6: yesterday / week / last month ──────────────────────────────────────

def test_yesterday_is_exact_local_day():
    mod = _mod()
    now = Z(2026, 5, 15, 12, 0)  # May15 15:00+03
    s, e, _, _, label = mod.resolve_period("yesterday", now=now, tz=RIYADH)
    assert label == "yesterday"
    assert (e - s) == timedelta(days=1)
    assert s == Z(2026, 5, 13, 21, 0)  # May14 00:00+03
    assert e == Z(2026, 5, 14, 21, 0)


def test_this_week_starts_monday_user_tz():
    mod = _mod()
    now = Z(2026, 5, 13, 10, 0)  # Wed May13 13:00+03
    s, e, _, _, label = mod.resolve_period("this_week", now=now, tz=RIYADH)
    assert label == "this_week"
    assert (e - s) == timedelta(days=7)
    assert s == Z(2026, 5, 10, 21, 0)  # Mon May11 00:00+03
    assert s.astimezone(timezone.utc).weekday() == 6  # Sunday 21:00Z = Mon local


def test_last_month_bounds_user_tz():
    mod = _mod()
    now = Z(2026, 5, 15, 12, 0)
    s, e, _, _, label = mod.resolve_period("last_month", now=now, tz=RIYADH)
    assert label == "last_month"
    assert s == Z(2026, 3, 31, 21, 0)  # Apr1 00:00+03
    assert e == Z(2026, 4, 30, 21, 0)  # May1 00:00+03


# ── 7: custom range interpreted in user tz ──────────────────────────────────

def test_custom_naive_range_uses_user_tz():
    mod = _mod()
    s, e, _, _, label = mod.resolve_period(
        "custom",
        start=datetime(2026, 5, 1), end=datetime(2026, 5, 10),
        now=Z(2026, 5, 15, 12, 0), tz=RIYADH)
    assert label == "custom"
    assert s == Z(2026, 4, 30, 21, 0)
    assert e == Z(2026, 5, 9, 21, 0)


# ── 8: equal + contiguous comparison windows ────────────────────────────────

def test_comparison_windows_equal_and_contiguous():
    mod = _mod()
    for name in ("today", "yesterday", "this_week", "this_month",
                 "last_month", "this_year"):
        s, e, ps, pe, _ = mod.resolve_period(
            name, now=Z(2026, 5, 15, 12, 0), tz=RIYADH)
        assert (e - s) == (pe - ps), name
        assert pe == s, name


# ── 9: stored timestamps untouched ──────────────────────────────────────────

def _rows(all_list):
    m = MagicMock()
    m.all.return_value = all_list
    sc = MagicMock()
    sc.all.return_value = all_list
    m.scalars.return_value = sc
    return m


def _empty_db_calls(n=22):
    return [_rows([])] * n


# (Stored timestamps / currency buckets of the analytics snapshot are pinned
# on the phone side now: test/fixtures/personal_analytics_parity.json.)


# ── 11: non-UTC zone with DST ───────────────────────────────────────────────

def test_non_utc_zone_with_dst():
    mod = _mod()
    # May 14 23:30 in New York (UTC-4) = May 15 03:30Z.
    now = Z(2026, 5, 15, 3, 30)
    s, e, _, _, _ = mod.resolve_period("today", now=now, tz=NY)
    assert s == Z(2026, 5, 14, 4, 0)  # May14 00:00-04 in UTC
    assert e == Z(2026, 5, 15, 4, 0)
    _, name = mod._tzinfo(NY)
    assert name == NY


# ── 12: fallback chain ──────────────────────────────────────────────────────

def test_fallback_when_no_stored_timezone():
    mod = _mod()
    assert mod.resolve_user_timezone_name(None) == "Asia/Riyadh"
    assert mod.resolve_user_timezone_name("") == "Asia/Riyadh"
    assert mod.resolve_user_timezone_name("   ") == "Asia/Riyadh"
    # Invalid stored value → app default, never raises, never invented per-user
    assert mod.resolve_user_timezone_name("Mars/Olympus") == "Asia/Riyadh"
    assert mod.resolve_user_timezone_name(RIYADH) == RIYADH
    assert mod.resolve_user_timezone_name(NY) == NY
    # Invalid tz argument → safe UTC behaviour (old code path)
    s, e, _, _, _ = mod.resolve_period("today", now=Z(2026, 5, 15, 12, 0),
                                       tz="Not/AZone")
    assert s == Z(2026, 5, 15, 0, 0)


@pytest.mark.asyncio
async def test_loader_falls_back_when_user_row_missing():
    mod = _mod()
    db = AsyncMock()
    db.execute.side_effect = Exception("no such row")
    assert await mod.load_user_timezone_name(db, uuid4()) == "Asia/Riyadh"
    db2 = AsyncMock()
    m = MagicMock()
    m.scalar.return_value = None
    db2.execute.return_value = m
    assert await mod.load_user_timezone_name(db2, uuid4()) == "Asia/Riyadh"
    db3 = AsyncMock()
    m3 = MagicMock()
    m3.scalar.return_value = NY
    db3.execute.return_value = m3
    assert await mod.load_user_timezone_name(db3, uuid4()) == NY


# ── runtime: device calls carry the stored user timezone ────────────────

@pytest.mark.asyncio
async def test_runtime_device_calls_use_stored_user_timezone(monkeypatch):
    from app.domain.services import sara_agent_service as mod
    from app.domain.models.agent_models import AgentContext
    monkeypatch.setattr(mod, "classify_intent", lambda q: mod.IntentClassification(
        category="analysis", period="today", needs_data=True))
    user_row = MagicMock()
    user_row.scalar.return_value = NY
    db = AsyncMock()
    db.execute.return_value = user_row
    ctx = AgentContext(user_id=str(uuid4()), user_name="t", language="en",
                       account_type="personal",
                       subscription_context={"known": True, "sections": {
                           "personal": {"active": True}, "business": {"active": False}}})
    response = await mod.SaraAgentService(db, uuid4(), uuid4()).process(
        "analyze my spending today", ctx)
    calls = response.device_calls
    assert calls, "the phone answers the context reads"
    bounded = [c for c in calls if (c.get("params") or {}).get("bounds")]
    assert bounded and all(c["params"]["bounds"]["timezone"] == NY for c in bounded)
