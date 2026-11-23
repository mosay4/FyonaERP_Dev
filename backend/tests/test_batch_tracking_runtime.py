"""Purchase batches → FIFO sales → returns: real lot tracking end-to-end.
Covers the mandatory scenarios (3 batches different prices/currencies, sell
from one lot, sell across two lots, return restores, no double conversion).
"""

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
    SaleIssuePayment,
    SaleIssueRequest,
    SaleReturnLine,
    SaleReturnRequest,
)
from app.domain.services import sale_service  # noqa: E402

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
            organization_id=ORG, name=f"BATCH-{tag}", unit="قطعة",
            price=Decimal("10"), cost_price=Decimal("5"), stock=Decimal("0"),
        )
        db.add(prod)
        await db.flush()
        pid = prod.id
        db.add(ProductUnit(
            organization_id=ORG, product_id=pid, name="قطعة",
            factor=Decimal("1"), is_base=True, group="count"))
        db.add(Supplier(organization_id=ORG, name=f"SUP-{tag}"))
        await db.flush()
        sup_id = (await db.execute(select(Supplier).where(
            Supplier.organization_id == ORG,
            Supplier.name == f"SUP-{tag}"))).scalar_one().id
        db.add(Customer(organization_id=ORG, name=f"CUS-{tag}"))
        await db.flush()
        cus_id = (await db.execute(select(Customer).where(
            Customer.organization_id == ORG,
            Customer.name == f"CUS-{tag}"))).scalar_one().id
        await db.commit()

    inv_ids, lot_ids = [], []

    async def buy(qty, price, ccy):
        async with async_session_factory() as db:
            r = await sale_service.issue_purchase(
                db, ORG, user_id,
                PurchaseIssueRequest(
                    supplier_id=sup_id,
                    currency=ccy,
                    items=[PurchaseIssueLine(
                        product_id=pid, description="", quantity=qty,
                        unit_price=Decimal(str(price)))],
                ))
            iid = UUID(str(r["id"] if isinstance(r.get("id"), str)
                           else r["id"]))
            inv_ids.append(iid)
            lots = (await db.execute(select(InventoryLot).where(
                InventoryLot.product_id == pid).order_by(
                    InventoryLot.created_at.asc()))).scalars().all()
            return iid, lots

    async def stock():
        async with async_session_factory() as db:
            p = (await db.execute(
                select(Product).where(Product.id == pid))).scalar_one()
            return float(p.stock)

    try:
        # 3 purchases, different prices/currencies (debt, no cash movement)
        await buy(100, 5, "SAR")
        await buy(100, 6, "USD")
        await buy(100, 7, "SAR")
        check("stock is 300 after 3 batches", await stock() == 300.0)
        async with async_session_factory() as db:
            lots = (await db.execute(select(InventoryLot).where(
                InventoryLot.product_id == pid).order_by(
                    InventoryLot.created_at.asc()))).scalars().all()
            lot_ids = [l.id for l in lots]
            check("3 independent lots exist", len(lots) == 3,
                  f"got {len(lots)}")
            check("lot costs/currencies preserved",
                  float(lots[0].unit_cost) == 5.0 and lots[0].currency == "SAR"
                  and float(lots[1].unit_cost) == 6.0 and lots[1].currency == "USD"
                  and float(lots[2].unit_cost) == 7.0 and lots[2].currency == "SAR")

        # Sell 50 (one lot, FIFO → lot 1) in SAR
        async with async_session_factory() as db:
            r = await sale_service.issue_sale(
                db, ORG, user_id,
                SaleIssueRequest(
                    customer_id=cus_id,
                    currency="SAR",
                    items=[SaleIssueLine(
                        product_id=pid, description="", quantity=50,
                        unit_price=Decimal("12"))],
                ))
            sale1 = UUID(str(r["id"]))
            inv_ids.append(sale1)
            cons = (await db.execute(select(InventoryLotConsumption).where(
                InventoryLotConsumption.invoice_item_id.in_(
                    select(InvoiceItem.id).where(
                        InvoiceItem.invoice_id == sale1))))).scalars().all()
            check("50 sold from lot 1 only",
                  len(cons) == 1 and cons[0].lot_id == lot_ids[0]
                  and float(cons[0].quantity) == 50.0,
                  f"{[(str(c.lot_id)[:8], c.quantity) for c in cons]}")
            check("stock 300 → 250", await stock() == 250.0)
            lots = (await db.execute(select(InventoryLot).where(
                InventoryLot.product_id == pid).order_by(
                    InventoryLot.created_at.asc()))).scalars().all()
            check("lot 1 remaining 50, lots 2-3 untouched",
                  float(lots[0].remaining_quantity) == 50.0
                  and float(lots[1].remaining_quantity) == 100.0)

        # Sell 150 → spans lot 1 (50 left) + lot 2 (100)
        async with async_session_factory() as db:
            r = await sale_service.issue_sale(
                db, ORG, user_id,
                SaleIssueRequest(
                    customer_id=cus_id,
                    currency="SAR",
                    items=[SaleIssueLine(
                        product_id=pid, description="", quantity=150,
                        unit_price=Decimal("12"))],
                ))
            sale2 = UUID(str(r["id"]))
            inv_ids.append(sale2)
            cons = (await db.execute(select(InventoryLotConsumption).where(
                InventoryLotConsumption.invoice_item_id.in_(
                    select(InvoiceItem.id).where(
                        InvoiceItem.invoice_id == sale2))))).scalars().all()
            by_lot = {c.lot_id: float(c.quantity) for c in cons}
            check("150 split 50 (lot1) + 100 (lot2)",
                  by_lot.get(lot_ids[0], 0) == 50.0
                  and by_lot.get(lot_ids[1], 0) == 100.0, str(by_lot))
            check("stock 250 → 100", await stock() == 100.0)

        # Return 20 from the second sale → back to the RIGHT lots
        async with async_session_factory() as db:
            items = (await db.execute(select(InvoiceItem).where(
                InvoiceItem.invoice_id == sale2))).scalars().all()
            await sale_service.confirm_return(
                db, ORG, user_id, sale2,
                SaleReturnRequest(lines=[SaleReturnLine(
                    invoice_item_id=items[0].id, quantity=20, restock=True)]))
            check("return restores stock 100 → 120",
                  await stock() == 120.0)
            lots = (await db.execute(select(InventoryLot).where(
                InventoryLot.product_id == pid).order_by(
                    InventoryLot.created_at.asc()))).scalars().all()
            # FIFO restore goes to the OLDEST open lot first (lot 2, since
            # lot 1 was fully consumed by the 150-sale).
            check("lots restored without duplication",
                  float(lots[0].remaining_quantity) == 0.0
                  and float(lots[1].remaining_quantity) == 20.0
                  and float(lots[2].remaining_quantity) == 100.0,
                  f"{[float(l.remaining_quantity) for l in lots]}")
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(InventoryLotConsumption).where(
                InventoryLotConsumption.lot_id.in_(lot_ids)))
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
