"""Commercial-debt notifications — isolated center + one-per-event + push.

* Domain 'commercial_debt' keeps these OUT of the main notification center and
  keeps the main center out of the debts center (same table, indexed filter).
* `event_id` + UNIQUE(user_id, event_id) guarantee exactly ONE notification per
  logical financial event per recipient — double taps, API retries, re-connects
  and re-processed jobs can never duplicate it.
* Rows are inserted in the SAME transaction as the financial operation
  (transactional outbox — the notification can never be lost after commit),
  while the FCM push is fired right after the commit via `push_event`.
"""

import json
from typing import Iterable, List, Optional
from uuid import UUID

from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.notification_entities import AppNotification
from app.domain.services.push_service import push_to_users_now

DOMAIN = "commercial_debt"


async def emit(
    db: AsyncSession, org_id: UUID, event_id: str, recipient_ids: Iterable[UUID],
    *, title: str, message: str, route: str, notif_type: str = "info",
    payload: Optional[dict] = None,
) -> List[str]:
    """Insert one notification row per recipient (deduped by event) INSIDE the
    caller's transaction. Returns the event ids that were actually created."""
    created: List[str] = []
    seen: set = set()
    event_id = (str(event_id) if event_id is not None else "")[:200]
    title = (title or "")[:300]
    route = (route or "")[:200]
    # SAVEPOINT (not a full rollback): a duplicate emit must never wipe the
    # caller's financial transaction — only the notification insert is undone.
    savepoint = await db.begin_nested()
    try:
        for uid in recipient_ids:
            if not uid or uid in seen:
                continue
            seen.add(uid)
            db.add(AppNotification(
                organization_id=org_id, user_id=uid, domain=DOMAIN,
                event_id=event_id, type=notif_type, title=title, message=message,
                action="open_screen", action_payload=json.dumps(payload or {},
                                                                ensure_ascii=False),
                route=route, is_read=False,
            ))
            created.append(event_id)
        await db.flush()
    except IntegrityError:
        # A concurrent/retried emit for the same event already stored it —
        # roll back to the savepoint only; the financial txn stays intact.
        await savepoint.rollback()
        return []
    return created


async def push_event(
    db: AsyncSession, org_id: UUID, event_id: str, recipient_ids: Iterable[UUID],
    *, title: str, message: str, route: str,
) -> dict:
    """Post-commit push for a previously emitted event (best effort, never
    raises). The in-app row already exists — push is a delivery channel only."""
    ids = [UUID(str(u)) for u in recipient_ids or [] if u]
    return await push_to_users_now(
        db, ids, title=title, body=message, action="open_screen",
        action_payload=route, log_type="debt_notification",
    )


def _category(event_id: str, notif_type: str) -> str:
    """Four categories: الديون / السداد / الرسائل / التنبيهات.

    Personal center shows all four; the business center uses only
    messages + alerts (debt/settlement events from the counterpart are
    grouped with the alerts there)."""
    e = (event_id or "").lower()
    t = (notif_type or "").lower()
    if t == "chat_message" or e.startswith("chat:"):
        return "chat"
    if t.startswith("settlement") or t in ("payment", "payment_request") \
            or e.startswith("settlement"):
        return "settlement"
    if (e.startswith("merchant_invite:") or e.startswith("link_accepted:")
            or e.startswith("link_rejected:") or e.startswith("link_revoked")
            or e.startswith("debt_edited:") or e.startswith("debt_deleted:")
            or "edit" in t or "delete" in t or "alert" in t
            or "revoke" in e or "unlink" in e):
        return "alert"
    return "debt"


def _link_of(row: AppNotification) -> str:
    try:
        payload = json.loads(row.action_payload or "{}")
    except Exception:
        payload = {}
    lid = payload.get("link_id")
    if lid:
        return str(lid)
    route = row.route or ""
    if "link=" in route:
        return route.split("link=")[1].split("&")[0]
    return ""


def _payload_of(row: AppNotification) -> dict:
    try:
        p = json.loads(row.action_payload or "{}")
        return p if isinstance(p, dict) else {}
    except Exception:
        return {}


def _side_of(row: AppNotification) -> str:
    """Which SIDE this row belongs to: the merchant (business center) or the
    personal user. Dual-role accounts (one login acting as both) thus get
    fully separated centers: a personal→merchant message lands in the
    business center only."""
    p = _payload_of(row)
    side = str(p.get("to_side") or "").strip().lower()
    if side in ("personal", "merchant"):
        return side
    route = (row.route or "").strip()
    if route.startswith("/personal"):
        return "personal"
    if (route.startswith("/debts") or route.startswith("/customers")
            or route.startswith("/suppliers")):
        return "merchant"
    return ""


