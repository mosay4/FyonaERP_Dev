"""Album multi-media runtime test (real DB, isolated rows)."""

import asyncio
import os
import sys
import uuid
from datetime import date
from decimal import Decimal
from uuid import UUID

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete  # noqa: E402

from app.api.v1 import reconciliation as _R  # noqa: E402,F401
from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import Organization, User  # noqa: E402
from app.domain.entities.business_entities import Customer  # noqa: E402
from app.domain.entities.chat_entities import ChatMessage, ChatPresence  # noqa: E402
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
    cust = None
    link = None
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
            db.add(cust)
            await db.flush()
            link = MerchantLink(merchant_org_id=m_org.id, party_kind="customer",
                                party_id=cust.id, external_user_id=customer.id,
                                status="accepted", display_name=cust.name,
                                invited_by=merchant.id)
            db.add(link)
            await db.flush()
            await db.commit()

        async with async_session_factory() as db:
            r = await cs.send_message(
                db, merchant.id, link.id, side="merchant", kind="album",
                media=[{"url": "uploads/chat/a.jpg", "kind": "image",
                        "file_name": "a.jpg"},
                       {"url": "uploads/chat/b.mp4", "kind": "video",
                        "file_name": "b.mp4"}],
                text="ألبوم", client_id=f"al-{tag}")
            await db.commit()
            m = r["message"]
            check("album kind", m["kind"] == "album")
            check("album media count 2", m["media_count"] == 2, str(m))
        async with async_session_factory() as db:
            msgs = (await cs.list_messages(
                db, customer.id, link.id, side="personal"))["messages"]
            await db.commit()
            m = next(x for x in msgs if x["kind"] == "album")
            check("recipient sees album media", len(m["media"]) == 2,
                  str(m.get("media")))
            check("album caption", m["text"] == "ألبوم")
    finally:
        async with async_session_factory() as db:
            if link is not None:
                await db.execute(delete(ChatMessage).where(
                    ChatMessage.link_id == link.id))
                await db.execute(delete(MerchantLink).where(
                    MerchantLink.id == link.id))
            if merchant is not None:
                await db.execute(delete(ChatPresence).where(
                    ChatPresence.user_id.in_([merchant.id, customer.id])))
            if cust is not None:
                await db.execute(delete(Customer).where(Customer.id == cust.id))
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
