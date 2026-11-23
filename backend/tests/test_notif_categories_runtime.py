"""Notification categories + self-action filtering (4 personal tabs,
2 business tabs)."""

import asyncio
import os
import sys
import uuid

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete  # noqa: E402
from app.api.v1 import reconciliation as _R  # noqa: E402,F401
from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import Organization, User  # noqa: E402
from app.domain.entities.notification_entities import AppNotification  # noqa: E402
from app.domain.services import debt_notification_service as dn  # noqa: E402

PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    check("chat → chat", dn._category("chat:abc", "chat_message") == "chat")
    check("settlement → settlement",
          dn._category("settlement_approved:x", "info") == "settlement")
    check("debt created → debt",
          dn._category("debt_created:x", "info") == "debt")
    check("invoice edit → alert",
          dn._category("debt_edited:x", "info") == "alert")
    check("invite → alert",
          dn._category("merchant_invite:x", "info") == "alert")
    check("link revoke → alert",
          dn._category("link_revoked_by_merchant:x", "info") == "alert")

    tag = uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org = Organization(name=f"O-{tag}", slug=f"o-{tag}")
        db.add(org)
        await db.flush()
        me = User(organization_id=org.id, full_name="me",
                  email=f"me{tag}@t.local", phone=f"+96775{tag}", role="owner")
        other = User(organization_id=org.id, full_name="other",
                     email=f"o{tag}@t.local", phone=f"+96776{tag}", role="owner")
        db.add_all([me, other])
        await db.flush()
        await dn.emit(db, org.id, f"chat:1-{tag}", [me.id],
                      title="mine", message="m",
                      route="/personal/merchant-accounts",
                      notif_type="chat_message",
                      payload={"sender_user_id": str(me.id),
                               "to_side": "merchant"})
        await dn.emit(db, org.id, f"chat:2-{tag}", [me.id],
                      title="incoming", message="m",
                      route="/personal/merchant-accounts",
                      notif_type="chat_message",
                      payload={"sender_user_id": str(other.id),
                               "to_side": "personal"})
        await dn.emit(db, org.id, f"debt_created:1-{tag}", [me.id],
                      title="debt", message="m", route="/personal",
                      payload={"actor_user_id": str(other.id),
                               "to_side": "personal"})
        await dn.emit(db, org.id, f"chat:3-{tag}", [me.id],
                      title="biz", message="m", route="/debts/chat",
                      notif_type="chat_message",
                      payload={"to_side": "merchant",
                               "link_id": "L-biz"})
        long_eid = f"debt_edited:{uuid.uuid4()}:{uuid.uuid4()}"
        made = await dn.emit(db, org.id, long_eid, [me.id],
                             title="تعديل فاتورة — اسم تاجر طويل جدًا",
                             message="تفاصيل", route="/personal/merchant-partner",
                             payload={"to_side": "personal"})
        check("long composite event id (85 chars) accepted",
              len(made) == 1, str(len(made)))
        await db.execute(delete(AppNotification).where(
            AppNotification.event_id == long_eid))
        await db.commit()
    async with async_session_factory() as db:
        unread = await dn.unread_count(db, me.id)
        check("unread total covers both sides (4)", unread == 4, str(unread))
        out = await dn.list_notifications(db, me.id)
        personal = await dn.list_notifications(db, me.id, side="personal")
        business = await dn.list_notifications(db, me.id, side="merchant")
        check("personal side excludes merchant chat",
              all('biz' != i['title'] for i in personal["items"]))
        check("business side keeps merchant chat",
              any('biz' == i['title'] for i in business["items"]))
        pu = await dn.unread_count(db, me.id, side="personal")
        bu = await dn.unread_count(db, me.id, side="merchant")
        check("side unread counts are separate", pu == 2 and bu == 2,
              f'{pu}/{bu}')
        title_by = {i["title"]: i["category"] for i in out["items"]}
        check("own sent chat hidden from personal",
              all(i["title"] != "mine" for i in personal["items"]),
              str([i["title"] for i in personal["items"]]))
        check("incoming chat kept as chat", title_by.get("incoming") == "chat")
        check("created debt kept as debt", title_by.get("debt") == "debt")
        await dn.mark_read(db, me.id)
        await db.flush()
        check("mark read clears both dots",
              await dn.unread_count(db, me.id) == 0)
        await db.execute(delete(AppNotification).where(
            AppNotification.user_id.in_([me.id, other.id])))
        await db.execute(delete(User).where(User.id.in_([me.id, other.id])))
        await db.execute(delete(Organization).where(Organization.id == org.id))
        await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
