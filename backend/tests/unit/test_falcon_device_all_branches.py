"""«جميع الفروع» on the phone: Falcon receives every branch's rows."""
from app.domain.services.falcon_service import device_dataset


def _row(branch, name, stock, sales, qty, cost=2.0):
    return {"id": f"{branch}-{name}", "name": name, "stock": stock, "min_stock": 1,
            "sell_price": 5, "cost_price": cost, "sales": sales, "qty_sold": qty,
            "cogs": 0, "profit": sales / 2, "purchases": 0, "qty_purchased": 0,
            "branch_id": branch, "branch_name": {"a": "الرياض", "b": "جدة"}[branch]}


def test_inventory_names_each_branch_and_merges_same_product():
    data, title = device_dataset([
        _row("a", "سكر", 10, 100, 4), _row("b", "سكر ", 6, 50, 2), _row("b", "أرز", 0, 0, 0),
    ], "SAR", "inventory", None)
    assert title == "المخزون"
    names = [row["branch_name"] for row in data["branch_summaries"]]
    assert names == ["الرياض", "جدة"]
    riyadh, jeddah = data["branch_summaries"]
    assert riyadh["total_sales"] == 100 and jeddah["total_sales"] == 50
    assert "أرز" in jeddah["out_of_stock"]
    # One sugar for the business: 16 in stock, 150 sold.
    sugar = next(i for i in data["top_sellers"] if i["name"].strip() == "سكر")
    assert sugar["stock"] == 16 and sugar["sales"] == 150
    assert data["total_sales"] == 150


def test_product_over_branches_sums_and_keeps_branch_evidence():
    data, _ = device_dataset([_row("a", "سكر", 10, 100, 4), _row("b", "سكر", 6, 50, 2)],
                             "SAR", "product", "b-سكر")
    assert data["stock"] == 16 and data["sales_total"] == 150
    assert [r["branch_name"] for r in data["branch_summaries"]] == ["الرياض", "جدة"]


def test_single_branch_rows_are_unchanged():
    rows = [{k: v for k, v in _row("a", "سكر", 10, 100, 4).items() if not k.startswith("branch")}]
    data, _ = device_dataset(rows, "SAR", "inventory", None)
    assert "branch_summaries" not in data
