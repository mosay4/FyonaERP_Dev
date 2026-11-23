"""All-branches read aggregation (customers/suppliers) across active branches."""

import asyncio, os, sys, uuid
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from sqlalchemy import delete
from app.api.v1 import reconciliation as _R  # noqa: F401
from app.api.v1.business import _get_service
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.business_entities import Customer, Supplier
from app.domain.entities.sale_entities import Branch
from app.domain.models.business_models import CustomerCreate, SupplierCreate
from app.domain.services import branch_service as bsvc

PASS, FAIL = [], []
def check(n,c,e=""):
    (PASS if c else FAIL).append(n); print(("  ✓ " if c else "  ✗ ")+n+("" if c else f" {e}"))

async def main():
    tag=uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org=Organization(name=f"All {tag}", slug=f"all-{tag}", subscription_plan="business")
        db.add(org); await db.flush()
        u=User(organization_id=org.id, full_name=f"O {tag}", email=f"al{tag}@t.local", phone=f"+96778{tag}", role="owner")
        db.add(u); await db.flush()
        main=await bsvc.main_branch(db, org.id)
        other=await bsvc.create_branch(db, org.id, f"B {tag}")
        await db.commit()
    mid, bid = main.id, other.id
    try:
        async with async_session_factory() as db:
            svc=_get_service(db)
            c1=await svc.create_customer(org.id, CustomerCreate(name=f"C1 {tag}"), branch_id=mid)
            c2=await svc.create_customer(org.id, CustomerCreate(name=f"C2 {tag}"), branch_id=bid)
            s1=await svc.create_supplier(org.id, SupplierCreate(name=f"S1 {tag}"), branch_id=mid)
            s2=await svc.create_supplier(org.id, SupplierCreate(name=f"S2 {tag}"), branch_id=bid)
            await db.commit()
            ids={str(c1.id), str(c2.id)}
        async with async_session_factory() as db:
            svc=_get_service(db)
            allc,_=await svc.list_customers(org.id, branch_ids=[mid,bid])
            names={str(c.id) for c in allc}
            check("all-branches customers include both", ids.issubset(names), str(len(names)))
            check("no duplicate customer rows", len(names)==len(allc))
            one,_=await svc.list_customers(org.id, branch_ids=[mid])
            check("single branch stays isolated", all(str(c.branch_id)==str(mid) for c in one))
            alls,_=await svc.list_suppliers(org.id, branch_ids=[mid,bid])
            check("all-branches suppliers include both", len({str(s.branch_id) for s in alls})==2)
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(Customer).where(Customer.organization_id==org.id))
            await db.execute(delete(Supplier).where(Supplier.organization_id==org.id))
            await db.execute(delete(Branch).where(Branch.organization_id==org.id))
            await db.execute(delete(User).where(User.id==u.id))
            await db.execute(delete(Organization).where(Organization.id==org.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL: print("FAILED:", FAIL); sys.exit(1)

asyncio.run(main())
