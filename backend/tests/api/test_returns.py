"""Business returns cycle tests (real per-test SQLite + ASGI app).

Covers the merchant flow through HTTP:
- customer (sale) return: partial (debt reduction), full (cash refund),
  the «لا تُرجع للمخزون» flag, over-return rejection, and the returns list.
- supplier (purchase) return: partial (payable reduction), full (cash
  refund into the account), stock OUT, over-return rejection.
- every return stays linked to the original invoice.
"""
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import uuid4

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine, select, func
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

from app.main import app
from app.core.config import settings
from app.core.database import Base, get_db
from app.core.security import create_access_token
from app.domain.entities import auth_entities  # noqa: F401
from app.domain.entities import business_entities  # noqa: F401
from app.domain.entities import invoice_entities  # noqa: F401
from app.domain.entities import finance_entities  # noqa: F401
from app.domain.entities import sale_entities  # noqa: F401
from app.domain.entities import purchase_entities  # noqa: F401
from app.domain.entities import payment_entities  # noqa: F401
from app.domain.entities import admin_entities  # noqa: F401
from app.domain.entities.auth_entities import (
    Organization,
    User,
    UserSession,
    Role,
)
from app.domain.entities.business_entities import Customer, Product, Supplier
from app.domain.entities.finance_entities import BankAccount
from app.domain.entities.invoice_entities import Invoice

pytestmark = pytest.mark.asyncio

API = settings.API_PREFIX


@pytest.fixture()
def _sync_engine(tmp_path):
    eng = create_engine(
        f"sqlite:///{tmp_path}/returns.db",
        connect_args={"check_same_thread": False},
    )
    Base.metadata.create_all(eng)
    return eng


@pytest.fixture()
def _async_engine(_sync_engine):
    return create_async_engine(f"sqlite+aiosqlite:///{_sync_engine.url.database}")


@pytest.fixture()
def _session_factory(_async_engine):
    return async_sessionmaker(_async_engine, expire_on_commit=False)


@pytest.fixture()
async def db(_session_factory):
    async with _session_factory() as session:
        yield session


@pytest.fixture()
async def client(_session_factory):
    async with _session_factory() as req_session:
        async def _override():
            try:
                yield req_session
                await req_session.commit()
            except Exception:
                await req_session.rollback()
                raise

        app.dependency_overrides[get_db] = _override
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://localhost") as ac:
            yield ac
        app.dependency_overrides.clear()


def _hdr(user):
    tok = create_access_token(str(user.id), str(user.organization_id), user.role)
    return {"Authorization": f"Bearer {tok}"}


@pytest.fixture()
async def org(db):
    o = Organization(
        id=uuid4(),
        name="Returns Org",
        slug=f"ret-{uuid4().hex[:8]}",
        subscription_status="trial",
        trial_end_date=datetime.now(timezone.utc) + timedelta(days=1),
    )
    db.add(o)
    await db.commit()
    return o


@pytest.fixture()
async def owner_role(db, org):
    r = Role(id=uuid4(), organization_id=org.id, name="owner", is_system=True)
    db.add(r)
    await db.commit()
    return r


@pytest.fixture()
async def owner(db, org, owner_role):
    u = User(
        id=uuid4(),
        organization_id=org.id,
        full_name="Owner",
        email=f"owner-{uuid4().hex[:8]}@t.com",
        password_hash="x",
        role="owner",
    )
    db.add(u)
    await db.flush()
    db.add(
        UserSession(
            user_id=u.id,
            refresh_token="rt",
            is_active=True,
            expires_at=datetime.now(timezone.utc) + timedelta(days=30),
        )
    )
    await db.commit()
    return u


@pytest.fixture()
async def cash_acct(db, org):
    a = BankAccount(
        organization_id=org.id,
        bank_name="كاش",
        account_name="Cash",
        account_number="CASH",
        currency="SAR",
        balance=Decimal("0"),
    )
    db.add(a)
    await db.commit()
    return a


