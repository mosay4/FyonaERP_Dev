"""Sara currency separation (backend): per-currency sums, converted-or-stop
transfer, currency-tagged rows, and LLM anti-sum rules in both prompts.

Stripe SDK + database are mocked; no network, no real charges.
"""
import os
from datetime import datetime, timezone
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import pytest

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")
os.environ.setdefault("CELERY_BROKER_URL", "redis://localhost:6379/1")
os.environ.setdefault("CELERY_RESULT_BACKEND", "redis://localhost:6379/2")


def _rows(all_list):
    m = MagicMock()
    m.all.return_value = all_list
    sc = MagicMock()
    sc.all.return_value = all_list
    m.scalars.return_value = sc
    return m


def _empty_dup():
    """No prior row for the tool idempotency key (contract check-then-insert)."""
    m = MagicMock()
    m.scalar_one_or_none.return_value = None
    return m


def _acct(name, currency, balance):
    a = MagicMock()
    a.id = uuid4()
    a.bank_name = name
    a.currency = currency
    a.balance = Decimal(str(balance))
    return a


def _tx_row(desc, amount, currency, tx_type="expense"):
    t = MagicMock()
    t.id = uuid4()
    t.description = desc
    t.amount = Decimal(str(amount))
    t.currency = currency
    t.tx_type = tx_type
    t.category = "food"
    t.date = datetime.now(timezone.utc)
    return t


def _svc(db):
    from app.domain.services import sara_agent_service as mod
    return mod.ToolExecutor(db, uuid4(), uuid4(), lang="ar"), mod


@pytest.mark.asyncio
async def test_financial_summary_grouped_by_currency():
    svc, mod = _svc(AsyncMock())
    db = svc._db
    tz_row = MagicMock()
    tz_row.scalar.return_value = "UTC"  # central tz lookup (bounds unchanged)
    db.execute.side_effect = [
        tz_row,
        _rows([("USD", 100), ("SAR", 200)]),
        _rows([("USD", 40), ("SAR", 500)]),
    ]
    ctx = mod.SaraContextBuilder(db, uuid4(), uuid4())
    out = await ctx._get_financial_summary("this_month")
    assert "income" not in out and "expense" not in out and "net" not in out
    by_cur = {r["currency"]: r for r in out["by_currency"]}
    assert by_cur["USD"]["income"] == "100"
    assert by_cur["SAR"]["expense"] == "500"
    assert by_cur["SAR"]["net"] == str(Decimal("200") - Decimal("500"))
    assert all("currency_id" in r and "currency" in r for r in out["by_currency"])


@pytest.mark.asyncio
async def test_expenses_grouped_no_mixed_total():
    svc, mod = _svc(AsyncMock())
    db = svc._db
    rows = [_tx_row("a", 10, "USD"), _tx_row("b", 20, "SAR"),
            _tx_row("c", 5, "USD")]
    tz_row = MagicMock()
    tz_row.scalar.return_value = "UTC"  # central tz lookup (bounds unchanged)
    db.execute.side_effect = [tz_row, _rows(rows)]
    out = await svc._exec_get_expenses_data({})
    assert "total_spending" not in out
    by_cur = {r["currency"]: r["total"] for r in out["by_currency"]}
    assert by_cur == {"USD": "15", "SAR": "20"}
    assert all("currency_id" in r for r in out["expenses"])
    cats = {(r["category"], r["currency"]): r["total"] for r in out["by_category"]}
    assert cats[("food", "USD")] == "15"


@pytest.mark.asyncio
async def test_recent_and_search_rows_carry_currency():
    svc, mod = _svc(AsyncMock())
    db = svc._db
    db.execute.side_effect = [_rows([_tx_row("x", 7, "YER_NEW")])]
    ctx = mod.SaraContextBuilder(db, uuid4(), uuid4())
    recent = await ctx._get_recent_transactions(10)
    assert recent[0]["currency"] == "YER_NEW"
    assert recent[0]["currency_id"] == "YER_NEW"
    db.execute.side_effect = [_rows([_tx_row("y", 9, "EUR")])]
    found = await svc._exec_search_all_transactions({})
    assert found["transactions"][0]["currency"] == "EUR"


@pytest.mark.asyncio
async def test_transfer_cross_currency_converted_and_tagged():
    svc, mod = _svc(AsyncMock())
    db = svc._db
    usd = _acct("DollarVault", "USD", 1000)
    sar = _acct("RiyalVault", "SAR", 0)
    db.execute.side_effect = [_empty_dup(), _rows([usd, sar])]
    db.flush = AsyncMock()
    db.get = AsyncMock(return_value=MagicMock())
    db.add = MagicMock()
    fx = MagicMock()
    fx.convert = AsyncMock(return_value=3750.0)
    import app.domain.services.currency_service as cs_mod
    with patch.object(cs_mod.CurrencyService, "get_instance", return_value=fx):
        out = await svc._exec_create_transaction({
            "operation": "transfer",
            "amount": 1000,
            "from_account_name": "DollarVault",
            "to_account_name": "RiyalVault",
        })
    assert out.get("success") is True
    assert "1000 USD" in out["message"] and "3750.0 SAR" in out["message"]
    added = [c.args[0] for c in db.add.call_args_list]
    by_cur = {a.currency: a.amount for a in added}
    assert by_cur == {"USD": Decimal("1000"), "SAR": Decimal("3750.0")}


