"""Option A stock: legacy quantities stay on the main branch, new branches
start at zero, adjustments are isolated, and the all-branches view sums once."""

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
from app.domain.entities.business_entities import Product  # noqa: E402
from app.domain.entities.sale_entities import Branch, BranchStock  # noqa: E402
from app.domain.services import branch_service as bsvc  # noqa: E402
from app.domain.services import branch_stock_service as st  # noqa: E402

PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    tag = uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org = Organization(name=f"Stk {tag}", slug=f"stk-{tag}",
                           subscription_plan="business")
        db.add(org); await db.flush()
        u = User(organization_id=org.id, full_name=f"O {tag}",
                 email=f"s{tag}@t.local", phone=f"+96774{tag}", role="owner")
        p = Product(organization_id=org.id, name=f"P {tag}", stock=Decimal("100"),
                    cost_price=Decimal("4"))
        db.add_all([u, p]); await db.commit()
    main_id = b_id = None
    try:
        async with async_session_factory() as db:
            main = await bsvc.main_branch(db, org.id)
            other = await bsvc.create_branch(db, org.id, f"B {tag}")
            main_id, b_id = main.id, other.id
            # simulate the migration row for this product on the MAIN branch
            db.add(BranchStock(organization_id=org.id, branch_id=main_id,
                               product_id=p.id, quantity=Decimal("100"),
                               avg_cost=Decimal("4")))
            await db.commit()
        async with async_session_factory() as db:
            q, a = await st.get_stock(db, b_id, p.id)
            check("new branch starts at zero", q == 0 and a == 0, f"{q}/{a}")
            await st.adjust_stock(db, org.id, b_id, p.id, Decimal("10"),
                                  Decimal("5"))
            await st.adjust_stock(db, org.id, b_id, p.id, Decimal("10"),
                                  Decimal("7"))
            await db.commit()
        async with async_session_factory() as db:
            q, a = await st.get_stock(db, b_id, p.id)
            check("branch B qty 20", q == Decimal("20.000"), str(q))
            check("weighted avg cost = 6", abs(a - Decimal("6")) < Decimal("0.0001"),
                  str(a))
            mq, ma = await st.get_stock(db, main_id, p.id)
            check("main branch unchanged (100 @4)",
                  mq == Decimal("100.000") and ma == Decimal("4"), f"{mq}/{ma}")
            tot_q, tot_v = await st.aggregate_all(db, org.id, p.id)
            check("all-branches qty = 120", tot_q == Decimal("120.000"), str(tot_q))
            check("all-branches value = 520",
                  abs(tot_v - Decimal("520")) < Decimal("0.01"), str(tot_v))
            await st.adjust_stock(db, org.id, b_id, p.id, Decimal("-5"))
            await db.commit()
        async with async_session_factory() as db:
            q, a = await st.get_stock(db, b_id, p.id)
            check("issue keeps avg, qty 15",
                  q == Decimal("15.000") and abs(a - Decimal("6")) < Decimal("0.0001"),
                  f"{q}/{a}")
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(BranchStock).where(
                BranchStock.organization_id == org.id))
            await db.execute(delete(Product).where(Product.organization_id == org.id))
            await db.execute(delete(Branch).where(Branch.organization_id == org.id))
            await db.execute(delete(User).where(User.id == u.id))
            await db.execute(delete(Organization).where(Organization.id == org.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL); sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