@pytest.fixture()
async def bank_acct(db, org):
    a = BankAccount(
        organization_id=org.id,
        bank_name="Test Bank",
        account_name="Main",
        account_number="123",
        currency="SAR",
        balance=Decimal("1000"),
    )
    db.add(a)
    await db.commit()
    return a


@pytest.fixture()
async def usd_acct(db, org):
    a = BankAccount(
        organization_id=org.id,
        bank_name="USD Bank",
        account_name="USD",
        account_number="999",
        currency="USD",
        balance=Decimal("500"),
    )
    db.add(a)
    await db.commit()
    return a


@pytest.fixture()
async def customer(db, org):
    c = Customer(
        id=uuid4(), organization_id=org.id, name="Test Customer", phone="0500000001"
    )
    db.add(c)
    await db.commit()
    return c


@pytest.fixture()
async def supplier(db, org):
    s = Supplier(
        id=uuid4(), organization_id=org.id, name="Test Supplier", phone="0500000002"
    )
    db.add(s)
    await db.commit()
    return s


@pytest.fixture()
async def product(db, org):
    p = Product(
        id=uuid4(),
        organization_id=org.id,
        name="Widget",
        unit="قطعة",
        price=Decimal("10"),
        stock=100.0,
    )
    db.add(p)
    await db.commit()
    return p


def _line(product_id, qty=1, price=10, **kw):
    d = {"quantity": qty, "unit_price": price, "description": "x", **kw}
    if product_id:
        d["product_id"] = str(product_id)
    return d


def _pay(acct, amount, method="cash"):
    return {
        "bank_account_id": str(acct.id),
        "amount": amount,
        "payment_method": method,
    }


async def _stock(db, pid):
    return (
        await db.execute(select(Product.stock).where(Product.id == pid))
    ).scalar_one()


async def _balance(db, aid):
    return (
        await db.execute(select(BankAccount.balance).where(BankAccount.id == aid))
    ).scalar_one()


async def _issue_sale(client, owner, items, payments=(), customer_id=None):
    body = {"currency": "SAR", "items": items, "payments": list(payments),
            "idempotency_key": f"k-{uuid4().hex}"}
    if customer_id:
        body["customer_id"] = str(customer_id)
    r = await client.post(
        f"{API}/invoices/issue-sale", json=body, headers=_hdr(owner)
    )
    assert r.status_code == 201, r.text
    return r.json()["data"]


async def _issue_purchase(client, owner, items, payments=(), supplier_id=None):
    body = {"currency": "SAR", "items": items, "payments": list(payments),
            "idempotency_key": f"k-{uuid4().hex}"}
    if supplier_id:
        body["supplier_id"] = str(supplier_id)
    r = await client.post(
        f"{API}/invoices/issue-purchase", json=body, headers=_hdr(owner)
    )
    assert r.status_code == 201, r.text
    return r.json()["data"]


# ── Sale (customer) returns ───────────────────────────────────────────


async def test_sale_partial_return_reduces_debt(
    client, owner, product, customer, bank_acct, db
):
    inv = await _issue_sale(
        client, owner, [_line(product.id, qty=10, price=10)],
        [_pay(bank_acct, 60, "bank")], customer_id=customer.id,
    )
    assert inv["balance"] == 40
    item_id = inv["items"][0]["id"]
    r = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={"lines": [{"invoice_item_id": item_id, "quantity": 4}], "reason": "تالف"},
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    d = r.json()["data"]
    assert d["return"]["total"] == 40
    assert d["return"]["kind"] == "sale_return"
    assert d["balance"] == 0
    assert d["receivable"]["amount"] == 0
    assert await _stock(db, product.id) == 100.0 - 10.0 + 4.0


