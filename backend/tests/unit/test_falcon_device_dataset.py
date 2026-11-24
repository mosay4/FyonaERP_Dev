"""The Falcon analyses a device-ledger branch from the figures the phone
sends (the server holds no stock data for it)."""
import pytest

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


def test_inventory_figures_from_the_phone():
    data, title = fs.device_dataset(ITEMS, "SAR", "inventory", None)
    assert title == "المخزون"
    assert data["total_sales"] == 5900 and data["total_profit"] == 1030
    assert data["inventory_value"] == 3 * 40 + 40 * 19
    assert data["low_stock"] == ["أرز بسمتي"]
    assert data["out_of_stock"] == ["سكر"]
    assert [i["name"] for i in data["slow_moving"]] == ["زيت ذرة"]
    assert [i["name"] for i in data["weak_margin"]] == ["سكر"]  # 3.3% margin
    assert data["top_sellers"][0]["name"] == "أرز بسمتي"


def test_product_figures_and_reorder_suggestion():
    data, title = fs.device_dataset(ITEMS, "SAR", "product", "p1")
    assert title == "المنتج" and data["name"] == "أرز بسمتي"
    assert data["stock"] == 3 and data["sales_quantity"] == 100
    assert data["suggested_order_qty"] == max(0, round(max(20, 100 / 6) - 3))


def test_bad_rows_are_ignored_and_numbers_sanitised():
    data, _ = fs.device_dataset([None, "x", {"name": "y", "stock": "abc"}], "usd", "inventory", None)
    assert data["report_currency"] == "USD" and data["products_count"] == 0


@pytest.mark.asyncio
async def test_analyze_uses_the_phone_figures(monkeypatch):
    async def no_ai(*a, **k):
        return None
    monkeypatch.setattr(fs, "_call_ai", no_ai)
    report = await fs.analyze(None, None, "inventory", None, "ar", "SAR",
                              device=fs.device_dataset(ITEMS, "SAR", "inventory", None))
    assert report["stats"]["total_sales"] == 5900
    assert report["status_line"]
    assert report["recommendations"]


def test_one_order_quantity_and_an_honest_status():
    data, _ = fs.device_dataset(ITEMS, "SAR", "inventory", None)
    rice = next(r for r in data["reorder"] if r["name"] == "أرز بسمتي")
    assert rice["order_qty"] == 17 and rice["order_cost"] == 17 * 40
    # Out-of-stock sugar is ordered too (it sells); idle oil is never ordered.
    assert {r["name"] for r in data["reorder"]} == {"أرز بسمتي", "سكر"}
    assert data["stagnant_value_share"] == round(760 / (3 * 40 + 40 * 19), 4)
    # Something that sells is out, and 86% of the stock value is idle.
    assert fs._verdict(fs._flags_from(data, "inventory"), "inventory") == "watch"
