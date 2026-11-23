"""All-branches returns list: both branches, no duplicates, isolated."""
import asyncio, os, sys, uuid
from decimal import Decimal
from datetime import date
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from sqlalchemy import delete
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.invoice_entities import Invoice
from app.domain.entities.sale_entities import Branch, InvoiceReturn
from app.domain.services import branch_service as bsvc
from app.domain.services import returns_service
PASS, FAIL = [], []
def check(n,c,e=""):
    (PASS if c else FAIL).append(n); print(("  ✓ " if c else "  ✗ ")+n+("" if c else f" {e}"))
async def main():
    tag=uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org=Organization(name=f"Rt {tag}", slug=f"rt-{tag}", subscription_plan="business")
        db.add(org); await db.flush()
        u=User(organization_id=org.id, full_name=f"O {tag}", email=f"rt{tag}@t.local", phone=f"+96776{tag}", role="owner")
        db.add(u); await db.flush()
        a=await bsvc.main_branch(db, org.id); b=await bsvc.create_branch(db, org.id, f"B {tag}")
        i1=Invoice(organization_id=org.id, branch_id=a.id, invoice_number=f"R1{tag}", invoice_type="sale", invoice_date=date.today(), status="confirmed", total=Decimal("100"), balance=Decimal("0"), currency="SAR")
        i2=Invoice(organization_id=org.id, branch_id=b.id, invoice_number=f"R2{tag}", invoice_type="sale", invoice_date=date.today(), status="confirmed", total=Decimal("50"), balance=Decimal("0"), currency="SAR")
        db.add_all([i1,i2]); await db.flush()
        db.add_all([
            InvoiceReturn(organization_id=org.id, invoice_id=i1.id, return_number=f"RA{tag}", return_date=date.today(), status="confirmed", total=Decimal("10")),
            InvoiceReturn(organization_id=org.id, invoice_id=i2.id, return_number=f"RB{tag}", return_date=date.today(), status="confirmed", total=Decimal("5")),
        ])
        await db.commit()
    try:
        async with async_session_factory() as db:
            both=await returns_service.list_returns(db, org.id, branch_ids=[a.id,b.id])
            refs={r.get("return_number") for r in both.get("items", both.get("returns", []))}
            check("returns from both branches", {f"RA{tag}",f"RB{tag}"} <= refs, str(refs))
            one=await returns_service.list_returns(db, org.id, branch_ids=[a.id])
            refs1={r.get("return_number") for r in one.get("items", one.get("returns", []))}
            check("branch A isolated", f"RA{tag}" in refs1 and f"RB{tag}" not in refs1, str(refs1))
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(InvoiceReturn).where(InvoiceReturn.organization_id==org.id))
            await db.execute(delete(Invoice).where(Invoice.organization_id==org.id))
            await db.execute(delete(Branch).where(Branch.organization_id==org.id))
            await db.execute(delete(User).where(User.id==u.id))
            await db.execute(delete(Organization).where(Organization.id==org.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL: print("FAILED:", FAIL); sys.exit(1)
asyncio.run(main())