async def test_sale_return_no_restock_keeps_stock(
    client, owner, product, customer, cash_acct, db
):
    inv = await _issue_sale(
        client, owner, [_line(product.id, qty=5, price=10)],
        [_pay(cash_acct, 50)], customer_id=customer.id,
    )
    stock_before = await _stock(db, product.id)
    r = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={
            "lines": [
                {"invoice_item_id": inv["items"][0]["id"], "quantity": 5,
                 "restock": False}
            ],
            "refund_account_id": str(cash_acct.id),
        },
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    # damaged product is NOT put back into stock
    assert await _stock(db, product.id) == stock_before
    # …but an informational «مرجوع إلى خارج المخزون» movement IS recorded
    from app.domain.entities.business_entities import InventoryMovement

    row = (
        await db.execute(
            select(InventoryMovement).where(
                InventoryMovement.product_id == product.id,
                InventoryMovement.movement_type == "sale_return_no_stock",
            )
        )
    ).scalars().first()
    assert row is not None


async def test_sale_over_return_and_full_refund(
    client, owner, product, cash_acct, db
):
    inv = await _issue_sale(
        client, owner, [_line(product.id, qty=2, price=50)], [_pay(cash_acct, 100)]
    )
    item_id = inv["items"][0]["id"]
    over = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={"lines": [{"invoice_item_id": item_id, "quantity": 3}]},
        headers=_hdr(owner),
    )
    assert over.status_code == 400
    r = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={"lines": [{"invoice_item_id": item_id, "quantity": 2}],
              "refund_account_id": str(cash_acct.id)},
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    assert float(await _balance(db, cash_acct.id)) == 0.0
    assert await _stock(db, product.id) == 100.0


# ── Purchase (supplier) returns ───────────────────────────────────────


async def test_purchase_partial_return_reduces_payable(
    client, owner, product, supplier, bank_acct, db
):
    inv = await _issue_purchase(
        client, owner, [_line(product.id, qty=10, price=10)],
        [_pay(bank_acct, 60, "bank")], supplier_id=supplier.id,
    )
    assert inv["balance"] == 40
    stock_after_purchase = await _stock(db, product.id)
    assert stock_after_purchase == 110.0
    item_id = inv["items"][0]["id"]
    r = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={"lines": [{"invoice_item_id": item_id, "quantity": 4}]},
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    d = r.json()["data"]
    assert d["return"]["kind"] == "purchase_return"
    assert d["return"]["total"] == 40
    assert d["balance"] == 0
    # stock goes OUT by 4
    assert await _stock(db, product.id) == 110.0 - 4.0
    # supplier payable cleared
    assert d["payable"]["amount"] == 0


async def test_purchase_full_return_cash_refund(
    client, owner, product, bank_acct, db
):
    inv = await _issue_purchase(
        client, owner, [_line(product.id, qty=2, price=50)], [_pay(bank_acct, 100)]
    )
    assert inv["status"] == "paid"
    bal_after_purchase = float(await _balance(db, bank_acct.id))
    r = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={"lines": [{"invoice_item_id": inv["items"][0]["id"], "quantity": 2}],
              "refund_account_id": str(bank_acct.id)},
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    # money comes back INTO the account
    assert float(await _balance(db, bank_acct.id)) == bal_after_purchase + 100.0
    assert await _stock(db, product.id) == 100.0


async def test_purchase_over_return_rejected(
    client, owner, product, supplier, cash_acct, db
):
    inv = await _issue_purchase(
        client, owner, [_line(product.id, qty=5, price=10)],
        [_pay(cash_acct, 10)], supplier_id=supplier.id,
    )
    r = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={"lines": [{"invoice_item_id": inv["items"][0]["id"], "quantity": 6}]},
        headers=_hdr(owner),
    )
    assert r.status_code == 400


# ── Unified list + detail + linkage ───────────────────────────────────


