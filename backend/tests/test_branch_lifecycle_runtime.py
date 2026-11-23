"""Permanent branch delete vs branch data reset (isolation + FK safety)."""

import asyncio, os, sys, uuid
from decimal import Decimal
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from sqlalchemy import delete, select, func
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.business_entities import Customer, Product
from app.domain.entities.finance_entities import BankAccount
from app.domain.entities.sale_entities import Branch, BranchStock
from app.domain.services import branch_service as bsvc
from app.domain.services import branch_lifecycle_service as life
from app.domain.services import branch_stock_service as stock

PASS, FAIL = [], []
def check(n, c, e=""):
    (PASS if c else FAIL).append(n); print(("  ✓ " if c else "  ✗ ") + n + ("" if c else f" {e}"))

async def main():
    tag = uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org = Organization(name=f"Life {tag}", slug=f"life-{tag}",
                           subscription_plan="business")
        db.add(org); await db.flush()
        owner = User(organization_id=org.id, full_name="Owner",
                     email=f"l{tag}@t.local", role="owner")
        db.add(owner); await db.flush()
        main = await bsvc.main_branch(db, org.id)
        extra = await bsvc.create_branch(db, org.id, f"Extra {tag}")
        acc_m = BankAccount(organization_id=org.id, branch_id=main.id,
                            bank_name="M", account_name="M", account_number="1",
                            balance=Decimal("100"), currency="SAR")
        acc_e = BankAccount(organization_id=org.id, branch_id=extra.id,
                            bank_name="E", account_name="E", account_number="2",
                            balance=Decimal("50"), currency="SAR")
        p_m = Product(organization_id=org.id, branch_id=main.id,
                      name=f"PM {tag}", unit="قطعة", price=1, stock=0)
        p_e = Product(organization_id=org.id, branch_id=extra.id,
                      name=f"PE {tag}", unit="قطعة", price=1, stock=0)
        c_e = Customer(organization_id=org.id, branch_id=extra.id,
                       name=f"CE {tag}", phone=f"+96772{tag}")
        db.add_all([acc_m, acc_e, p_m, p_e, c_e]); await db.flush()
        await stock.adjust_stock(db, org.id, main.id, p_m.id,
                                 Decimal("5"), Decimal("1"))
        await stock.adjust_stock(db, org.id, extra.id, p_e.id,
                                 Decimal("7"), Decimal("1"))
        await db.commit()
        oid, mid, eid = org.id, main.id, extra.id
        pm, pe = p_m.id, p_e.id
        owner_id = owner.id

    async with async_session_factory() as db:
        extra = await bsvc._get(db, oid, eid)
        await life.reset_branch_data(db, oid, extra)
        await db.commit()
        check("branch still exists after reset",
              await db.scalar(select(func.count()).select_from(Branch).where(
                  Branch.id == eid)) == 1)
        reset_bank = (await db.execute(select(BankAccount).where(
            BankAccount.branch_id == eid))).scalar_one_or_none()
        check("reset keeps branch bank/currencies",
              reset_bank is not None)
        check("reset zeroes branch bank balance",
              reset_bank is not None and Decimal(str(reset_bank.balance)) == 0)
        check("reset removed branch products", await db.scalar(
            select(func.count()).select_from(Product).where(
                Product.branch_id == eid)) == 0)
        check("reset removed branch customers", await db.scalar(
            select(func.count()).select_from(Customer).where(
                Customer.branch_id == eid)) == 0)
        check("reset kept main bank", await db.scalar(
            select(func.count()).select_from(BankAccount).where(
                BankAccount.id == acc_m.id)) == 1)
        check("reset kept main product and stock", await db.scalar(
            select(func.count()).select_from(Product).where(
                Product.id == pm)) == 1)
        q, _ = await stock.get_stock(db, mid, pm)
        check("reset kept main stock quantity", q == Decimal("5"), str(q))

    async with async_session_factory() as db:
        extra = await bsvc._get(db, oid, eid, include_archived=True)
        await life.delete_branch_permanently(db, oid, extra)
        await db.commit()
        check("branch deleted permanently", await db.scalar(
            select(func.count()).select_from(Branch).where(
                Branch.id == eid)) == 0)
        check("main branch survives", await db.scalar(
            select(func.count()).select_from(Branch).where(
                Branch.id == mid)) == 1)
        check("main account survives", await db.scalar(
            select(func.count()).select_from(BankAccount).where(
                BankAccount.id == acc_m.id)) == 1)

    async with async_session_factory() as db:
        main = await bsvc._get(db, oid, mid, include_archived=True)
        try:
            await life.delete_branch_permanently(db, oid, main)
            check("main branch cannot be deleted", False)
        except ValueError as e:
            check("main branch cannot be deleted", "الرئيسي" in str(e))
            await db.rollback()

    # whole-business reset: all branches gone, one fresh main only
    async with async_session_factory() as db:
        e2 = await bsvc.create_branch(db, oid, f"ResetAll {tag}")
        db.add(BankAccount(organization_id=oid, branch_id=e2.id,
                           bank_name="R", account_name="R", account_number="9",
                           balance=Decimal("9"), currency="SAR"))
        await db.commit()
        e2id = e2.id
        fresh = await life.reset_whole_business(db, oid, "Fresh Business")
        await db.commit()
        branches = (await db.execute(select(Branch).where(
            Branch.organization_id == oid))).scalars().all()
        check("account reset leaves exactly one main branch", len(branches) == 1,
              str(len(branches)))
        check("fresh main is default", branches[0].is_default is True)
        check("extra branch removed by account reset", await db.scalar(
            select(func.count()).select_from(Branch).where(
                Branch.id == e2id)) == 0)
        check("account reset removed banks", await db.scalar(
            select(func.count()).select_from(BankAccount).where(
                BankAccount.organization_id == oid)) == 0)
        check("account reset removed products", await db.scalar(
            select(func.count()).select_from(Product).where(
                Product.organization_id == oid)) == 0)
        check("fresh main has expected name",
              branches[0].name == "Fresh Business", branches[0].name)

    async with async_session_factory() as db:
        await db.execute(delete(BranchStock).where(
            BranchStock.organization_id == oid))
        await db.execute(delete(BankAccount).where(
            BankAccount.organization_id == oid))
        await db.execute(delete(Product).where(Product.organization_id == oid))
        await db.execute(delete(Customer).where(Customer.organization_id == oid))
        await db.execute(delete(Branch).where(Branch.organization_id == oid))
        await db.execute(delete(User).where(User.id == owner_id))
        await db.execute(delete(Organization).where(Organization.id == oid))
        await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL); sys.exit(1)

asyncio.run(main())
