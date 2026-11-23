"""Unlink + party-delete runtime test.

1. Personal unlink revokes the binding and notifies the merchant, keeping the
   merchant's party and debts intact.
2. Merchant deletes a LINKED party → revoke + soft delete + notification.
3. Merchant deletes an UNLINKED party → permanent delete + JSON backup; the
   explicit debt row is gone (CASCADE) while the invoice survives anonymised
   (customer_id NULL), i.e. the balance remains but its source is unknown.
"""

import asyncio
import os
import sys
import uuid
from datetime import date
from decimal import Decimal

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete, select  # noqa: E402

from app.api.v1 import reconciliation as _R  # noqa: E402,F401
from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import Organization, User  # noqa: E402
from app.domain.entities.business_entities import Customer  # noqa: E402
from app.domain.entities.invoice_entities import Invoice  # noqa: E402
from app.domain.entities.merchant_entities import (  # noqa: E402
    MerchantLink, SharedAuditLog,
)
from app.domain.entities.notification_entities import AppNotification  # noqa: E402
from app.domain.entities.sale_entities import CustomerReceivable  # noqa: E402
from app.domain.services import merchant_link_service as svc  # noqa: E402

PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    tag = uuid.uuid4().hex[:6]
    m_org = p_org = owner = p_user = None
    c1 = c2 = inv1 = rec1 = None
    link1 = link2 = None
    async with async_session_factory() as db:
        m_org = Organization(name=f"M-{tag}", slug=f"m-{tag}")
        db.add(m_org)
        await db.flush()
        owner = User(organization_id=m_org.id, full_name=f"تاجر {tag}",
                     email=f"o{tag}@t.local", phone=f"+96770{tag}", role="owner")
        db.add(owner)
        p_org = Organization(name=f"P-{tag}", slug=f"p-{tag}",
                             subscription_plan="personal")
        db.add(p_org)
        await db.flush()
        p_user = User(organization_id=p_org.id, full_name=f"عميل {tag}",
                      email=f"p{tag}@t.local", phone=f"+96771{tag}", role="owner")
        db.add(p_user)
        await db.flush()
        await svc.ensure_user_code(db, p_user)
        c1 = Customer(organization_id=m_org.id, name=f"مرتبط {tag}",
                      phone=p_user.phone)
        c2 = Customer(organization_id=m_org.id, name=f"غير مرتبط {tag}")
        db.add_all([c1, c2])
        await db.flush()
        inv1 = Invoice(organization_id=m_org.id, invoice_number=f"INV-{tag}",
                       invoice_type="sale", customer_id=c1.id,
                       invoice_date=date.today(), status="partially_paid",
                       total=Decimal("100"), paid_amount=Decimal("0"),
                       balance=Decimal("100"), currency="SAR")
        db.add(inv1)
        await db.flush()
        rec1 = CustomerReceivable(organization_id=m_org.id, customer_id=c1.id,
                                  invoice_id=inv1.id, amount=Decimal("100"),
                                  paid=Decimal("0"), status="open")
        db.add(rec1)
        await db.flush()
        r1 = await svc.invite(db, m_org.id, owner.id, "customer", c1.id,
                              phone=p_user.phone)
        link1 = uuid.UUID(r1["id"])
        await svc.respond(db, p_user.id, link1, True)
        await db.commit()

    try:
        # 1) personal unlink
        async with async_session_factory() as db:
            out = await svc.user_unlink(db, p_user.id, link1)
            await db.commit()
            check("user unlink → revoked", out["status"] == "revoked")
        async with async_session_factory() as db:
            l = (await db.execute(select(MerchantLink).where(
                MerchantLink.id == link1))).scalar_one()
            c = (await db.execute(select(Customer).where(
                Customer.id == c1.id))).scalar_one()
            note = (await db.execute(select(AppNotification).where(
                AppNotification.user_id == owner.id))).scalars().all()
            check("party kept after user unlink", c.is_deleted is False)
            check("merchant notified about the unlink", len(note) >= 1, str(len(note)))
        async with async_session_factory() as db:
            check("personal list no longer shows it",
                  await svc.user_links(db, p_user.id) == [])
            check("re-link needs a fresh invite", (
                await svc.invite(db, m_org.id, owner.id, "customer", c1.id,
                                 phone=p_user.phone))["status"] == "pending")
            await db.commit()
        async with async_session_factory() as db:
            await svc.respond(db, p_user.id, link1, True)
            await db.commit()

        # 2) merchant deletes a LINKED party
        async with async_session_factory() as db:
            out = await svc.merchant_delete_party(
                db, m_org.id, owner.id, "customer", c1.id)
            await db.commit()
            check("linked delete reports linked", out["linked"] is True)
        async with async_session_factory() as db:
            l = (await db.execute(select(MerchantLink).where(
                MerchantLink.id == link1))).scalar_one()
            c = (await db.execute(select(Customer).where(
                Customer.id == c1.id))).scalar_one()
            notes = (await db.execute(select(AppNotification).where(
                AppNotification.user_id == p_user.id))).scalars().all()
            check("linked delete revokes the link", l.status == "revoked")
            check("linked delete hides but keeps the party", c.is_deleted is True)
            check("linked delete notifies the personal user",
                  any("إلغاء الربط" in (n.title or "") for n in notes))

        # 3) merchant deletes an UNLINKED party
        #    make a debt for c2 too, then delete permanently
        async with async_session_factory() as db:
            inv2 = Invoice(organization_id=m_org.id, invoice_number=f"INV2-{tag}",
                           invoice_type="sale", customer_id=c2.id,
                           invoice_date=date.today(), status="partially_paid",
                           total=Decimal("50"), paid_amount=Decimal("0"),
                           balance=Decimal("50"), currency="SAR")
            db.add(inv2)
            await db.flush()
            db.add(CustomerReceivable(organization_id=m_org.id,
                                      customer_id=c2.id, invoice_id=inv2.id,
                                      amount=Decimal("50"), paid=Decimal("0"),
                                      status="open"))
            await db.commit()
            inv2_id = inv2.id
        async with async_session_factory() as db:
            out = await svc.merchant_delete_party(
                db, m_org.id, owner.id, "customer", c2.id)
            await db.commit()
            check("unlinked delete reports not linked", out["linked"] is False)
            check("unlinked delete wrote a backup", ".json" in out["backup"])
        async with async_session_factory() as db:
            c = (await db.execute(select(Customer).where(
                Customer.id == c2.id))).scalar_one_or_none()
            recs = (await db.execute(select(CustomerReceivable).where(
                CustomerReceivable.customer_id == c2.id))).scalars().all()
            inv = (await db.execute(select(Invoice).where(
                Invoice.id == inv2_id))).scalar_one()
            check("unlinked party is gone", c is None)
            check("its debt rows are gone (CASCADE)", recs == [])
            check("its invoice survives anonymised (balance kept)",
                  inv.customer_id is None and float(inv.balance) == 50.0)
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(AppNotification).where(
                AppNotification.user_id.in_([p_user.id, owner.id])))
            await db.execute(delete(SharedAuditLog).where(
                SharedAuditLog.organization_id == m_org.id))
            await db.execute(delete(MerchantLink).where(
                MerchantLink.merchant_org_id == m_org.id))
            await db.execute(delete(Invoice).where(
                Invoice.organization_id == m_org.id))
            await db.execute(delete(Customer).where(
                Customer.organization_id == m_org.id))
            await db.execute(delete(User).where(
                User.id.in_([p_user.id, owner.id])))
            for o in (p_org, m_org):
                if o:
                    await db.execute(delete(Organization).where(
                        Organization.id == o.id))
            await db.commit()

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
