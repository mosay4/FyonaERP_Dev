"""All-branches bank view: one row per bank identity+currency, balances summed,
original accounts preserved, different currencies never mixed."""
import asyncio, os, sys, uuid, json
from decimal import Decimal
from types import SimpleNamespace
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from sqlalchemy import delete
from app.api.v1 import finance as F
from app.api.v1 import reconciliation as _R  # noqa: F401
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.finance_entities import BankAccount, BankTransaction
from app.domain.entities.sale_entities import Branch
from app.domain.services import branch_service as bsvc
PASS, FAIL = [], []
def check(n,c,e=""):
    (PASS if c else FAIL).append(n); print(("  ✓ " if c else "  ✗ ")+n+("" if c else f" {e}"))
async def main():
    tag=uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org=Organization(name=f"Bk {tag}", slug=f"bk-{tag}", subscription_plan="business")
        db.add(org); await db.flush()
        u=User(organization_id=org.id, full_name=f"O {tag}", email=f"bk{tag}@t.local", phone=f"+96771{tag}", role="owner")
        db.add(u); await db.flush()
        a=await bsvc.main_branch(db, org.id); b=await bsvc.create_branch(db, org.id, f"B {tag}"); c=await bsvc.create_branch(db, org.id, f"C {tag}")
        await db.commit()
    ids=[a.id,b.id,c.id]
    try:
        async with async_session_factory() as db:
            db.add_all([
                BankAccount(organization_id=org.id, branch_id=a.id, bank_name="جيب", account_name="A", account_number="1", iban="SA0380000000000000001", currency="SAR", balance=Decimal("100")),
                BankAccount(organization_id=org.id, branch_id=a.id, bank_name="جيب", account_name="A2", account_number="2", iban="SA0380000000000000002", currency="USD", balance=Decimal("20")),
                BankAccount(organization_id=org.id, branch_id=b.id, bank_name="جيب", account_name="B", account_number="3", iban="SA0380000000000000003", currency="SAR", balance=Decimal("50")),
                BankAccount(organization_id=org.id, branch_id=c.id, bank_name="الكريمي", account_name="C", account_number="4", iban="SA9980000000000000004", currency="SAR", balance=Decimal("30")),
                # Same display name, DIFFERENT IBAN bank code → must NOT merge.
                BankAccount(organization_id=org.id, branch_id=c.id, bank_name="جيب", account_name="C2", account_number="5", iban="SA4420000000000000005", currency="SAR", balance=Decimal("40")),
            ])
            await db.commit()
        async with async_session_factory() as db:
            scope=SimpleNamespace(all_mode=True, branch_id=None, branch_ids=ids)
            rows=await F.list_bank_accounts(str(org.id), scope, db, True)
            check("three identities incl. mandatory cash", len(rows)==3, str(len(rows)))
            geeb=[r for r in rows if r['bank_name']=='جيب']
            check("same-name bank grouped once", len(geeb)==1)
            curs=geeb[0]['currencies']
            check("SAR summed across branches 190 (no currency mixing)", Decimal(curs['SAR'])==Decimal('190'), str(curs))
            check("USD kept separate 20", Decimal(curs['USD'])==Decimal('20'), str(curs))
            check("all original accounts preserved", len(geeb[0]['accounts'])==4)
            linked=await F.link_bank_accounts(
                F.BankLinkRequest(account_ids=[__import__('uuid').UUID(str(x['id'])) for x in geeb[0]['accounts']]),
                str(org.id), scope, db, True)
            _lb=json.loads(linked.body); check("explicit link returns a stable key", _lb['data']['bank_group_key'].startswith('link:'), str(_lb))
            rows2=await F.list_bank_accounts(str(org.id), scope, db, True)
            check("confirmed link preserves groups", len(rows2)==3, str(len(rows2)))
            geeb2=[r for r in rows2 if r['bank_name']=='جيب'][0]
            check("linked balances preserved", Decimal(geeb2['currencies']['SAR'])==Decimal('190'), str(geeb2['currencies']))
            ids2=[__import__('uuid').UUID(str(x['id'])) for x in geeb2['accounts']]
            un=await F.unlink_bank_accounts(F.BankLinkRequest(account_ids=ids2), str(org.id), scope, db, True)
            check("unlink succeeds", json.loads(un.body)['success'] is True)
            rows3=await F.list_bank_accounts(str(org.id), scope, db, True)
            check("unlink restores name identities", len(rows3)==3, str(len(rows3)))
        async with async_session_factory() as db:
            scope=SimpleNamespace(all_mode=False, branch_id=a.id, branch_ids=[a.id])
            rows=await F.list_bank_accounts(str(org.id), scope, db, True)
            check("single branch only its accounts", all(str(r['branch_id'])==str(a.id) for r in rows), str(len(rows)))
    finally:
        async with async_session_factory() as db:
            accs=(await db.execute(__import__('sqlalchemy').select(BankAccount.id).where(BankAccount.organization_id==org.id))).scalars().all()
            if accs:
                await db.execute(delete(BankTransaction).where(BankTransaction.bank_account_id.in_(accs)))
            await db.execute(delete(BankAccount).where(BankAccount.organization_id==org.id))
            await db.execute(delete(Branch).where(Branch.organization_id==org.id))
            await db.execute(delete(User).where(User.id==u.id))
            await db.execute(delete(Organization).where(Organization.id==org.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL: print("FAILED:", FAIL); sys.exit(1)
asyncio.run(main())
