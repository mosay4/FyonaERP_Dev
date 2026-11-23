"""Chat edit/delete/direction runtime test (real DB, no mocks).

- edit within 30 min (sender only) → edited flag
- other party cannot edit
- edit after 30 min rejected (server time)
- delete for everyone hides content for both
- SAME-USER direction: a message sent from Personal is mine in Personal and
  NOT mine in Business (side-based, not user-id-based).
"""

import asyncio
import os
import sys
import uuid
from datetime import date
from decimal import Decimal
from uuid import UUID

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete, text  # noqa: E402

from app.api.v1 import reconciliation as _R  # noqa: E402,F401
from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import Organization, User  # noqa: E402
from app.domain.entities.business_entities import Customer  # noqa: E402
from app.domain.entities.chat_entities import ChatMessage, ChatPresence  # noqa: E402
from app.domain.entities.invoice_entities import Invoice  # noqa: E402
from app.domain.entities.merchant_entities import MerchantLink  # noqa: E402
from app.domain.services import chat_service as cs  # noqa: E402

PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    tag = uuid.uuid4().hex[:6]
    m_org = p_org = None
    merchant = customer = None
    cust = cust2 = None
    inv = None
    link = self_link = None
    try:
        async with async_session_factory() as db:
            m_org = Organization(name=f"Shop-{tag}", slug=f"shop-{tag}")
            p_org = Organization(name=f"P-{tag}", slug=f"p-{tag}",
                                 subscription_plan="personal")
            db.add_all([m_org, p_org])
            await db.flush()
            merchant = User(organization_id=m_org.id, full_name=f"تاجر {tag}",
                            email=f"m{tag}@t.local", role="owner")
            customer = User(organization_id=p_org.id, full_name=f"عميل {tag}",
                            email=f"c{tag}@t.local", role="owner")
            db.add_all([merchant, customer])
            await db.flush()
            cust = Customer(organization_id=m_org.id, name=f"زبون {tag}")
            cust2 = Customer(organization_id=m_org.id, name=f"زبون2 {tag}")
            db.add_all([cust, cust2])
            await db.flush()
            inv = Invoice(organization_id=m_org.id, invoice_number=f"ED-{tag}",
                          invoice_type="sale", customer_id=cust.id,
                          invoice_date=date.today(), status="confirmed",
                          total=Decimal("100"), paid_amount=Decimal("0"),
                          balance=Decimal("100"), currency="SAR")
            db.add(inv)
            await db.flush()
            link = MerchantLink(merchant_org_id=m_org.id, party_kind="customer",
                                party_id=cust.id, external_user_id=customer.id,
                                status="accepted", display_name=cust.name,
                                invited_by=merchant.id)
            # Same-user relation: merchant is BOTH sides.
            self_link = MerchantLink(
                merchant_org_id=m_org.id, party_kind="customer",
                party_id=cust2.id, external_user_id=merchant.id,
                status="accepted", display_name=cust2.name,
                invited_by=merchant.id)
            db.add_all([link, self_link])
            await db.flush()
            await db.commit()

        # ── edit within window ──
        async with async_session_factory() as db:
            r = await cs.send_message(db, merchant.id, link.id, side="merchant",
                                      kind="text", text="النسخة الأولى",
                                      client_id=f"e1-{tag}")
            mid = UUID(r["message"]["id"])
            await db.commit()
            e = await cs.edit_message(db, merchant.id, link.id, mid,
                                      "النسخة المعدلة")
            await db.commit()
            check("edit within 30min", e["message"]["edited"] is True
                  and e["message"]["text"] == "النسخة المعدلة", str(e))

        # ── other party cannot edit ──
        async with async_session_factory() as db:
            try:
                await cs.edit_message(db, customer.id, link.id, mid, "تلاعب")
                check("other party cannot edit", False)
            except ValueError:
                check("other party cannot edit", True)
            await db.rollback()

        # ── after 30 min rejected ──
        async with async_session_factory() as db:
            await db.execute(text(
                "update chat_messages set created_at = now() - interval '31 minutes' "
                "where id = :i"), {"i": mid})
            await db.commit()
        async with async_session_factory() as db:
            try:
                await cs.edit_message(db, merchant.id, link.id, mid, "متأخر")
                check("edit after 30min rejected", False)
            except ValueError:
                check("edit after 30min rejected", True)
            await db.rollback()

        # ── delete for everyone hides content ──
        async with async_session_factory() as db:
            r = await cs.send_message(db, merchant.id, link.id, side="merchant",
                                      kind="text", text="للحذف",
                                      client_id=f"d1-{tag}")
            did = UUID(r["message"]["id"])
            await db.commit()
            d = await cs.delete_message(db, merchant.id, link.id, did)
            await db.commit()
            check("delete succeeds", d["deleted"] is True)
        async with async_session_factory() as db:
            for uid, side in ((merchant.id, "merchant"),
                              (customer.id, "personal")):
                msgs = (await cs.list_messages(
                    db, uid, link.id, side=side))["messages"]
                m = next((x for x in msgs if x["id"] == str(did)), None)
                check(f"deleted hidden for {side}",
                      m is not None and m["deleted"] is True
                      and m["text"] is None, str(m))
            await db.commit()

        # ── SAME-USER direction (side-based) ──
        async with async_session_factory() as db:
            r = await cs.send_message(db, merchant.id, self_link.id,
                                      side="personal", kind="text",
                                      text="من الشخصي", client_id=f"s-{tag}")
            sid = r["message"]["id"]
            await db.commit()
            as_personal = (await cs.list_messages(
                db, merchant.id, self_link.id, side="personal"))["messages"]
            as_merchant = (await cs.list_messages(
                db, merchant.id, self_link.id, side="merchant"))["messages"]
            await db.commit()
            pm = next(x for x in as_personal if x["id"] == sid)
            mm = next(x for x in as_merchant if x["id"] == sid)
            check("personal view: mine (right)", pm["mine"] is True, str(pm))
            check("business view: theirs (left)", mm["mine"] is False, str(mm))
    finally:
        async with async_session_factory() as db:
            ids = [l.id for l in (link, self_link) if l is not None]
            if ids:
                await db.execute(delete(ChatMessage).where(
                    ChatMessage.link_id.in_(ids)))
                await db.execute(delete(MerchantLink).where(
                    MerchantLink.id.in_(ids)))
            if merchant is not None:
                await db.execute(delete(ChatPresence).where(
                    ChatPresence.user_id.in_([merchant.id, customer.id])))
            if inv is not None:
                await db.execute(delete(Invoice).where(Invoice.id == inv.id))
            for c in (cust, cust2):
                if c is not None:
                    await db.execute(delete(Customer).where(Customer.id == c.id))
            for u in (merchant, customer):
                if u is not None:
                    await db.execute(delete(User).where(User.id == u.id))
            for o in (m_org, p_org):
                if o is not None:
                    await db.execute(delete(Organization).where(
                        Organization.id == o.id))
            await db.commit()

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
