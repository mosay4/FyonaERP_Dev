"""Sara Financial Analytics (backend P1): bounded real-data context.

Mocked AsyncSession (same pattern as test_sara_currency.py): asserts cover
single/multi currency, YER vs YER_NEW, equal-window comparison, top
categories, named rows with IDs, budgets/goals/debts/recurring, banks,
insufficient data, FX unavailable/valid, the anomaly rule, no cross-currency
merge, similar-name disambiguation, bounded size, and the REAL runtime path
(SaraContextBuilder.build + tool exec + prompt rules AR/EN).

No network, no real DB.
"""
import json
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

NOW = datetime(2026, 5, 15, 12, 0, tzinfo=timezone.utc)
UID = uuid4()


def A(rows):
    """Result mock for tuple-row queries (.all())."""
    m = MagicMock()
    m.all.return_value = rows
    sc = MagicMock()
    sc.all.return_value = []
    m.scalars.return_value = sc
    m.scalar.return_value = 0
    return m


def E(entities):
    """Result mock for entity queries (.scalars().all())."""
    m = MagicMock()
    sc = MagicMock()
    sc.all.return_value = entities
    m.scalars.return_value = sc
    m.all.return_value = []
    m.scalar.return_value = 0
    return m


def V(value):
    """Result mock for scalar queries (.scalar())."""
    m = MagicMock()
    m.scalar.return_value = value
    m.all.return_value = []
    sc = MagicMock()
    sc.all.return_value = []
    m.scalars.return_value = sc
    return m


def _tx(desc, amount, currency, tx_type="expense", category="طعام",
        days_ago=2, **kw):
    t = MagicMock()
    t.id = uuid4()
    t.description = desc
    t.amount = Decimal(str(amount))
    t.currency = currency
    t.tx_type = tx_type
    t.category = category
    t.date = NOW - timedelta(days=days_ago)
    t.bank_account_id = kw.get("bank_account_id")
    t.goal_amount = kw.get("goal_amount")
    t.goal_id = kw.get("goal_id")
    t.debt_id = kw.get("debt_id")
    t.budget_id = kw.get("budget_id")
    return t


def _acct(name, currency, balance):
    a = MagicMock()
    a.id = uuid4()
    a.bank_name = name
    a.currency = currency
    a.balance = Decimal(str(balance))
    return a


def _goal(name, target, current, currency="SAR"):
    g = MagicMock()
    g.id = uuid4()
    g.name = name
    g.target_amount = Decimal(str(target))
    g.current_amount = Decimal(str(current))
    g.currency = currency
    g.deadline = None
    g.is_completed = False
    return g


def _debt(name, amount, currency="SAR"):
    d = MagicMock()
    d.id = uuid4()
    d.person_name = name
    d.debt_type = "payable"
    d.amount = Decimal(str(amount))
    d.currency = currency
    d.due_date = None
    d.is_paid = False
    return d


def _pay(debt_id, amount, currency="SAR"):
    p = MagicMock()
    p.id = uuid4()
    p.debt_id = debt_id
    p.amount = Decimal(str(amount))
    p.currency = currency
    p.payment_date = NOW - timedelta(days=1)
    return p


def _budget(name, total, spent, currency="SAR"):
    b = MagicMock()
    b.id = uuid4()
    b.name = name
    b.total_amount = Decimal(str(total))
    b.spent = Decimal(str(spent))
    b.currency = currency
    b.period_type = "monthly"
    return b


def _bcat(budget_id, name, alloc, spent, currency="SAR"):
    c = MagicMock()
    c.id = uuid4()
    c.budget_id = budget_id
    c.name = name
    c.type = "expense"
    c.allocated_amount = Decimal(str(alloc))
    c.spent_amount = Decimal(str(spent))
    c.currency = currency
    c.goal_id = None
    c.debt_id = None
    return c


def _rec(name, amount, currency="SAR", **kw):
    r = MagicMock()
    r.id = uuid4()
    r.name = name
    r.amount = Decimal(str(amount))
    r.currency = currency
    r.tx_type = kw.get("tx_type", "expense")
    r.frequency = kw.get("frequency", "monthly")
    r.interval_value = 1
    r.category = kw.get("category", "اشتراكات")
    r.bank_account_id = kw.get("bank_account_id")
    r.last_executed_at = NOW - timedelta(days=10)
    r.next_run_date = (NOW + timedelta(days=20)).date()
    r.is_active = True
    return r


