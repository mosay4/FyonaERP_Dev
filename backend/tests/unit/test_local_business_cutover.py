"""Freeze a non-default synthetic branch and export for the SQLCipher tests."""

import asyncio
from datetime import date
from decimal import Decimal
from hashlib import sha256
from io import BytesIO
import json
import os
from pathlib import Path
from uuid import UUID, uuid4

import pytest
import pytest_asyncio
from sqlalchemy import select, text
from sqlalchemy.engine import URL
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.domain.services import local_business_cutover as cutover


@pytest_asyncio.fixture
async def engine():
    socket = os.environ.get("FYONA_TEST_CUTOVER_SOCKET")
    if socket is None:
        pytest.skip("A disposable Business cutover socket is required")
    if not cutover.SOCKET_PATH.fullmatch(socket):
        pytest.fail("Refusing to connect to a non-fixture database")
    db = create_async_engine(URL.create(
        "postgresql+asyncpg", username="root", database=cutover.FIXTURE_DB,
        query={"host": socket},
    ))
    try:
        # These imports only register tables; no web app, session factory
        # from settings, lifecycle, push sender or FX provider is started.
        from app.api.v1 import reconciliation  # noqa: F401
        from app.core.database import Base
        from app.domain.entities import (  # noqa: F401
            accounting_entities, branch_entities, business_settings_entities, employee_workspace_entities,
            hr_entities, invoice_entities, merchant_entities, purchase_entities, sales_entities,
        )
        async with db.begin() as conn:
            await cutover._require_socket(conn, socket)
            await conn.run_sync(Base.metadata.create_all)
            installed = await conn.scalar(text(
                "SELECT to_regclass('public.fyona_qa_business_cutovers') IS NOT NULL"
            ))
        if not installed:
            await cutover.install_fixture_guard(db)
        yield db
    finally:
        await db.dispose()


async def _seed(engine):
    from app.domain.entities.auth_entities import Organization, User
    from app.domain.entities.business_entities import Customer, Product, Supplier
    from app.domain.entities.sale_entities import Branch
    from app.domain.services import bank_money_service as banks

    ids = [uuid4() for _ in range(9)]
    org, owner, employee, branch, sibling, customer, supplier, product, other_customer = ids
    slug = f"ledger-cutover-{org.hex}"
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker.begin() as db:
        db.add(Organization(id=org, slug=slug, name="Synthetic ledger"))
        await db.flush()
        db.add_all([
            User(id=owner, organization_id=org, role="owner", full_name="Fixture Owner",
                 email=f"{slug}@example.test"),
            User(id=employee, organization_id=org, role="employee", full_name="Fixture Employee",
                 email=f"employee-{org.hex}@example.test"),
            Branch(id=branch, organization_id=org, name="Freeze branch", is_default=False),
            Branch(id=sibling, organization_id=org, name="Keep connected", is_default=True),
        ])
        await db.flush()
        db.add_all([
            Customer(id=customer, organization_id=org, branch_id=branch, name="Buyer A"),
            Customer(id=other_customer, organization_id=org, branch_id=sibling, name="Sibling only"),
            Supplier(id=supplier, organization_id=org, branch_id=branch, name="Vendor A"),
            Product(id=product, organization_id=org, branch_id=branch, name="Fixture product",
                    price=Decimal("20.00")),
        ])
        await db.flush()
        account_values = {
            "bank_name": "Cash", "account_name": "Fixture SAR",
            "account_number": "1", "currency": "SAR", "balance": "100.00",
        }
        account = (await banks.create_account(db, org, branch, account_values)).id
        other_account = (await banks.create_account(db, org, sibling, account_values)).id

    return cutover.CutoverScope(org, owner, branch), {
        "employee": employee, "sibling": sibling, "customer": customer,
        "supplier": supplier, "product": product, "other_customer": other_customer,
        "account": account, "other_account": other_account,
    }