async def test_returns_list_and_detail(
    client, owner, product, customer, supplier, cash_acct, db
):
    sale = await _issue_sale(
        client, owner, [_line(product.id, qty=4, price=10)], [_pay(cash_acct, 40)],
        customer_id=customer.id,
    )
    sr = await client.post(
        f"{API}/invoices/{sale['id']}/returns",
        json={"lines": [{"invoice_item_id": sale["items"][0]["id"], "quantity": 1}],
              "refund_account_id": str(cash_acct.id)},
        headers=_hdr(owner),
    )
    assert sr.status_code == 201, sr.text
    purchase = await _issue_purchase(
        client, owner, [_line(product.id, qty=3, price=10)], [_pay(cash_acct, 30)],
        supplier_id=supplier.id,
    )
    pr = await client.post(
        f"{API}/invoices/{purchase['id']}/returns",
        json={"lines": [{"invoice_item_id": purchase["items"][0]["id"], "quantity": 2}],
              "refund_account_id": str(cash_acct.id)},
        headers=_hdr(owner),
    )
    assert pr.status_code == 201, pr.text

    lst = await client.get(f"{API}/returns", headers=_hdr(owner))
    assert lst.status_code == 200, lst.text
    body = lst.json()["data"]
    items = body["items"] if isinstance(body, dict) else body
    kinds = {i["kind"] for i in items}
    assert kinds == {"sale_return", "purchase_return"}
    assert all(i["invoice_id"] for i in items)  # always linked to the invoice

    # invoice-scoped list (used by the app to cap returnable qty)
    one = await client.get(
        f"{API}/returns?invoice_id={sale['id']}", headers=_hdr(owner)
    )
    assert one.status_code == 200, one.text
    one_body = one.json()["data"]
    one_items = one_body["items"] if isinstance(one_body, dict) else one_body
    assert len(one_items) == 1
    assert one_items[0]["items"][0]["invoice_item_id"] == sale["items"][0]["id"]

    det = await client.get(
        f"{API}/returns/sale_return/{sr.json()['data']['return']['id']}",
        headers=_hdr(owner),
    )
    assert det.status_code == 200, det.text
    assert det.json()["data"]["return_number"].startswith("RTN")

    det2 = await client.get(
        f"{API}/returns/purchase_return/{pr.json()['data']['return']['id']}",
        headers=_hdr(owner),
    )
    assert det2.status_code == 200, det2.text
    assert det2.json()["data"]["return_number"].startswith("PRT")


async def test_purchase_return_reduces_stock_before_after(
    client, owner, product, supplier, cash_acct, db
):
    before = await _stock(db, product.id)
    inv = await _issue_purchase(
        client, owner, [_line(product.id, qty=3, price=10)], [_pay(cash_acct, 30)],
        supplier_id=supplier.id,
    )
    assert await _stock(db, product.id) == before + 3
    r = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={"lines": [{"invoice_item_id": inv["items"][0]["id"], "quantity": 3,
                         "restock": False}],
              "refund_account_id": str(cash_acct.id)},
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    # restock=false → stock left untouched
    assert await _stock(db, product.id) == before + 3


async def test_invoice_search_by_party_and_barcode(
    client, owner, product, customer, supplier, cash_acct, db
):
    product.barcode = "BC-RET-123"
    await db.commit()
    sale = await _issue_sale(
        client, owner, [_line(product.id, qty=2, price=10)], [_pay(cash_acct, 20)],
        customer_id=customer.id,
    )
    purchase = await _issue_purchase(
        client, owner, [_line(product.id, qty=1, price=10)], [_pay(cash_acct, 10)],
        supplier_id=supplier.id,
    )

    # text search by party name (previously only invoice_number was searched)
    cust = await client.get(
        f"{API}/invoices?invoice_type=sale&search={customer.name}",
        headers=_hdr(owner),
    )
    assert cust.status_code == 200, cust.text
    assert any(i["id"] == sale["id"] for i in cust.json()["data"]["items"])

    sup = await client.get(
        f"{API}/invoices?invoice_type=purchase&search={supplier.name}",
        headers=_hdr(owner),
    )
    assert sup.status_code == 200, sup.text
    assert any(i["id"] == purchase["id"] for i in sup.json()["data"]["items"])

    # barcode search ignores the invoice_type filter → returns BOTH invoices
    bc = await client.get(
        f"{API}/invoices?invoice_type=sale&search=BC-RET-123",
        headers=_hdr(owner),
    )
    assert bc.status_code == 200, bc.text
    ids = {i["id"] for i in bc.json()["data"]["items"]}
    assert sale["id"] in ids
    assert purchase["id"] in ids



# ── Cross-currency + insufficient-balance refunds ─────────────────────


