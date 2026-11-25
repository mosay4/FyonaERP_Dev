"""The Falcon answers fast and never fails because of the model: the effort is
chosen from the merchant's question (not the figures dump), the AI call is
bounded, and a phone may send its own compact summary instead of every row."""
import asyncio
import time
from types import SimpleNamespace

import pytest

from app.domain.services import ai_router
from app.domain.services import falcon_service as fs

ITEMS = [
    {"id": "p1", "name": "أرز بسمتي", "unit": "كيس", "stock": 3, "min_stock": 10,
     "sell_price": 50, "cost_price": 40, "sales": 5000, "qty_sold": 100,
     "cogs": 4000, "profit": 1000, "purchases": 4400, "qty_purchased": 110},
    {"id": "p2", "name": "زيت ذرة", "unit": "علبة", "stock": 40, "min_stock": 5,
     "sell_price": 20, "cost_price": 19, "sales": 0, "qty_sold": 0,
     "cogs": 0, "profit": 0, "purchases": 760, "qty_purchased": 40},
    {"id": "p3", "name": "سكر", "unit": "كيس", "stock": 0, "min_stock": 5,
     "sell_price": 30, "cost_price": 29, "sales": 900, "qty_sold": 30,
     "cogs": 870, "profit": 30, "purchases": 870, "qty_purchased": 30},
]


def _branches():
    return [{**row, "branch_id": bid, "branch_name": name}
            for bid, name in (("b1", "فرع الرياض"), ("b2", "فرع جدة")) for row in ITEMS]


@pytest.mark.parametrize("scope,ref,items", [
    ("inventory", None, ITEMS),
    ("category", None, ITEMS),
    ("product", "p1", ITEMS),
    ("inventory", None, _branches()),
])
def test_phone_summary_gives_the_same_figures_as_the_rows(scope, ref, items):
    rows, title = fs.device_dataset(items, "SAR", scope, ref, "حبوب")
    summary, same_title = fs.device_summary_dataset(rows, "SAR", scope, "حبوب")
    assert same_title == title
    for key in ("total_sales", "total_profit", "inventory_value", "products_count",
                "low_stock", "out_of_stock", "stock", "suggested_order_qty",
                "stagnant_value_share", "branch_ids"):
        assert summary.get(key) == rows.get(key), key
    for key in ("top_sellers", "reorder", "slow_moving", "weak_margin"):
        assert [r["name"] for r in summary.get(key, [])] == [r["name"] for r in rows.get(key, [])]
    assert [b["branch_name"] for b in summary.get("branch_summaries", [])] == \
        [b["branch_name"] for b in rows.get("branch_summaries", [])]


def test_phone_summary_is_reshaped_never_trusted():
    data, _ = fs.device_summary_dataset({
        "total_sales": "nan", "products_count": "7", "evil": {"x": 1},
        "top_sellers": [{"name": "x" * 900, "qty_sold": "inf", "script": "<b>"}] * 40,
        "low_stock": ["a", {"b": 1}, 3],
        "branch_summaries": [{"branch_id": "b1", "total_sales": 5}, {"no": "id"}],
    }, "usd", "inventory")
    assert data["report_currency"] == "USD"
    assert data["total_sales"] == 0.0 and data["products_count"] == 7
    assert "evil" not in data
    assert len(data["top_sellers"]) == 10
    assert len(data["top_sellers"][0]["name"]) == 200
    assert data["top_sellers"][0]["qty_sold"] == 0.0
    assert "script" not in data["top_sellers"][0]
    assert data["low_stock"] == ["a", "3"]
    assert [b["branch_id"] for b in data["branch_summaries"]] == ["b1"]


def test_the_figures_dump_alone_always_looked_max():
    # Root cause of the slow «تعذّر تشغيل التحليل»: routing on the prompt.
    data, title = fs.device_dataset(ITEMS * 200, "SAR", "inventory", None)
    pb = fs._type_context("inventory", data, [i["name"] for i in data["top_sellers"]], "")["playbook"]
    dump = f"{pb['pricing']} {pb['turnover']} {pb['risks']}\n{fs._compact_scoped_data(data)}"
    assert ai_router.classify_difficulty(dump) == "max"
    assert ai_router.classify_difficulty("") == "low"