async def _legacy_example(engine, scope, ids):
    from app.domain.entities.business_entities import Product
    from app.domain.entities.invoice_entities import InvoiceItem
    from app.domain.entities.sale_entities import ProductBarcode, ProductPrice
    from app.domain.models.invoice_models import (
        PartyPaymentRequest, PurchaseIssueLine, PurchaseIssuePayment,
        PurchaseIssueRequest, SaleIssueLine, SaleIssuePayment, SaleIssueRequest,
        SaleReturnLine, SaleReturnRequest,
    )
    from app.domain.services import (
        debt_invoice_service as debt, merchant_link_service as links,
        returns_service as returns, sale_service as sales,
    )

    args = (scope.organization_id, scope.account_id)
    async with async_sessionmaker(engine, expire_on_commit=False)() as db:
        product = await db.get(Product, ids["product"])
        base = await sales.ensure_base_unit(db, args[0], product)
        # Source the stock and cash from the unchanged connected services:
        # buy 5 × 10, sell 2 × 20, return/restock 1 × 20.
        purchase = await sales.issue_purchase(db, *args, PurchaseIssueRequest(
            branch_id=scope.branch_id, supplier_id=ids["supplier"],
            items=[PurchaseIssueLine(
                product_id=ids["product"], unit_id=base.id, quantity=5, unit_price="10",
                expiry_date=date(2030, 6, 1), lot_number="LOT-01",
            )],
            payments=[PurchaseIssuePayment(bank_account_id=ids["account"], amount="50")],
        ))
        sale = await sales.issue_sale(db, *args, SaleIssueRequest(
            branch_id=scope.branch_id, customer_id=ids["customer"],
            items=[SaleIssueLine(
                product_id=ids["product"], unit_id=base.id, quantity=2, unit_price="20",
                original_price="5", price_currency="USD", exchange_rate="4",
            )],
            payments=[SaleIssuePayment(bank_account_id=ids["account"], amount="40")],
        ))
        sale_id = UUID(str(sale["id"]))
        line = await db.scalar(select(InvoiceItem).where(InvoiceItem.invoice_id == sale_id))
        await sales.confirm_return(db, *args, sale_id, SaleReturnRequest(
            lines=[SaleReturnLine(invoice_item_id=line.id, quantity=1)],
            refund_account_id=ids["account"],
        ))
        db.add_all([
            ProductPrice(organization_id=args[0], product_id=ids["product"],
                         currency="USD", price=Decimal("5"), buy_price=Decimal("2.50")),
            ProductBarcode(organization_id=args[0], product_id=ids["product"],
                           unit_id=line.unit_id, barcode="FIXTURE-BASE-001"),
        ])
        # Also cover the other return table. Returning an unpaid service
        # changes its payable, but neither stock nor the cash account.
        service = await sales.issue_purchase(db, *args, PurchaseIssueRequest(
            branch_id=scope.branch_id, supplier_id=ids["supplier"],
            items=[PurchaseIssueLine(description="Fixture service", quantity=1, unit_price="17")],
        ))
        service_id = UUID(str(service["id"]))
        service_line = await db.scalar(select(InvoiceItem).where(InvoiceItem.invoice_id == service_id))
        await returns.confirm_purchase_return(db, *args, service_id, SaleReturnRequest(
            lines=[SaleReturnLine(invoice_item_id=service_line.id, quantity=1)],
        ))
        # Also cover a legacy opening invoice with NULL branch_id. Its party
        # owns it. Use the original settlement service without external push.
        opening = await links.create_opening_debt(
            db, *args, "customer", ids["customer"], Decimal("30.25"), "SAR",
        )
        await db.commit()
        await sales.add_customer_payment(
            db, *args, ids["customer"],
            PartyPaymentRequest(bank_account_id=ids["account"], amount="5",
                                currency="SAR", invoice_id=opening["invoice_id"]),
            notify_linked=False,
        )
        opening_id = UUID(opening["invoice_id"])
        opening_line = await db.scalar(select(InvoiceItem).where(InvoiceItem.invoice_id == opening_id))
        # Change the line without changing the 30.25 total. The original item
        # ID and its revision must survive, as well as the posted 5.00.
        await debt.adjust_debt_invoice(
            db, *args, "customer", ids["customer"], opening_id,
            [{"item_id": opening_line.id, "quantity": 1.25, "unit_price": "24.20"}],
        )
        folder = await links.create_debt_group(
            db, *args, "customer", ids["customer"], "Fixture opening debts",
            kind="auto", period="2026-11",
        )
        await links.assign_group(db, *args, "customer", ids["customer"], opening_id, UUID(folder["id"]))
        supplier_opening = await links.create_opening_debt(
            db, *args, "supplier", ids["supplier"], Decimal("7.50"), "SAR",
        )
        await db.commit()
        return {"opening": opening["invoice_id"], "sale": str(sale_id),
                "supplier_opening": supplier_opening["invoice_id"],
                "group": folder["id"], "purchase": str(purchase["id"]),
                "returned_service": str(service_id), "item": line.id}