def _script(*results):
    db = AsyncMock()
    db.execute.side_effect = list(results)
    return db


def _empty_tail(n):
    return [A([])] * n


def _analytics(**kw):
    from app.domain.services import sara_analytics as mod
    return mod


async def _run(db, **kw):
    mod = _analytics()
    return await mod.build_financial_analytics(db, UID, "this_month", now=NOW, **kw)


def _money(a):
    return {m["currency_id"]: m for m in a["facts"]["money_by_currency"]}


# ── 1-3: currency facts ────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_single_currency_month_facts():
    db = _script(
        A([("SAR", 3000, 2)]), A([("SAR", 1200, 3)]),   # cur sums
        A([]), A([]),                                     # prev sums
        A([]),                                           # transfers
        A([("طعام", "SAR", 800, 2)]),                    # top cats
        A([("راتب", "SAR", 3000, 2)]),                   # income sources
        E([]), A([]),                                    # banks + flows
        E([]),                                           # budgets
        E([]),                                           # goals
        E([]),                                           # debts
        E([]),                                           # recurring
        A([("طعام", "SAR", 800)]), A([]),                # cat movers
        A([]),                                           # anomaly base
        E([_tx("عشاء عائلي", 500, "SAR")] * 1),          # period expenses
        E([]), E([]),                                    # top + recent
        A([]),                                           # frequent
    )
    a = await _run(db)
    m = _money(a)
    assert set(m) == {"SAR"}
    assert m["SAR"]["income"] == "3000"
    assert m["SAR"]["expense"] == "1200"
    assert m["SAR"]["net"] == "1800"
    assert a["conversion"]["status"] == "not_requested"
    assert a["meta"]["period"] == "this_month"
    assert a["meta"]["timezone"] == "UTC"


@pytest.mark.asyncio
async def test_two_currencies_never_merge():
    db = _script(
        A([("SAR", 200, 1), ("USD", 100, 1)]),
        A([("SAR", 500, 2), ("USD", 40, 1)]),
        A([]), A([]),
        A([]),
        A([("طعام", "SAR", 500, 2), ("food", "USD", 40, 1)]),
        A([("راتب", "SAR", 200, 1)]),
        E([]), A([]),
        E([]), E([]), E([]), E([]),
        A([("طعام", "SAR", 500), ("food", "USD", 40)]), A([]),
        A([]),
        E([]),
        E([]), E([]),
        A([]),
    )
    a = await _run(db)
    m = _money(a)
    assert set(m) == {"SAR", "USD"}
    assert m["SAR"]["net"] == str(Decimal("200") - Decimal("500"))
    assert m["USD"]["net"] == str(Decimal("100") - Decimal("40"))
    assert "unified_total" not in json.dumps(a)


@pytest.mark.asyncio
async def test_yer_and_yer_new_are_separate_buckets():
    db = _script(
        A([("YER", 1000, 1), ("YER_NEW", 2000, 1)]),
        A([("YER", 100, 1), ("YER_NEW", 200, 1)]),
        A([]), A([]),
        A([]),
        A([("قات", "YER", 100, 1)]),
        A([]),
        E([]), A([]),
        E([]), E([]), E([]), E([]),
        A([("قات", "YER", 100)]), A([]),
        A([]),
        E([]),
        E([]), E([]),
        A([]),
    )
    a = await _run(db)
    m = _money(a)
    assert m["YER"]["income"] == "1000"
    assert m["YER_NEW"]["income"] == "2000"
    assert m["YER"]["net"] != m["YER_NEW"]["net"]


# ── 4-5: comparison + top categories ───────────────────────────────────────