@pytest.mark.asyncio
async def test_report_routes_on_the_question_and_is_bounded(monkeypatch):
    seen = {}

    def route(text, **kw):
        seen["text"] = text
        return SimpleNamespace(api_key="test-only", model="m", max_tokens=900, effort="low")

    async def slow(**kw):
        await asyncio.sleep(5)

    monkeypatch.setattr(ai_router, "route", route)
    monkeypatch.setattr(ai_router, "build_client", lambda r: SimpleNamespace(
        chat=SimpleNamespace(completions=SimpleNamespace(create=slow))))
    monkeypatch.setattr(fs, "AI_REPORT_TIMEOUT", 0.2)
    started = time.monotonic()
    report = await fs.analyze(None, None, "inventory", None, "ar", "SAR",
                              device=fs.device_dataset(ITEMS, "SAR", "inventory", None))
    assert time.monotonic() - started < 2
    assert seen["text"] == ""
    assert report["ai"] is False
    assert report["status_line"] and report["recommendations"]
    assert report["stats"]["total_sales"] == 5900


@pytest.mark.asyncio
async def test_sdk_retries_are_disabled(monkeypatch):
    bounded = {}

    class Client:
        def with_options(self, **kw):
            bounded.update(kw)
            return self

        @property
        def chat(self):
            async def create(**kw):
                return SimpleNamespace(choices=[SimpleNamespace(
                    message=SimpleNamespace(content='{"status_line": "تمام"}'))])
            return SimpleNamespace(completions=SimpleNamespace(create=create))

    monkeypatch.setattr(ai_router, "route", lambda *a, **k: SimpleNamespace(
        api_key="test-only", model="m", max_tokens=900, effort="low"))
    monkeypatch.setattr(ai_router, "build_client", lambda r: Client())
    assert await fs._call_ai("s", "u") == '{"status_line": "تمام"}'
    assert bounded == {"timeout": fs.AI_REPORT_TIMEOUT, "max_retries": 0}


@pytest.mark.asyncio
async def test_chat_routes_on_the_question_and_falls_back_on_timeout(monkeypatch):
    seen = {}

    def route(text, **kw):
        seen["text"] = text
        return SimpleNamespace(api_key="test-only", model="m", max_tokens=500, effort="low")

    async def slow(**kw):
        await asyncio.sleep(5)

    monkeypatch.setattr(fs.settings, "OPENAI_API_KEY", "test-only")
    monkeypatch.setattr(ai_router, "route", route)
    monkeypatch.setattr(ai_router, "build_client", lambda r: SimpleNamespace(
        chat=SimpleNamespace(completions=SimpleNamespace(create=slow))))
    monkeypatch.setattr(fs, "AI_CHAT_TIMEOUT", 0.2)
    started = time.monotonic()
    result = await fs.chat(None, None, "inventory", None, "كم ربحي؟", [], "ar", "SAR",
                           device=fs.device_dataset(ITEMS, "SAR", "inventory", None))
    assert time.monotonic() - started < 2
    assert seen["text"] == "كم ربحي؟"
    assert result["answer"]


@pytest.mark.asyncio
async def test_analyze_route_accepts_the_phone_summary(monkeypatch):
    from uuid import uuid4

    from app.api.v1 import business
    from app.domain.models.business_models import FalconAnalyzeRequest

    async def no_ai(*a, **k):
        return None

    monkeypatch.setattr(fs, "_call_ai", no_ai)
    rows, _ = fs.device_dataset(_branches(), "SAR", "inventory", None)
    body = FalconAnalyzeRequest(scope="inventory", report_currency="SAR", device_summary=rows)
    result = await business.falcon_analyze(
        data=body, org_id=str(uuid4()), db=None,
        branch_context=SimpleNamespace(all_mode=True, branch_ids=[], branch_id=None), _=True)
    import json
    stats = json.loads(result.body)["data"]["stats"]
    assert stats["total_sales"] == rows["total_sales"]
    assert [b["branch_name"] for b in stats["branch_summaries"]] == ["فرع الرياض", "فرع جدة"]