@pytest.mark.asyncio
async def test_frozen_copy_matches_connected_branch_by_id_and_receipt(engine):
    scope, ids = await _seed(engine)
    operations = await _legacy_example(engine, scope, ids)
    frozen = await cutover.freeze_fixture_branch(engine, scope)
    assert frozen == await cutover.freeze_fixture_branch(engine, scope)
    assert frozen.digest == sha256(frozen.body).hexdigest()
    body = json.loads(frozen.body)
    assert body["version"] == 2
    assert body["allow_negative"] is False
    assert body["controls"]["stock"] == [[str(ids["product"]), 4000, 100_000]]
    assert body["controls"]["accounts"] == [[str(ids["account"]), "SAR", 7500]]
    assert [operations["opening"], "SAR", 3025, 500, 2525] in body["controls"]["invoices"]
    assert [operations["supplier_opening"], "SAR", 750, 0, 750] in body["controls"]["invoices"]
    assert [operations["sale"], "SAR", 4000, 2000, 0] in body["controls"]["invoices"]
    assert [operations["returned_service"], "SAR", 1700, 0, 0] in body["controls"]["invoices"]
    assert body["tables"]["debt_groups"][0]["id"] == operations["group"]
    assert len(body["tables"]["invoice_item_changes"]) == 1
    assert len(body["tables"]["invoice_returns"]) == 1
    assert len(body["tables"]["purchase_returns"]) == 1
    assert [c["id"] for c in body["tables"]["customers"]] == [str(ids["customer"])]
    assert str(ids["other_account"]).encode() not in frozen.body
    assert str(ids["employee"]).encode() not in frozen.body

    # Real legacy writes and indirect rows must keep the snapshot unchanged.
    from app.domain.services import bank_money_service as banks
    with pytest.raises(DBAPIError, match="Business branch is frozen"):
        async with async_sessionmaker(engine).begin() as db:
            await banks.deposit(db, scope.organization_id, scope.branch_id,
                                ids["account"], Decimal("1.00"))
    for query, key in [
        ("UPDATE bank_transactions SET description = 'blocked' WHERE bank_account_id = :id", "account"),
        ("UPDATE payments SET notes = 'blocked' WHERE invoice_id = :id", "opening"),
        ("UPDATE invoice_items SET description = 'blocked' WHERE id = :id", "item"),
        ("UPDATE inventory_lots SET remaining_quantity = 0 WHERE product_id = :id", "product"),
        ("UPDATE branch_stock SET quantity = 0 WHERE product_id = :id", "product"),
        ("DELETE FROM customers WHERE id = :id", "customer"),
    ]:
        val = operations.get(key) or ids[key]
        with pytest.raises(DBAPIError, match="Business branch is frozen"):
            async with engine.begin() as conn:
                await conn.execute(text(query), {"id": UUID(str(val))})
    with pytest.raises(DBAPIError, match="Business branch is frozen"):
        async with engine.begin() as conn:
            await conn.execute(text("TRUNCATE bank_transactions"))
    # Even a movement declaring the sibling branch is owned by the source
    # return as well. A branch label cannot detach it from the frozen invoice.
    sibling_product, sibling_invoice = uuid4(), uuid4()
    async with engine.begin() as conn:
        await conn.execute(text("""
            INSERT INTO products (id, organization_id, branch_id, name, price)
            VALUES (:product, :org, :sibling, 'Sibling product', 0)
        """), {"product": sibling_product, "org": scope.organization_id, "sibling": ids["sibling"]})
        await conn.execute(text("""
            INSERT INTO invoices (
                id, organization_id, branch_id, invoice_number, invoice_type,
                invoice_date, status, currency
            )
            VALUES (:invoice, :org, :sibling, 'SIBLING-INVOICE', 'sale', CURRENT_DATE, 'draft', 'SAR')
        """), {"invoice": sibling_invoice, "org": scope.organization_id, "sibling": ids["sibling"]})
    movement = text("""
        INSERT INTO inventory_movements (
            id, organization_id, product_id, branch_id, movement_type, quantity,
            reference_type, reference_id
        )
        VALUES (:id, :org, :product, :branch, 'return', 1, 'invoice_return', :ref)
    """)
    with pytest.raises(DBAPIError, match="Business branch is frozen"):
        async with engine.begin() as conn:
            await conn.execute(movement, {
                "id": uuid4(), "org": scope.organization_id, "product": sibling_product,
                "branch": ids["sibling"], "ref": UUID(body["tables"]["invoice_returns"][0]["id"]),
            })
    with pytest.raises(DBAPIError, match="Business branch is frozen"):
        async with engine.begin() as conn:
            await conn.execute(text("""
                INSERT INTO invoice_item_changes (id, organization_id, invoice_id, item_id)
                VALUES (:id, :org, :invoice, :item)
            """), {"id": uuid4(), "org": scope.organization_id,
                   "invoice": sibling_invoice, "item": operations["item"]})
    async with async_sessionmaker(engine).begin() as db:
        await banks.deposit(db, scope.organization_id, ids["sibling"], ids["other_account"], Decimal("2"))
    assert frozen == await cutover.freeze_fixture_branch(engine, scope)

    staff = cutover.CutoverScope(scope.organization_id, ids["employee"], scope.branch_id)
    for bad_scope, digest in [(staff, frozen.digest), (scope, "0" * 64)]:
        with pytest.raises(cutover.CutoverRejected):
            await cutover.acknowledge_fixture_import(engine, bad_scope, frozen.id, digest)
    # Normally only called with the committed device receipt. The optional
    # handoff allows the Flutter fixture to acknowledge these exact bytes.
    export = os.environ.get("FYONA_TEST_CUTOVER_EXPORT_DIR")
    if export is not None:
        export_path = Path(export).resolve(strict=True)
        if str(export_path) != str(Path(engine.url.query["host"]).parent / "handoff"):
            pytest.fail("Export must stay in the private fixture directory")
        (export_path / "snapshot.json").write_bytes(frozen.body)
        (export_path / "snapshot.sha256").write_text(frozen.digest, encoding="ascii")
    else:
        receipt = await cutover.acknowledge_fixture_import(engine, scope, frozen.id, frozen.digest)
        assert receipt == await cutover.acknowledge_fixture_import(engine, scope, frozen.id, frozen.digest)


