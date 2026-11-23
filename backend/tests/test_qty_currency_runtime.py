"""Runtime test: quantity sync + stats display currency + Falcon product
consistency (Business only).

Scenario: 50 kg → sell 5 → 45 EVERYWHERE without app restart; stats money
converts per the product's priced currencies; Falcon PRODUCT analysis uses
the SAME authoritative query as the stats page (no fake zeros).
"""
import asyncio
import uuid
from datetime import date
from decimal import Decimal
from pathlib import Path
import sys as _sys

_sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sqlalchemy import select

from app.core.database import async_session_factory, engine
import app.domain.entities  # register most mappers
for _m in ("finance_entities", "payment_entities", "accounting_entities",
           "hr_entities", "admin_entities", "analytics_entities",
           "notification_entities", "purchase_entities", "sale_entities",
           "sales_entities", "backup_entities", "subscription_invoice_entities",
           "suggestions_entities", "push_entities"):
    __import__(f"app.domain.entities.{_m}")

from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.business_entities import Product
from app.domain.entities.sale_entities import ProductPrice
from app.domain.entities.invoice_entities import Invoice, InvoiceItem
from app.infrastructure.repositories.sql_alchemy_business_repository import (
    SqlAlchemyCustomerRepository, SqlAlchemySupplierRepository,
    SqlAlchemyProductCategoryRepository, SqlAlchemyProductRepository)
from app.domain.services import inventory_stats, falcon_service
from app.domain.services.business_service import BusinessService
from app.domain.models.business_models import InventoryAdjustRequest
from app.infrastructure.repositories.sql_alchemy_business_repository import (
    SqlAlchemyInventoryMovementRepository)


