"""Business relay: the server is a mailbox and a sequencer, never a store.

Every Business write is committed on the device that made it. The device then
hands the operation here. The relay:

* stamps it with the next sequence number of the organization (arrival order —
  "the first one to reach the server wins" is decided by this number on every
  device, without the server knowing any balance);
* keeps one inbox row per destination replica (every other device that works
  on the branch);
* deletes the operation the moment the last destination acknowledged it, or
  after RETENTION days, flagging the replicas that missed it for a resync.

A replica is one local Business database (one install of the app for one
account/organization). It is stable across logins, unlike a JWT session.
Payloads are opaque JSON bytes: the relay never reads Business data.
"""

from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
import json
from typing import Iterable
from uuid import UUID

from sqlalchemy import (BigInteger, Boolean, Column, Index, LargeBinary,
                        MetaData, String, Table, Uuid, delete, func, insert,
                        select, text, update)
from sqlalchemy.ext.asyncio import AsyncConnection

metadata = MetaData()

RETENTION = timedelta(days=90)
MAX_PAYLOAD = 4 * 1024 * 1024
MAX_SNAPSHOT = 48 * 1024 * 1024
MAX_BATCH = 200
OP_KINDS = frozenset({"ops"})
CONTROL_KINDS = frozenset({"snapshot_request", "snapshot"})

replicas = Table(
    "business_relay_replicas", metadata,
    Column("id", Uuid, primary_key=True),
    Column("organization_id", Uuid, nullable=False, index=True),
    Column("user_id", Uuid, nullable=False),
    Column("session_id", Uuid, nullable=True),
    Column("created_us", BigInteger, nullable=False),
    Column("last_seen_us", BigInteger, nullable=False),
    Column("resync_required", Boolean, nullable=False, default=False),
    Column("retired", Boolean, nullable=False, default=False),
)

heads = Table(
    "business_relay_heads", metadata,
    Column("organization_id", Uuid, primary_key=True),
    Column("last_seq", BigInteger, nullable=False),
)

ops = Table(
    "business_relay_ops", metadata,
    Column("id", Uuid, primary_key=True),
    Column("organization_id", Uuid, nullable=False),
    Column("branch_id", Uuid, nullable=True),
    # Control messages (snapshot hand-over) are not part of the ordered log.
    Column("seq", BigInteger, nullable=True),
    Column("kind", String(32), nullable=False),
    Column("replica_id", Uuid, nullable=False),
    Column("actor_user_id", Uuid, nullable=False),
    Column("payload", LargeBinary, nullable=False),
    Column("created_us", BigInteger, nullable=False),
    Index("business_relay_ops_org_seq", "organization_id", "seq", unique=True),
)

inbox = Table(
    "business_relay_inbox", metadata,
    Column("op_id", Uuid, primary_key=True),
    Column("replica_id", Uuid, primary_key=True),
    Index("business_relay_inbox_replica", "replica_id"),
)


class RelayAccessDenied(Exception):
    pass


class RelayInvalid(ValueError):
    pass


def _now_us(now: datetime | None = None) -> int:
    return int((now or datetime.now(timezone.utc)).timestamp() * 1_000_000)


async def _user_can_use_branch(conn: AsyncConnection, org: UUID, user: UUID,
                               branch: UUID | None) -> bool:
    """Members of the organization, and employees whose active membership
    covers the branch."""
    own = await conn.scalar(text("""
        SELECT 1 FROM public.users u
        WHERE u.id = :user AND u.organization_id = :org AND u.status = 'active'
    """), {"user": user, "org": org})
    if own:
        # Branches are born on the owner's devices: the server may not hold a
        # row for them, and does not need one.
        return True
    if not await _has_members(conn):
        return False
    row = (await conn.execute(text("""
        SELECT m.branch_ids, m.all_branches FROM public.branch_members m
        JOIN public.users u ON u.id = m.user_id
        WHERE m.user_id = :user AND m.organization_id = :org
          AND m.status = 'active' AND u.status = 'active'
    """), {"user": user, "org": org})).first()
    if row is None:
        return False
    if branch is None or row.all_branches:
        return True
    try:
        return str(branch) in {str(b) for b in json.loads(row.branch_ids or "[]")}
    except ValueError:
        return False


async def _has_members(conn: AsyncConnection) -> bool:
    return await conn.scalar(text(
        "SELECT to_regclass('public.branch_members') IS NOT NULL"
    )) is True