@pytest.mark.asyncio
async def test_month_vs_previous_equal_window():
    db = _script(
        A([("SAR", 3000, 2)]), A([("SAR", 1800, 3)]),
        A([("SAR", 2500, 2)]), A([("SAR", 1500, 2)]),
        A([]),
        A([("طعام", "SAR", 900, 2)]),
        A([("راتب", "SAR", 3000, 2)]),
        E([]), A([]),
        E([]), E([]), E([]), E([]),
        A([("طعام", "SAR", 900)]), A([("طعام", "SAR", 700)]),
        A([]),
        E([]),
        E([]), E([]),
        A([]),
    )
    a = await _run(db)
    assert a["meta"]["period_start"] == "2026-05-01T00:00:00+00:00"
    # Equal 31-day windows: [Mar31, May1) vs [May1, Jun1).
    assert a["meta"]["prev_start"] == "2026-03-31T00:00:00+00:00"
    assert a["meta"]["prev_end"] == "2026-05-01T00:00:00+00:00"
    cur_len = (datetime.fromisoformat(a["meta"]["period_end"]) -
               datetime.fromisoformat(a["meta"]["period_start"]))
    prev_len = (datetime.fromisoformat(a["meta"]["prev_end"]) -
                datetime.fromisoformat(a["meta"]["prev_start"]))
    assert cur_len == prev_len  # equal windows only
    rows = {(c["metric"], c["currency_id"]): c
            for c in a["comparisons"]["per_currency"]}
    exp = rows[("expense", "SAR")]
    assert exp["current"] == "1800" and exp["previous"] == "1500"
    assert exp["delta"] == "300" and exp["trend"] == "up"
    movers = {(m["category"], m["currency_id"]): m
              for m in a["comparisons"]["category_movers"]}
    assert movers[("طعام", "SAR")]["delta"] == "200"


@pytest.mark.asyncio
async def test_top_expense_categories_ranked():
    db = _script(
        A([("SAR", 0, 0)]), A([("SAR", 1500, 5)]),
        A([]), A([]),
        A([]),
        A([("مطاعم", "SAR", 700, 2), ("وقود", "SAR", 500, 2),
           ("تسوق", "SAR", 300, 1)]),
        A([]),
        E([]), A([]),
        E([]), E([]), E([]), E([]),
        A([("مطاعم", "SAR", 700), ("وقود", "SAR", 500),
           ("تسوق", "SAR", 300)]), A([]),
        A([]),
        E([]),
        E([]), E([]),
        A([]),
    )
    a = await _run(db)
    tops = a["facts"]["top_expense_categories"]
    assert [t["category"] for t in tops] == ["مطاعم", "وقود", "تسوق"]
    assert tops[0]["total"] == "700" and tops[0]["currency_id"] == "SAR"


# ── 6: named transaction with ID ────────────────────────────────────────────

@pytest.mark.asyncio
async def test_named_transaction_carries_real_name_and_id():
    tx = _tx("فاتورة كهرباء مايو", 350, "SAR", category="فواتير")
    txid = str(tx.id)
    db = _script(
        A([("SAR", 0, 0)]), A([("SAR", 350, 1)]),
        A([]), A([]),
        A([]),
        A([("فواتير", "SAR", 350, 1)]),
        A([]),
        E([]), A([]),
        E([]), E([]), E([]), E([]),
        A([("فواتير", "SAR", 350)]), A([]),
        A([]),
        E([tx]),
        E([tx]), E([tx]),
        A([]),
    )
    a = await _run(db)
    top = a["details"]["top_expenses"][0]
    assert top["name"] == "فاتورة كهرباء مايو"
    assert top["tx_id"] == txid
    assert top["amount"] == "350" and top["currency_id"] == "SAR"
    assert top["category"] == "فواتير"


# ── 7-9: budgets / goals / debts ────────────────────────────────────────────

@pytest.mark.asyncio
async def test_budget_with_categories_and_usage():
    b = _budget("ميزانية البيت", 5000, 3200)
    c1 = _bcat(b.id, "طعام", 3000, 2000)
    c2 = _bcat(b.id, "وقود", 2000, 1200)
    db = _script(
        A([]), A([]), A([]), A([]),
        A([]), A([]), A([]),
        E([]), A([]),
        E([b]), E([c1, c2]), V(7),
        E([]), E([]), E([]),
        A([]), A([]),
        A([]),
        E([]),
        E([]), E([]),
        A([]),
    )
    a = await _run(db)
    assert len(a["facts"]["budgets"]) == 1
    got = a["facts"]["budgets"][0]
    assert got["name"] == "ميزانية البيت"
    assert got["budget_id"] == str(b.id)
    assert got["total"] == "5000" and got["spent"] == "3200"
    assert got["remaining"] == "1800"
    assert got["used_num"] == "3200" and got["used_den"] == "5000"
    assert [c["name"] for c in got["categories"]] == ["طعام", "وقود"]
    assert got["linked_expense_count"] == 7