async def verify():
    async with async_session_factory() as db:
        try:
            org = Organization(name="QtySync", slug="qsync-" + uuid.uuid4().hex)
            db.add(org)
            await db.flush()
            user = User(organization_id=org.id, full_name="Owner",
                        email=f"qsync-{uuid.uuid4().hex[:8]}@t.dev",
                        role="owner")
            db.add(user)
            await db.flush()
            uid = user.id

            prod = Product(organization_id=org.id, name="طماطم", unit="كيلو",
                           stock=50, price=Decimal("20"), cost_price=Decimal("10"))
            db.add(prod)
            await db.flush()
            # Product priced in SAR + USD (both real price rows).
            db.add(ProductPrice(organization_id=org.id, product_id=prod.id,
                                currency="SAR", price=Decimal("20")))
            db.add(ProductPrice(organization_id=org.id, product_id=prod.id,
                                currency="USD", price=Decimal("20")))
            await db.flush()

            service = BusinessService(
                customer_repo=SqlAlchemyCustomerRepository(db),
                supplier_repo=SqlAlchemySupplierRepository(db),
                category_repo=SqlAlchemyProductCategoryRepository(db),
                product_repo=SqlAlchemyProductRepository(db),
                inventory_repo=SqlAlchemyInventoryMovementRepository(db),
            )
            await service.adjust_stock(
                org.id, uid,
                InventoryAdjustRequest(product_id=prod.id, mode="remove",
                                       amount=5, reason="sale"))

            # ── 1) Quantity: ONE source of truth = products.stock ──
            assert prod.stock == 45, prod.stock
            fresh = await SqlAlchemyProductRepository(db).get_by_id(prod.id, org.id)
            assert fresh.stock == 45, fresh.stock  # details endpoint reads this
            items, total = await SqlAlchemyProductRepository(db).list(org.id)
            assert total == 1 and float(items[0].stock) == 45  # list endpoint
            # Falcon dataset (its own query path) sees 45 as well:
            data, _t = await falcon_service._dataset(db, org.id, "product",
                                                     str(prod.id), "SAR")
            assert data["stock"] == 45, data["stock"]

            # ── 2) Stats currency: real invoices in SAR + USD ──
            inv1 = Invoice(organization_id=org.id, invoice_number="S1",
                           invoice_type="sale", currency="SAR",
                           invoice_date=date.today(), status="confirmed",
                           subtotal=Decimal("20"), total=Decimal("20"))
            db.add(inv1)
            await db.flush()
            db.add(InvoiceItem(invoice_id=inv1.id, product_id=prod.id,
                               description="طماطم", quantity=5,
                               base_quantity=5, unit_price=Decimal("4"),
                               total=Decimal("20"), cost_total=Decimal("10"),
                               profit=Decimal("10")))
            inv2 = Invoice(organization_id=org.id, invoice_number="S2",
                           invoice_type="sale", currency="USD",
                           invoice_date=date.today(), status="confirmed",
                           subtotal=Decimal("10"), total=Decimal("10"))
            db.add(inv2)
            await db.flush()
            db.add(InvoiceItem(invoice_id=inv2.id, product_id=prod.id,
                               description="طماطم", quantity=2,
                               base_quantity=2, unit_price=Decimal("5"),
                               total=Decimal("10"), cost_total=Decimal("4"),
                               profit=Decimal("6")))
            await db.flush()

            # No explicit currency → default = FIRST PRICED currency (SAR)
            s = await inventory_stats.product_stats(db, org.id, prod.id)
            assert s["display_currency"] == "SAR", s["display_currency"]
            assert s["priced_currencies"] == ["SAR", "USD"]
            assert abs(s["sales_total"] - 57.5) < 0.01, s["sales_total"]
            assert abs(s["profit"] - (10 + 6 * 3.75)) < 0.01, s["profit"]

            # Explicit USD → everything recomputed in USD
            s2 = await inventory_stats.product_stats(db, org.id, prod.id,
                                                     display_currency="USD")
            assert s2["display_currency"] == "USD"
            assert abs(s2["sales_total"] - 15.33) < 0.01, s2["sales_total"]
            assert abs(s2["profit"] - (10 * 0.2667 + 6)) < 0.01, s2["profit"]
            assert s2["sales_quantity"] == 7.0  # quantities NEVER convert

            # Period filter still works
            s3 = await inventory_stats.product_stats(db, org.id, prod.id,
                                                     date_from=date.today(),
                                                     date_to=date.today())
            assert s3["sales_count"] == 2
            print("PASS: stock 45 everywhere (details/list/falcon); stats "
                  "default=first priced ccy (SAR 57.5), USD recompute (15.33), "
                  "quantities untouched")

            # ── 3) Falcon PRODUCT analysis consistency (no fake zeros) ──
            # Stats page and Falcon product dataset MUST agree — the dataset
            # now carries the SAME unified keys (total_sales/…).
            st = await inventory_stats.product_stats(db, org.id, prod.id,
                                                     display_currency="SAR")
            fd, _t2 = await falcon_service._dataset(db, org.id, "product",
                                                    str(prod.id), "SAR")
            assert abs(st["sales_total"] - fd["total_sales"]) < 0.01, (
                st["sales_total"], fd["total_sales"])
            assert abs(st["profit"] - fd["total_profit"]) < 0.01
            assert fd["total_sales"] > 0  # NOT zeros
            assert fd["stock"] == 45

            # Full analyze() → non-empty report with REAL totals.
            rep = await falcon_service.analyze(db, org.id, "product",
                                               str(prod.id), "ar",
                                               report_currency="SAR")
            assert rep.get("stats", {}).get("total_sales", 0) > 0
            assert rep.get("status") in ("excellent", "good", "watch", "weak")
            print("DEBUG PAYLOAD:", rep.get("debug"))
            assert rep.get("debug", {}).get("sale_items_count", 0) == 2
            print("PASS: falcon product analysis matches stats (no fake "
                  "zeros); report built with debug counts")
        finally:
            await db.rollback()
    await engine.dispose()


asyncio.run(verify())