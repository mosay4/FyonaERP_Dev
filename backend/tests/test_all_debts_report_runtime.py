"""All-branches debts report: receivables from two branches, no duplication/leak."""
import asyncio, os, sys, uuid
from decimal import Decimal
from datetime import date, datetime, timezone
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from sqlalchemy import delete
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.business_entities import Customer
from app.domain.entities.invoice_entities import Invoice
from app.domain.entities.sale_entities import Branch, CustomerReceivable
from app.domain.services import branch_service as bsvc
from app.domain.services import business_reports_service as svc
PASS, FAIL = [], []
def check(n,c,e=""):
    (PASS if c else FAIL).append(n); print(("  ✓ " if c else "  ✗ ")+n+("" if c else f" {e}"))
async def main():
    tag=uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org=Organization(name=f"Db {tag}", slug=f"db-{tag}", subscription_plan="business")
        db.add(org); await db.flush()
        u=User(organization_id=org.id, full_name=f"O {tag}", email=f"db{tag}@t.local", phone=f"+96775{tag}", role="owner")
        c1=Customer(organization_id=org.id, name=f"C1 {tag}")
        c2=Customer(organization_id=org.id, name=f"C2 {tag}")
        db.add_all([u,c1,c2]); await db.flush()
        a=await bsvc.main_branch(db, org.id); b=await bsvc.create_branch(db, org.id, f"B {tag}")
        i1=Invoice(organization_id=org.id, branch_id=a.id, customer_id=c1.id, invoice_number=f"D1{tag}", invoice_type="sale", invoice_date=date.today(), status="confirmed", total=Decimal("100"), balance=Decimal("100"), currency="SAR")
        i2=Invoice(organization_id=org.id, branch_id=b.id, customer_id=c2.id, invoice_number=f"D2{tag}", invoice_type="sale", invoice_date=date.today(), status="confirmed", total=Decimal("50"), balance=Decimal("50"), currency="SAR")
        db.add_all([i1,i2]); await db.flush()
        db.add_all([
            CustomerReceivable(organization_id=org.id, customer_id=c1.id, invoice_id=i1.id, amount=Decimal("100"), paid=Decimal("0"), status="open"),
            CustomerReceivable(organization_id=org.id, customer_id=c2.id, invoice_id=i2.id, amount=Decimal("50"), paid=Decimal("0"), status="open"),
        ])
        await db.commit()
    now=datetime.now(timezone.utc)
    try:
        async with async_session_factory() as db:
            both=await svc.debts_report_data(db, org.id, now, now, "SAR", [a.id,b.id])
            check("both branches receivable total", abs(float(both["customers"]["total"])-150.0)<0.01, str(both["customers"]))
            one=await svc.debts_report_data(db, org.id, now, now, "SAR", [a.id])
            check("branch A only", abs(float(one["customers"]["total"])-100.0)<0.01, str(one["customers"]))
            other=await svc.debts_report_data(db, org.id, now, now, "SAR", [b.id])
            check("branch B only", abs(float(other["customers"]["total"])-50.0)<0.01, str(other["customers"]))
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(CustomerReceivable).where(CustomerReceivable.organization_id==org.id))
            await db.execute(delete(Invoice).where(Invoice.organization_id==org.id))
            await db.execute(delete(Customer).where(Customer.organization_id==org.id))
            await db.execute(delete(Branch).where(Branch.organization_id==org.id))
            await db.execute(delete(User).where(User.id==u.id))
            await db.execute(delete(Organization).where(Organization.id==org.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL: print("FAILED:", FAIL); sys.exit(1)
asyncio.run(main())