@pytest.mark.asyncio
async def test_freeze_waits_for_old_write_and_denies_stale_transaction(engine):
    scope, ids = await _seed(engine)
    async with engine.connect() as stale:
        await stale.execution_options(isolation_level="REPEATABLE READ")
        async with stale.begin():
            assert await stale.scalar(text("SELECT balance FROM bank_accounts WHERE id = :id"),
                                      {"id": ids["account"]}) == 100
            async with engine.begin() as active:
                await active.execute(text(
                    "UPDATE bank_accounts SET balance = balance + 1 WHERE id = :id"
                ), {"id": ids["account"]})
                freeze = asyncio.create_task(cutover.freeze_fixture_branch(engine, scope))
                done, _ = await asyncio.wait({freeze}, timeout=0.1)
                assert not done
            frozen = await freeze
            assert json.loads(frozen.body)["controls"]["accounts"][0][-1] == 10100
            with pytest.raises(DBAPIError) as rejected:
                await stale.execute(text(
                    "UPDATE customers SET name = 'stale' WHERE id = :id"
                ), {"id": ids["customer"]})
            assert rejected.value.orig.sqlstate == "40001"
            await stale.rollback()


@pytest.mark.asyncio
async def test_cross_branch_edges_abort_instead_of_creating_two_writers(engine):
    scope, ids = await _seed(engine)
    main = cutover.CutoverScope(scope.organization_id, scope.account_id, ids["sibling"])
    with pytest.raises(cutover.CutoverRejected):
        await cutover.freeze_fixture_branch(engine, main)

    transfer = uuid4()
    query = text("""
        INSERT INTO branch_transfers
          (id, organization_id, transfer_number, kind, from_branch_id, to_branch_id,
           from_account_id, to_account_id)
        VALUES (:id, :org, :number, 'financial', :other, :branch, :source, :target)
    """)
    params = dict(id=transfer, org=scope.organization_id, number=str(transfer),
                  branch=scope.branch_id, other=ids["sibling"],
                  source=ids["other_account"], target=ids["account"])
    async with engine.begin() as conn:
        await conn.execute(query, params)
    with pytest.raises(cutover.CutoverRejected, match="cross-branch"):
        await cutover.freeze_fixture_branch(engine, scope)
    async with engine.begin() as conn:
        await conn.execute(text("DELETE FROM branch_transfers WHERE id = :id"), {"id": transfer})
    frozen = await cutover.freeze_fixture_branch(engine, scope)
    with pytest.raises(DBAPIError, match="Business branch is frozen"):
        async with engine.begin() as conn:
            await conn.execute(text("UPDATE bank_accounts SET balance = 0 WHERE id = :id"),
                               {"id": ids["other_account"]})
            await conn.execute(query, params)
    async with engine.connect() as conn:
        assert await conn.scalar(text("SELECT balance FROM bank_accounts WHERE id = :id"),
                                 {"id": ids["other_account"]}) == 100
    assert frozen == await cutover.freeze_fixture_branch(engine, scope)