async def list_notifications(
    db: AsyncSession, user_id: UUID, limit: int = 100,
    link_id: Optional[UUID] = None, side: Optional[str] = None,
) -> dict:
    rows = (
        await db.execute(
            select(AppNotification)
            .where(AppNotification.user_id == user_id,
                   AppNotification.domain == DOMAIN)
            .order_by(AppNotification.created_at.desc())
            .limit(300)
        )
    ).scalars().all()
    want = (side or "").strip().lower()
    if want in ("personal", "merchant"):
        rows = [r for r in rows if _side_of(r) == want]
    # Per-party isolation: only this commercial relationship's notifications.
    if link_id is not None:
        rows = [r for r in rows if _link_of(r) == str(link_id)]
    rows = rows[:limit]
    unread = sum(1 for r in rows if not r.is_read)
    return {
        "unread": unread,
        "items": [
            {
                "id": str(r.id), "event_id": r.event_id, "type": r.type,
                "category": _category(r.event_id, r.type),
                "title": r.title, "message": r.message, "route": r.route,
                "action_payload": r.action_payload,
                "is_read": r.is_read,
                "created_at": r.created_at.isoformat() if r.created_at else None,
            }
            for r in rows
        ],
    }


async def _drop_stale_invites(db: AsyncSession, rows: list) -> list:
    """An invite that is no longer pending is stale — never hold the red dot."""
    from app.domain.entities.merchant_entities import MerchantLink

    invite_links = []
    for r in rows:
        eid = r.event_id or ""
        if eid.startswith("merchant_invite:"):
            lid = _payload_of(r).get("link_id")
            if lid:
                invite_links.append(str(lid))
    if not invite_links:
        return rows
    try:
        pending = set(str(x) for x in (await db.execute(
            select(MerchantLink.id).where(
                MerchantLink.id.in_([UUID(x) for x in invite_links]),
                MerchantLink.status == "pending",
            )
        )).scalars().all())
    except Exception:
        return rows
    keep = []
    for r in rows:
        eid = r.event_id or ""
        if eid.startswith("merchant_invite:"):
            if str(_payload_of(r).get("link_id") or "") not in pending:
                r.is_read = True
                continue
        keep.append(r)
    return keep


async def unread_count(
    db: AsyncSession, user_id: UUID, side: Optional[str] = None
) -> int:
    """Cheap red-dot count, scoped to one side (personal or business)."""
    rows = (
        await db.execute(
            select(AppNotification)
            .where(AppNotification.user_id == user_id,
                   AppNotification.domain == DOMAIN,
                   AppNotification.is_read.is_(False))
            .order_by(AppNotification.created_at.desc())
            .limit(500)
        )
    ).scalars().all()
    rows = await _drop_stale_invites(db, rows)
    want = (side or "").strip().lower()
    if want in ("personal", "merchant"):
        rows = [r for r in rows if _side_of(r) == want]
    return len(rows)


async def unread_chat_by_link(
    db: AsyncSession, user_id: UUID, side: Optional[str] = None
) -> dict:
    """Unread CHAT notifications grouped by link → red dot on the chat icon."""
    rows = (
        await db.execute(
            select(AppNotification)
            .where(AppNotification.user_id == user_id,
                   AppNotification.domain == DOMAIN,
                   AppNotification.is_read.is_(False),
                   AppNotification.type == "chat_message")
            .order_by(AppNotification.created_at.desc())
            .limit(500)
        )
    ).scalars().all()
    want = (side or "").strip().lower()
    out: dict = {}
    for r in rows:
        if want in ("personal", "merchant") and _side_of(r) != want:
            continue
        lid = str(_payload_of(r).get("link_id") or "")
        if not lid:
            continue
        out[lid] = int(out.get(lid, 0)) + 1
    return {"total": sum(out.values()), "by_link": out}


async def mark_chat_read(
    db: AsyncSession, user_id: UUID, link_id) -> int:
    """Opening a conversation clears its red dot: mark that link's unread
    chat notifications read."""
    rows = (
        await db.execute(
            select(AppNotification).where(
                AppNotification.user_id == user_id,
                AppNotification.domain == DOMAIN,
                AppNotification.type == "chat_message",
                AppNotification.is_read.is_(False),
            ).limit(500)
        )
    ).scalars().all()
    want = str(link_id)
    n = 0
    for r in rows:
        if str(_payload_of(r).get("link_id") or "") == want:
            r.is_read = True
            n += 1
    if n:
        await db.flush()
    return n


async def mark_event_read(
    db: AsyncSession, user_id: UUID, event_id: str
) -> int:
    stmt = update(AppNotification).where(
        AppNotification.user_id == user_id,
        AppNotification.domain == DOMAIN,
        AppNotification.event_id == event_id,
        AppNotification.is_read.is_(False),
    ).values(is_read=True)
    res = await db.execute(stmt)
    return res.rowcount or 0


async def mark_read(
    db: AsyncSession, user_id: UUID,
    notification_ids: Optional[List[UUID]] = None,
) -> int:
    stmt = update(AppNotification).where(
        AppNotification.user_id == user_id,
        AppNotification.domain == DOMAIN,
        AppNotification.is_read.is_(False),
    )
    if notification_ids:
        stmt = stmt.where(AppNotification.id.in_(notification_ids))
    stmt = stmt.values(is_read=True)
    res = await db.execute(stmt)
    return res.rowcount or 0