async def _replica(conn: AsyncConnection, org: UUID, user: UUID,
                   replica_id: UUID, *, lock: bool = False):
    query = select(replicas).where(
        replicas.c.id == replica_id,
        replicas.c.organization_id == org,
        replicas.c.user_id == user,
        replicas.c.retired.is_(False),
    )
    row = (await conn.execute(query.with_for_update() if lock else query)
           ).mappings().one_or_none()
    if row is None:
        raise RelayAccessDenied
    return row


async def register(conn: AsyncConnection, *, org: UUID, user: UUID,
                   session: UUID | None, replica_id: UUID,
                   now: datetime | None = None) -> dict:
    """Bind a local database to this account. A brand-new replica of an
    organization that other live replicas already work in must first receive a
    snapshot (the server has nothing to give it)."""
    if not await _user_can_use_branch(conn, org, user, None):
        raise RelayAccessDenied
    stamp = _now_us(now)
    existing = (await conn.execute(select(replicas).where(
        replicas.c.id == replica_id,
    ).with_for_update())).mappings().one_or_none()
    if existing is not None:
        if (existing["organization_id"] != org or existing["user_id"] != user
                or existing["retired"]):
            raise RelayAccessDenied
        await conn.execute(update(replicas).where(replicas.c.id == replica_id)
                           .values(session_id=session, last_seen_us=stamp))
        resync = existing["resync_required"]
    else:
        others = await conn.scalar(select(func.count()).select_from(replicas)
                                   .where(replicas.c.organization_id == org,
                                          replicas.c.retired.is_(False)))
        resync = bool(others)
        await conn.execute(insert(replicas).values(
            id=replica_id, organization_id=org, user_id=user,
            session_id=session, created_us=stamp, last_seen_us=stamp,
            resync_required=resync, retired=False,
        ))
    head = await conn.scalar(select(heads.c.last_seq)
                             .where(heads.c.organization_id == org)) or 0
    return {"replica_id": str(replica_id), "resync_required": resync,
            "head": head}


async def _destinations(conn: AsyncConnection, org: UUID, branch: UUID | None,
                        exclude: UUID) -> list[UUID]:
    rows = (await conn.execute(select(replicas.c.id, replicas.c.user_id).where(
        replicas.c.organization_id == org,
        replicas.c.retired.is_(False),
        replicas.c.id != exclude,
    ))).all()
    out = []
    for rid, uid in rows:
        if await _user_can_use_branch(conn, org, uid, branch):
            out.append(rid)
    return sorted(out, key=str)


async def _next_seq(conn: AsyncConnection, org: UUID) -> int:
    current = await conn.scalar(select(heads.c.last_seq).where(
        heads.c.organization_id == org).with_for_update())
    if current is None:
        await conn.execute(insert(heads).values(organization_id=org, last_seq=1))
        return 1
    await conn.execute(update(heads).where(heads.c.organization_id == org)
                       .values(last_seq=current + 1))
    return current + 1


async def push(conn: AsyncConnection, *, org: UUID, user: UUID,
               replica_id: UUID, items: Iterable[dict],
               now: datetime | None = None) -> list[dict]:
    """Sequence operations in arrival order. Idempotent by operation id: a
    retried push returns the original sequence number."""
    source = await _replica(conn, org, user, replica_id)
    stamp = _now_us(now)
    result = []
    for item in list(items)[:MAX_BATCH]:
        op_id = UUID(str(item["id"]))
        kind = str(item.get("kind") or "ops")
        if kind not in OP_KINDS:
            raise RelayInvalid("Unknown operation kind")
        payload = _payload(item.get("payload"), MAX_PAYLOAD)
        branch = UUID(str(item["branch_id"])) if item.get("branch_id") else None
        seen = (await conn.execute(select(ops.c.seq, ops.c.organization_id)
                                   .where(ops.c.id == op_id))).first()
        if seen is not None:
            if seen.organization_id != org:
                raise RelayAccessDenied
            result.append({"id": str(op_id), "seq": seen.seq})
            continue
        prior = await conn.scalar(text(
            "SELECT seq FROM business_relay_delivered WHERE id = :id AND organization_id = :org"
        ), {"id": op_id, "org": org}) if await _delivered_table(conn) else None
        if prior is not None:
            result.append({"id": str(op_id), "seq": prior})
            continue
        if not await _user_can_use_branch(conn, org, user, branch):
            raise RelayAccessDenied
        seq = await _next_seq(conn, org)
        audience = await _destinations(conn, org, branch, source["id"])
        await conn.execute(insert(ops).values(
            id=op_id, organization_id=org, branch_id=branch, seq=seq, kind=kind,
            replica_id=source["id"], actor_user_id=user, payload=payload,
            created_us=stamp,
        ))
        if audience:
            await conn.execute(insert(inbox), [
                {"op_id": op_id, "replica_id": r} for r in audience])
        else:
            await _forget(conn, org, op_id, seq)
        result.append({"id": str(op_id), "seq": seq})
    await conn.execute(update(replicas).where(replicas.c.id == source["id"])
                       .values(last_seen_us=stamp))
    return result


