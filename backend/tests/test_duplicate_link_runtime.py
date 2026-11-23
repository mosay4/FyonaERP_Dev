"""One personal account cannot be linked to the same merchant twice (even via
another party with the same phone/code)."""

import asyncio
import os
import sys
import uuid
from datetime import date, datetime, timezone

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete  # noqa: E402
from app.api.v1 import reconciliation as _R  # noqa: E402,F401
from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import Organization, User  # noqa: E402
from app.domain.entities.business_entities import Customer, Supplier  # noqa: E402
from app.domain.entities.merchant_entities import MerchantLink  # noqa: E402
from app.domain.services import merchant_link_service as svc  # noqa: E402

PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    tag = uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        m = Organization(name=f"M-{tag}", slug=f"m-{tag}")
        db.add(m)
        await db.flush()
        owner = User(organization_id=m.id, full_name=f"تاجر {tag}",
                     email=f"o{tag}@t.local", phone=f"+96777{tag}", role="owner")
        p = Organization(name=f"P-{tag}", slug=f"p-{tag}",
                         subscription_plan="personal")
        db.add(p)
        await db.flush()
        puser = User(organization_id=p.id, full_name=f"مستخدم {tag}",
                     email=f"p{tag}@t.local", phone=f"+96778{tag}", role="owner")
        db.add_all([owner, puser])
        await db.flush()
        await svc.ensure_user_code(db, puser)
        c1 = Customer(organization_id=m.id, name=f"عميل1 {tag}",
                      phone=puser.phone)
        c2 = Customer(organization_id=m.id, name=f"عميل2 {tag}")
        s1 = Supplier(organization_id=m.id, name=f"مورد1 {tag}")
        db.add_all([c1, c2, s1])
        await db.flush()
        r1 = await svc.invite(db, m.id, owner.id, "customer", c1.id,
                              phone=puser.phone)
        await svc.respond(db, puser.id, uuid.UUID(r1["id"]), True)
        await db.commit()
    try:
        async with async_session_factory() as db:
            try:
                await svc.invite(db, m.id, owner.id, "customer", c2.id,
                                 phone=puser.phone)
                check("same account via another customer rejected", False)
            except ValueError as e:
                check("same account via another customer rejected",
                      "مرتبط" in str(e), str(e))
            await db.rollback()
        async with async_session_factory() as db:
            try:
                await svc.invite(db, m.id, owner.id, "supplier", s1.id,
                                 code=puser.public_code)
                check("same account as a supplier rejected", False)
            except ValueError as e:
                check("same account as a supplier rejected",
                      "مرتبط" in str(e), str(e))
            await db.rollback()
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(MerchantLink).where(
                MerchantLink.merchant_org_id == m.id))
            await db.execute(delete(Customer).where(
                Customer.organization_id == m.id))
            await db.execute(delete(Supplier).where(
                Supplier.organization_id == m.id))
            await db.execute(delete(User).where(User.id.in_([owner.id, puser.id])))
            for o in (p, m):
                await db.execute(delete(Organization).where(Organization.id == o.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
