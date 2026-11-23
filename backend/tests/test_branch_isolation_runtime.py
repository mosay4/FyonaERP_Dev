"""Customer/supplier branch isolation: same names allowed per branch, lists
filtered by branch, and cross-branch read/update/delete rejected."""

import asyncio
import os
import sys
import uuid
from decimal import Decimal
from datetime import datetime, timezone

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete  # noqa: E402
from app.api.v1 import reconciliation as _R  # noqa: E402,F401
from app.api.v1.business import _get_service  # noqa: E402
from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import Organization, User  # noqa: E402
from app.domain.entities.business_entities import Customer, Supplier  # noqa: E402
from app.domain.entities.sale_entities import Branch  # noqa: E402
from app.domain.entities.finance_entities import BankAccount, BankTransaction  # noqa: E402
from app.domain.services import business_transactions_service as btx  # noqa: E402
from app.domain.models.business_models import (  # noqa: E402
    CustomerCreate, CustomerUpdate, SupplierCreate)
from app.domain.services import branch_service as bsvc  # noqa: E402

PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    tag = uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org = Organization(name=f"Biz {tag}", slug=f"bz-{tag}",
                           subscription_plan="business")
        db.add(org)
        await db.flush()
        user = User(organization_id=org.id, full_name=f"O {tag}",
                    email=f"b{tag}@t.local", phone=f"+96773{tag}", role="owner")
        db.add(user)
        await db.commit()
    main_id = b_id = None
    try:
        async with async_session_factory() as db:
            main = await bsvc.main_branch(db, org.id)
            other = await bsvc.create_branch(db, org.id, f"B {tag}")
            main_id, b_id = main.id, other.id
            await db.commit()
        async with async_session_factory() as db:
            svc = _get_service(db)
            a = await svc.create_customer(org.id, CustomerCreate(name=f"Same {tag}"),
                                          branch_id=main_id)
            b = await svc.create_customer(org.id, CustomerCreate(name=f"Same {tag}"),
                                          branch_id=b_id)
            sa = await svc.create_supplier(org.id, SupplierCreate(name=f"Sup {tag}"),
                                           branch_id=main_id)
            await db.commit()
            a_id, b_id_c, sa_id = a.id, b.id, sa.id
        async with async_session_factory() as db:
            svc = _get_service(db)
            main_items, main_total = await svc.list_customers(
                org.id, branch_id=main_id)
            other_items, other_total = await svc.list_customers(
                org.id, branch_id=b_id)
            check("main list only its customer",
                  main_total >= 1 and all(i.branch_id == main_id for i in main_items))
            check("other list only its customer",
                  other_total >= 1 and all(i.branch_id == b_id for i in other_items))
            try:
                await svc.get_customer(b_id_c, org.id, branch_id=main_id)
                check("cross-branch get rejected", False)
            except ValueError as e:
                check("cross-branch get rejected", "فرع آخر" in str(e))
            try:
                await svc.update_customer(
                    b_id_c, org.id, CustomerUpdate(name="Hacked"), branch_id=main_id)
                check("cross-branch update rejected", False)
            except ValueError as e:
                check("cross-branch update rejected", "فرع آخر" in str(e))
            try:
                await svc.delete_customer(b_id_c, org.id, branch_id=main_id)
                check("cross-branch delete rejected", False)
            except ValueError as e:
                check("cross-branch delete rejected", "فرع آخر" in str(e))
            sups, _ = await svc.list_suppliers(org.id, branch_id=main_id)
            check("supplier isolated to main",
                  all(s.branch_id == main_id for s in sups))
            # Bank movements (latest home operations) must be branch-scoped.
            am = BankAccount(organization_id=org.id, branch_id=main_id,
                             bank_name="Main", account_name="M",
                             account_number="1", balance=Decimal("50"),
                             currency="SAR")
            ab = BankAccount(organization_id=org.id, branch_id=b_id,
                             bank_name="Other", account_name="B",
                             account_number="2", balance=Decimal("500"),
                             currency="SAR")
            db.add_all([am, ab])
            await db.flush()
            now = datetime.now(timezone.utc)
            db.add_all([
                BankTransaction(organization_id=org.id, bank_account_id=am.id,
                                date=now, description="main deposit",
                                tx_type="deposit", amount=Decimal("50"),
                                currency="SAR", reference="M-1"),
                BankTransaction(organization_id=org.id, bank_account_id=ab.id,
                                date=now, description="other deposit",
                                tx_type="deposit", amount=Decimal("500"),
                                currency="SAR", reference="B-1"),
            ])
            await db.flush()
            main_tx = await btx.list_transactions(
                db, org.id, per_page=50, branch_ids=[main_id])
            refs = {r.get("reference") for r in main_tx["items"]}
            other_tx = await btx.list_transactions(
                db, org.id, per_page=50, branch_ids=[b_id])
            refs2 = {r.get("reference") for r in other_tx["items"]}
            check("bank timeline isolated to requested branch",
                  "B-1" in refs2 and "M-1" not in refs2, str(refs2))
            check("main branch timeline excludes other bank movement",
                  "M-1" in refs and "B-1" not in refs, str(refs))
            check("timeline rows carry branch name",
                  all((r.get("branch_name") or "") for r in other_tx["items"]
                      if r.get("source_type") == "bank_tx"))
            await db.rollback()
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(Customer).where(Customer.organization_id == org.id))
            await db.execute(delete(Supplier).where(Supplier.organization_id == org.id))
            await db.execute(delete(Branch).where(Branch.organization_id == org.id))
            await db.execute(delete(User).where(User.id == user.id))
            await db.execute(delete(Organization).where(Organization.id == org.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
