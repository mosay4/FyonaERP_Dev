"""Branch media relay: the server carries the payload, it never keeps it.

A device that changes a branch picture or name keeps the result on its own
disk and hands one payload here for the other devices of the same branch.
Every destination stores it locally and acknowledges it. The moment the last
one does, the payload is deleted. Nothing is stored on the server.
"""

import base64
from datetime import datetime, timezone
import re
from uuid import UUID, uuid4

from sqlalchemy import (BigInteger, JSON, Column, LargeBinary, MetaData,
                        String, Table, Uuid, delete, select, text, update)
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncSession

metadata = MetaData()

transit = Table(
    "business_media_transit", metadata,
    Column("id", Uuid, primary_key=True),
    Column("organization_id", Uuid, nullable=False),
    Column("branch_id", Uuid, nullable=False),
    Column("actor_id", Uuid, nullable=False),
    Column("session_id", Uuid, nullable=False),
    Column("kind", String(32), nullable=False),
    Column("target_id", String(64), nullable=False),
    Column("payload", LargeBinary, nullable=False),
    Column("destinations", JSON, nullable=False),
    Column("acked", JSON, nullable=False),
    Column("created_us", BigInteger, nullable=False),
)

MAX_PAYLOAD = 3 * 1024 * 1024
KINDS = ("branch_update",)


class MediaAccessDenied(Exception):
    pass


def _where(table, **match):
    from sqlalchemy import and_
    return and_(*(table.c[key] == value for key, value in match.items()))


async def destinations(conn, *, workspace_id: UUID, branch_id: UUID,
                       exclude: UUID) -> list[str]:
    """Every other live device that works on this branch: the account's own
    devices and the employees linked to it."""
    rows = (await conn.execute(text("""
        SELECT DISTINCT s.id
        FROM public.user_sessions s
        JOIN public.users u ON u.id = s.user_id
        WHERE s.is_active AND s.expires_at > now() AND s.id <> :exclude
          AND u.status = 'active' AND u.organization_id = :org
    """), {"org": workspace_id, "exclude": exclude})).scalars().all()
    found = {str(row) for row in rows}
    if await conn.scalar(text(
        "SELECT to_regclass('public.branch_members') IS NOT NULL",
    )) is True:
        extra = (await conn.execute(text("""
            SELECT DISTINCT s.id
            FROM public.user_sessions s
            JOIN public.users u ON u.id = s.user_id
            JOIN public.branch_members m ON m.user_id = u.id
            WHERE s.is_active AND s.expires_at > now() AND s.id <> :exclude
              AND u.status = 'active'
              AND m.organization_id = :org AND m.status = 'active'
        """), {"org": workspace_id, "exclude": exclude})).scalars().all()
        found |= {str(row) for row in extra}
    return sorted(found)


async def submit(conn: AsyncConnection, *, workspace_id: UUID, branch_id: UUID,
                 actor_id: UUID, session_id: UUID, kind: str,
                 target_id: str, payload: bytes) -> dict:
    if kind not in KINDS or not payload or len(payload) > MAX_PAYLOAD:
        raise ValueError("Invalid transit payload")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", target_id):
        raise ValueError("Invalid transit target")
    await _require_branch(conn, workspace_id, branch_id, actor_id)
    audience = await destinations(conn, workspace_id=workspace_id,
                                  branch_id=branch_id, exclude=session_id)
    row = dict(
        id=uuid4(), organization_id=workspace_id, branch_id=branch_id,
        actor_id=actor_id, session_id=session_id, kind=kind,
        target_id=target_id, payload=bytes(payload), destinations=audience,
        acked=[], created_us=int(datetime.now(timezone.utc).timestamp() * 1e6),
    )
    await conn.execute(transit.insert().values(**row))
    if not audience:
        # Nobody else to carry it to: the payload is never kept.
        await conn.execute(delete(transit).where(transit.c.id == row["id"]))
    return {"id": str(row["id"]), "destinations": audience}


async def poll(conn: AsyncConnection, *, workspace_id: UUID,
               session_id: UUID) -> list[dict]:
    rows = (await conn.execute(select(transit).where(
        transit.c.organization_id == workspace_id,
    ))).mappings().all()
    out = []
    for row in rows:
        if session_id in [UUID(x) for x in row["destinations"]] \
                and session_id not in [UUID(x) for x in row["acked"]]:
            out.append({
                "id": str(row["id"]), "kind": row["kind"],
                "target_id": row["target_id"],
                "payload": base64.b64encode(row["payload"]).decode(),
            })
    return out


async def ack(conn: AsyncConnection, *, workspace_id: UUID, session_id: UUID,
              payload_id: UUID) -> bool:
    row = (await conn.execute(select(transit).where(
        transit.c.id == payload_id,
        transit.c.organization_id == workspace_id,
    ).with_for_update())).mappings().one_or_none()
    if row is None:
        return True
    acked = {UUID(x) for x in row["acked"]}
    if session_id not in [UUID(x) for x in row["destinations"]]:
        raise MediaAccessDenied
    acked.add(session_id)
    if {UUID(x) for x in row["destinations"]} <= acked:
        # The last device stored it locally: the payload leaves the server.
        await conn.execute(delete(transit).where(transit.c.id == payload_id))
        return True
    await conn.execute(update(transit).where(transit.c.id == payload_id).values(
        acked=sorted(str(x) for x in acked),
    ))
    return False


async def _require_branch(conn, workspace_id, branch_id, actor_id) -> None:
    ok = (await conn.execute(text("""
        SELECT 1 FROM public.users u
        JOIN public.branches b ON b.organization_id = u.organization_id
        WHERE u.id = :actor AND u.organization_id = :org AND u.status = 'active'
          AND b.id = :branch AND b.is_active AND NOT b.is_archived
    """), {"actor": actor_id, "org": workspace_id, "branch": branch_id})).scalar()
    if not ok:
        raise MediaAccessDenied