"""Business sale-invoice cycle tests (real per-test SQLite + ASGI app).

Covers the merchant flow end to end through HTTP:
cash sale without a registered customer, existing + quick-add customers,
full / partial / credit payment, split accounts, multi-unit + barcode
resolution, stock effects + insufficient-stock atomicity, receiving accounts,
receivables + customer balance, currency strictness, branches, permissions,
idempotency, overpay/credit-without-customer guards, line snapshots,
sequential numbering, returns (restock + money), services/manual lines,
discount + tax math, unit management rules, org isolation, and zero
Personal-section coupling.
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
from app.domain.entities import payment_entities  # noqa: F401
from app.domain.entities import admin_entities  # noqa: F401
from app.domain.entities.auth_entities import (
    Organization,
    User,
    UserSession,
    Role,
    RolePermission,
)
from app.domain.entities.business_entities import Customer, Product
from app.domain.entities.finance_entities import BankAccount
from app.domain.entities.invoice_entities import Invoice

pytestmark = pytest.mark.asyncio

API = settings.API_PREFIX


# ── Per-test SQLite DB ─────────────────────────────────────────────────


@pytest.fixture()
def _sync_engine(tmp_path):
    eng = create_engine(
        f"sqlite:///{tmp_path}/sale.db", connect_args={"check_same_thread": False}
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
    # Dedicated request session: service commits/rollbacks here must never
    # expire the `db` fixture objects used for setup + assertions.
    # Mirrors production get_db (commit on success, rollback on error).
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


# ── Fixtures ───────────────────────────────────────────────────────────


def _hdr(user):
    tok = create_access_token(str(user.id), str(user.organization_id), user.role)
    return {"Authorization": f"Bearer {tok}"}


@pytest.fixture()
async def org(db):
    o = Organization(
        id=uuid4(),
        name="Sale Org",
        slug=f"sale-{uuid4().hex[:8]}",
        # Active trial unlocks the subscription-gated business router,
        # exactly like a real trialing merchant.
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


@pytest.fixture()
async def service_product(db, org):
    p = Product(
        id=uuid4(),
        organization_id=org.id,
        name="Delivery",
        price=Decimal("25"),
        is_service=True,
    )
    db.add(p)
    await db.commit()
    return p


def _issue(
    items,
    payments=(),
    customer_id=None,
    key=None,
    currency="SAR",
    **kw,
):
    body = {
        "currency": currency,
        "items": items,
        "payments": list(payments),
        **kw,
    }
    if customer_id:
        body["customer_id"] = str(customer_id)
    if key:
        body["idempotency_key"] = key
    return body


def _line(product_id=None, qty=1, price=10, **kw):
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


async def _invoice_count(db, org):
    return (
        await db.execute(
            select(func.count())
            .select_from(Invoice)
            .where(Invoice.organization_id == org.id)
        )
    ).scalar_one()


# ── 1. Cash sale, no registered customer ───────────────────────────────


async def test_cash_sale_without_customer(client, owner, product, cash_acct, org, db):
    r = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [_line(product.id, qty=3, price=10)],
            [_pay(cash_acct, 30)],
            key=f"k-{uuid4().hex}",
        ),
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    data = r.json()["data"]
    assert data["status"] == "paid"
    assert data["balance"] == 0
    assert data["customer_id"] is None
    assert data["receivable"] is None
    assert data["currency"] == "SAR"
    assert data["branch_id"] is not None  # default branch auto-created
    assert await _stock(db, product.id) == 100.0 - 3.0
    assert float(await _balance(db, cash_acct.id)) == 30.0


# ── 2/3. Existing + quick-add customer ─────────────────────────────────


async def test_sale_to_existing_customer_with_debt(
    client, owner, product, bank_acct, customer, org, db
):
    r = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [_line(product.id, qty=5, price=10)],
            [_pay(bank_acct, 20)],
            customer_id=customer.id,
            key=f"k-{uuid4().hex}",
        ),
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    data = r.json()["data"]
    assert data["status"] == "partially_paid"
    assert data["balance"] == 30
    assert data["receivable"]["amount"] == 30
    assert data["customer_id"] == str(customer.id)
    # customer balance snapshot
    b = await client.get(
        f"{API}/customers/{customer.id}/balance", headers=_hdr(owner)
    )
    assert b.status_code == 200, b.text
    assert b.json()["data"]["debts"] == [{"currency": "SAR", "debt": 30.0}]


async def test_quick_add_customer_then_use(
    client, owner, product, cash_acct, org, db
):
    c = await client.post(
        f"{API}/customers",
        json={"name": "Quick Buyer", "phone": "0551111111"},
        headers=_hdr(owner),
    )
    assert c.status_code == 201, c.text
    cid = c.json()["data"]["id"]
    r = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [_line(product.id, qty=1, price=10)],
            [],
            customer_id=cid,
            key=f"k-{uuid4().hex}",
        ),
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    data = r.json()["data"]
    assert data["status"] == "confirmed"  # full credit
    assert data["receivable"]["amount"] == 10


async def test_credit_without_customer_rejected(
    client, owner, product, cash_acct, org
):
    r = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [_line(product.id, qty=1, price=10)], [], key=f"k-{uuid4().hex}"
        ),
        headers=_hdr(owner),
    )
    assert r.status_code == 400
    assert "نقدي" in r.text


# ── 4. Split payment across accounts ───────────────────────────────────


async def test_split_payment_two_accounts(
    client, owner, product, cash_acct, bank_acct, org, db
):
    r = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [_line(product.id, qty=10, price=10)],
            [_pay(cash_acct, 40), _pay(bank_acct, 60, "bank")],
            key=f"k-{uuid4().hex}",
        ),
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    data = r.json()["data"]
    assert data["status"] == "paid"
    assert len(data["payments"]) == 2
    assert float(await _balance(db, cash_acct.id)) == 40.0
    assert float(await _balance(db, bank_acct.id)) == 1060.0


async def test_overpay_rejected(client, owner, product, cash_acct, org, db):
    before = await _invoice_count(db, org)
    r = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [_line(product.id, qty=1, price=10)],
            [_pay(cash_acct, 11)],
            key=f"k-{uuid4().hex}",
        ),
        headers=_hdr(owner),
    )
    assert r.status_code == 400
    assert await _invoice_count(db, org) == before  # atomic: nothing persisted


# ── 5. Units + barcodes ────────────────────────────────────────────────


async def _make_units(client, owner, product):
    base = await client.get(
        f"{API}/products/{product.id}/units", headers=_hdr(owner)
    )
    assert base.status_code == 200, base.text
    pack = await client.post(
        f"{API}/products/{product.id}/units",
        json={"name": "باكيت", "factor": 6, "barcode": "PACK-A", "sale_price": 55},
        headers=_hdr(owner),
    )
    assert pack.status_code == 201, pack.text
    carton = await client.post(
        f"{API}/products/{product.id}/units",
        json={"name": "كرتون", "factor": 24, "barcode": "CARTON-B", "sale_price": 200},
        headers=_hdr(owner),
    )
    assert carton.status_code == 201, carton.text
    return base.json()["data"], pack.json()["data"], carton.json()["data"]


async def test_barcode_resolution_and_unit_stock(
    client, owner, product, cash_acct, org, db
):
    _, pack, carton = await _make_units(client, owner, product)
    # resolve carton barcode → unit + factor + price
    r = await client.get(
        f"{API}/products/resolve-barcode", params={"code": "CARTON-B"}, headers=_hdr(owner)
    )
    assert r.status_code == 200, r.text
    res = r.json()["data"]
    assert res["unit"]["id"] == carton["id"]
    assert res["unit"]["factor"] == 24
    assert res["suggested_price"] == 200
    # sell 2 cartons → stock -48, paid in full
    s = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [
                {
                    "product_id": str(product.id),
                    "unit_id": carton["id"],
                    "description": "Widget",
                    "quantity": 2,
                    "unit_price": 200,
                    "discount": 0,
                }
            ],
            [_pay(cash_acct, 400)],
            key=f"k-{uuid4().hex}",
        ),
        headers=_hdr(owner),
    )
    assert s.status_code == 201, s.text
    item = s.json()["data"]["items"][0]
    assert item["base_quantity"] == 48
    assert item["unit_name"] == "كرتون"
    assert await _stock(db, product.id) == 100.0 - 48.0


async def test_insufficient_stock_atomic(
    client, owner, product, cash_acct, org, db
):
    before = await _invoice_count(db, org)
    r = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [_line(product.id, qty=500, price=10)],
            [_pay(cash_acct, 5000)],
            key=f"k-{uuid4().hex}",
        ),
        headers=_hdr(owner),
    )
    assert r.status_code == 400
    assert "المخزون" in r.text
    assert await _invoice_count(db, org) == before
    assert await _stock(db, product.id) == 100.0
    assert float(await _balance(db, cash_acct.id)) == 0.0


async def test_unit_rules(client, owner, product, org):
    await _make_units(client, owner, product)
    # duplicate unit name
    d = await client.post(
        f"{API}/products/{product.id}/units",
        json={"name": "باكيت", "factor": 6},
        headers=_hdr(owner),
    )
    assert d.status_code == 400
    # duplicate barcode
    b = await client.post(
        f"{API}/products/{product.id}/units",
        json={"name": "علبة", "factor": 2, "barcode": "PACK-A"},
        headers=_hdr(owner),
    )
    assert b.status_code == 400
    # base unit cannot be deleted
    units = (
        await client.get(f"{API}/products/{product.id}/units", headers=_hdr(owner))
    ).json()["data"]["units"]
    base = next(u for u in units if u["is_base"])
    dd = await client.delete(
        f"{API}/products/units/{base['id']}",
        headers=_hdr(owner),
    )
    assert dd.status_code == 400


# ── 6. Currency strictness ─────────────────────────────────────────────


async def test_currency_mixing_rejected(
    client, owner, product, cash_acct, usd_acct, org, db
):
    r = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [_line(product.id, qty=1, price=10)],
            [_pay(usd_acct, 10)],
            key=f"k-{uuid4().hex}",
            currency="SAR",
        ),
        headers=_hdr(owner),
    )
    assert r.status_code == 400
    # Correct behaviour: a foreign-currency payment is allowed ONLY with a
    # positive exchange-rate snapshot. The old assertion expected a vague
    # "mixing" message that the service never emitted.
    assert "سعر الصرف مطلوب" in r.text
    # with a valid frozen rate the differently-currency account is accepted
    r_rate = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [_line(product.id, qty=1, price=10)],
            [{**_pay(usd_acct, 4), "currency": "USD",
              "exchange_rate": 2.5}],
            key=f"k-{uuid4().hex}",
            currency="SAR",
        ),
        headers=_hdr(owner),
    )
    assert r_rate.status_code == 201, r_rate.text
    # matching currency invoice works
    r2 = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [_line(product.id, qty=1, price=10)],
            [_pay(usd_acct, 10)],
            key=f"k-{uuid4().hex}",
            currency="USD",
        ),
        headers=_hdr(owner),
    )
    assert r2.status_code == 201, r2.text
    assert r2.json()["data"]["currency"] == "USD"


# ── 7. Idempotency ─────────────────────────────────────────────────────


async def test_idempotent_reissue(client, owner, product, cash_acct, org, db):
    key = f"k-{uuid4().hex}"
    body = _issue([_line(product.id, qty=2, price=10)], [_pay(cash_acct, 20)], key=key)
    r1 = await client.post(f"{API}/invoices/issue-sale", json=body, headers=_hdr(owner))
    r2 = await client.post(f"{API}/invoices/issue-sale", json=body, headers=_hdr(owner))
    assert r1.status_code == 201 and r2.status_code == 201
    d1, d2 = r1.json()["data"], r2.json()["data"]
    assert d1["invoice_number"] == d2["invoice_number"]
    assert d2["already_issued"] is True
    assert await _invoice_count(db, org) == 1
    assert await _stock(db, product.id) == 100.0 - 2.0  # decremented once


# ── 8. Sequential numbering + snapshots ────────────────────────────────


async def test_numbering_and_price_snapshot(
    client, owner, product, cash_acct, org, db
):
    n1 = (
        await client.post(
            f"{API}/invoices/issue-sale",
            json=_issue([_line(product.id, qty=1, price=10)], [_pay(cash_acct, 10)], key=f"k-{uuid4().hex}"),
            headers=_hdr(owner),
        )
    ).json()["data"]["invoice_number"]
    n2 = (
        await client.post(
            f"{API}/invoices/issue-sale",
            json=_issue([_line(product.id, qty=1, price=10)], [_pay(cash_acct, 10)], key=f"k-{uuid4().hex}"),
            headers=_hdr(owner),
        )
    ).json()["data"]["invoice_number"]
    assert n1 != n2 and n1.startswith("INV-") and n2.startswith("INV-")
    # change product price → old invoice line unchanged
    await client.put(
        f"{API}/products/{product.id}", json={"price": 99}, headers=_hdr(owner)
    )
    inv_id = (
        await db.execute(
            select(Invoice.id).where(
                Invoice.organization_id == org.id, Invoice.invoice_number == n1
            )
        )
    ).scalar_one()
    g = await client.get(f"{API}/invoices/{inv_id}", headers=_hdr(owner))
    assert g.status_code == 200
    assert float(g.json()["data"]["items"][0]["unit_price"]) == 10.0


# ── 9. Services + manual lines skip stock ──────────────────────────────


async def test_service_and_manual_lines(
    client, owner, product, service_product, cash_acct, org, db
):
    r = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [
                _line(service_product.id, qty=1, price=25),
                {"description": "تركيب", "quantity": 1, "unit_price": 50, "discount": 0},
                _line(product.id, qty=2, price=10),
            ],
            [_pay(cash_acct, 95)],
            key=f"k-{uuid4().hex}",
        ),
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    assert r.json()["data"]["total"] == 95
    assert await _stock(db, product.id) == 100.0 - 2.0
    assert await _stock(db, service_product.id) == 0.0


# ── 10. Discount + tax math ────────────────────────────────────────────


async def test_totals_math(client, owner, product, cash_acct, customer, org):
    r = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [
                {"product_id": str(product.id), "description": "x", "quantity": 2, "unit_price": 100, "discount": 10},
                {"product_id": str(product.id), "description": "x", "quantity": 1, "unit_price": 50, "discount": 0},
            ],
            [_pay(cash_acct, 100)],
            customer_id=customer.id,
            key=f"k-{uuid4().hex}",
            discount_type="percentage",
            discount_value=10,
            tax_type="percentage",
            tax_rate=15,
        ),
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    d = r.json()["data"]
    # subtotal 240 → -10% = 216 → +15% = 248.4 ; paid 100 → balance 148.4
    assert d["subtotal"] == 240
    assert d["discount_amount"] == 24
    assert d["tax_amount"] == 32.4
    assert d["total"] == 248.4
    assert d["balance"] == 148.4
    assert d["status"] == "partially_paid"


# ── 11. Returns ────────────────────────────────────────────────────────


async def test_partial_return_restocks_and_adjusts(
    client, owner, product, customer, cash_acct, bank_acct, org, db
):
    s = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [_line(product.id, qty=10, price=10)],
            [_pay(bank_acct, 60, "bank")],
            customer_id=customer.id,
            key=f"k-{uuid4().hex}",
        ),
        headers=_hdr(owner),
    )
    inv = s.json()["data"]
    assert inv["balance"] == 40
    item_id = inv["items"][0]["id"]
    # return 4 units → 40 covers the 40 balance, no refund
    r = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={"lines": [{"invoice_item_id": item_id, "quantity": 4}], "reason": "تالف"},
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    d = r.json()["data"]
    assert d["return"]["total"] == 40
    assert d["balance"] == 0
    assert await _stock(db, product.id) == 100.0 - 10.0 + 4.0
    assert d["receivable"]["amount"] == 0
    # over-return rejected
    r2 = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={"lines": [{"invoice_item_id": item_id, "quantity": 7}]},
        headers=_hdr(owner),
    )
    assert r2.status_code == 400


async def test_full_return_with_cash_refund(
    client, owner, product, cash_acct, org, db
):
    s = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue(
            [_line(product.id, qty=2, price=50)], [_pay(cash_acct, 100)], key=f"k-{uuid4().hex}"
        ),
        headers=_hdr(owner),
    )
    inv = s.json()["data"]
    assert inv["status"] == "paid"
    r = await client.post(
        f"{API}/invoices/{inv['id']}/returns",
        json={
            "lines": [{"invoice_item_id": inv["items"][0]["id"], "quantity": 2}],
            "refund_account_id": str(cash_acct.id),
        },
        headers=_hdr(owner),
    )
    assert r.status_code == 201, r.text
    assert float(await _balance(db, cash_acct.id)) == 0.0  # 100 in, 100 refunded
    assert await _stock(db, product.id) == 100.0


# ── 12. Permissions ────────────────────────────────────────────────────


async def test_permission_enforced(client, db, org, product, cash_acct, owner_role):
    emp = User(
        id=uuid4(),
        organization_id=org.id,
        full_name="Emp",
        email=f"emp-{uuid4().hex[:8]}@t.com",
        password_hash="x",
        role="employee",
    )
    db.add(emp)
    await db.flush()
    db.add(
        UserSession(
            user_id=emp.id,
            refresh_token="rt2",
            is_active=True,
            expires_at=datetime.now(timezone.utc) + timedelta(days=30),
        )
    )
    db.add(Role(id=uuid4(), organization_id=org.id, name="employee", is_system=True))
    await db.commit()
    r = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue([_line(product.id, qty=1, price=5)], [_pay(cash_acct, 5)], key=f"k-{uuid4().hex}"),
        headers=_hdr(emp),
    )
    assert r.status_code == 403
    # grant invoices:create → allowed
    role = (
        await db.execute(
            select(Role).where(Role.organization_id == org.id, Role.name == "employee")
        )
    ).scalar_one()
    db.add(
        RolePermission(
            role_id=role.id, resource="invoices", can_create=True, can_read=True
        )
    )
    await db.commit()
    r2 = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue([_line(product.id, qty=1, price=5)], [_pay(cash_acct, 5)], key=f"k-{uuid4().hex}"),
        headers=_hdr(emp),
    )
    assert r2.status_code == 201, r2.text


# ── 13. Org isolation + Personal untouched ─────────────────────────────


async def test_org_isolation_and_no_personal_coupling(
    client, db, org, owner, product, cash_acct
):
    r = await client.post(
        f"{API}/invoices/issue-sale",
        json=_issue([_line(product.id, qty=1, price=7)], [_pay(cash_acct, 7)], key=f"k-{uuid4().hex}"),
        headers=_hdr(owner),
    )
    inv_id = r.json()["data"]["id"]
    # second org cannot see it
    org2 = Organization(id=uuid4(), name="O2", slug=f"o2-{uuid4().hex[:8]}")
    db.add(org2)
    await db.flush()
    u2 = User(
        id=uuid4(), organization_id=org2.id, full_name="U2",
        email=f"u2-{uuid4().hex[:8]}@t.com", password_hash="x", role="owner",
    )
    db.add(u2)
    await db.flush()
    db.add(
        UserSession(
            user_id=u2.id, refresh_token="rt3", is_active=True,
            expires_at=datetime.now(timezone.utc) + timedelta(days=30),
        )
    )
    db.add(Role(id=uuid4(), organization_id=org2.id, name="owner", is_system=True))
    await db.commit()
    g = await client.get(f"{API}/invoices/{inv_id}", headers=_hdr(u2))
    assert g.status_code == 404
    # personal tables exist but are untouched by the whole cycle
    from app.domain.entities import personal_entities as pe

    for table in (
        pe.PersonalBankAccount,
        pe.PersonalTransaction,
        pe.PersonalDebt,
    ):
        n = (await db.execute(select(func.count()).select_from(table))).scalar_one()
        assert n == 0