@pytest.mark.asyncio
async def test_policy_frozen_for_import_without_locking_sibling_settings(engine):
    from app.domain.entities.business_settings_entities import BusinessProjectSettings
    scope, ids = await _seed(engine)
    maker = async_sessionmaker(engine)
    async with maker.begin() as db:
        db.add(BusinessProjectSettings(
            organization_id=scope.organization_id, settings='{"allow_negative":true}',
        ))
    frozen = await cutover.freeze_fixture_branch(engine, scope)
    assert json.loads(frozen.body)["allow_negative"] is True
    async with maker.begin() as db:
        saved = await db.get(BusinessProjectSettings, scope.organization_id)
        saved.settings = '{"allow_negative":false}'
    assert await cutover.freeze_fixture_branch(engine, scope) == frozen


@pytest.mark.asyncio
async def test_confirmed_bank_links_need_separate_handoff(engine):
    scope, ids = await _seed(engine)
    async with engine.begin() as conn:
        await conn.execute(text("UPDATE bank_accounts SET bank_group_key = :key WHERE id = :id"),
                           {"key": f"link:{uuid4().hex}", "id": ids["account"]})
    with pytest.raises(cutover.CutoverRejected, match="Unsupported confirmed bank link"):
        await cutover.freeze_fixture_branch(engine, scope)
    async with engine.begin() as conn:
        await conn.execute(text("UPDATE bank_accounts SET bank_group_key = NULL WHERE id = :id"),
                           {"id": ids["account"]})
    await cutover.freeze_fixture_branch(engine, scope)


@pytest.mark.asyncio
@pytest.mark.parametrize("read_mode", ["single", "all", "payment_options"])
async def test_legacy_bank_reads_cannot_create_or_retype_frozen_cash(engine, read_mode):
    from starlette.requests import Request
    from app.api.deps import BranchScopeContext
    from app.api.v1 import finance

    scope, ids = await _seed(engine)
    branches = [ids["sibling"], scope.branch_id] if read_mode == "all" else [scope.branch_id]
    context = BranchScopeContext(scope.branch_id, read_mode == "all", branches)
    maker = async_sessionmaker(engine)
    # Test the INSERT as well as the less obvious retyping UPDATE. Renaming
    # the example account keeps its exact balance/history but leaves no cash.
    async with maker.begin() as db:
        if read_mode in ("single", "all"):
            await db.execute(text("UPDATE bank_accounts SET bank_name = 'Fixture bank' WHERE id = :id"),
                             {"id": ids["account"]})
        await db.execute(text(
            "UPDATE bank_accounts SET account_type = 'checking' WHERE id IN (:target, :sibling)"
        ), {"target": ids["account"], "sibling": ids["other_account"]})
    frozen = await cutover.freeze_fixture_branch(engine, scope)

    with pytest.raises(DBAPIError, match="Business branch is frozen"):
        async with maker.begin() as db:
            if read_mode == "payment_options":
                request = Request({"type": "http", "method": "GET",
                                   "path": "/api/v1/business/payment-options", "headers": []})
                await finance.payment_options(
                    request, str(scope.organization_id), scope.account_id, context, db, branch_id=None,
                )
            else:
                await finance.list_bank_accounts(str(scope.organization_id), context, db, True)
    assert frozen == await cutover.freeze_fixture_branch(engine, scope)
    async with maker.begin() as db:
        # The aggregate's attempt at provisioning a sibling is also rolled
        # back; an ordinary read of the sibling alone still works.
        assert await db.scalar(text("SELECT account_type FROM bank_accounts WHERE id = :id"),
                               {"id": ids["other_account"]}) == "checking"
        sibling = BranchScopeContext(ids["sibling"], False, [ids["sibling"]])
        rows = await finance.list_bank_accounts(str(scope.organization_id), sibling, db, True)
        assert len(rows) == 1 and rows[0]["account_type"] == "cash"