def _payload(value, limit: int) -> bytes:
    if isinstance(value, (dict, list)):
        data = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()
    elif isinstance(value, str):
        try:
            data = base64.b64decode(value, validate=True)
        except ValueError as exc:
            raise RelayInvalid("Invalid payload") from exc
    else:
        raise RelayInvalid("Invalid payload")
    if not data or len(data) > limit:
        raise RelayInvalid("Invalid payload size")
    return data


async def _delivered_table(conn: AsyncConnection) -> bool:
    return await conn.scalar(text(
        "SELECT to_regclass('public.business_relay_delivered') IS NOT NULL"
    )) is True


async def _forget(conn: AsyncConnection, org: UUID, op_id: UUID,
                  seq: int | None) -> None:
    """Drop the payload. Only the (id, seq) pair is kept, so a late retry of an
    already delivered push is answered with its original order, not
    re-sequenced. It holds no Business data."""
    if seq is not None and await _delivered_table(conn):
        await conn.execute(text("""
            INSERT INTO business_relay_delivered (id, organization_id, seq, created_us)
            VALUES (:id, :org, :seq, :at) ON CONFLICT (id) DO NOTHING
        """), {"id": op_id, "org": org, "seq": seq, "at": _now_us()})
    await conn.execute(delete(inbox).where(inbox.c.op_id == op_id))
    await conn.execute(delete(ops).where(ops.c.id == op_id))


async def pull(conn: AsyncConnection, *, org: UUID, user: UUID,
               replica_id: UUID, limit: int = MAX_BATCH,
               now: datetime | None = None) -> dict:
    source = await _replica(conn, org, user, replica_id)
    rows = (await conn.execute(
        select(ops).join(inbox, inbox.c.op_id == ops.c.id).where(
            inbox.c.replica_id == source["id"],
            ops.c.organization_id == org,
        ).order_by(ops.c.seq.is_(None).desc(), ops.c.seq, ops.c.created_us)
        .limit(max(1, min(limit, MAX_BATCH)))
    )).mappings().all()
    remaining = await conn.scalar(
        select(func.count()).select_from(inbox)
        .where(inbox.c.replica_id == source["id"])) or 0
    head = await conn.scalar(select(heads.c.last_seq)
                             .where(heads.c.organization_id == org)) or 0
    await conn.execute(update(replicas).where(replicas.c.id == source["id"])
                       .values(last_seen_us=_now_us(now)))
    return {
        "items": [{
            "id": str(r["id"]), "seq": r["seq"], "kind": r["kind"],
            "branch_id": str(r["branch_id"]) if r["branch_id"] else None,
            "replica_id": str(r["replica_id"]),
            "actor_user_id": str(r["actor_user_id"]),
            "payload": base64.b64encode(r["payload"]).decode(),
        } for r in rows],
        "drained": remaining <= len(rows),
        "head": head,
        "resync_required": source["resync_required"],
    }


async def ack(conn: AsyncConnection, *, org: UUID, user: UUID,
              replica_id: UUID, op_ids: Iterable[UUID]) -> int:
    source = await _replica(conn, org, user, replica_id)
    purged = 0
    for op_id in op_ids:
        await conn.execute(delete(inbox).where(
            inbox.c.op_id == op_id, inbox.c.replica_id == source["id"]))
        left = await conn.scalar(select(func.count()).select_from(inbox)
                                 .where(inbox.c.op_id == op_id))
        if not left:
            row = (await conn.execute(select(ops.c.seq).where(
                ops.c.id == op_id, ops.c.organization_id == org))).first()
            if row is not None:
                await _forget(conn, org, op_id, row.seq)
                purged += 1
    return purged


async def request_snapshot(conn: AsyncConnection, *, org: UUID, user: UUID,
                           replica_id: UUID, now: datetime | None = None) -> dict:
    """Ask the organization's other live replicas for a full copy. Whoever
    answers first serves it; the request itself is a control message."""
    source = await _replica(conn, org, user, replica_id)
    audience = await _destinations(conn, org, None, source["id"])
    if not audience:
        # Nobody else holds data: this replica is the only copy.
        await conn.execute(update(replicas).where(replicas.c.id == source["id"])
                           .values(resync_required=False))
        return {"requested": False, "resync_required": False}
    from uuid import uuid4
    op_id = uuid4()
    await conn.execute(insert(ops).values(
        id=op_id, organization_id=org, branch_id=None, seq=None,
        kind="snapshot_request", replica_id=source["id"], actor_user_id=user,
        payload=json.dumps({"replica_id": str(source["id"])}).encode(),
        created_us=_now_us(now),
    ))
    await conn.execute(insert(inbox), [
        {"op_id": op_id, "replica_id": r} for r in audience])
    return {"requested": True, "resync_required": True}


