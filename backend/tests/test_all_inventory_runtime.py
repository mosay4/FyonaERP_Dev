"""All-branches stock/cost come from branch_stock (never Product.stock twice)."""
import asyncio, os, sys, uuid
from decimal import Decimal
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from sqlalchemy import delete
from app.api.v1 import reconciliation as _R  # noqa: F401
from app.api.v1.business import _get_service
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.business_entities import Product
from app.domain.entities.sale_entities import Branch, BranchStock
from app.domain.models.business_models import ProductCreate
from app.domain.services import branch_service as bsvc
PASS, FAIL = [], []
def check(n,c,e=""):
    (PASS if c else FAIL).append(n); print(("  ✓ " if c else "  ✗ ")+n+("" if c else f" {e}"))
async def main():
    tag=uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org=Organization(name=f"Inv {tag}", slug=f"iv-{tag}", subscription_plan="business")
        db.add(org); await db.flush()
        u=User(organization_id=org.id, full_name=f"O {tag}", email=f"iv{tag}@t.local", phone=f"+96770{tag}", role="owner")
        db.add(u); await db.flush()
        main=await bsvc.main_branch(db, org.id); other=await bsvc.create_branch(db, org.id, f"B {tag}")
        await db.commit()
    mid,bid=main.id,other.id
    try:
        async with async_session_factory() as db:
            svc=_get_service(db)
            p1=await svc.create_product(org.id, ProductCreate(name=f"P1 {tag}", unit="قطعة", stock=999, cost_price=Decimal("99")), branch_id=mid)
            p2=await svc.create_product(org.id, ProductCreate(name=f"P2 {tag}", unit="قطعة"), branch_id=bid)
            db.add_all([
                BranchStock(organization_id=org.id, branch_id=mid, product_id=p1.id, quantity=Decimal("10"), avg_cost=Decimal("5")),
                BranchStock(organization_id=org.id, branch_id=bid, product_id=p2.id, quantity=Decimal("4"), avg_cost=Decimal("7")),
            ])
            await db.commit()
            p1id,p2id=p1.id,p2.id
        async with async_session_factory() as db:
            svc=_get_service(db)
            rows,_=await svc.list_products(org.id, branch_ids=[mid,bid])
            by={str(p.id):p for p in rows}
            check("p1 stock from branch_stock (10, not 999)", float(by[str(p1id)].stock)==10.0, str(by[str(p1id)].stock))
            check("p1 avg cost 5", float(by[str(p1id)].cost_price)==5.0, str(by[str(p1id)].cost_price))
            check("p2 stock 4 / cost 7", float(by[str(p2id)].stock)==4.0 and float(by[str(p2id)].cost_price)==7.0)
            one,_=await svc.list_products(org.id, branch_ids=[mid])
            check("single branch stock 10", float(one[0].stock)==10.0, str(one[0].stock))
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(BranchStock).where(BranchStock.organization_id==org.id))
            await db.execute(delete(Product).where(Product.organization_id==org.id))
            await db.execute(delete(Branch).where(Branch.organization_id==org.id))
            await db.execute(delete(User).where(User.id==u.id))
            await db.execute(delete(Organization).where(Organization.id==org.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL: print("FAILED:", FAIL); sys.exit(1)
asyncio.run(main())
