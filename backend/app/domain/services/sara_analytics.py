"""Sara Financial Analytics Context (P1) — the server-side helpers.

The bounded analytics snapshot itself is computed on the user's phone from
its own ledger (personal_analytics.dart); the server only resolves periods
in the user's timezone and converts per-currency nets with the real FX
engine. The rules below are the ones the phone follows.

Hard rules (mirrors the P0 currency work — do not weaken):
- Money is Decimal end-to-end. No float math, no rounding during
  computation. Percentages carry exact numerator/denominator; only the
  `display` string is rounded (1dp) for speech.
- NEVER merge currencies. Every aggregate carries `currency_id`.
  `YER` and `YER_NEW` are separate buckets. Currency identity is the
  canonical upper-case CODE (never the display name).
- A unified cross-currency total exists ONLY as an explicitly converted
  total via the real FX engine (CurrencyService.get_rate, freshness
  fresh/stale). Otherwise conversion is reported unavailable — never guessed.
- Bounded output: every row query has a hard LIMIT; no full-table loads.
- IDs (UUID strings) ride along internally on every item; names are the
  real stored names. No fuzzy matching anywhere in this module.

Sections: meta / facts / comparisons / detections / details / missing /
conversion. The prompt layer is instructed to treat them exactly as such.
"""

from datetime import datetime, timezone, timedelta, date as date_cls
from decimal import Decimal, InvalidOperation
from typing import Any, Dict, List, Optional, Tuple
from uuid import UUID
from zoneinfo import ZoneInfo

from sqlalchemy import select

# ── Bounds (context must stay small) ──────────────────────────────────────
TOP_CATEGORIES = 5
TOP_EXPENSES = 5
RECENT_TX = 5
INCOME_SOURCES = 5
LINKED_ROWS = 3          # goal contributions / debt payments per entity
MAX_RECURRING = 10
MAX_BUDGETS = 10
MAX_BUDGET_CATEGORIES = 10
MAX_ACCOUNTS = 20

# ── Anomaly rule (single, documented, testable) ────────────────────────────
# A period expense is "unusual" iff, for the same (category, currency), the
# mean of that category over the PRIOR 90 days rests on >= MIN_BASE_TX
# transactions AND amount >= ANOMALY_RATIO * mean. Otherwise the category is
# reported under `insufficient_history` — never flagged.
ANOMALY_LOOKBACK_DAYS = 90
ANOMALY_MIN_BASE_TX = 3
ANOMALY_RATIO = Decimal("3")

TRANSFER_CATEGORIES = ("تحويل", "Transfer")

_VALID_PERIODS = (
    "today", "yesterday", "this_week", "this_month",
    "last_month", "this_year", "custom",
)

# ── User timezone: existing sources only ──────────────────────────────────
# `users.timezone` is the per-account source (column default below). When no
# stored value exists we fall back to that same app default — the default the
# app itself uses for organization settings and scheduled jobs — and to UTC
# only if a name is not a usable IANA zone. Nothing is invented per user.
APP_DEFAULT_TZ = "Asia/Riyadh"


def _tzinfo(tz) -> Tuple[Any, str]:
    """Normalize [tz] (IANA name | tzinfo | None) → (tzinfo, display name)."""
    if tz is None:
        return timezone.utc, "UTC"
    if isinstance(tz, str):
        try:
            return ZoneInfo(tz), tz
        except Exception:
            return timezone.utc, "UTC"
    name = getattr(tz, "key", None) or "custom"
    return tz, str(name)


def resolve_user_timezone_name(stored: Any) -> str:
    """Pick the effective timezone name: stored valid IANA value wins,
    otherwise the app default, otherwise UTC (never raises)."""
    if isinstance(stored, str) and stored.strip():
        try:
            ZoneInfo(stored.strip())
            return stored.strip()
        except Exception:
            pass
    try:
        ZoneInfo(APP_DEFAULT_TZ)
        return APP_DEFAULT_TZ
    except Exception:
        return "UTC"


async def load_user_timezone_name(db, user_id: UUID) -> str:
    """Central loader: the user's stored timezone (one indexed SELECT).

    Storage is never written here; a missing row/NULL/empty value simply
    yields the documented fallback chain via [resolve_user_timezone_name].
    """
    try:
        from app.domain.entities.auth_entities import User
        r = await db.execute(select(User.timezone).where(User.id == user_id))
        stored = r.scalar()
    except Exception:
        stored = None
    return resolve_user_timezone_name(stored)


def _d(value: Any) -> Decimal:
    """Exact Decimal coercion (never via float)."""
    if isinstance(value, Decimal):
        return value
    if value is None:
        return Decimal("0")
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError):
        return Decimal("0")


def _cur(value: Any) -> str:
    return str(value or "SAR").upper()