@pytest.mark.asyncio
async def test_old_purchase_order_writers_cannot_reach_the_frozen_branch(engine):
    scope, ids = await _seed(engine)
    order = uuid4()
    write = text("""
        INSERT INTO purchase_orders
            (id, organization_id, supplier_id, order_number, order_date, status, is_deleted)
        VALUES (:id, :org, :supplier, :number, CURRENT_DATE, 'draft', FALSE)
    """)
    params = {
        "id": order, "org": scope.organization_id, "supplier": ids["supplier"],
        "number": "FIXTURE-ORDER",
    }
    async with engine.begin() as conn:
        await conn.execute(write, params)
    with pytest.raises(cutover.CutoverRejected, match="purchase_orders"):
        await cutover.freeze_fixture_branch(engine, scope)
    async with engine.begin() as conn:
        await conn.execute(text("DELETE FROM purchase_orders WHERE id = :id"), {"id": order})
    await cutover.freeze_fixture_branch(engine, scope)
    with pytest.raises(DBAPIError, match="Business branch is frozen"):
        async with engine.begin() as conn:
            await conn.execute(write, params)


@pytest.mark.asyncio
async def test_non_fixture_url_is_rejected_before_connecting():
    db = create_async_engine("postgresql+asyncpg://fixture@unused.example.test/fake")
    try:
        with pytest.raises(cutover.CutoverRejected, match="disposable"):
            await cutover.install_fixture_guard(db)
    finally:
        await db.dispose()


@pytest.mark.asyncio
@pytest.mark.parametrize("bad_category", ["foreign", "deleted"])
async def test_unresolved_category_refuses_cutover_without_freezing_the_branch(engine, bad_category):
    from app.domain.entities.business_entities import Product, ProductCategory

    scope, ids = await _seed(engine)
    foreign, _ = await _seed(engine) if bad_category == "foreign" else (scope, ids)
    maker = async_sessionmaker(engine)
    async with maker.begin() as db:
        category = ProductCategory(
            organization_id=foreign.organization_id, name="Unresolved",
            is_deleted=bad_category == "deleted",
        )
        db.add(category)
        await db.flush()
        (await db.get(Product, ids["product"])).category_id = category.id
    with pytest.raises(cutover.CutoverRejected, match="Unresolved shared product category"):
        await cutover.freeze_fixture_branch(engine, scope)
    async with maker.begin() as db:
        # A failed snapshot must not leave a partial fence.
        product = await db.get(Product, ids["product"])
        product.category_id = None
        product.name = "Unfrozen after refusal"
    await cutover.freeze_fixture_branch(engine, scope)