async def test_sale_return_cross_currency_refund(
    client, owner, product, cash_acct, usd_acct, db
):
    # Fully-paid SAR sale (100) → the whole return is a cash refund.
    inv = await _issue_sale(
        client, owner, [_line(product.id, qty=2, price=50)], [_pay(cash_acct, 100)]
    )
    usd_before = float(await _balance(db, usd_acct.id))
    r = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={
            "lines": [{"invoice_item_id": inv["items"][0]["id"], "quantity": 2}],
            "refund_account_id": str(usd_acct.id),
            "refund_currency": "USD",
            "refund_amount": 25,          # 100 SAR ≈ 25 USD (1 USD = 4 SAR)
            "refund_exchange_rate": 4,
        },
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    # the USD account moves in USD, base value stays in SAR on the invoice
    assert float(await _balance(db, usd_acct.id)) == usd_before - 25.0
    assert r.json()["data"]["balance"] == 0


async def test_sale_return_insufficient_balance_needs_allow(
    client, owner, product, bank_acct, cash_acct, db
):
    # Paid via bank so the cash account stays at 0 → refund is insufficient.
    inv = await _issue_sale(
        client, owner, [_line(product.id, qty=4, price=10)],
        [_pay(bank_acct, 40, "bank")],
    )
    body = {
        "lines": [{"invoice_item_id": inv["items"][0]["id"], "quantity": 4}],
        "refund_account_id": str(cash_acct.id),
    }
    r = await client.post(
        f"{API}/invoices/{inv['id']}/returns", json=body, headers=_hdr(owner)
    )
    assert r.status_code == 400
    # the settlement-style allowance lets the account go negative
    body["allow_negative"] = True
    r2 = await client.post(
        f"{API}/invoices/{inv['id']}/returns", json=body, headers=_hdr(owner)
    )
    assert r2.status_code == 201, r2.text
    assert float(await _balance(db, cash_acct.id)) == -40.0


async def test_purchase_return_cross_currency_deposit(
    client, owner, product, bank_acct, usd_acct, db
):
    inv = await _issue_purchase(
        client, owner, [_line(product.id, qty=2, price=50)], [_pay(bank_acct, 100)]
    )
    usd_before = float(await _balance(db, usd_acct.id))
    r = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={
            "lines": [{"invoice_item_id": inv["items"][0]["id"], "quantity": 2}],
            "refund_account_id": str(usd_acct.id),
            "refund_currency": "USD",
            "refund_amount": 25,
            "refund_exchange_rate": 4,
        },
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    # money comes back INTO the USD account in USD
    assert float(await _balance(db, usd_acct.id)) == usd_before + 25.0


# ── 7. Frozen per-line FX snapshot feeds statistics ────────────────────────


async def test_purchase_snapshot_stored_and_used_in_stats(
    client, owner, org, supplier, product, db
):
    """A purchase line keeps its original price/currency/rate, and product
    statistics convert the ACTUAL amount with the SAVED rate (never live)."""
    body = {
        "currency": "YER_OLD",
        "supplier_id": str(supplier.id),
        "items": [
            {
                "product_id": str(product.id),
                "quantity": 1,
                "unit_price": 6800,  # 50 USD × 136 (the adjusted invoice price)
                "description": "Widget",
                "original_price": 50,
                "price_currency": "USD",
                "exchange_rate": 136,
            }
        ],
        "payments": [],
        "idempotency_key": f"k-{uuid4().hex}",
    }
    r = await client.post(
        f"{API}/invoices/issue-purchase", json=body, headers=_hdr(owner)
    )
    assert r.status_code == 201, r.text

    from app.domain.entities.invoice_entities import InvoiceItem
    from app.domain.services import inventory_stats

    item = (
        await db.execute(
            select(InvoiceItem).where(InvoiceItem.product_id == product.id)
        )
    ).scalars().first()
    assert item is not None
    assert float(item.original_unit_price) == 50.0
    assert item.price_currency == "USD"
    assert float(item.exchange_rate_used) == 136.0

    stats = await inventory_stats.product_stats(
        db, org.id, product.id, display_currency="USD"
    )
    assert stats["display_currency"] == "USD"
    # 6800 YER_OLD ÷ 136 (SAVED) = 50 USD exactly.
    assert abs(stats["purchases_total"] - 50.0) < 0.01