def resolve_period(
    name: Optional[str],
    start: Optional[datetime] = None,
    end: Optional[datetime] = None,
    now: Optional[datetime] = None,
    tz=None,
) -> Tuple[datetime, datetime, datetime, datetime, str]:
    """Return (start, end, prev_start, prev_end, label) as UTC bounds.

    Day/week/month/year edges are derived from the USER's wall clock in
    [tz] (IANA name or tzinfo; None/UTC preserves the historical behaviour),
    then converted back to UTC for querying. Stored timestamps are never
    rewritten or reinterpreted — only the window edges move. The previous
    window always has exactly the same length (equal comparisons only).
    """
    local_tz, _tz_name = _tzinfo(tz)
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        current = current.replace(tzinfo=timezone.utc)
    local = current.astimezone(local_tz)
    pname = (name or "this_month").lower()
    if pname not in _VALID_PERIODS:
        pname = "this_month"

    def _to_utc(dt_local):
        return dt_local.astimezone(timezone.utc)

    day = local.replace(hour=0, minute=0, second=0, microsecond=0)
    if pname == "today":
        ls, le = day, day + timedelta(days=1)
        label = "today"
    elif pname == "yesterday":
        ls, le = day - timedelta(days=1), day
        label = "yesterday"
    elif pname == "this_week":
        ls = day - timedelta(days=day.weekday())  # Monday start (app convention)
        le = ls + timedelta(days=7)
        label = "this_week"
    elif pname == "last_month":
        first = local.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        # first day of previous month:
        prev_first = (first - timedelta(days=1)).replace(day=1)
        ls, le = prev_first, first
        label = "last_month"
    elif pname == "this_year":
        ls = local.replace(month=1, day=1, hour=0, minute=0, second=0, microsecond=0)
        le = ls.replace(year=ls.year + 1)
        label = "this_year"
    elif pname == "custom" and start is not None and end is not None:
        # Naive user input is interpreted in the user's timezone.
        ls = start if start.tzinfo else start.replace(tzinfo=local_tz)
        le = end if end.tzinfo else end.replace(tzinfo=local_tz)
        ls, le = ls.astimezone(local_tz), le.astimezone(local_tz)
        if le <= ls:
            le = ls + timedelta(days=1)
        label = "custom"
    else:  # this_month (default)
        ls = local.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
        if ls.month == 12:
            le = ls.replace(year=ls.year + 1, month=1)
        else:
            le = ls.replace(month=ls.month + 1)
        label = "this_month"

    s, e = _to_utc(ls), _to_utc(le)
    length = e - s
    return s, e, s - length, s, label


def _pct_display(num: Decimal, den: Decimal) -> Tuple[Optional[str], str]:
    """(display rounded to 1dp or None, status). Exact num/den travel along."""
    if den == 0:
        return None, ("new" if num != 0 else "flat")
    pct = (num / den * Decimal("100")).quantize(Decimal("0.1"))
    if num == 0:
        return "0.0", "flat"
    return str(pct), ("up" if num > 0 else "down")


# The server-side analytics over the Personal tables (build_financial_analytics)
# is gone (Stage 6, docs/PERSONAL_LOCAL_PLAN.md): Personal data lives only on
# the user's devices, and the phone computes the same snapshot
# (lib/features/personal/domain/services/personal_analytics.dart; expected
# outputs frozen in test/fixtures/personal_analytics_parity.json). The server
# keeps the shared period windows (resolve_period) and the explicit FX
# conversion of the per-currency nets (convert_net_totals).


async def convert_net_totals(facts_money, target_currency: str, fx_get_rate=None) -> Dict[str, Any]:
    """Explicit cross-currency total of the per-currency nets: the real FX
    engine (fresh/stale rates) or "unavailable" — never guessed. Shared by
    the server analytics and Personal device-mode analytics."""
    conversion: Dict[str, Any] = {"status": "not_requested"}
    target = target_currency.strip().upper()
    if fx_get_rate is None:
        try:
            from app.domain.services.currency_service import CurrencyService
            fx_get_rate = CurrencyService.get_instance().get_rate
        except Exception:
            fx_get_rate = None
    if fx_get_rate is None:
        conversion = {"status": "unavailable",
                      "reason": "fx_engine_unreachable",
                      "target_currency": target}
    else:
        codes = sorted({m["currency_id"] for m in facts_money})
        lines, gone = [], []
        try:
            for code in codes:
                if code == target:
                    amt = next(m for m in facts_money
                               if m["currency_id"] == code)
                    lines.append({
                        "from_currency": code, "target_currency": target,
                        "amount": amt["net"], "converted": amt["net"],
                        "rate": "1", "rate_source": "identity",
                        "freshness": "fresh"})
                    continue
                meta = await fx_get_rate(code, target)
                rate = (meta or {}).get("rate")
                fresh = (meta or {}).get("freshness", "")
                if rate and fresh in ("fresh", "stale"):
                    amt = next(m for m in facts_money
                               if m["currency_id"] == code)
                    conv = (_d(amt["net"]) * _d(rate)).quantize(
                        Decimal("0.01"))
                    lines.append({
                        "from_currency": code, "target_currency": target,
                        "amount": amt["net"], "converted": str(conv),
                        "rate": str(_d(rate)),
                        "rate_source": (meta or {}).get("source", "unknown"),
                        "freshness": fresh})
                else:
                    gone.append(code)
        except Exception:
            conversion = {"status": "unavailable",
                          "reason": "fx_lookup_failed",
                          "target_currency": target}
        else:
            if gone:
                conversion = {"status": "unavailable",
                              "reason": "no_valid_rate",
                              "target_currency": target,
                              "missing_currencies": sorted(gone)}
            else:
                conversion = {"status": "ok", "target_currency": target,
                              "lines": lines}

    return conversion