@pytest.mark.asyncio
async def test_catalog_snapshot_replays_even_after_shared_source_changes(engine):
    from PIL import Image
    from app.domain.entities.business_entities import Product, ProductCategory, WarehouseSetting

    scope, ids = await _seed(engine)
    await _legacy_example(engine, scope, ids)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    category_id, hidden_id, extra_id, sibling_id = (uuid4() for _ in range(4))
    ref = "https://assets.example.test/inventory/legacy.png"
    cat_ref = "/uploads/catalogue/shared.png"

    def photo(reference, color):
        encoded = BytesIO()
        Image.new("RGB", (3, 4), color).save(encoded, format="PNG")
        payload = encoded.getvalue()
        return cutover.CatalogImage(reference, sha256(payload).hexdigest(), payload)

    async with maker.begin() as db:
        db.add_all([
            ProductCategory(id=category_id, organization_id=scope.organization_id,
                            name="Shared fixture", image=cat_ref, description="Not needed locally"),
            ProductCategory(id=hidden_id, organization_id=scope.organization_id,
                            name="Sibling-only fixture", image="/uploads/catalogue/sibling.png"),
            WarehouseSetting(organization_id=scope.organization_id,
                             expiry_enabled=True, expiry_warn_days=17),
        ])
        await db.flush()
        product = await db.get(Product, ids["product"])
        product.category_id, product.image, product.expiry_date = category_id, ref, date(2030, 1, 10)
        db.add_all([
            Product(id=extra_id, organization_id=scope.organization_id, branch_id=scope.branch_id,
                    name="Unbundled fixture", image="/uploads/inventory/no-bytes.png"),
            Product(id=sibling_id, organization_id=scope.organization_id, branch_id=ids["sibling"],
                    name="Sibling inventory", image=ref, category_id=hidden_id),
        ])
    products = ("products", ids["product"])
    cats = ("product_categories", category_id)
    images = {products: photo(ref, "red"), cats: photo(cat_ref, "blue")}
    truncated = b"\x89PNG\r\n\x1a\n"
    for bad, problem in [
        ({products: photo("/wrong-reference.png", "red")}, "does not match"),
        ({products: cutover.CatalogImage(ref, "0" * 64, images[products].data)}, "does not match"),
        ({products: cutover.CatalogImage(ref, sha256(truncated).hexdigest(), truncated)}, "Unusable"),
        ({("products", sibling_id): images[products]}, "outside the captured inventory scope"),
        ({("product_categories", hidden_id): images[cats]}, "outside the captured inventory scope"),
    ]:
        with pytest.raises(cutover.CutoverRejected, match=problem):
            await cutover.freeze_fixture_branch(engine, scope, inventory_images=bad)
    async with maker.begin() as db:
        # All refusals left the branch connected.
        (await db.get(Product, ids["product"])).name = "Catalog fixture product"
    frozen = await cutover.freeze_fixture_branch(engine, scope, inventory_images=images)
    body = json.loads(frozen.body)
    assert body["version"] == 3 and body["tables"]["branches"][0]["device_catalogue"] is True
    category, = body["tables"]["product_categories"]
    assert category["id"] == str(category_id)
    assert category["device_image_sha256"] == images[cats].digest
    assert "description" not in category
    assert str(sibling_id).encode() not in frozen.body
    assert str(hidden_id).encode() not in frozen.body
    rows = {p["id"]: p for p in body["tables"]["products"]}
    assert rows[str(ids["product"])]["device_image_sha256"] == images[products].digest
    assert "device_image" not in rows[str(extra_id)]
    assert body["tables"]["warehouse_settings"][0]["expiry_warn_days"] == 17
    async with maker.begin() as db:
        (await db.get(ProductCategory, category_id)).name = "Updated shared name"
        setting = await db.scalar(select(WarehouseSetting).where(
            WarehouseSetting.organization_id == scope.organization_id,
        ))
        setting.expiry_warn_days = 4
    assert await cutover.freeze_fixture_branch(engine, scope) == frozen
    assert await cutover.freeze_fixture_branch(engine, scope, inventory_images=images) == frozen
    with pytest.raises(cutover.CutoverRejected, match="Cannot change photos"):
        await cutover.freeze_fixture_branch(engine, scope, inventory_images={products: photo(ref, "green")})
    with pytest.raises(cutover.CutoverRejected, match="Cannot attach photos"):
        await cutover.freeze_fixture_branch(
            engine, scope, inventory_images={("products", extra_id): images[products]},
        )

    if export := os.environ.get("FYONA_TEST_CUTOVER_EXPORT_DIR"):
        folder = Path(export).resolve(strict=True)
        assert folder == Path(engine.url.query["host"]).parent / "handoff"
        (folder / "catalogue.json").write_bytes(frozen.body)
        (folder / "catalogue.sha256").write_text(frozen.digest, encoding="ascii")


@pytest.mark.asyncio
async def test_existing_v2_receipt_ignores_new_shared_settings(engine):
    from app.domain.entities.business_entities import Product, WarehouseSetting

    scope, ids = await _seed(engine)
    ref = "/uploads/inventory/fixture.png"
    async with async_sessionmaker(engine).begin() as db:
        (await db.get(Product, ids["product"])).image = ref
    old = await cutover.freeze_fixture_branch(engine, scope)
    assert json.loads(old.body)["version"] == 2
    acknowledged = await cutover.acknowledge_fixture_import(engine, scope, old.id, old.digest)
    async with async_sessionmaker(engine).begin() as db:
        db.add(WarehouseSetting(organization_id=scope.organization_id,
                                expiry_enabled=True, expiry_warn_days=21))
    with pytest.raises(cutover.CutoverRejected, match="already frozen"):
        await cutover.freeze_fixture_branch(
            engine, scope, inventory_images={("products", ids["product"]): cutover.CatalogImage(ref, "", b"")},
        )
    assert await cutover.freeze_fixture_branch(engine, scope) == old
    assert await cutover.acknowledge_fixture_import(engine, scope, old.id, old.digest) == acknowledged


