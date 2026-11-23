"""Peer relay between a merchant and a linked customer/supplier account.

After the link is accepted (online, once), every debt update the merchant
records and every chat message either side writes is saved on the author's
device first. The device hands it here; the relay carries it to the other
side's devices (and the author's other devices), sends the usual
notification, and deletes the payload once every destination stored it (or
after RETENTION). Nothing is kept.
"""

from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
import json
from typing import Iterable
from uuid import UUID, uuid4

from sqlalchemy import (BigInteger, Column, JSON, LargeBinary, MetaData, String,
                        Table, Uuid, delete, select, text, update)
from sqlalchemy.ext.asyncio import AsyncConnection

metadata = MetaData()

RETENTION = timedelta(days=90)
MAX_PAYLOAD = 2 * 1024 * 1024
KINDS = frozenset({"debt_snapshot", "chat", "chat_receipt"})

devices = Table(
    "business_peer_devices", metadata,
    Column("device_id", Uuid, primary_key=True),
    Column("user_id", Uuid, nullable=False, index=True),
    Column("last_seen_us", BigInteger, nullable=False),
)

transit = Table(
    "business_peer_transit", metadata,
    Column("id", Uuid, primary_key=True),
    Column("link_id", Uuid, nullable=False, index=True),
    Column("kind", String(24), nullable=False),
    Column("from_user", Uuid, nullable=False),
    Column("from_device", Uuid, nullable=False),
    Column("payload", LargeBinary, nullable=False),
    Column("destinations", JSON, nullable=False),
    Column("acked", JSON, nullable=False),
    Column("created_us", BigInteger, nullable=False),
)


class PeerDenied(Exception):
    pass


def _now_us(now: datetime | None = None) -> int:
    return int((now or datetime.now(timezone.utc)).timestamp() * 1_000_000)


async def install(conn: AsyncConnection) -> None:
    await conn.run_sync(metadata.create_all)


async def register(conn: AsyncConnection, *, user: UUID, device: UUID) -> None:
    owner = await conn.scalar(select(devices.c.user_id).where(devices.c.device_id == device))
    if owner is not None and owner != user:
        raise PeerDenied
    if owner is None:
        await conn.execute(devices.insert().values(
            device_id=device, user_id=user, last_seen_us=_now_us()))
    else:
        await conn.execute(update(devices).where(devices.c.device_id == device)
                           .values(last_seen_us=_now_us()))


async def _sides(conn: AsyncConnection, link_id: UUID) -> tuple[list[UUID], list[UUID], dict]:
    """(merchant users, party users, link row) of an accepted link."""
    link = (await conn.execute(text("""
        SELECT id, merchant_org_id, external_user_id, party_kind, status
        FROM public.merchant_links WHERE id = :link
    """), {"link": link_id})).mappings().one_or_none()
    if link is None or link["status"] != "accepted" or link["external_user_id"] is None:
        raise PeerDenied
    merchants = list((await conn.execute(text("""
        SELECT id FROM public.users
        WHERE organization_id = :org AND status = 'active'
    """), {"org": link["merchant_org_id"]})).scalars().all())
    return merchants, [link["external_user_id"]], dict(link)


async def push(conn: AsyncConnection, *, user: UUID, device: UUID, link_id: UUID,
               kind: str, op_id: UUID, payload) -> dict:
    if kind not in KINDS:
        raise ValueError("Unknown kind")
    data = (json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
            if isinstance(payload, (dict, list)) else base64.b64decode(payload))
    if not data or len(data) > MAX_PAYLOAD:
        raise ValueError("Invalid payload")
    merchants, party, link = await _sides(conn, link_id)
    if user not in merchants and user not in party:
        raise PeerDenied
    if kind == "debt_snapshot" and user not in merchants:
        raise PeerDenied  # only the merchant publishes debts
    if await conn.scalar(select(transit.c.id).where(transit.c.id == op_id)):
        return {"id": str(op_id), "duplicate": True, "link": link}
    users = merchants + party
    audience = [str(d) for d in (await conn.execute(select(devices.c.device_id).where(
        devices.c.user_id.in_(users), devices.c.device_id != device,
    ))).scalars().all()]
    if audience:
        await conn.execute(transit.insert().values(
            id=op_id, link_id=link_id, kind=kind, from_user=user, from_device=device,
            payload=data, destinations=sorted(audience), acked=[],
            created_us=_now_us(),
        ))
    recipients = party if user in merchants else merchants
    return {"id": str(op_id), "duplicate": False, "link": link,
            "recipients": [str(r) for r in recipients]}


async def pull(conn: AsyncConnection, *, user: UUID, device: UUID,
               limit: int = 200) -> list[dict]:
    owner = await conn.scalar(select(devices.c.user_id).where(devices.c.device_id == device))
    if owner != user:
        raise PeerDenied
    await conn.execute(update(devices).where(devices.c.device_id == device)
                       .values(last_seen_us=_now_us()))
    rows = (await conn.execute(select(transit).order_by(transit.c.created_us)
                               .limit(2000))).mappings().all()
    out = []
    for row in rows:
        if str(device) in row["destinations"] and str(device) not in row["acked"]:
            out.append({"id": str(row["id"]), "link_id": str(row["link_id"]),
                        "kind": row["kind"], "from_user": str(row["from_user"]),
                        "created_us": row["created_us"],
                        "payload": base64.b64encode(row["payload"]).decode()})
            if len(out) >= limit:
                break
    return out


async def ack(conn: AsyncConnection, *, user: UUID, device: UUID,
              ids: Iterable[UUID]) -> int:
    owner = await conn.scalar(select(devices.c.user_id).where(devices.c.device_id == device))
    if owner != user:
        raise PeerDenied
    gone = 0
    for op_id in ids:
        row = (await conn.execute(select(transit).where(transit.c.id == op_id)
                                  .with_for_update())).mappings().one_or_none()
        if row is None or str(device) not in row["destinations"]:
            continue
        acked = set(row["acked"]) | {str(device)}
        if set(row["destinations"]) <= acked:
            await conn.execute(delete(transit).where(transit.c.id == op_id))
            gone += 1
        else:
            await conn.execute(update(transit).where(transit.c.id == op_id)
                               .values(acked=sorted(acked)))
    return gone


async def purge_expired(conn: AsyncConnection, *, now: datetime | None = None) -> int:
    cutoff = _now_us((now or datetime.now(timezone.utc)) - RETENTION)
    result = await conn.execute(delete(transit).where(transit.c.created_us < cutoff))
    return result.rowcount or 0