@pytest.mark.asyncio
async def test_goal_with_contributions_and_progress():
    g = _goal("سيارة جديدة", 100000, 25000)
    t1 = _tx("تحويل للهدف", 5000, "SAR", tx_type="expense",
             category="ادخار", goal_id=g.id, goal_amount=5000)
    db = _script(
        A([]), A([]), A([]), A([]),
        A([]), A([]), A([]),
        E([]), A([]),
        E([]),
        E([g]), E([t1]),
        E([]), E([]),
        A([]), A([]),
        A([]),
        E([]),
        E([]), E([]),
        A([]),
    )
    a = await _run(db)
    got = a["facts"]["goals"][0]
    assert got["name"] == "سيارة جديدة" and got["goal_id"] == str(g.id)
    assert got["target"] == "100000" and got["current"] == "25000"
    assert got["remaining"] == "75000"
    assert got["progress_num"] == "25000" and got["progress_den"] == "100000"
    assert got["recent_contributions"][0]["tx_id"] == str(t1.id)
    assert got["recent_contributions"][0]["amount"] == "5000"


@pytest.mark.asyncio
async def test_debt_with_payments_paid_is_exact_sum():
    d = _debt("سلفة أخي", 10000)
    p1, p2 = _pay(d.id, 3000), _pay(d.id, 2000)
    db = _script(
        A([]), A([]), A([]), A([]),
        A([]), A([]), A([]),
        E([]), A([]),
        E([]), E([]),
        E([d]), A([(5000, 2)]), E([p1, p2]),
        E([]),
        A([]), A([]),
        A([]),
        E([]),
        E([]), E([]),
        A([]),
    )
    a = await _run(db)
    got = a["facts"]["debts"][0]
    assert got["name"] == "سلفة أخي" and got["debt_id"] == str(d.id)
    assert got["original"] == "10000"
    assert got["paid"] == "5000"  # exact SUM of payment rows
    assert got["remaining"] == "5000"
    assert got["payment_count"] == 2
    assert {p["payment_id"] for p in got["recent_payments"]} == \
        {str(p1.id), str(p2.id)}


# ── 10-11: recurring + banks ────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_recurring_row_with_schedule_and_account():
    acc = _acct("الراجحي", "SAR", 9000)
    rec = _rec("اشتراك النت", 150, bank_account_id=acc.id)
    db = _script(
        A([]), A([]), A([]), A([]),
        A([]), A([]), A([]),
        E([acc]), A([]),
        E([]), E([]), E([]),
        E([rec]), V("الراجحي"),
        A([]), A([]),
        A([]),
        E([]),
        E([]), E([]),
        A([]),
    )
    a = await _run(db)
    got = a["facts"]["recurring"][0]
    assert got["name"] == "اشتراك النت"
    assert got["recurring_id"] == str(rec.id)
    assert got["amount"] == "150" and got["currency_id"] == "SAR"
    assert got["frequency"] == "monthly"
    assert got["next_run"] != ""
    assert got["account_name"] == "الراجحي"
    assert got["is_active"] is True


@pytest.mark.asyncio
async def test_multiple_banks_with_period_flows():
    a1, a2 = _acct("الراجحي", "SAR", 9000), _acct("Chase", "USD", 1200)
    db = _script(
        A([]), A([]), A([]), A([]),
        A([]), A([]), A([]),
        E([a1, a2]),
        A([(a1.id, "income", "SAR", 5000, 1),
           (a1.id, "expense", "SAR", 1200, 3),
           (a2.id, "income", "USD", 800, 1)]),
        E([]), E([]), E([]), E([]),
        A([]), A([]),
        A([]),
        E([]),
        E([]), E([]),
        A([]),
    )
    a = await _run(db)
    by_id = {b["account_id"]: b for b in a["facts"]["banks"]}
    assert by_id[str(a1.id)]["balance"] == "9000"
    assert by_id[str(a1.id)]["period_in"] == {"SAR": {"total": "5000", "count": 1}}
    assert by_id[str(a1.id)]["period_out"]["SAR"]["total"] == "1200"
    assert by_id[str(a2.id)]["currency_id"] == "USD"