async def serve_snapshot(conn: AsyncConnection, *, org: UUID, user: UUID,
                         replica_id: UUID, target: UUID, payload,
                         now: datetime | None = None) -> bool:
    """A live replica hands its full copy to one waiting replica."""
    source = await _replica(conn, org, user, replica_id)
    waiting = (await conn.execute(select(replicas).where(
        replicas.c.id == target, replicas.c.organization_id == org,
        replicas.c.retired.is_(False), replicas.c.resync_required.is_(True),
    ))).mappings().one_or_none()
    if waiting is None:
        return False
    # One snapshot per waiting replica: a second answer is not needed.
    pending = await conn.scalar(
        select(func.count()).select_from(ops).join(inbox, inbox.c.op_id == ops.c.id)
        .where(ops.c.kind == "snapshot", inbox.c.replica_id == target))
    if pending:
        return False
    from uuid import uuid4
    op_id = uuid4()
    await conn.execute(insert(ops).values(
        id=op_id, organization_id=org, branch_id=None, seq=None,
        kind="snapshot", replica_id=source["id"], actor_user_id=user,
        payload=_payload(payload, MAX_SNAPSHOT), created_us=_now_us(now),
    ))
    await conn.execute(insert(inbox).values(op_id=op_id, replica_id=target))
    return True


async def snapshot_applied(conn: AsyncConnection, *, org: UUID, user: UUID,
                           replica_id: UUID) -> None:
    source = await _replica(conn, org, user, replica_id, lock=True)
    await conn.execute(update(replicas).where(replicas.c.id == source["id"])
                       .values(resync_required=False))


async def retire_sessions(conn: AsyncConnection, *, org: UUID) -> int:
    """A replica whose last session was revoked (logout, removed device) stops
    receiving; what waited for it is dropped."""
    rows = (await conn.execute(text("""
        SELECT r.id FROM business_relay_replicas r
        JOIN public.user_sessions s ON s.id = r.session_id
        WHERE r.organization_id = :org AND NOT r.retired AND NOT s.is_active
    """), {"org": org})).scalars().all()
    for rid in rows:
        await _retire(conn, org, rid)
    return len(rows)


async def _retire(conn: AsyncConnection, org: UUID, rid: UUID) -> None:
    await conn.execute(update(replicas).where(replicas.c.id == rid)
                       .values(retired=True))
    waiting = (await conn.execute(select(inbox.c.op_id)
                                  .where(inbox.c.replica_id == rid))).scalars().all()
    await conn.execute(delete(inbox).where(inbox.c.replica_id == rid))
    for op_id in waiting:
        left = await conn.scalar(select(func.count()).select_from(inbox)
                                 .where(inbox.c.op_id == op_id))
        if not left:
            seq = await conn.scalar(select(ops.c.seq).where(ops.c.id == op_id))
            await _forget(conn, org, op_id, seq)


async def purge_expired(conn: AsyncConnection, *, now: datetime | None = None,
                        retention: timedelta = RETENTION) -> int:
    """Nothing waits on the server longer than the retention. A replica that
    misses an operation this way must take a snapshot when it returns."""
    cutoff = _now_us((now or datetime.now(timezone.utc)) - retention)
    expired = (await conn.execute(select(ops.c.id, ops.c.organization_id, ops.c.seq)
                                  .where(ops.c.created_us < cutoff))).all()
    for op_id, org, seq in expired:
        missed = (await conn.execute(select(inbox.c.replica_id)
                                     .where(inbox.c.op_id == op_id))).scalars().all()
        if missed:
            await conn.execute(update(replicas).where(replicas.c.id.in_(missed))
                               .values(resync_required=True))
        await _forget(conn, org, op_id, seq)
    if await _delivered_table(conn):
        await conn.execute(text(
            "DELETE FROM business_relay_delivered WHERE created_us < :cutoff"
        ), {"cutoff": cutoff})
    return len(expired)


DELIVERED_DDL = """
CREATE TABLE IF NOT EXISTS business_relay_delivered (
  id UUID PRIMARY KEY,
  organization_id UUID NOT NULL,
  seq BIGINT NOT NULL,
  created_us BIGINT NOT NULL
)
"""


async def install(conn: AsyncConnection) -> None:
    await conn.run_sync(metadata.create_all)
    await conn.execute(text(DELIVERED_DDL))
