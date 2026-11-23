"""Sara Financial Analytics Context (P1).

Builds a bounded, structured analytics snapshot from the user's REAL data so
the LLM interprets pre-computed FACTS instead of doing raw financial math.

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

from sqlalchemy import select, func

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


async def build_financial_analytics(
    db,
    user_id: UUID,
    period: Optional[str] = None,
    *,
    target_currency: Optional[str] = None,
    custom_start: Optional[datetime] = None,
    custom_end: Optional[datetime] = None,
    now: Optional[datetime] = None,
    fx_get_rate=None,
    tz=None,
) -> Dict[str, Any]:
    """Assemble the bounded analytics snapshot from REAL user data.

    `fx_get_rate` is an injectable ``async (from, to) -> {rate, freshness,
    source}`` used ONLY when `target_currency` is set (tests inject a stub;
    production passes CurrencyService.get_instance().get_rate).
    """
    from app.domain.entities.personal_entities import (
        PersonalBankAccount,
        PersonalTransaction,
        PersonalSavingsGoal,
        PersonalDebt,
        PersonalDebtPayment,
        PersonalBudget,
        PersonalBudgetCategory,
        PersonalRecurringTransaction,
    )

    start, end, prev_start, prev_end, label = resolve_period(
        period, custom_start, custom_end, now, tz
    )
    _, tz_name = _tzinfo(tz)
    missing: List[Dict[str, str]] = []

    # ── facts: income/expense/net per currency (SQL GROUP BY) ─────────────
    async def _sums(s, e):
        out: Dict[str, Dict[str, Decimal]] = {}
        for ttype in ("income", "expense"):
            r = await db.execute(
                select(
                    PersonalTransaction.currency,
                    func.coalesce(func.sum(PersonalTransaction.amount), 0),
                    func.count(PersonalTransaction.id),
                ).where(
                    PersonalTransaction.user_id == user_id,
                    ~PersonalTransaction.is_deleted,
                    PersonalTransaction.tx_type == ttype,
                    PersonalTransaction.date >= s,
                    PersonalTransaction.date < e,
                ).group_by(PersonalTransaction.currency)
            )
            for cur, total, cnt in r.all():
                code = _cur(cur)
                slot = out.setdefault(
                    code, {"income": Decimal("0"), "expense": Decimal("0"),
                           "income_count": 0, "expense_count": 0})
                slot[ttype] = slot[ttype] + _d(total)
                slot[f"{ttype}_count"] = int(cnt or 0)
        return out

    cur_sums = await _sums(start, end)
    prev_sums = await _sums(prev_start, prev_end)
    facts_money = []
    for code in sorted(set(cur_sums) | set(prev_sums)):
        c = cur_sums.get(code, {})
        inc = c.get("income", Decimal("0"))
        exp = c.get("expense", Decimal("0"))
        facts_money.append({
            "currency_id": code, "currency": code,
            "income": str(inc), "expense": str(exp), "net": str(inc - exp),
            "income_count": c.get("income_count", 0),
            "expense_count": c.get("expense_count", 0),
        })

    # ── facts: transfers (category-labelled legs, never paired by fuzzy) ──
    r = await db.execute(
        select(
            PersonalTransaction.tx_type,
            PersonalTransaction.currency,
            func.coalesce(func.sum(PersonalTransaction.amount), 0),
            func.count(PersonalTransaction.id),
        ).where(
            PersonalTransaction.user_id == user_id,
            ~PersonalTransaction.is_deleted,
            PersonalTransaction.category.in_(TRANSFER_CATEGORIES),
            PersonalTransaction.date >= start,
            PersonalTransaction.date < end,
        ).group_by(PersonalTransaction.tx_type, PersonalTransaction.currency)
    )
    transfers = [
        {"direction": t, "currency_id": _cur(c), "currency": _cur(c),
         "total": str(_d(total)), "count": int(cnt or 0)}
        for t, c, total, cnt in r.all()
    ]

    # ── facts: top expense categories (+ counts), per (category, currency) ─
    r = await db.execute(
        select(
            PersonalTransaction.category,
            PersonalTransaction.currency,
            func.coalesce(func.sum(PersonalTransaction.amount), 0),
            func.count(PersonalTransaction.id),
        ).where(
            PersonalTransaction.user_id == user_id,
            ~PersonalTransaction.is_deleted,
            PersonalTransaction.tx_type == "expense",
            PersonalTransaction.date >= start,
            PersonalTransaction.date < end,
        ).group_by(PersonalTransaction.category, PersonalTransaction.currency
        ).order_by(func.sum(PersonalTransaction.amount).desc()
        ).limit(TOP_CATEGORIES)
    )
    top_categories = [
        {"category": cat or "", "currency_id": _cur(c), "currency": _cur(c),
         "total": str(_d(total)), "tx_count": int(cnt or 0)}
        for cat, c, total, cnt in r.all()
    ]
    if not top_categories:
        missing.append({"block": "top_categories", "reason": "no_expenses_in_period"})

    # ── facts: income sources (top income categories per currency) ─────────
    r = await db.execute(
        select(
            PersonalTransaction.category,
            PersonalTransaction.currency,
            func.coalesce(func.sum(PersonalTransaction.amount), 0),
            func.count(PersonalTransaction.id),
        ).where(
            PersonalTransaction.user_id == user_id,
            ~PersonalTransaction.is_deleted,
            PersonalTransaction.tx_type == "income",
            PersonalTransaction.date >= start,
            PersonalTransaction.date < end,
        ).group_by(PersonalTransaction.category, PersonalTransaction.currency
        ).order_by(func.sum(PersonalTransaction.amount).desc()
        ).limit(INCOME_SOURCES)
    )
    income_sources = [
        {"category": cat or "", "currency_id": _cur(c), "currency": _cur(c),
         "total": str(_d(total)), "tx_count": int(cnt or 0)}
        for cat, c, total, cnt in r.all()
    ]
    if not income_sources:
        missing.append({"block": "income_sources", "reason": "no_income_in_period"})

    # ── facts: banks (balance + period flows per account per currency) ─────
    r = await db.execute(
        select(PersonalBankAccount).where(
            PersonalBankAccount.user_id == user_id,
            ~PersonalBankAccount.is_deleted,
        ).limit(MAX_ACCOUNTS)
    )
    accounts = r.scalars().all()
    r = await db.execute(
        select(
            PersonalTransaction.bank_account_id,
            PersonalTransaction.tx_type,
            PersonalTransaction.currency,
            func.coalesce(func.sum(PersonalTransaction.amount), 0),
            func.count(PersonalTransaction.id),
        ).where(
            PersonalTransaction.user_id == user_id,
            ~PersonalTransaction.is_deleted,
            PersonalTransaction.date >= start,
            PersonalTransaction.date < end,
        ).group_by(PersonalTransaction.bank_account_id,
                    PersonalTransaction.tx_type, PersonalTransaction.currency)
    )
    flows: Dict[Any, Dict[str, Any]] = {}
    for acc_id, ttype, cur, total, cnt in r.all():
        slot = flows.setdefault(str(acc_id) if acc_id else "unassigned",
                                {"in": {}, "out": {}})
        code = _cur(cur)
        bucket = slot["in" if ttype == "income" else "out"]
        bucket[code] = {"total": str(_d(bucket.get(code, {}).get("total", "0")) + _d(total)),
                        "count": int(bucket.get(code, {}).get("count", 0)) + int(cnt or 0)}
    banks = []
    for a in accounts:
        key = str(a.id)
        banks.append({
            "account_id": key,
            "account_name": a.bank_name,
            "currency_id": _cur(a.currency),
            "currency": _cur(a.currency),
            "balance": str(_d(a.balance)),
            "period_in": flows.get(key, {}).get("in", {}),
            "period_out": flows.get(key, {}).get("out", {}),
        })
    if not banks:
        missing.append({"block": "banks", "reason": "no_accounts"})
    if "unassigned" in flows:
        banks.append({"account_id": None, "account_name": None,
                      "unassigned": True,
                      "period_in": flows["unassigned"]["in"],
                      "period_out": flows["unassigned"]["out"]})

    # ── facts: budgets (stored totals + categories + linked-expense count) ─
    r = await db.execute(
        select(PersonalBudget).where(
            PersonalBudget.user_id == user_id,
            ~PersonalBudget.is_deleted,
        ).limit(MAX_BUDGETS)
    )
    budgets = []
    for b in r.scalars().all():
        rc = await db.execute(
            select(PersonalBudgetCategory).where(
                PersonalBudgetCategory.budget_id == b.id,
            ).limit(MAX_BUDGET_CATEGORIES)
        )
        cats = []
        for c in rc.scalars().all():
            alloc = _d(c.allocated_amount)
            spent = _d(c.spent_amount)
            cats.append({
                "category_id": str(c.id), "name": c.name, "type": c.type,
                "currency_id": _cur(c.currency), "currency": _cur(c.currency),
                "allocated": str(alloc), "spent": str(spent),
                "remaining": str(alloc - spent),
            })
        total = _d(b.total_amount)
        spent_b = _d(getattr(b, "spent", 0) or 0)
        rl = await db.execute(
            select(func.count(PersonalTransaction.id)).where(
                PersonalTransaction.user_id == user_id,
                ~PersonalTransaction.is_deleted,
                PersonalTransaction.budget_id == b.id,
                PersonalTransaction.date >= start,
                PersonalTransaction.date < end,
            )
        )
        linked = rl.scalar() or 0
        pct, _ = _pct_display(spent_b, total)
        budgets.append({
            "budget_id": str(b.id), "name": b.name,
            "currency_id": _cur(b.currency), "currency": _cur(b.currency),
            "total": str(total), "spent": str(spent_b),
            "remaining": str(total - spent_b),
            "used_pct": pct, "used_num": str(spent_b), "used_den": str(total),
            "period": getattr(b, "period_type", None),
            "categories": cats, "linked_expense_count": int(linked),
        })
    if not budgets:
        missing.append({"block": "budgets", "reason": "no_budgets"})

    # ── facts: goals (+ recent contributions via goal_id link) ─────────────
    r = await db.execute(
        select(PersonalSavingsGoal).where(
            PersonalSavingsGoal.user_id == user_id,
            ~PersonalSavingsGoal.is_deleted,
        ).limit(MAX_BUDGETS)
    )
    goals = []
    for g in r.scalars().all():
        rc = await db.execute(
            select(PersonalTransaction).where(
                PersonalTransaction.user_id == user_id,
                ~PersonalTransaction.is_deleted,
                PersonalTransaction.goal_id == g.id,
            ).order_by(PersonalTransaction.date.desc()).limit(LINKED_ROWS)
        )
        contribs = [{
            "tx_id": str(t.id),
            # goal_amount = exact credit in goal currency (may differ for
            # cross-currency contributions); falls back to tx amount.
            "amount": str(_d(t.goal_amount if t.goal_amount is not None else t.amount)),
            "tx_currency_id": _cur(t.currency),
            "date": t.date.isoformat() if hasattr(t.date, "isoformat") else str(t.date),
        } for t in rc.scalars().all()]
        target = _d(g.target_amount)
        current = _d(g.current_amount)
        pct, _ = _pct_display(current, target)
        goals.append({
            "goal_id": str(g.id), "name": g.name,
            "currency_id": _cur(g.currency), "currency": _cur(g.currency),
            "target": str(target), "current": str(current),
            "remaining": str(target - current),
            "progress_pct": pct, "progress_num": str(current),
            "progress_den": str(target),
            "deadline": str(getattr(g, "deadline", "") or ""),
            "is_completed": bool(getattr(g, "is_completed", False)),
            "recent_contributions": contribs,
        })
    if not goals:
        missing.append({"block": "goals", "reason": "no_goals"})

    # ── facts: debts (+ payments; paid = exact SUM of payment rows) ────────
    r = await db.execute(
        select(PersonalDebt).where(
            PersonalDebt.user_id == user_id,
            ~PersonalDebt.is_deleted,
        ).limit(MAX_BUDGETS)
    )
    debts = []
    for d in r.scalars().all():
        rp = await db.execute(
            select(
                func.coalesce(func.sum(PersonalDebtPayment.amount), 0),
                func.count(PersonalDebtPayment.id),
            ).where(
                PersonalDebtPayment.debt_id == d.id,
                ~PersonalDebtPayment.is_deleted
                if hasattr(PersonalDebtPayment, "is_deleted") else True,
            )
        )
        paid_row = rp.all()
        paid = _d(paid_row[0][0]) if paid_row else Decimal("0")
        pay_cnt = int(paid_row[0][1] or 0) if paid_row else 0
        rl = await db.execute(
            select(PersonalDebtPayment).where(
                PersonalDebtPayment.debt_id == d.id,
            ).order_by(PersonalDebtPayment.payment_date.desc()
            ).limit(LINKED_ROWS)
        )
        pays = [{
            "payment_id": str(p.id), "amount": str(_d(p.amount)),
            "currency_id": _cur(p.currency),
            "date": p.payment_date.isoformat()
            if hasattr(p.payment_date, "isoformat") else str(p.payment_date),
        } for p in rl.scalars().all()]
        original = _d(d.amount)
        debts.append({
            "debt_id": str(d.id), "name": d.person_name,
            "debt_type": getattr(d, "debt_type", ""),
            "currency_id": _cur(d.currency), "currency": _cur(d.currency),
            "original": str(original), "paid": str(paid),
            "remaining": str(original - paid), "payment_count": pay_cnt,
            "due_date": str(getattr(d, "due_date", "") or ""),
            "is_paid": bool(getattr(d, "is_paid", False)),
            "recent_payments": pays,
        })
    if not debts:
        missing.append({"block": "debts", "reason": "no_debts"})

    # ── facts: recurring (active first, bounded) ────────────────────────────
    r = await db.execute(
        select(PersonalRecurringTransaction).where(
            PersonalRecurringTransaction.user_id == user_id,
            ~PersonalRecurringTransaction.is_deleted,
        ).order_by(PersonalRecurringTransaction.is_active.desc()
        ).limit(MAX_RECURRING)
    )
    recurring = []
    for t in r.scalars().all():
        acc_name = None
        if getattr(t, "bank_account_id", None):
            ra = await db.execute(
                select(PersonalBankAccount.bank_name).where(
                    PersonalBankAccount.id == t.bank_account_id)
            )
            acc_name = ra.scalar()
        recurring.append({
            "recurring_id": str(t.id), "name": t.name or "",
            "currency_id": _cur(t.currency), "currency": _cur(t.currency),
            "amount": str(_d(t.amount)), "tx_type": t.tx_type,
            "frequency": t.frequency,
            "interval": getattr(t, "interval_value", 1),
            "category": t.category or "",
            "account_id": str(t.bank_account_id) if t.bank_account_id else None,
            "account_name": acc_name,
            "last_run": str(getattr(t, "last_executed_at", "") or ""),
            "next_run": str(getattr(t, "next_run_date", "") or ""),
            "is_active": bool(getattr(t, "is_active", True)),
        })
    if not recurring:
        missing.append({"block": "recurring", "reason": "no_recurring"})

    facts = {
        "money_by_currency": facts_money,
        "transfers": transfers,
        "top_expense_categories": top_categories,
        "income_sources": income_sources,
        "banks": banks,
        "budgets": budgets,
        "goals": goals,
        "debts": debts,
        "recurring": recurring,
    }

    # ── comparisons: current vs previous EQUAL window, per currency ─────────
    comparisons = []
    for code in sorted(set(cur_sums) | set(prev_sums)):
        c = cur_sums.get(code, {})
        p = prev_sums.get(code, {})
        for kind in ("income", "expense", "net"):
            if kind == "net":
                cv = c.get("income", Decimal("0")) - c.get("expense", Decimal("0"))
                pv = p.get("income", Decimal("0")) - p.get("expense", Decimal("0"))
            else:
                cv = c.get(kind, Decimal("0"))
                pv = p.get(kind, Decimal("0"))
            delta = cv - pv
            disp, status = _pct_display(delta, pv)
            comparisons.append({
                "currency_id": code, "currency": code, "metric": kind,
                "current": str(cv), "previous": str(pv), "delta": str(delta),
                "delta_pct": disp, "delta_num": str(delta), "delta_den": str(pv),
                "trend": status,
            })

    # category movers: same (category, currency) in either window
    async def _cat_sums(s, e):
        r = await db.execute(
            select(
                PersonalTransaction.category,
                PersonalTransaction.currency,
                func.coalesce(func.sum(PersonalTransaction.amount), 0),
            ).where(
                PersonalTransaction.user_id == user_id,
                ~PersonalTransaction.is_deleted,
                PersonalTransaction.tx_type == "expense",
                PersonalTransaction.date >= s,
                PersonalTransaction.date < e,
            ).group_by(PersonalTransaction.category, PersonalTransaction.currency)
        )
        return {(cat or "", _cur(c)): _d(t) for cat, c, t in r.all()}

    cur_cats = await _cat_sums(start, end)
    prev_cats = await _cat_sums(prev_start, prev_end)
    movers = []
    for key in set(cur_cats) | set(prev_cats):
        cv, pv = cur_cats.get(key, Decimal("0")), prev_cats.get(key, Decimal("0"))
        if cv == pv:
            continue
        disp, status = _pct_display(cv - pv, pv)
        movers.append({"category": key[0], "currency_id": key[1],
                       "currency": key[1], "current": str(cv),
                       "previous": str(pv), "delta": str(cv - pv),
                       "delta_pct": disp, "trend": status})
    movers.sort(key=lambda m: abs(_d(m["delta"])), reverse=True)
    comparisons_movers = movers[:TOP_CATEGORIES]

    # ── detections: the ONE anomaly rule + insufficient-history ledger ─────
    base_start = start - timedelta(days=ANOMALY_LOOKBACK_DAYS)
    r = await db.execute(
        select(
            PersonalTransaction.category,
            PersonalTransaction.currency,
            func.coalesce(func.sum(PersonalTransaction.amount), 0),
            func.count(PersonalTransaction.id),
        ).where(
            PersonalTransaction.user_id == user_id,
            ~PersonalTransaction.is_deleted,
            PersonalTransaction.tx_type == "expense",
            PersonalTransaction.date >= base_start,
            PersonalTransaction.date < start,
        ).group_by(PersonalTransaction.category, PersonalTransaction.currency)
    )
    base = {((cat or ""), _cur(c)): (_d(t), int(cnt or 0))
            for cat, c, t, cnt in r.all()}
    r = await db.execute(
        select(PersonalTransaction).where(
            PersonalTransaction.user_id == user_id,
            ~PersonalTransaction.is_deleted,
            PersonalTransaction.tx_type == "expense",
            PersonalTransaction.date >= start,
            PersonalTransaction.date < end,
        ).order_by(PersonalTransaction.amount.desc()).limit(50)
    )
    anomalies = []
    thin: Dict[Tuple[str, str], int] = {}
    for t in r.scalars().all():
        key = ((t.category or ""), _cur(t.currency))
        mean_base, n = base.get(key, (Decimal("0"), 0))
        if n < ANOMALY_MIN_BASE_TX:
            thin[key] = n
            continue
        mean = mean_base / n
        if mean > 0 and _d(t.amount) >= ANOMALY_RATIO * mean:
            ratio = (_d(t.amount) / mean).quantize(Decimal("0.1"))
            anomalies.append({
                "tx_id": str(t.id),
                "name": t.description or "",
                "amount": str(_d(t.amount)),
                "currency_id": key[1], "currency": key[1],
                "category": key[0],
                "category_mean_90d": str(mean),
                "base_tx_count": n,
                "ratio": str(ratio),
                "rule": f"amount >= {ANOMALY_RATIO}x category mean (90d, n={n})",
                "date": t.date.isoformat() if hasattr(t.date, "isoformat") else str(t.date),
            })
    anomalies.sort(key=lambda a: _d(a["ratio"]), reverse=True)
    detections = {
        "rule": (f"expense >= {ANOMALY_RATIO}x its (category, currency) 90-day "
                 f"mean with >= {ANOMALY_MIN_BASE_TX} base transactions"),
        "anomalies": anomalies[:TOP_EXPENSES],
        "insufficient_history": [
            {"category": k[0], "currency_id": k[1], "base_tx_count": v}
            for k, v in sorted(thin.items())
        ],
    }
    if not anomalies:
        missing.append({"block": "anomalies",
                        "reason": "no_anomaly_by_rule_or_thin_history"})

    # ── details: top expenses + recent, full linkage, IDs internal ─────────
    async def _tx_row(t, acc_names):
        return {
            "tx_id": str(t.id),
            "name": t.description or "",
            "amount": str(_d(t.amount)),
            "currency_id": _cur(t.currency),
            "currency": _cur(t.currency),
            "tx_type": t.tx_type,
            "date": t.date.isoformat() if hasattr(t.date, "isoformat") else str(t.date),
            "account_id": str(t.bank_account_id) if t.bank_account_id else None,
            "account_name": acc_names.get(str(t.bank_account_id)) if t.bank_account_id else None,
            "category": t.category or "",
            "notes": getattr(t, "description", "") or "",
        }

    acc_names = {b["account_id"]: b["account_name"] for b in banks
                 if b.get("account_id")}
    r = await db.execute(
        select(PersonalTransaction).where(
            PersonalTransaction.user_id == user_id,
            ~PersonalTransaction.is_deleted,
            PersonalTransaction.tx_type == "expense",
            PersonalTransaction.date >= start,
            PersonalTransaction.date < end,
        ).order_by(PersonalTransaction.amount.desc()).limit(TOP_EXPENSES)
    )
    top_expense_rows = [await _tx_row(t, acc_names) for t in r.scalars().all()]
    r = await db.execute(
        select(PersonalTransaction).where(
            PersonalTransaction.user_id == user_id,
            ~PersonalTransaction.is_deleted,
            PersonalTransaction.date >= start,
            PersonalTransaction.date < end,
        ).order_by(PersonalTransaction.date.desc()).limit(RECENT_TX)
    )
    recent_rows = [await _tx_row(t, acc_names) for t in r.scalars().all()]
    if not recent_rows:
        missing.append({"block": "transactions",
                        "reason": "no_transactions_in_period"})

    # frequent descriptions (recurring-like spending, >=3 in 90d)
    r = await db.execute(
        select(
            PersonalTransaction.description,
            PersonalTransaction.currency,
            func.count(PersonalTransaction.id),
            func.coalesce(func.sum(PersonalTransaction.amount), 0),
        ).where(
            PersonalTransaction.user_id == user_id,
            ~PersonalTransaction.is_deleted,
            PersonalTransaction.date >= base_start,
            PersonalTransaction.date < end,
        ).group_by(PersonalTransaction.description, PersonalTransaction.currency
        ).having(func.count(PersonalTransaction.id) >= 3
        ).order_by(func.count(PersonalTransaction.id).desc()).limit(5)
    )
    frequent = [
        {"name": desc or "", "currency_id": _cur(c), "currency": _cur(c),
         "occurrences_90d": int(cnt or 0), "total_90d": str(_d(total))}
        for desc, c, cnt, total in r.all()
    ]

    details = {
        "top_expenses": top_expense_rows,
        "recent_transactions": recent_rows,
        "frequent_descriptions_90d": frequent,
    }

    # ── conversion: explicit target only, real engine or unavailable ────────
    conversion: Dict[str, Any] = {"status": "not_requested"}
    if target_currency:
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

    meta = {
        "period": label,
        "period_start": start.isoformat(),
        "period_end": end.isoformat(),
        "prev_start": prev_start.isoformat(),
        "prev_end": prev_end.isoformat(),
        "timezone": tz_name,
        "source": "server_db",
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }

    return {
        "meta": meta,
        "facts": facts,
        "comparisons": {"per_currency": comparisons,
                        "category_movers": comparisons_movers},
        "detections": detections,
        "details": details,
        "missing": missing,
        "conversion": conversion,
    }