# ── 12: insufficient data honesty ───────────────────────────────────────────

@pytest.mark.asyncio
async def test_insufficient_data_lists_missing_blocks():
    db = _script(
        A([]), A([]), A([]), A([]),
        A([]), A([]), A([]),
        E([]), A([]),
        E([]), E([]), E([]), E([]),
        A([]), A([]),
        A([]),
        E([]),
        E([]), E([]),
        A([]),
    )
    a = await _run(db)
    blocks = {m["block"] for m in a["missing"]}
    assert {"top_categories", "income_sources", "banks", "budgets",
            "goals", "debts", "recurring", "transactions",
            "anomalies"} <= blocks
    assert a["detections"]["anomalies"] == []
    assert a["facts"]["money_by_currency"] == []


# ── 13-14: FX unavailable vs valid ──────────────────────────────────────────

@pytest.mark.asyncio
async def test_no_fx_rate_reports_unavailable():
    async def no_rate(frm, to):
        return None

    db = _script(
        A([("SAR", 200, 1), ("USD", 100, 1)]),
        A([("SAR", 50, 1), ("USD", 10, 1)]),
        A([]), A([]),
        A([]), A([]), A([]),
        E([]), A([]),
        E([]), E([]), E([]), E([]),
        A([]), A([]),
        A([]),
        E([]),
        E([]), E([]),
        A([]),
    )
    a = await _run(db, target_currency="EUR", fx_get_rate=no_rate)
    conv = a["conversion"]
    assert conv["status"] == "unavailable"
    assert set(conv["missing_currencies"]) == {"SAR", "USD"}
    assert "lines" not in conv


@pytest.mark.asyncio
async def test_valid_fx_rate_gives_explicit_unified_lines():
    async def rate(frm, to):
        assert to == "SAR"
        return {"rate": 3.75 if frm == "USD" else None,
                "freshness": "fresh", "source": "test"}

    db = _script(
        A([("SAR", 200, 1), ("USD", 100, 1)]),
        A([("SAR", 50, 1), ("USD", 10, 1)]),
        A([]), A([]),
        A([]), A([]), A([]),
        E([]), A([]),
        E([]), E([]), E([]), E([]),
        A([]), A([]),
        A([]),
        E([]),
        E([]), E([]),
        A([]),
    )
    a = await _run(db, target_currency="SAR", fx_get_rate=rate)
    conv = a["conversion"]
    assert conv["status"] == "ok"
    by_from = {ln["from_currency"]: ln for ln in conv["lines"]}
    assert by_from["USD"]["rate"] == "3.75"
    # net USD = 100-10 = 90 → 90 * 3.75 = 337.50 exactly
    assert by_from["USD"]["converted"] == "337.50"
    assert by_from["SAR"]["rate"] == "1"


# ── 15: anomaly rule ────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_anomaly_flags_3x_mean_with_history_only():
    base = [_tx("غداء", 100, "SAR", category="مطاعم", days_ago=80 + i)
            for i in range(5)]
    for t in base:
        t.date = NOW - timedelta(days=80)
    big = _tx("وليمة كبيرة", 400, "SAR", category="مطاعم", days_ago=2)
    thin = _tx("كتاب نادر", 900, "SAR", category="كتب", days_ago=2)
    db = _script(
        A([("SAR", 0, 0)]), A([("SAR", 1300, 2)]),
        A([]), A([]),
        A([]),
        A([("مطاعم", "SAR", 400, 1), ("كتب", "SAR", 900, 1)]),
        A([]),
        E([]), A([]),
        E([]), E([]), E([]), E([]),
        A([("مطاعم", "SAR", 400), ("كتب", "SAR", 900)]), A([]),
        A([("مطاعم", "SAR", 500, 5), ("كتب", "SAR", 300, 2)]),
        E([big, thin]),
        E([thin, big]), E([big, thin]),
        A([]),
    )
    a = await _run(db)
    anoms = a["detections"]["anomalies"]
    assert len(anoms) == 1
    assert anoms[0]["tx_id"] == str(big.id)
    assert anoms[0]["name"] == "وليمة كبيرة"
    assert anoms[0]["ratio"] == "4.0"  # 400 vs mean 100
    assert "90" in anoms[0]["rule"]
    thin_blocks = {(h["category"], h["currency_id"])
                   for h in a["detections"]["insufficient_history"]}
    assert ("كتب", "SAR") in thin_blocks  # 2 base txs → never flagged


