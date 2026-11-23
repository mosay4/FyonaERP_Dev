"""Real sale issuance on two branches: branch stock moves, main mirrors
Product.stock, other branches untouched, and insufficient branch stock blocks."""

import asyncio
import os
import sys
import uuid
from decimal import Decimal

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete, select  # noqa: E402
from app.api.v1 import reconciliation as _R  # noqa: E402,F401
from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import Organization, User  # noqa: E402
from app.domain.entities.business_entities import Customer, Product  # noqa: E402
from app.domain.entities.invoice_entities import Invoice, InvoiceItem  # noqa: E402
from app.domain.entities.sale_entities import (  # noqa: E402
    Branch, BranchStock, CustomerReceivable, ProductUnit)
from app.domain.models.invoice_models import (  # noqa: E402
    SaleIssueLine, SaleIssueRequest)
from app.domain.services import branch_service as bsvc  # noqa: E402
from app.domain.services import branch_stock_service as st  # noqa: E402
from app.domain.services import sale_service  # noqa: E402

PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    tag = uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org = Organization(name=f"Sale {tag}", slug=f"sl-{tag}",
                           subscription_plan="business")
        db.add(org); await db.flush()
        u = User(organization_id=org.id, full_name=f"O {tag}",
                 email=f"sl{tag}@t.local", phone=f"+96775{tag}", role="owner")
        c = Customer(organization_id=org.id, name=f"C {tag}")
        p = Product(organization_id=org.id, name=f"P {tag}", stock=Decimal("100"),
                    cost_price=Decimal("4"))
        db.add_all([u, c, p]); await db.flush()
        unit = ProductUnit(organization_id=org.id, product_id=p.id,
                           name="قطعة", factor=1, is_base=True,
                           sale_price=Decimal("10"), purchase_price=Decimal("4"))
        db.add(unit); await db.flush()
        main = await bsvc.main_branch(db, org.id)
        other = await bsvc.create_branch(db, org.id, f"B {tag}")
        db.add_all([
            BranchStock(organization_id=org.id, branch_id=main.id,
                        product_id=p.id, quantity=Decimal("100"),
                        avg_cost=Decimal("4")),
            BranchStock(organization_id=org.id, branch_id=other.id,
                        product_id=p.id, quantity=Decimal("50"),
                        avg_cost=Decimal("4")),
        ])
        await db.commit()
    main_id, b_id = main.id, other.id
    pid, cid, uid = p.id, c.id, u.id
    org_id = org.id
    try:
        async with async_session_factory() as db:
            await sale_service.issue_sale(
                db, org_id, uid,
                SaleIssueRequest(customer_id=cid, currency="SAR",
                                 branch_id=main_id,
                                 idempotency_key=f"s1-{tag}",
                                 items=[SaleIssueLine(product_id=pid,
                                                      quantity=3,
                                                      unit_price=Decimal("10"))]))
            await db.commit()
        async with async_session_factory() as db:
            mq, _ = await st.get_stock(db, main_id, pid)
            bq, _ = await st.get_stock(db, b_id, pid)
            pr = (await db.execute(select(Product).where(Product.id == pid))).scalar_one()
            check("main branch 100→97", mq == Decimal("97.000"), str(mq))
            check("other branch untouched (50)", bq == Decimal("50.000"), str(bq))
            check("Product.stock mirrors main (97)", float(pr.stock) == 97.0,
                  str(pr.stock))
        async with async_session_factory() as db:
            await sale_service.issue_sale(
                db, org_id, uid,
                SaleIssueRequest(customer_id=cid, currency="SAR",
                                 branch_id=b_id,
                                 idempotency_key=f"s2-{tag}",
                                 items=[SaleIssueLine(product_id=pid,
                                                      quantity=2,
                                                      unit_price=Decimal("10"))]))
            await db.commit()
        async with async_session_factory() as db:
            mq, _ = await st.get_stock(db, main_id, pid)
            bq, _ = await st.get_stock(db, b_id, pid)
            pr = (await db.execute(select(Product).where(Product.id == pid))).scalar_one()
            check("branch B 50→48", bq == Decimal("48.000"), str(bq))
            check("main stays 97", mq == Decimal("97.000"), str(mq))
            check("Product.stock still 97 (not changed by B)",
                  float(pr.stock) == 97.0, str(pr.stock))
            total, _ = await st.aggregate_all(db, org_id, pid)
            check("all branches = 145", total == Decimal("145.000"), str(total))
        async with async_session_factory() as db:
            try:
                await sale_service.issue_sale(
                    db, org_id, uid,
                    SaleIssueRequest(customer_id=cid, currency="SAR",
                                     branch_id=b_id,
                                     idempotency_key=f"s3-{tag}",
                                     items=[SaleIssueLine(product_id=pid,
                                                          quantity=60,
                                                          unit_price=Decimal("10"))]))
                check("insufficient branch stock blocked", False)
            except ValueError as e:
                check("insufficient branch stock blocked",
                      "المخزون" in str(e), str(e))
                await db.rollback()
        async with async_session_factory() as db:
            pr = (await db.execute(select(Product).where(Product.id == pid))).scalar_one()
            pr.branch_id = main_id
            await db.commit()
        async with async_session_factory() as db:
            try:
                await sale_service.issue_sale(
                    db, org_id, uid,
                    SaleIssueRequest(customer_id=cid, currency="SAR",
                                     branch_id=b_id,
                                     idempotency_key=f"s4-{tag}",
                                     items=[SaleIssueLine(product_id=pid,
                                                          quantity=1,
                                                          unit_price=Decimal("10"))]))
                check("product of another branch rejected", False)
            except ValueError as e:
                check("product of another branch rejected",
                      "فرع آخر" in str(e), str(e))
                await db.rollback()
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(CustomerReceivable).where(
                CustomerReceivable.organization_id == org_id))
            await db.execute(delete(InvoiceItem).where(
                InvoiceItem.invoice_id.in_(select(Invoice.id).where(
                    Invoice.organization_id == org_id))))
            await db.execute(delete(Invoice).where(Invoice.organization_id == org_id))
            await db.execute(delete(BranchStock).where(
                BranchStock.organization_id == org_id))
            await db.execute(delete(ProductUnit).where(
                ProductUnit.organization_id == org_id))
            await db.execute(delete(Product).where(Product.organization_id == org_id))
            await db.execute(delete(Customer).where(Customer.organization_id == org_id))
            await db.execute(delete(Branch).where(Branch.organization_id == org_id))
            await db.execute(delete(User).where(User.id == uid))
            await db.execute(delete(Organization).where(Organization.id == org_id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL); sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
