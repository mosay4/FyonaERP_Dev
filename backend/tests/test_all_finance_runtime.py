"""All-branches aggregation for expenses, financial payments and journal."""
import asyncio, os, sys, uuid
from decimal import Decimal
from types import SimpleNamespace
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from sqlalchemy import delete
from app.api.v1 import finance as F
from app.api.v1 import accounting as A
from app.api.v1 import reconciliation as _R  # noqa: F401
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.finance_entities import Expense, FinancialPayment
from app.domain.entities.accounting_entities import JournalEntry
from app.domain.entities.sale_entities import Branch
from app.domain.services import branch_service as bsvc
PASS, FAIL = [], []
def check(n,c,e=""):
    (PASS if c else FAIL).append(n); print(("  ✓ " if c else "  ✗ ")+n+("" if c else f" {e}"))
async def main():
    tag=uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org=Organization(name=f"Fin {tag}", slug=f"fn-{tag}", subscription_plan="business")
        db.add(org); await db.flush()
        u=User(organization_id=org.id, full_name=f"O {tag}", email=f"fn{tag}@t.local", phone=f"+96772{tag}", role="owner")
        db.add(u); await db.flush()
        a=await bsvc.main_branch(db, org.id); b=await bsvc.create_branch(db, org.id, f"B {tag}")
        await db.commit()
    ids=[a.id,b.id]
    try:
        async with async_session_factory() as db:
            db.add_all([
                Expense(organization_id=org.id, branch_id=a.id, expense_no=f"E1{tag}", amount=Decimal("10")),
                Expense(organization_id=org.id, branch_id=b.id, expense_no=f"E2{tag}", amount=Decimal("20")),
                FinancialPayment(organization_id=org.id, branch_id=a.id, payment_no=f"P1{tag}", amount=Decimal("5")),
                FinancialPayment(organization_id=org.id, branch_id=b.id, payment_no=f"P2{tag}", amount=Decimal("6")),
                JournalEntry(organization_id=org.id, branch_id=a.id, entry_number=f"J1{tag}", description="A", status="draft"),
                JournalEntry(organization_id=org.id, branch_id=b.id, entry_number=f"J2{tag}", description="B", status="draft"),
            ])
            await db.commit()
        scope=SimpleNamespace(all_mode=True, branch_id=None, branch_ids=ids)
        async with async_session_factory() as db:
            ex=await F.list_expenses(1, 50, str(org.id), scope, db, True)
            pay=await F.list_payments(1, 50, str(org.id), scope, db, True)
            check("expenses from both branches", {str(x['branch_id']) for x in ex}=={str(a.id),str(b.id)}, str(len(ex)))
            check("payments from both branches", {str(x['branch_id']) for x in pay}=={str(a.id),str(b.id)}, str(len(pay)))
            items,total=await A._svc(db).list_journal_entries(org.id, 1, 20, None, ids)
            check("journal from both branches", {str(i.branch_id) for i in items}=={str(a.id),str(b.id)}, str(len(items)))
        scope1=SimpleNamespace(all_mode=False, branch_id=a.id, branch_ids=[a.id])
        async with async_session_factory() as db:
            ex=await F.list_expenses(1, 50, str(org.id), scope1, db, True)
            check("single branch expenses isolated", all(str(x['branch_id'])==str(a.id) for x in ex))
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(Expense).where(Expense.organization_id==org.id))
            await db.execute(delete(FinancialPayment).where(FinancialPayment.organization_id==org.id))
            await db.execute(delete(JournalEntry).where(JournalEntry.organization_id==org.id))
            await db.execute(delete(Branch).where(Branch.organization_id==org.id))
            await db.execute(delete(User).where(User.id==u.id))
            await db.execute(delete(Organization).where(Organization.id==org.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL: print("FAILED:", FAIL); sys.exit(1)
asyncio.run(main())
