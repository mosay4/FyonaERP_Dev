"""Smart import: Sara only suggests a column mapping; the server keeps only
known fields mapped to columns that really exist, caps what is sent, and
says so plainly when the AI is not available."""

import json
from uuid import uuid4

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api import deps
from app.api.v1 import import_mapping as im


def _client():
    app = FastAPI()
    app.include_router(im.router, prefix="/api/v1")
    app.dependency_overrides[deps.get_current_user_uuid] = lambda: uuid4()
    return TestClient(app)


def test_only_real_columns_and_known_fields_survive():
    cols = ["الاسم", "الجوال", "الرصيد"]
    got = im.validate("parties", {"mapping": {"name": "الاسم", "phone": "الجوال", "balance": "غير موجود",
                                              "hack": "الرصيد", "currency": "الاسم"}}, cols)
    assert got == {"name": "الاسم", "phone": "الجوال"}
    assert im.validate("products", "not a dict", cols) == {}


def test_what_is_sent_is_capped(monkeypatch):
    seen = {}

    async def fake_ask(target, cols, rows):
        seen.update(target=target, cols=cols, rows=rows)
        return json.dumps({"mapping": {"name": cols[0], "stock": cols[1]}})

    monkeypatch.setattr(im, "_ask", fake_ask)
    sample = [["x" * 500, "5"]] * 30
    r = _client().post("/api/v1/ai/import-mapping", json={"target": "products", "columns": ["n", "q"], "sample": sample})
    assert r.status_code == 200, r.text
    assert r.json()["data"]["mapping"] == {"name": "n", "stock": "q"}
    assert all(len(v) <= 60 for row in seen["rows"] for v in row)
    too_many = _client().post("/api/v1/ai/import-mapping", json={"target": "products", "columns": ["n"], "sample": [["a"]] * 31})
    assert too_many.status_code == 422


def test_ai_unavailable_is_a_clear_503(monkeypatch):
    async def boom(*a):
        raise RuntimeError("provider said: secret customer name")

    monkeypatch.setattr(im, "_ask", boom)
    r = _client().post("/api/v1/ai/import-mapping", json={"target": "parties", "columns": ["a"], "sample": []})
    assert r.status_code == 503
    assert "secret" not in r.text


def test_schema_answers_are_checked_against_the_real_tables():
    tables = [im.TableIn(name="tbl_items", columns=["ItemName", "Qty", "Price"]),
              im.TableIn(name="tbl_staff", columns=["Name", "Salary"])]
    raw = {"tables": [
        {"name": "tbl_items", "role": "products", "mapping": {"name": "ItemName", "stock": "Qty", "sale_price": "Nope"}},
        {"name": "tbl_staff", "role": "unsupported", "mapping": {}},
        {"name": "ghost", "role": "products", "mapping": {}},
        {"name": "tbl_items", "role": "made-up", "mapping": {}},
    ]}
    got = im.validate_schema(raw, tables)
    assert got == [
        {"name": "tbl_items", "role": "products", "mapping": {"name": "ItemName", "stock": "Qty"}, "link": None},
        {"name": "tbl_staff", "role": "unsupported", "mapping": {}, "link": None},
    ]


def test_customer_tables_use_the_party_fields():
    tables = [im.TableIn(name="T_CL", columns=["ClNo", "ClName", "Tel", "Due"])]
    got = im.validate_schema({"tables": [{"name": "T_CL", "role": "customers",
                                          "mapping": {"name": "ClName", "phone": "Tel", "balance": "Due"}}]}, tables)
    assert got[0]["mapping"] == {"name": "ClName", "phone": "Tel", "balance": "Due"}


def test_new_roles_keep_their_own_fields():
    tables = [im.TableIn(name="customer_receivables", columns=["customer_id", "amount_due", "paid", "cur"]),
              im.TableIn(name="product_prices", columns=["product_id", "price_type", "price", "currency"])]
    got = im.validate_schema({"tables": [
        {"name": "customer_receivables", "role": "balances", "mapping": {"amount": "amount_due", "paid": "paid"},
         "link": "customer_id"},
        {"name": "product_prices", "role": "prices", "mapping": {"price": "price", "kind": "price_type", "bogus": "x"},
         "link": "product_id"},
    ]}, tables)
    assert got[0] == {"name": "customer_receivables", "role": "balances",
                      "mapping": {"amount": "amount_due", "paid": "paid"}, "link": "customer_id"}
    assert got[1]["mapping"] == {"price": "price", "kind": "price_type"}


def test_agent_ops_are_checked_against_the_file():
    tables = [im.AgentTableIn(name="products", role="products", columns=["name", "price"]),
              im.AgentTableIn(name="tbl_x", role="unknown", columns=["a", "b"])]
    raw = {"reply": "تم", "ops": [
        {"op": "set_role", "table": "tbl_x", "role": "customers"},
        {"op": "set_role", "table": "ghost", "role": "customers"},
        {"op": "set_role", "table": "tbl_x", "role": "made-up"},
        {"op": "map", "table": "products", "field": "sale_price", "column": "price"},
        {"op": "map", "table": "products", "field": "sale_price", "column": "nope"},
        {"op": "set_currency", "currency": "usd"},
        {"op": "set_currency", "currency": "dollars"},
        {"op": "set_currency", "currency": "yer_new"},
        # Sara never writes prices, balances or quantities.
        {"op": "set_field", "target": "products", "field": "sale_price", "value": 10, "only_empty": True},
        {"op": "set_field", "target": "customers", "field": "balance", "value": 10},
        {"op": "set_field", "target": "products", "field": "currency", "value": "usd",
         "where": {"field": "name", "op": "contains", "value": "قلم"}},
        {"op": "set_field", "target": "products", "field": "currency", "value": "dollar"},
        {"op": "set_field", "target": "products", "field": "password", "value": "x"},
        {"op": "adjust", "field": "sale_price", "percent": 10},
        {"op": "adjust", "field": "sale_price", "percent": 99999},
        {"op": "reject", "target": "products", "where": {"field": "sale_price", "op": "empty"}},
        {"op": "reject", "target": "products", "where": {"field": "x", "op": "drop table"}},
        {"op": "delete_everything"},
    ]}
    assert im.validate_ops(raw, tables) == [
        {"op": "set_role", "table": "tbl_x", "role": "customers"},
        {"op": "map", "table": "products", "field": "sale_price", "column": "price"},
        {"op": "set_currency", "currency": "USD"},
        {"op": "set_currency", "currency": "YER_NEW"},
        {"op": "set_field", "target": "products", "field": "currency", "value": "USD", "only_empty": False,
         "where": {"field": "name", "op": "contains", "value": "قلم"}},
        {"op": "reject", "target": "products", "where": {"field": "sale_price", "op": "empty", "value": None}},
    ]


def test_agent_unavailable_is_a_clear_503(monkeypatch):
    from app.domain.services import ai_router

    class R:
        api_key = None
        model = "x"

    monkeypatch.setattr(ai_router, "route", lambda *a, **k: R())
    r = _client().post("/api/v1/ai/import-agent", json={"message": "زد الأسعار 10%", "tables": []})
    assert r.status_code == 503


def test_agent_accepts_fyona_currency_codes():
    """The phone sends FYONA's own codes (YER_NEW): that once failed with 422
    and showed «Sara unavailable»."""
    assert im.AgentIn(message="افحص الملف", currency="YER_NEW", tables=[]).currency == "YER_NEW"
    assert im.AgentIn(message="افحص الملف", tables=[]).currency is None
