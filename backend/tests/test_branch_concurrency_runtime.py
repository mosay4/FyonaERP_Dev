"""Concurrency + legacy balance checks for branch transfers (PostgreSQL)."""

import asyncio, os, sys, uuid
from decimal import Decimal
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from sqlalchemy import delete, select
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.business_entities import Product
from app.domain.entities.finance_entities import BankAccount, BankTransaction
from app.domain.entities.sale_entities import Branch, BranchStock
from app.domain.entities.branch_entities import BranchTransfer, BranchTransferItem
from app.domain.services import branch_service as bsvc
from app.domain.services import branch_transfer_service as tsvc
from app.domain.services import branch_stock_service as stock

PASS, FAIL = [], []
def check(n, c, e=""):
    (PASS if c else FAIL).append(n); print(("  ✓ " if c else "  ✗ ") + n + ("" if c else f" {e}"))

async def _owner(db, oid):
    return (await db.execute(select(User).where(User.organization_id == oid,
                                                User.role == "owner"))).scalar_one()

async def main():
    tag = uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org = Organization(name=f"Conc {tag}", slug=f"conc-{tag}",
                           subscription_plan="business")
        db.add(org); await db.flush()
        owner = User(organization_id=org.id, full_name="Owner",
                     email=f"c{tag}@t.local", role="owner")
        db.add(owner); await db.flush()
        b1 = await bsvc.main_branch(db, org.id)
        b2 = await bsvc.create_branch(db, org.id, f"B2 {tag}")
        a1 = BankAccount(organization_id=org.id, branch_id=b1.id,
                         bank_name="A", account_name="A", account_number="1",
                         balance=Decimal("1000"), currency="USD")
        a2 = BankAccount(organization_id=org.id, branch_id=b2.id,
                         bank_name="B", account_name="B", account_number="2",
                         balance=Decimal("0"), currency="USD")
        p1 = Product(organization_id=org.id, branch_id=b1.id, name=f"P {tag}",
                     unit="قطعة", price=10, cost_price=4, stock=0)
        p2 = Product(organization_id=org.id, branch_id=b2.id, name=f"P2 {tag}",
                     unit="قطعة", price=10, cost_price=4, stock=0)
        db.add_all([a1, a2, p1, p2]); await db.flush()
        await stock.adjust_stock(db, org.id, b1.id, p1.id, Decimal("10"), Decimal("4"))
        await stock.adjust_stock(db, org.id, b2.id, p2.id, Decimal("0"), Decimal("4"))
        await db.commit()
        oid, b1id, b2id = org.id, b1.id, b2.id
        a1id, a2id, p1id, p2id = a1.id, a2.id, p1.id, p2.id
        owner_id = owner.id
    try:
        # 1) same idempotency key in parallel → one execution
        async def same_key():
            async with async_session_factory() as db:
                o = await _owner(db, oid)
                return await tsvc.create_financial(
                    db, oid, o, from_branch_id=b1id, to_branch_id=b2id,
                    from_account_id=a1id, to_account_id=a2id, amount=10,
                    idempotency_key=f"same-{tag}")
        results = await asyncio.gather(same_key(), same_key(), return_exceptions=True)
        ok = [r for r in results if isinstance(r, dict)]
        check("parallel same-key: no exception", len(ok) == 2, str(results))
        if len(ok) == 2:
            check("parallel same-key: one operation id", ok[0]["id"] == ok[1]["id"])
        async with async_session_factory() as db:
            a = (await db.execute(select(BankAccount).where(BankAccount.id == a1id))).scalar_one()
            check("parallel same-key: deducted once", Decimal(str(a.balance)) == Decimal("990"), str(a.balance))

        # 2) two different transfers racing the same balance → no overdraft
        async def different(i):
            async with async_session_factory() as db:
                o = await _owner(db, oid)
                return await tsvc.create_financial(
                    db, oid, o, from_branch_id=b1id, to_branch_id=b2id,
                    from_account_id=a1id, to_account_id=a2id, amount=700,
                    idempotency_key=f"race-{tag}-{i}")
        res = await asyncio.gather(different(1), different(2), return_exceptions=True)
        successes = [r for r in res if isinstance(r, dict)]
        failures = [r for r in res if isinstance(r, ValueError)]
        check("parallel race: exactly one succeeds", len(successes) == 1, str(res))
        check("parallel race: insufficient balance rejected", len(failures) == 1)
        async with async_session_factory() as db:
            a = (await db.execute(select(BankAccount).where(BankAccount.id == a1id))).scalar_one()
            check("parallel race: no negative balance", Decimal(str(a.balance)) == Decimal("290"), str(a.balance))

        # 2b) concurrent reversals: only one reversal is created
        async with async_session_factory() as db:
            o = await _owner(db, oid)
            tr = await tsvc.create_financial(
                db, oid, o, from_branch_id=b1id, to_branch_id=b2id,
                from_account_id=a1id, to_account_id=a2id, amount=5,
                idempotency_key=f"rev-{tag}")
        async def do_rev():
            async with async_session_factory() as db:
                o = await _owner(db, oid)
                return await tsvc.reverse_financial(
                    db, oid, o, uuid.UUID(tr["id"]))
        res = await asyncio.gather(do_rev(), do_rev(), return_exceptions=True)
        successes = [r for r in res if isinstance(r, dict)]
        failures = [r for r in res if isinstance(r, ValueError)]
        check("concurrent reversal: exactly one succeeds", len(successes) == 1, str(res))
        check("concurrent reversal: duplicate rejected", len(failures) == 1)

        # 3) inventory race cannot oversell
        async def inv(i):
            async with async_session_factory() as db:
                o = await _owner(db, oid)
                return await tsvc.create_inventory(
                    db, oid, o, from_branch_id=b1id, to_branch_id=b2id,
                    items=[{"from_product_id": str(p1id), "quantity": 8,
                            "to_product_id": str(p2id)}],
                    idempotency_key=f"inv-{tag}-{i}")
        res = await asyncio.gather(inv(1), inv(2), return_exceptions=True)
        successes = [r for r in res if isinstance(r, dict)]
        failures = [r for r in res if isinstance(r, ValueError)]
        check("inventory race: exactly one succeeds", len(successes) == 1, str(res))
        check("inventory race: second rejected", len(failures) == 1)
        async with async_session_factory() as db:
            q, _ = await stock.get_stock(db, b1id, p1id)
            check("inventory race: source never negative", q == Decimal("2"), str(q))
            q2, _ = await stock.get_stock(db, b2id, p2id)
            check("inventory race: target exactly 8", q2 == Decimal("8"), str(q2))

        # 4) legacy product stock seeds branch_stock on first movement
        async with async_session_factory() as db:
            legacy = Product(organization_id=oid, branch_id=None,
                             name=f"Legacy {tag}", unit="قطعة", price=1,
                             cost_price=2, stock=50)
            db.add(legacy); await db.flush()
            lid = legacy.id
            await stock.apply_delta(db, oid, b1id, legacy, Decimal("-5"))
            await db.commit()
            q, _ = await stock.get_stock(db, b1id, lid)
            check("legacy stock seeded from Product.stock", q == Decimal("45"), str(q))
    finally:
        async with async_session_factory() as db:
            ids = select(BranchTransfer.id).where(
                BranchTransfer.organization_id == oid)
            await db.execute(delete(BranchTransferItem).where(
                BranchTransferItem.transfer_id.in_(ids)))
            await db.execute(delete(BranchTransfer).where(
                BranchTransfer.organization_id == oid))
            await db.execute(delete(BranchStock).where(
                BranchStock.organization_id == oid))
            await db.execute(delete(BankTransaction).where(
                BankTransaction.organization_id == oid))
            await db.execute(delete(BankAccount).where(
                BankAccount.organization_id == oid))
            await db.execute(delete(Product).where(Product.organization_id == oid))
            await db.execute(delete(Branch).where(Branch.organization_id == oid))
            await db.execute(delete(User).where(User.id == owner_id))
            await db.execute(delete(Organization).where(Organization.id == oid))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL); sys.exit(1)

asyncio.run(main())
