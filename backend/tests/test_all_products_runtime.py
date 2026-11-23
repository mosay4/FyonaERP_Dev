"""All-branches products list aggregation (identity preserved, no duplication)."""
import asyncio, os, sys, uuid
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from sqlalchemy import delete
from app.api.v1 import reconciliation as _R  # noqa: F401
from app.api.v1.business import _get_service
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.business_entities import Product
from app.domain.entities.sale_entities import Branch
from app.domain.models.business_models import ProductCreate
from app.domain.services import branch_service as bsvc
PASS, FAIL = [], []
def check(n,c,e=""):
    (PASS if c else FAIL).append(n); print(("  ✓ " if c else "  ✗ ")+n+("" if c else f" {e}"))
async def main():
    tag=uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org=Organization(name=f"Pr {tag}", slug=f"pr-{tag}", subscription_plan="business")
        db.add(org); await db.flush()
        u=User(organization_id=org.id, full_name=f"O {tag}", email=f"pr{tag}@t.local", phone=f"+96779{tag}", role="owner")
        db.add(u); await db.flush()
        main=await bsvc.main_branch(db, org.id); other=await bsvc.create_branch(db, org.id, f"B {tag}")
        await db.commit()
    mid,bid=main.id,other.id
    try:
        async with async_session_factory() as db:
            svc=_get_service(db)
            p1=await svc.create_product(org.id, ProductCreate(name=f"P1 {tag}", unit="قطعة"), branch_id=mid)
            p2=await svc.create_product(org.id, ProductCreate(name=f"P2 {tag}", unit="قطعة"), branch_id=bid)
            await db.commit()
            ids={str(p1.id),str(p2.id)}
        async with async_session_factory() as db:
            svc=_get_service(db)
            allp,total=await svc.list_products(org.id, branch_ids=[mid,bid])
            got={str(p.id) for p in allp}
            check("all-branches products include both", ids.issubset(got), str(len(got)))
            check("no duplicates", len(got)==len(allp))
            onep,_=await svc.list_products(org.id, branch_ids=[mid])
            check("single branch isolated", all(str(p.branch_id)==str(mid) for p in onep))
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(Product).where(Product.organization_id==org.id))
            await db.execute(delete(Branch).where(Branch.organization_id==org.id))
            await db.execute(delete(User).where(User.id==u.id))
            await db.execute(delete(Organization).where(Organization.id==org.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL: print("FAILED:", FAIL); sys.exit(1)
asyncio.run(main())
