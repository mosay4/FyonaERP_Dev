"""Expenses are per-branch: lists filtered and cross-branch get/update/delete 404."""

import asyncio, os, sys, uuid
from decimal import Decimal
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from sqlalchemy import delete
from app.api.v1 import finance as F
from app.api.v1 import reconciliation as _R  # noqa: F401
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.finance_entities import Expense
from app.domain.entities.sale_entities import Branch
from app.domain.models.finance_models import ExpenseCreate
from app.domain.services import branch_service as bsvc

PASS, FAIL = [], []
def check(n,c,e=""):
    (PASS if c else FAIL).append(n); print(("  ✓ " if c else "  ✗ ")+n+("" if c else f" {e}"))

async def main():
    tag=uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org=Organization(name=f"Ex {tag}", slug=f"ex-{tag}", subscription_plan="business")
        db.add(org); await db.flush()
        u=User(organization_id=org.id, full_name=f"O {tag}", email=f"ex{tag}@t.local", phone=f"+96777{tag}", role="owner")
        db.add(u); await db.flush()
        main=await bsvc.main_branch(db, org.id)
        other=await bsvc.create_branch(db, org.id, f"B {tag}")
        await db.commit()
    oid=str(org.id); mid=main.id; bid=other.id
    try:
        async with async_session_factory() as db:
            e1=await F.create_expense(ExpenseCreate(category="A", amount=Decimal("10")), oid, main, db, True)
            e2=await F.create_expense(ExpenseCreate(category="B", amount=Decimal("20")), oid, other, db, True)
            await db.commit()
            e1_id=e1["id"]; e2_id=e2["id"]
        async with async_session_factory() as db:
            la=await F.list_expenses(1, 50, oid, main, db, True)
            lb=await F.list_expenses(1, 50, oid, other, db, True)
            check("branch A list only A", all(str(x["id"])!=str(e2_id) for x in la), str(len(la)))
            check("branch B list only B", all(str(x["id"])!=str(e1_id) for x in lb), str(len(lb)))
            for fn,label in ((lambda: F.get_expense(e2_id, oid, main, db, True),"get"),
                             (lambda: F.update_expense(e2_id, ExpenseCreate(category="X", amount=Decimal("1")), oid, main, db, True),"update"),
                             (lambda: F.delete_expense(e2_id, oid, main, db, True),"delete")):
                try:
                    await fn(); check(f"cross-branch {label} rejected", False)
                except Exception:
                    check(f"cross-branch {label} rejected", True)
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(Expense).where(Expense.organization_id==org.id))
            await db.execute(delete(Branch).where(Branch.organization_id==org.id))
            await db.execute(delete(User).where(User.id==u.id))
            await db.execute(delete(Organization).where(Organization.id==org.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL: print("FAILED:", FAIL); sys.exit(1)

asyncio.run(main())
