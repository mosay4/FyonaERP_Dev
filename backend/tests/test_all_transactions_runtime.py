"""All-branches unified transactions timeline: both branches, no duplicates, isolated."""
import asyncio, os, sys, uuid
from decimal import Decimal
from datetime import date
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from sqlalchemy import delete
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.invoice_entities import Invoice
from app.domain.entities.finance_entities import Expense
from app.domain.entities.sale_entities import Branch
from app.domain.services import branch_service as bsvc
from app.domain.services import business_transactions_service as svc
PASS, FAIL = [], []
def check(n,c,e=""):
    (PASS if c else FAIL).append(n); print(("  ✓ " if c else "  ✗ ")+n+("" if c else f" {e}"))
async def main():
    tag=uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org=Organization(name=f"Tx {tag}", slug=f"tx-{tag}", subscription_plan="business")
        db.add(org); await db.flush()
        u=User(organization_id=org.id, full_name=f"O {tag}", email=f"tx{tag}@t.local", phone=f"+96774{tag}", role="owner")
        db.add(u); await db.flush()
        a=await bsvc.main_branch(db, org.id); b=await bsvc.create_branch(db, org.id, f"B {tag}")
        await db.commit()
    ids=[a.id,b.id]
    try:
        async with async_session_factory() as db:
            db.add_all([
                Invoice(organization_id=org.id, branch_id=a.id, invoice_number=f"T1{tag}", invoice_type="sale", invoice_date=date.today(), status="confirmed", total=Decimal("10"), balance=Decimal("10"), currency="SAR"),
                Invoice(organization_id=org.id, branch_id=b.id, invoice_number=f"T2{tag}", invoice_type="purchase", invoice_date=date.today(), status="confirmed", total=Decimal("20"), balance=Decimal("20"), currency="SAR"),
                Expense(organization_id=org.id, branch_id=a.id, expense_no=f"E1{tag}", category="general", description="x", amount=Decimal("5"), expense_date=date.today(), payment_method="cash"),
                Expense(organization_id=org.id, branch_id=b.id, expense_no=f"E2{tag}", category="general", description="y", amount=Decimal("7"), expense_date=date.today(), payment_method="cash"),
            ])
            await db.commit()
        async with async_session_factory() as db:
            both=await svc.list_transactions(db, org.id, branch_ids=ids, per_page=100)
            refs={r.get("reference") for r in both["items"]}
            check("sale+purchase from both branches", {f"T1{tag}",f"T2{tag}"} <= refs, str(refs))
            ids_seen=[r.get("source_id") for r in both["items"]]
            check("no duplicate rows", len(ids_seen)==len(set(ids_seen)))
            one=await svc.list_transactions(db, org.id, branch_ids=[a.id], per_page=100)
            refs1={r.get("reference") for r in one["items"]}
            check("single branch isolated", f"T1{tag}" in refs1 and f"T2{tag}" not in refs1 and f"E2{tag}" not in refs1, str(refs1))
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(Expense).where(Expense.organization_id==org.id))
            await db.execute(delete(Invoice).where(Invoice.organization_id==org.id))
            await db.execute(delete(Branch).where(Branch.organization_id==org.id))
            await db.execute(delete(User).where(User.id==u.id))
            await db.execute(delete(Organization).where(Organization.id==org.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL: print("FAILED:", FAIL); sys.exit(1)
asyncio.run(main())