@pytest.mark.asyncio
async def test_stock_adjustment_uses_the_original_expiring_lot(engine):
    from app.api.v1.business import _get_service
    from app.domain.entities.sale_entities import BranchStock, InventoryLot
    from app.domain.models.business_models import InventoryAdjustRequest

    scope, ids = await _seed(engine)
    await _legacy_example(engine, scope, ids)
    async with async_sessionmaker(engine, expire_on_commit=False).begin() as db:
        service = _get_service(db)
        for mode, amount, reason, previous, expected in [
            ("add", 1.25, "increase", 4, 5.25), ("remove", 2, "damaged", 5.25, 3.25),
        ]:
            movement = await service.adjust_stock(
                scope.organization_id, scope.account_id, InventoryAdjustRequest(
                    product_id=ids["product"], branch_id=scope.branch_id,
                    mode=mode, amount=amount, reason=reason,
                ),
            )
            assert (movement.old_quantity, movement.new_quantity, movement.reason) == (
                previous, expected, reason,
            )
        stock = await db.scalar(select(BranchStock).where(BranchStock.branch_id == scope.branch_id))
        assert stock.quantity == Decimal("3.250")
        assert stock.avg_cost == Decimal("10.0000")
        lots = {lot.source: lot for lot in (await db.scalars(select(InventoryLot).where(
            InventoryLot.product_id == ids["product"],
        ))).all()}
        assert lots["purchase"].remaining_quantity == 2
        assert lots["adjustment"].remaining_quantity == 1.25


@pytest.mark.asyncio
async def test_opening_debt_edit_and_cancel_reference(engine):
    from app.domain.entities.finance_entities import BankAccount
    from app.domain.entities.invoice_entities import InvoiceItem
    from app.domain.models.invoice_models import PartyPaymentRequest
    from app.domain.services import debt_invoice_service as debt, merchant_link_service as links
    from app.domain.services import sale_service as sales

    scope, ids = await _seed(engine)
    org, owner = scope.organization_id, scope.account_id
    customer, till = ids["customer"], ids["account"]
    async with async_sessionmaker(engine, expire_on_commit=False)() as db:
        start = await links.create_opening_debt(
            db, org, owner, "customer", customer, Decimal("30.25"), "SAR",
        )
        await db.commit()
        invoice = UUID(start["invoice_id"])
        line = await db.scalar(select(InvoiceItem).where(InvoiceItem.invoice_id == invoice))
        await sales.add_customer_payment(
            db, org, owner, customer, PartyPaymentRequest(
                bank_account_id=till, amount="35", currency="SAR", invoice_id=invoice,
            ), notify_linked=False,
        )
        edit = await debt.adjust_debt_invoice(db, org, owner, "customer", customer, invoice, [{
            "item_id": line.id, "quantity": 1.5, "unit_price": "10.25",
        }])
        assert (edit["total"], edit["paid"], edit["balance"]) == (15.38, 30.25, 0)
        await debt.delete_debt_invoice(db, org, owner, "customer", customer, invoice)
        await db.commit()
        assert (await db.get(BankAccount, till)).balance == Decimal("104.75")


@pytest.mark.asyncio
@pytest.mark.parametrize("kind", ["snapshot", "catalogue"])
async def test_device_receipt_is_recorded_only_after_reopen(engine, kind):
    export = os.environ.get("FYONA_TEST_CUTOVER_EXPORT_DIR")
    if export is None:
        pytest.skip("Run the SQLCipher handoff first")
    folder = Path(export).resolve(strict=True)
    if folder != Path(engine.url.query["host"]).parent / "handoff":
        pytest.fail("Expected the private handoff directory")
    receipt_file = folder / ("device-receipt.json" if kind == "snapshot" else "catalogue-receipt.json")
    if not receipt_file.exists():
        if os.environ.get("FYONA_TEST_CUTOVER_REQUIRE_RECEIPT"):
            pytest.fail("No receipt produced by the encrypted client")
        pytest.skip("Run the SQLCipher handoff first")
    doc = json.loads((folder / f"{kind}.json").read_bytes())
    scope = cutover.CutoverScope(*(UUID(doc[name]) for name in (
        "organization_id", "account_id", "branch_id",
    )))
    receipt = json.loads(receipt_file.read_bytes())
    assert doc["snapshot_id"] == receipt["snapshot_id"]
    snapshot_id = UUID(receipt["snapshot_id"])
    stamp = await cutover.acknowledge_fixture_import(engine, scope, snapshot_id, receipt["digest"])
    assert await cutover.acknowledge_fixture_import(
        engine, scope, snapshot_id, receipt["digest"],
    ) == stamp
    assert (await cutover.freeze_fixture_branch(engine, scope)).digest == receipt["digest"]