async def test_sale_snapshot_used_in_stats(
    client, owner, org, customer, product, db
):
    """A sale line snapshot converts revenue back to the product's currency
    with the saved rate, independent of any live rate."""
    body = {
        "currency": "YER_OLD",
        "customer_id": str(customer.id),
        "items": [
            {
                "product_id": str(product.id),
                "quantity": 2,
                "unit_price": 7000,  # merchant edited 6800 → 7000
                "description": "Widget",
                "original_price": 50,
                "price_currency": "USD",
                "exchange_rate": 136,
            }
        ],
        "payments": [],
        "idempotency_key": f"k-{uuid4().hex}",
    }
    r = await client.post(
        f"{API}/invoices/issue-sale", json=body, headers=_hdr(owner)
    )
    assert r.status_code == 201, r.text

    from app.domain.services import inventory_stats

    stats = await inventory_stats.product_stats(
        db, org.id, product.id, display_currency="USD"
    )
    # 2 × 7000 = 14000 YER_OLD ÷ 136 = 102.94 USD (saved rate).
    assert abs(stats["sales_total"] - (14000.0 / 136.0)) < 0.05


async def test_stats_flags_fx_incomplete_when_no_rate(
    client, owner, org, customer, product, db, monkeypatch
):
    """No direct/saved rate for a cross-currency line: statistics must NOT
    silently assume 1:1 — the amount is excluded and flagged."""
    body = {
        "currency": "USD",
        "customer_id": str(customer.id),
        "items": [
            {
                "product_id": str(product.id),
                "quantity": 1,
                "unit_price": 100,
                "description": "Widget",
            }
        ],
        "payments": [],
        "idempotency_key": f"k-{uuid4().hex}",
    }
    r = await client.post(
        f"{API}/invoices/issue-sale", json=body, headers=_hdr(owner)
    )
    assert r.status_code == 201, r.text

    from app.domain.services import fx_snapshot, inventory_stats

    async def _no_rate(from_ccy, to_ccy):
        return None

    monkeypatch.setattr(fx_snapshot, "live_rate", _no_rate)

    stats = await inventory_stats.product_stats(
        db, org.id, product.id, display_currency="YER_NEW"
    )
    assert stats["fx_incomplete"] is True
    # The 100 USD was NOT carried over as 100 YER_NEW (silent 1:1).
    assert stats["sales_total"] == 0.0


async def test_fully_returned_invoice_hidden_from_return_picker(
    client, owner, customer, product
):
    """A fully-returned invoice disappears from the return picker; a partially
    returned one stays."""
    inv = await _issue_sale(
        client, owner, [_line(product.id, qty=2, price=10)],
        customer_id=customer.id,
    )
    item_id = inv["items"][0]["id"]

    # Partial return (1 of 2) -> still returnable.
    r = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={"lines": [{"invoice_item_id": item_id, "quantity": 1}]},
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    r2 = await client.get(
        f"{API}/invoices",
        params={"invoice_type": "sale", "returnable_only": True},
        headers=_hdr(owner),
    )
    assert inv["id"] in [i["id"] for i in r2.json()["data"]["items"]]

    # Full return of the remainder -> hidden.
    r3 = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={"lines": [{"invoice_item_id": item_id, "quantity": 1}]},
        headers=_hdr(owner),
    )
    assert r3.status_code == 201, r3.text
    r4 = await client.get(
        f"{API}/invoices",
        params={"invoice_type": "sale", "returnable_only": True},
        headers=_hdr(owner),
    )
    assert inv["id"] not in [i["id"] for i in r4.json()["data"]["items"]]

    # Without the filter it is still listed (records preserved).
    r5 = await client.get(
        f"{API}/invoices",
        params={"invoice_type": "sale"},
        headers=_hdr(owner),
    )
    assert inv["id"] in [i["id"] for i in r5.json()["data"]["items"]]