# ── 16: no cross-currency merge anywhere ────────────────────────────────────

@pytest.mark.asyncio
async def test_no_aggregate_without_currency_id():
    acc = _acct("الراجحي", "SAR", 100)
    b = _budget("X", 100, 10)
    g = _goal("Y", 100, 10)
    d = _debt("Z", 100)
    rec = _rec("R", 10)
    tx = _tx("T", 10, "SAR")
    db = _script(
        A([("SAR", 100, 1), ("USD", 50, 1)]),
        A([("SAR", 10, 1), ("USD", 5, 1)]),
        A([("SAR", 90, 1), ("USD", 60, 1)]),
        A([("SAR", 8, 1), ("USD", 5, 1)]),
        A([("expense", "SAR", 10, 1)]),
        A([("T", "SAR", 10, 1)]),
        A([("I", "SAR", 100, 1)]),
        E([acc]), A([(acc.id, "income", "SAR", 100, 1)]),
        E([b]), E([]), V(1),
        E([g]), E([]),
        E([d]), A([(10, 1)]), E([]),
        E([rec]),
        A([("T", "SAR", 10)]), A([("T", "SAR", 8)]),
        A([("T", "SAR", 30, 3)]),
        E([tx]),
        E([tx]), E([tx]),
        A([("T", "SAR", 3, 30)]),
    )

    async def rate(frm, to):
        return {"rate": 2, "freshness": "fresh", "source": "test"}

    a = await _run(db, target_currency="SAR", fx_get_rate=rate)
    money_keys = {"income", "expense", "net", "total", "amount", "paid",
                  "remaining", "balance", "target", "current", "original",
                  "allocated", "spent", "previous", "delta"}

    def walk(node, parent_key=None):
        if isinstance(node, dict):
            keys = set(node)
            if keys & money_keys:
                keyed_by_currency = (
                    isinstance(parent_key, str) and parent_key.isupper()
                    and len(parent_key) <= 8 and keys <= {"total", "count"})
                assert "currency_id" in node or \
                    ("from_currency" in node and "target_currency" in node) or \
                    keyed_by_currency, \
                    f"money without currency: {sorted(keys)}"
            for k, v in node.items():
                walk(v, k)
        elif isinstance(node, list):
            for v in node:
                walk(v, parent_key)

    walk(a["facts"])
    walk(a["comparisons"])
    walk(a["details"])
    walk(a["conversion"])


# ── 17: similar names, distinct IDs ─────────────────────────────────────────

@pytest.mark.asyncio
async def test_similar_names_keep_distinct_ids():
    d1, d2 = _debt("سلفة", 5000), _debt("سلفة", 7000)
    db = _script(
        A([]), A([]), A([]), A([]),
        A([]), A([]), A([]),
        E([]), A([]),
        E([]), E([]),
        E([d1, d2]), A([(0, 0)]), E([]), A([(0, 0)]), E([]),
        E([]),
        A([]), A([]),
        A([]),
        E([]),
        E([]), E([]),
        A([]),
    )
    a = await _run(db)
    got = a["facts"]["debts"]
    assert len(got) == 2
    assert got[0]["debt_id"] != got[1]["debt_id"]
    assert {got[0]["debt_id"], got[1]["debt_id"]} == \
        {str(d1.id), str(d2.id)}
    assert {got[0]["original"], got[1]["original"]} == {"5000", "7000"}


