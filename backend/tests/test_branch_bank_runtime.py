"""Bank accounts are per-branch: lists are filtered, and another branch's
account cannot be read/deposited into (404)."""

import asyncio, os, sys, uuid
from types import SimpleNamespace
from decimal import Decimal
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from sqlalchemy import delete
from app.api.v1 import finance as F
from app.api.v1 import reconciliation as _R  # noqa: F401
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.finance_entities import BankAccount, BankTransaction
from app.domain.entities.sale_entities import Branch
from app.domain.models.finance_models import BankAccountCreate, AmountRequest
from app.domain.services import branch_service as bsvc

PASS, FAIL = [], []
def check(n, c, e=""):
    (PASS if c else FAIL).append(n); print(("  ✓ " if c else "  ✗ ")+n+("" if c else f" {e}"))

async def main():
    tag=uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org=Organization(name=f"Bk {tag}", slug=f"bk-{tag}", subscription_plan="business")
        db.add(org); await db.flush()
        u=User(organization_id=org.id, full_name=f"O {tag}", email=f"bk{tag}@t.local", phone=f"+96776{tag}", role="owner")
        db.add(u); await db.flush()
        main=await bsvc.main_branch(db, org.id)
        other=await bsvc.create_branch(db, org.id, f"B {tag}")
        await db.commit()
    oid=str(org.id); mid=main.id; bid=other.id
    try:
        async with async_session_factory() as db:
            a1=await F.create_bank_account(BankAccountCreate(bank_name=f"A {tag}", account_name="A", account_number="1", currency="SAR", balance=Decimal("10")), oid, main, db, True)
            a2=await F.create_bank_account(BankAccountCreate(bank_name=f"B {tag}", account_name="B", account_number="2", currency="USD", balance=Decimal("5")), oid, other, db, True)
            await db.commit()
            a1_id=a1["id"]; a2_id=a2["id"]
        async with async_session_factory() as db:
            la=await F.list_bank_accounts(oid, SimpleNamespace(all_mode=False, branch_id=mid, branch_ids=[mid]), db, True)
            lb=await F.list_bank_accounts(oid, SimpleNamespace(all_mode=False, branch_id=bid, branch_ids=[bid]), db, True)
            check("branch A list only A accounts", all(str(x["branch_id"]) == str(mid) for x in la), str(len(la)))
            check("branch B list only B accounts", all(str(x["branch_id"]) == str(bid) for x in lb), str(len(lb)))
            check("A account not in B list", all(str(x["id"]) != str(a1_id) for x in lb))
            try:
                await F.get_bank_account(a1_id, oid, other, db, True)
                check("cross-branch get rejected", False)
            except Exception:
                check("cross-branch get rejected", True)
            try:
                await F.deposit(a1_id, AmountRequest(amount=Decimal("1")), oid, other, db, True)
                check("cross-branch deposit rejected", False)
            except Exception:
                check("cross-branch deposit rejected", True)
    finally:
        async with async_session_factory() as db:
            ids=(await db.execute(__import__('sqlalchemy').select(BankAccount.id).where(BankAccount.organization_id==org.id))).scalars().all()
            if ids:
                await db.execute(delete(BankTransaction).where(BankTransaction.bank_account_id.in_(ids)))
            await db.execute(delete(BankAccount).where(BankAccount.organization_id==org.id))
            await db.execute(delete(Branch).where(Branch.organization_id==org.id))
            await db.execute(delete(User).where(User.id==u.id))
            await db.execute(delete(Organization).where(Organization.id==org.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL: print("FAILED:", FAIL); sys.exit(1)

asyncio.run(main())
