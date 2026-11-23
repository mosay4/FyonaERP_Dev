"""All-branches invoice list aggregation (no duplication, branch identity kept)."""
import asyncio, os, sys, uuid
from decimal import Decimal
from datetime import date
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from sqlalchemy import delete
from app.api.v1 import reconciliation as _R  # noqa: F401
from app.api.v1.invoices import _get_service
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.invoice_entities import Invoice
from app.domain.entities.sale_entities import Branch
from app.domain.services import branch_service as bsvc
PASS, FAIL = [], []
def check(n,c,e=""):
    (PASS if c else FAIL).append(n); print(("  ✓ " if c else "  ✗ ")+n+("" if c else f" {e}"))
async def main():
    tag=uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org=Organization(name=f"Iv {tag}", slug=f"iv-{tag}", subscription_plan="business")
        db.add(org); await db.flush()
        u=User(organization_id=org.id, full_name=f"O {tag}", email=f"iv{tag}@t.local", phone=f"+96773{tag}", role="owner")
        db.add(u); await db.flush()
        a=await bsvc.main_branch(db, org.id); b=await bsvc.create_branch(db, org.id, f"B {tag}")
        await db.commit()
    ids=[a.id,b.id]
    try:
        async with async_session_factory() as db:
            db.add_all([
                Invoice(organization_id=org.id, branch_id=a.id, invoice_number=f"A{tag}", invoice_type="sale", invoice_date=date.today(), status="confirmed", total=Decimal("10"), balance=Decimal("10"), currency="SAR"),
                Invoice(organization_id=org.id, branch_id=b.id, invoice_number=f"B{tag}", invoice_type="sale", invoice_date=date.today(), status="confirmed", total=Decimal("20"), balance=Decimal("20"), currency="SAR"),
            ])
            await db.commit()
        async with async_session_factory() as db:
            svc=_get_service(db)
            items,total=await svc.list_invoices(org.id, branch_ids=ids)
            branches={str(i.branch_id) for i in items}
            check("invoices from both branches", branches=={str(a.id),str(b.id)}, str(len(items)))
            check("no duplicates", len(items)==len({i.id for i in items}))
            one,_=await svc.list_invoices(org.id, branch_ids=[a.id])
            check("single branch isolated", all(str(i.branch_id)==str(a.id) for i in one))
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(Invoice).where(Invoice.organization_id==org.id))
            await db.execute(delete(Branch).where(Branch.organization_id==org.id))
            await db.execute(delete(User).where(User.id==u.id))
            await db.execute(delete(Organization).where(Organization.id==org.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL: print("FAILED:", FAIL); sys.exit(1)
asyncio.run(main())