# ── 18: bounded context ─────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_context_is_bounded():
    txs = [_tx(f"عملية {i}", 10 + i, "SAR") for i in range(5)]
    db = _script(
        A([("SAR", 1000, 50)]), A([("SAR", 500, 50)]),
        A([("SAR", 900, 40)]), A([("SAR", 400, 40)]),
        A([]),
        A([(f"cat{i}", "SAR", 100 - i, 3) for i in range(5)]),
        A([("راتب", "SAR", 1000, 2)]),
        E([_acct(f"بنك {i}", "SAR", 100) for i in range(3)]),
        A([]),
        E([]), E([]), E([]), E([]),
        A([]), A([]),
        A([]),
        E(txs),
        E(txs), E(txs),
        A([]),
    )
    a = await _run(db)
    assert len(a["facts"]["top_expense_categories"]) <= 5
    assert len(a["details"]["top_expenses"]) <= 5
    assert len(a["details"]["recent_transactions"]) <= 5
    assert len(a["detections"]["anomalies"]) <= 5
    assert len(json.dumps(a, ensure_ascii=False)) < 24 * 1024


# ── runtime path: builder + tool + prompts ──────────────────────────────────

@pytest.mark.asyncio
async def test_runtime_builder_attaches_analytics_for_analysis():
    from app.domain.services import sara_agent_service as mod
    db = _script(
        A([]),  # banking
        V("UTC"),  # central tz lookup (bounds identical to old behaviour)
        A([]), A([]),  # financial (income/expense grouped)
        A([]), A([]),  # analytics current sums
        A([]), A([]),  # analytics previous sums
        A([]), A([]), A([]),  # transfers/tops/income
        E([]), A([]),  # banks + flows
        E([]), E([]), E([]), E([]),  # budgets/goals/debts/recurring
        A([]), A([]),  # movers
        A([]),  # anomaly base
        E([]),  # period expenses
        E([]), E([]),  # top + recent
        A([]),  # frequent
    )
    intent = mod.IntentClassification(category="analysis",
                                      subcategory="financial_summary",
                                      period="this_month",
                                      needs_data=True)
    builder = mod.SaraContextBuilder(db, uuid4(), UID)
    data = await builder.build(intent)
    assert "analytics" in data and "financial" in data
    ana = data["analytics"]
    for section in ("meta", "facts", "comparisons", "detections",
                    "details", "missing", "conversion"):
        assert section in ana, section
    assert ana["meta"]["source"] == "server_db"


@pytest.mark.asyncio
async def test_runtime_tool_exec_returns_analytics():
    from app.domain.services import sara_agent_service as mod
    svc = mod.ToolExecutor(_script(
        V("UTC"),  # central tz lookup (bounds identical to old behaviour)
        A([]), A([]), A([]), A([]),
        A([]), A([]), A([]),
        E([]), A([]),
        E([]), E([]), E([]), E([]),
        A([]), A([]),
        A([]),
        E([]),
        E([]), E([]),
        A([]),
    ), uuid4(), UID, lang="ar")
    out = await svc._exec_get_financial_analytics({"period": "this_month"})
    assert out["meta"]["period"] == "this_month"
    assert any(m["block"] == "transactions" for m in out["missing"])


def test_prompt_rules_cover_analytics_both_languages():
    from app.domain.services import sara_agent_service as mod
    from app.domain.models.agent_models import AgentContext
    intent = mod.IntentClassification(category="analysis", needs_data=True)
    ctx = AgentContext(user_id=str(uuid4()), user_name="ت",
                       account_type="personal", language="ar")
    ar = mod.build_dynamic_prompt(ctx, intent, {"analytics": {"meta": {}}})
    assert "0ب" in ar and "analytics" in ar
    assert "فصل العملات" in ar  # P0 currency rules intact
    ctx_en = AgentContext(user_id=str(uuid4()), user_name="t",
                          account_type="personal", language="en")
    en = mod.build_dynamic_prompt(ctx_en, intent, {"analytics": {"meta": {}}})
    assert "0b" in en and "analytics" in en
    assert "Currency separation" in en  # P0 currency rules intact
