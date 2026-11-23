"""Chat runtime test — isolated rows, real DB, no mocks.

Covers: participant isolation, text send/list, delivered + read receipts,
client_id idempotency, invoice sharing validation, presence, and unread count.
"""

import asyncio
import os
import sys
import uuid
from datetime import date
from decimal import Decimal
from uuid import UUID

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete, select  # noqa: E402

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
    merchant = customer = stranger = None
    cust = None
    inv = None
    link = None
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
        stranger = User(organization_id=p_org.id, full_name=f"غريب {tag}",
                        email=f"s{tag}@t.local", role="owner")
        db.add_all([merchant, customer, stranger])
        await db.flush()
        cust = Customer(organization_id=m_org.id, name=f"زبون {tag}")
        db.add(cust)
        await db.flush()
        inv = Invoice(organization_id=m_org.id, invoice_number=f"CH-{tag}",
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
        db.add(link)
        await db.flush()
        await db.commit()

    try:
        async with async_session_factory() as db:
            # stranger cannot access
            try:
                await cs.conversation_info(db, stranger.id, link.id)
                check("stranger blocked", False)
            except ValueError:
                check("stranger blocked", True)
            await db.rollback()

        # merchant sends
        async with async_session_factory() as db:
            r = await cs.send_message(db, merchant.id, link.id, side="merchant", kind="text",
                                      text="مرحبا", client_id=f"c1-{tag}")
            mid = UUID(r["message"]["id"])
            await db.commit()
            check("send returns message", r["message"]["text"] == "مرحبا")
            # duplicate client_id
            r2 = await cs.send_message(db, merchant.id, link.id, side="merchant", kind="text",
                                       text="مرحبا", client_id=f"c1-{tag}")
            await db.commit()
            check("client_id dedupes", r2.get("duplicate") is True)
            await db.commit()

        # customer lists → delivered
        async with async_session_factory() as db:
            info = await cs.conversation_info(db, customer.id, link.id, side="personal")
            check("customer sees shop name",
                  info["other_name"] == m_org.name, str(info))
            check("unread for customer", info["unread"] == 1, str(info))
            await db.commit()
            msgs = (await cs.list_messages(db, customer.id, link.id, side="personal"))["messages"]
            await db.commit()
            check("customer receives message",
                  len(msgs) == 1 and msgs[0]["text"] == "مرحبا", str(msgs))
            check("delivered after list", msgs[0]["delivered"] is True)
            check("not read yet", msgs[0]["read"] is False)

        # customer reads
        async with async_session_factory() as db:
            rr = await cs.mark_read(db, customer.id, link.id)
            await db.commit()
            check("mark read", rr["read"] >= 1, str(rr))

        # merchant sees read + presence
        async with async_session_factory() as db:
            msgs = (await cs.list_messages(db, merchant.id, link.id, side="merchant"))["messages"]
            await db.commit()
            check("merchant sees read receipt",
                  msgs and msgs[0]["read"] is True, str(msgs))
            check("customer online after poll",
                  (await cs.conversation_info(
                      db, merchant.id, link.id, side="merchant"))["online"] is True)
            await db.commit()

        # invoice share + wrong invoice rejected
        async with async_session_factory() as db:
            r = await cs.send_message(db, merchant.id, link.id, side="merchant",
                                      kind="invoice", invoice_id=inv.id,
                                      client_id=f"inv-{tag}")
            await db.commit()
            check("invoice message has number",
                  r["message"]["invoice_number"] == inv.invoice_number, str(r))
            lst = await cs.list_invoices_for_chat(db, customer.id, link.id)
            check("chat invoice list", any(x["id"] == str(inv.id) for x in lst))
            await db.commit()
        async with async_session_factory() as db:
            try:
                await cs.send_message(db, merchant.id, link.id, side="merchant",
                                      kind="invoice",
                                      invoice_id=UUID(int=1))
                check("foreign invoice rejected", False)
            except ValueError:
                check("foreign invoice rejected", True)
            await db.rollback()
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(ChatMessage).where(
                ChatMessage.link_id == link.id))
            await db.execute(delete(ChatPresence).where(
                ChatPresence.user_id.in_([merchant.id, customer.id, stranger.id])))
            await db.execute(delete(MerchantLink).where(
                MerchantLink.id == link.id))
            await db.execute(delete(Invoice).where(Invoice.id == inv.id))
            await db.execute(delete(Customer).where(Customer.id == cust.id))
            for u in (merchant, customer, stranger):
                await db.execute(delete(User).where(User.id == u.id))
            for o in (m_org, p_org):
                await db.execute(delete(Organization).where(Organization.id == o.id))
            await db.commit()

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