@pytest.mark.asyncio
async def test_transfer_no_rate_stops_without_writing():
    svc, mod = _svc(AsyncMock())
    db = svc._db
    usd = _acct("DollarVault", "USD", 1000)
    sar = _acct("RiyalVault", "SAR", 0)
    db.execute.side_effect = [_empty_dup(), _rows([usd, sar])]
    db.add = MagicMock()
    fx = MagicMock()
    fx.convert = AsyncMock(return_value=None)
    import app.domain.services.currency_service as cs_mod
    with patch.object(cs_mod.CurrencyService, "get_instance", return_value=fx):
        out = await svc._exec_create_transaction({
            "operation": "transfer",
            "amount": 1000,
            "from_account_name": "DollarVault",
            "to_account_name": "RiyalVault",
        })
    assert "error" in out
    assert "سعر صرف" in out["error"]
    db.add.assert_not_called()


@pytest.mark.asyncio
async def test_same_currency_transfer_untouched():
    svc, mod = _svc(AsyncMock())
    db = svc._db
    a1 = _acct("A", "SAR", 500)
    a2 = _acct("B", "SAR", 0)
    db.execute.side_effect = [_empty_dup(), _rows([a1, a2])]
    db.flush = AsyncMock()
    db.get = AsyncMock(return_value=MagicMock())
    db.add = MagicMock()
    out = await svc._exec_create_transaction({
        "operation": "transfer",
        "amount": 100,
        "from_account_name": "A",
        "to_account_name": "B",
    })
    assert out.get("success") is True
    added = [c.args[0] for c in db.add.call_args_list]
    assert [a.amount for a in added] == [Decimal("100"), Decimal("100")]


def fyona_noop():
    raise AssertionError("unreachable")


@pytest.mark.asyncio
async def test_prompt_rules_both_languages():
    from app.domain.services.sara_agent_service import build_dynamic_prompt
    from app.domain.models.agent_models import AgentContext, IntentClassification
    ctx = AgentContext(user_id="u", user_name="T", language="Arabic")
    intent = IntentClassification(category="analysis")
    en_ctx = AgentContext(user_id="u", user_name="T", language="en")
    ar = build_dynamic_prompt(ctx, intent, {"financial": {"by_currency": []}})
    en = build_dynamic_prompt(en_ctx, intent, {"financial": {"by_currency": []}})
    assert "never sum across currencies" in en.lower()
    assert "ممنوع" in ar and "العملات" in ar


@pytest.mark.asyncio
async def test_exchange_rate_read_uses_real_engine():
    svc, mod = _svc(AsyncMock())
    fx = MagicMock()
    fx.get_rate = AsyncMock(return_value={
        "rate": 540.0, "from": "USD", "to": "YER_OLD",
        "source": "test", "freshness": "fresh",
    })
    import app.domain.services.currency_service as cs_mod
    with patch.object(cs_mod.CurrencyService, "get_instance", return_value=fx):
        out = await svc._exec_get_exchange_rate(
            {"from_currency": "USD", "to_currency": "YER_OLD"})
    assert out.get("rate") == 540.0
    assert out.get("to") == "YER_OLD"


@pytest.mark.asyncio
async def test_exchange_rate_bare_yer_is_ambiguous():
    svc, mod = _svc(AsyncMock())
    out = await svc._exec_get_exchange_rate(
        {"from_currency": "USD", "to_currency": "YER"})
    assert "error" in out
    assert "YER_OLD" in out["error"]


@pytest.mark.asyncio
async def test_exchange_rate_missing_codes_rejected():
    svc, mod = _svc(AsyncMock())
    out = await svc._exec_get_exchange_rate({"from_currency": "USD"})
    assert "error" in out


@pytest.mark.asyncio
async def test_exchange_rate_unavailable_never_invented():
    svc, mod = _svc(AsyncMock())
    fx = MagicMock()
    fx.get_rate = AsyncMock(return_value={"rate": None, "from": "USD", "to": "XYZ"})
    import app.domain.services.currency_service as cs_mod
    with patch.object(cs_mod.CurrencyService, "get_instance", return_value=fx):
        out = await svc._exec_get_exchange_rate(
            {"from_currency": "USD", "to_currency": "XYZ"})
    assert "error" in out


@pytest.mark.asyncio
async def test_deposit_message_carries_currency():
    svc, mod = _svc(AsyncMock())
    db = svc._db
    acc = _acct("كاش", "YER_OLD", 0)
    db.execute.side_effect = [_empty_dup(), _rows([acc])]
    db.flush = AsyncMock()
    db.get = AsyncMock(return_value=MagicMock())
    db.add = MagicMock()
    out = await svc._exec_create_transaction({
        "operation": "deposit", "amount": 54000,
        "account_name": "كاش", "currency": "YER_OLD",
    })
    assert out.get("success") is True
    assert "YER_OLD" in out["message"]
    added = [c.args[0] for c in db.add.call_args_list]
    assert added[0].currency == "YER_OLD"
    assert added[0].amount == Decimal("54000")


def test_ar_prompt_is_masculine_and_complete():
    from app.domain.services.sara_agent_service import build_dynamic_prompt
    from app.domain.models.agent_models import AgentContext, IntentClassification
    ctx = AgentContext(user_id="u", user_name="T", language="Arabic")
    ar = build_dynamic_prompt(ctx, IntentClassification(category="delete"), {})
    for marker in ["تتكلمي", "صديقة", "كوني", "استخدمي", "اسألي",
                   "افهمي", "اختاري", "نفذي", "راجعي", "أنتِ", "آسفة"]:
        assert marker not in ar, marker
    assert "خبرني" in ar
    for needle in ["delete_budget", "delete_recurring", "YER_OLD",
                   "YER_NEW", "get_exchange_rate", "ask_clarification",
                   "receivable", "payable", "get_operation_status"]:
        assert needle in ar, needle
