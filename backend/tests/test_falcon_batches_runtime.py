"""Falcon batch analysis matches the REALLY saved lots + linked sales."""

import asyncio
import os
import sys
import uuid
from decimal import Decimal
from uuid import UUID

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete, select  # noqa: E402

from app.api.v1 import reconciliation as _R  # noqa: E402,F401 (entity graph)
from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import User  # noqa: E402
from app.domain.entities.business_entities import (  # noqa: E402
    Customer,
    InventoryMovement,
    Product,
    Supplier,
)
from app.domain.entities.invoice_entities import Invoice, InvoiceItem  # noqa: E402,F401
from app.domain.entities.sale_entities import (  # noqa: E402
    InventoryLot,
    InventoryLotConsumption,
    ProductUnit,
)
from app.domain.models.invoice_models import (  # noqa: E402
    PurchaseIssueLine,
    PurchaseIssueRequest,
    SaleIssueLine,
    SaleIssueRequest,
)
from app.domain.services import falcon_service, sale_service  # noqa: E402

ORG = UUID("d6c27bfb-9a8d-4535-8e43-f23787330cbe")
PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    tag = uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        user_id = (await db.execute(
            select(User.id).where(User.organization_id == ORG).limit(1)
        )).scalar_one()
        prod = Product(
            organization_id=ORG, name=f"FALCON-{tag}", unit="قطعة",
            price=Decimal("12"), cost_price=Decimal("5"), stock=Decimal("0"),
        )
        db.add(prod)
        await db.flush()
        pid = prod.id
        db.add(ProductUnit(
            organization_id=ORG, product_id=pid, name="قطعة",
            factor=Decimal("1"), is_base=True, group="count"))
        db.add(Supplier(organization_id=ORG, name=f"FSUP-{tag}"))
        db.add(Customer(organization_id=ORG, name=f"FCUS-{tag}"))
        await db.flush()
        sup_id = (await db.execute(select(Supplier).where(
            Supplier.organization_id == ORG,
            Supplier.name == f"FSUP-{tag}"))).scalar_one().id
        cus_id = (await db.execute(select(Customer).where(
            Customer.organization_id == ORG,
            Customer.name == f"FCUS-{tag}"))).scalar_one().id
        await db.commit()

    inv_ids = []
    try:
        # Two batches: 100 @ 5 SAR, then 100 @ 8 SAR (2nd is pricier).
        async with async_session_factory() as db:
            for qty, price in ((100, 5), (100, 8)):
                r = await sale_service.issue_purchase(
                    db, ORG, user_id,
                    PurchaseIssueRequest(
                        supplier_id=sup_id, currency="SAR",
                        items=[PurchaseIssueLine(
                            product_id=pid, description="", quantity=qty,
                            unit_price=Decimal(str(price)))]))
                inv_ids.append(UUID(str(r["id"])))
            # Sell 120 @ 12 SAR → 100 from lot 1 + 20 from lot 2.
            r = await sale_service.issue_sale(
                db, ORG, user_id,
                SaleIssueRequest(
                    customer_id=cus_id, currency="SAR",
                    items=[SaleIssueLine(
                        product_id=pid, description="", quantity=120,
                        unit_price=Decimal("12"))]))
            inv_ids.append(UUID(str(r["id"])))

            batches = await falcon_service._product_batches(
                db, ORG, pid, "SAR")
            check("Falcon sees 2 real batches", len(batches) == 2,
                  f"got {len(batches)}")
            b1 = [b for b in batches if b["n"] == 1][0]
            b2 = [b for b in batches if b["n"] == 2][0]
            check("batch 1 sold 100 @ cost 5",
                  b1["sold"] == 100.0 and b1["unit_cost"] == 5.0, str(b1))
            check("batch 2 sold 20 @ cost 8",
                  b2["sold"] == 20.0 and b2["unit_cost"] == 8.0, str(b2))
            # Revenue 120×12=1440; COGS 100×5+20×8=660; profit 780.
            # Lot 1 share: 100/120 of 1440=1200 rev, profit 1200-500=700.
            # Lot 2 share: 20/120 of 1440=240 rev, profit 240-160=80.
            check("batch profits apportioned from real sales",
                  abs(b1["profit"] - 700.0) < 1.0
                  and abs(b2["profit"] - 80.0) < 1.0,
                  f"b1={b1['profit']} b2={b2['profit']}")

            pts = falcon_service._attention_points(
                {"out": False, "loss": False, "low": False, "stagnant": False,
                 "sales": 1440, "margin": 0.5, "profit": 780, "stock": 80,
                 "min_stock": 0, "qty_sold": 120},
                "product",
                {"batches": batches},
                "SAR",
            )
            joined = " ".join(pts)
            check("attention compares most/least profitable batches",
                  "الدفعة 1" in joined and "الدفعة 2" in joined, joined[:200])
    finally:
        async with async_session_factory() as db:
            lots = (await db.execute(select(InventoryLot).where(
                InventoryLot.product_id == pid))).scalars().all()
            await db.execute(delete(InventoryLotConsumption).where(
                InventoryLotConsumption.lot_id.in_([l.id for l in lots])))
            await db.execute(delete(InventoryLot).where(
                InventoryLot.product_id == pid))
            await db.execute(delete(InvoiceItem).where(
                InvoiceItem.invoice_id.in_(inv_ids)))
            await db.execute(delete(Invoice).where(Invoice.id.in_(inv_ids)))
            await db.execute(delete(InventoryMovement).where(
                InventoryMovement.product_id == pid))
            await db.execute(delete(ProductUnit).where(
                ProductUnit.product_id == pid))
            await db.execute(delete(Product).where(Product.id == pid))
            await db.execute(delete(Supplier).where(Supplier.id == sup_id))
            await db.execute(delete(Customer).where(Customer.id == cus_id))
            await db.commit()

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
