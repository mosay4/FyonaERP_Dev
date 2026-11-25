"""Personal relay: the server carries one user's changes between that user's
devices, then forgets them. It is never a store of Personal data.

Every Personal write is committed (encrypted) on the device that made it. The
device then hands the operation here. The relay:

* stamps it with the next sequence number of the user (arrival order: every
  device of the user applies the same order without the server reading it);
* keeps one inbox row per destination replica (every other live device of the
  same user);
* deletes the payload the moment the last destination acknowledged it, or
  after RETENTION days, flagging the replicas that missed it for a resync.
  Only an (id, seq) tombstone stays, so a late retry is not re-sequenced.

A replica is one local Personal database (one install of the app for one
user). Payloads are opaque bytes (normally ciphertext): the relay never reads
them. Modelled on app.domain.services.business_relay, in its own tables.
"""

from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
import json
from typing import Iterable
from uuid import UUID, uuid4

from sqlalchemy import (BigInteger, Boolean, Column, Index, LargeBinary,
                        MetaData, String, Table, Uuid, delete, func, insert,
                        select, text, update)
from sqlalchemy.ext.asyncio import AsyncConnection

metadata = MetaData()

RETENTION = timedelta(days=90)
MAX_PAYLOAD = 16 * 1024 * 1024
MAX_SNAPSHOT = 48 * 1024 * 1024
MAX_BATCH = 200
OP_KINDS = frozenset({"ops"})
CONTROL_KINDS = frozenset({"snapshot_request", "snapshot"})

replicas = Table(
    "personal_relay_replicas", metadata,
    Column("id", Uuid, primary_key=True),
    Column("user_id", Uuid, nullable=False, index=True),
    Column("session_id", Uuid, nullable=True),
    Column("created_us", BigInteger, nullable=False),
    Column("last_seen_us", BigInteger, nullable=False),
    Column("resync_required", Boolean, nullable=False, default=False),
    Column("retired", Boolean, nullable=False, default=False),
)

heads = Table(
    "personal_relay_heads", metadata,
    Column("user_id", Uuid, primary_key=True),
    Column("last_seq", BigInteger, nullable=False),
)

ops = Table(
    "personal_relay_ops", metadata,
    Column("id", Uuid, primary_key=True),
    Column("user_id", Uuid, nullable=False),
    # Control messages (snapshot hand-over) are not part of the ordered log.
    Column("seq", BigInteger, nullable=True),
    Column("kind", String(32), nullable=False),
    Column("replica_id", Uuid, nullable=False),
    Column("payload", LargeBinary, nullable=False),
    Column("created_us", BigInteger, nullable=False),
    Index("personal_relay_ops_user_seq", "user_id", "seq", unique=True),
    Index("personal_relay_ops_created", "created_us"),
)

inbox = Table(
    "personal_relay_inbox", metadata,
    Column("op_id", Uuid, primary_key=True),
    Column("replica_id", Uuid, primary_key=True),
    Index("personal_relay_inbox_replica", "replica_id"),
)

# Tombstones of delivered operations: id and order only, no payload.
delivered = Table(
    "personal_relay_delivered", metadata,
    Column("id", Uuid, primary_key=True),
    Column("user_id", Uuid, nullable=False),
    Column("seq", BigInteger, nullable=False),
    Column("created_us", BigInteger, nullable=False),
    Index("personal_relay_delivered_created", "created_us"),
)


class RelayAccessDenied(Exception):
    pass


class RelayInvalid(ValueError):
    pass


def _now_us(now: datetime | None = None) -> int:
    return int((now or datetime.now(timezone.utc)).timestamp() * 1_000_000)


async def _active_user(conn: AsyncConnection, user: UUID) -> bool:
    return bool(await conn.scalar(text(
        "SELECT 1 FROM public.users WHERE id = :user AND status = 'active'"
    ), {"user": user}))


async def _replica(conn: AsyncConnection, user: UUID, replica_id: UUID, *,
                   lock: bool = False):
    query = select(replicas).where(
        replicas.c.id == replica_id,
        replicas.c.user_id == user,
        replicas.c.retired.is_(False),
    )
    row = (await conn.execute(query.with_for_update() if lock else query)
           ).mappings().one_or_none()
    if row is None:
        raise RelayAccessDenied
    return row


async def _head(conn: AsyncConnection, user: UUID) -> int:
    return await conn.scalar(select(heads.c.last_seq)
                             .where(heads.c.user_id == user)) or 0


async def register(conn: AsyncConnection, *, user: UUID,
                   session: UUID | None, replica_id: UUID,
                   now: datetime | None = None) -> dict:
    """Bind a local Personal database to this user. A brand-new replica of a
    user who already has other live replicas must first receive a snapshot
    from one of them (the server has nothing to give it)."""
    if not await _active_user(conn, user):
        raise RelayAccessDenied
    stamp = _now_us(now)
    existing = (await conn.execute(select(replicas).where(
        replicas.c.id == replica_id,
    ).with_for_update())).mappings().one_or_none()
    if existing is not None:
        if existing["user_id"] != user:
            raise RelayAccessDenied
        # A retired device that comes back missed what was carried meanwhile.
        resync = existing["resync_required"] or existing["retired"]
        await conn.execute(update(replicas).where(replicas.c.id == replica_id)
                           .values(session_id=session, last_seen_us=stamp,
                                   retired=False, resync_required=resync))
    else:
        others = await conn.scalar(select(func.count()).select_from(replicas)
                                   .where(replicas.c.user_id == user,
                                          replicas.c.retired.is_(False)))
        resync = bool(others)
        await conn.execute(insert(replicas).values(
            id=replica_id, user_id=user, session_id=session,
            created_us=stamp, last_seen_us=stamp,
            resync_required=resync, retired=False,
        ))
    return {"replica_id": str(replica_id), "resync_required": resync,
            "head": await _head(conn, user)}


async def _destinations(conn: AsyncConnection, user: UUID,
                        exclude: UUID) -> list[UUID]:
    rows = (await conn.execute(select(replicas.c.id).where(
        replicas.c.user_id == user,
        replicas.c.retired.is_(False),
        replicas.c.id != exclude,
    ))).scalars().all()
    return sorted(rows, key=str)


async def _next_seq(conn: AsyncConnection, user: UUID) -> int:
    return await conn.scalar(text("""
        INSERT INTO personal_relay_heads (user_id, last_seq) VALUES (:user, 1)
        ON CONFLICT (user_id)
        DO UPDATE SET last_seq = personal_relay_heads.last_seq + 1
        RETURNING last_seq
    """), {"user": user})


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


async def push(conn: AsyncConnection, *, user: UUID, replica_id: UUID,
               items: Iterable[dict], now: datetime | None = None) -> list[dict]:
    """Sequence operations in arrival order. Idempotent by operation id: a
    retried push returns the original sequence number."""
    source = await _replica(conn, user, replica_id)
    batch = list(items)
    if len(batch) > MAX_BATCH:
        raise RelayInvalid("Too many operations")
    stamp = _now_us(now)
    result = []
    for item in batch:
        op_id = UUID(str(item["id"]))
        kind = str(item.get("kind") or "ops")
        if kind not in OP_KINDS:
            raise RelayInvalid("Unknown operation kind")
        payload = _payload(item.get("payload"), MAX_PAYLOAD)
        seen = (await conn.execute(select(ops.c.seq, ops.c.user_id)
                                   .where(ops.c.id == op_id))).first()
        if seen is None:
            seen = (await conn.execute(select(delivered.c.seq, delivered.c.user_id)
                                       .where(delivered.c.id == op_id))).first()
        if seen is not None:
            if seen.user_id != user or seen.seq is None:
                raise RelayAccessDenied
            result.append({"id": str(op_id), "seq": seen.seq})
            continue
        seq = await _next_seq(conn, user)
        audience = await _destinations(conn, user, source["id"])
        await conn.execute(insert(ops).values(
            id=op_id, user_id=user, seq=seq, kind=kind,
            replica_id=source["id"], payload=payload, created_us=stamp,
        ))
        if audience:
            await conn.execute(insert(inbox), [
                {"op_id": op_id, "replica_id": r} for r in audience])
        else:
            await _forget(conn, user, op_id, seq)
        result.append({"id": str(op_id), "seq": seq})
    await conn.execute(update(replicas).where(replicas.c.id == source["id"])
                       .values(last_seen_us=stamp))
    return result


async def _forget(conn: AsyncConnection, user: UUID, op_id: UUID,
                  seq: int | None) -> None:
    """Drop the payload. Only (id, seq) is kept for ordered operations."""
    if seq is not None:
        await conn.execute(text("""
            INSERT INTO personal_relay_delivered (id, user_id, seq, created_us)
            VALUES (:id, :user, :seq, :at) ON CONFLICT (id) DO NOTHING
        """), {"id": op_id, "user": user, "seq": seq, "at": _now_us()})
    await conn.execute(delete(inbox).where(inbox.c.op_id == op_id))
    await conn.execute(delete(ops).where(ops.c.id == op_id))


async def _forget_if_done(conn: AsyncConnection, user: UUID,
                          op_id: UUID) -> bool:
    left = await conn.scalar(select(func.count()).select_from(inbox)
                             .where(inbox.c.op_id == op_id))
    if left:
        return False
    row = (await conn.execute(select(ops.c.seq).where(
        ops.c.id == op_id, ops.c.user_id == user))).first()
    if row is None:
        return False
    await _forget(conn, user, op_id, row.seq)
    return True


async def pull(conn: AsyncConnection, *, user: UUID, replica_id: UUID,
               limit: int = MAX_BATCH, now: datetime | None = None) -> dict:
    """What waits for this replica: control messages first, then operations
    in sequence order."""
    source = await _replica(conn, user, replica_id)
    rows = (await conn.execute(
        select(ops).join(inbox, inbox.c.op_id == ops.c.id).where(
            inbox.c.replica_id == source["id"],
            ops.c.user_id == user,
        ).order_by(ops.c.seq.is_(None).desc(), ops.c.seq, ops.c.created_us)
        .limit(max(1, min(limit, MAX_BATCH)))
    )).mappings().all()
    remaining = await conn.scalar(
        select(func.count()).select_from(inbox)
        .where(inbox.c.replica_id == source["id"])) or 0
    await conn.execute(update(replicas).where(replicas.c.id == source["id"])
                       .values(last_seen_us=_now_us(now)))
    return {
        "items": [{
            "id": str(r["id"]), "seq": r["seq"], "kind": r["kind"],
            "replica_id": str(r["replica_id"]),
            "payload": base64.b64encode(r["payload"]).decode(),
        } for r in rows],
        "drained": remaining <= len(rows),
        "head": await _head(conn, user),
        "resync_required": source["resync_required"],
    }


async def ack(conn: AsyncConnection, *, user: UUID, replica_id: UUID,
              op_ids: Iterable[UUID]) -> int:
    source = await _replica(conn, user, replica_id)
    purged = 0
    for op_id in op_ids:
        await conn.execute(delete(inbox).where(
            inbox.c.op_id == op_id, inbox.c.replica_id == source["id"]))
        if await _forget_if_done(conn, user, op_id):
            purged += 1
    return purged


async def request_snapshot(conn: AsyncConnection, *, user: UUID,
                           replica_id: UUID, now: datetime | None = None) -> dict:
    """Ask the user's other live replicas for a full copy. The first to answer
    serves it; the request itself is a control message."""
    source = await _replica(conn, user, replica_id)
    audience = await _destinations(conn, user, source["id"])
    if not audience:
        # Nobody else holds data: this replica is the only copy.
        await conn.execute(update(replicas).where(replicas.c.id == source["id"])
                           .values(resync_required=False))
        return {"requested": False, "resync_required": False}
    # One open request per replica is enough.
    await _drop_requests(conn, user, source["id"])
    op_id = uuid4()
    await conn.execute(insert(ops).values(
        id=op_id, user_id=user, seq=None, kind="snapshot_request",
        replica_id=source["id"],
        payload=json.dumps({"replica_id": str(source["id"])}).encode(),
        created_us=_now_us(now),
    ))
    await conn.execute(insert(inbox), [
        {"op_id": op_id, "replica_id": r} for r in audience])
    await conn.execute(update(replicas).where(replicas.c.id == source["id"])
                       .values(resync_required=True))
    return {"requested": True, "resync_required": True}


async def _drop_requests(conn: AsyncConnection, user: UUID,
                         requester: UUID) -> None:
    ids = (await conn.execute(select(ops.c.id).where(
        ops.c.user_id == user, ops.c.kind == "snapshot_request",
        ops.c.replica_id == requester))).scalars().all()
    for op_id in ids:
        await _forget(conn, user, op_id, None)


async def serve_snapshot(conn: AsyncConnection, *, user: UUID,
                         replica_id: UUID, target: UUID, payload,
                         now: datetime | None = None) -> bool:
    """A live replica hands its full copy to one waiting replica of the same
    user. The blob is delivered once, then deleted."""
    source = await _replica(conn, user, replica_id)
    if target == source["id"]:
        return False
    waiting = (await conn.execute(select(replicas).where(
        replicas.c.id == target, replicas.c.user_id == user,
        replicas.c.retired.is_(False), replicas.c.resync_required.is_(True),
    ))).mappings().one_or_none()
    if waiting is None:
        return False
    pending = await conn.scalar(
        select(func.count()).select_from(ops).join(inbox, inbox.c.op_id == ops.c.id)
        .where(ops.c.kind == "snapshot", inbox.c.replica_id == target))
    if pending:
        return False
    blob = _payload(payload, MAX_SNAPSHOT)
    # The request is answered: nobody else needs to serve it.
    await _drop_requests(conn, user, target)
    op_id = uuid4()
    await conn.execute(insert(ops).values(
        id=op_id, user_id=user, seq=None, kind="snapshot",
        replica_id=source["id"], payload=blob, created_us=_now_us(now),
    ))
    await conn.execute(insert(inbox).values(op_id=op_id, replica_id=target))
    return True


async def snapshot_applied(conn: AsyncConnection, *, user: UUID,
                           replica_id: UUID) -> None:
    """The waiting replica stored its copy: the snapshot blob (and any open
    request of it) is deleted, and it now follows the ordered log."""
    source = await _replica(conn, user, replica_id, lock=True)
    blobs = (await conn.execute(
        select(ops.c.id).join(inbox, inbox.c.op_id == ops.c.id).where(
            ops.c.kind == "snapshot", ops.c.user_id == user,
            inbox.c.replica_id == source["id"]))).scalars().all()
    for op_id in blobs:
        await _forget(conn, user, op_id, None)
    await _drop_requests(conn, user, source["id"])
    await conn.execute(update(replicas).where(replicas.c.id == source["id"])
                       .values(resync_required=False))


async def my_replicas(conn: AsyncConnection, *, user: UUID) -> list[dict]:
    """The caller's live devices: metadata and counts only, never payloads."""
    pending = (select(inbox.c.replica_id, func.count().label("n"))
               .group_by(inbox.c.replica_id).subquery())
    rows = (await conn.execute(
        select(replicas, func.coalesce(pending.c.n, 0).label("pending"))
        .outerjoin(pending, pending.c.replica_id == replicas.c.id)
        .where(replicas.c.user_id == user, replicas.c.retired.is_(False))
        .order_by(replicas.c.created_us))).mappings().all()
    return [{"replica_id": str(r["id"]), "created_us": r["created_us"],
             "last_seen_us": r["last_seen_us"],
             "resync_required": r["resync_required"],
             "pending": int(r["pending"]),
             "session_id": str(r["session_id"]) if r["session_id"] else None}
            for r in rows]


async def retire(conn: AsyncConnection, *, user: UUID, replica_id: UUID) -> None:
    """A device leaves (logout, uninstall): nothing waits for it any more, and
    what only waited for it is deleted."""
    source = await _replica(conn, user, replica_id, lock=True)
    await _retire(conn, user, source["id"])


async def _retire(conn: AsyncConnection, user: UUID, rid: UUID) -> None:
    await conn.execute(update(replicas).where(replicas.c.id == rid)
                       .values(retired=True))
    await _drop_requests(conn, user, rid)
    waiting = (await conn.execute(select(inbox.c.op_id)
                                  .where(inbox.c.replica_id == rid))).scalars().all()
    await conn.execute(delete(inbox).where(inbox.c.replica_id == rid))
    for op_id in waiting:
        await _forget_if_done(conn, user, op_id)


async def purge_expired(conn: AsyncConnection, *, now: datetime | None = None,
                        retention: timedelta = RETENTION) -> int:
    """Nothing waits on the server longer than the retention. A replica that
    misses an operation this way must take a snapshot when it returns."""
    cutoff = _now_us((now or datetime.now(timezone.utc)) - retention)
    expired = (await conn.execute(select(ops.c.id, ops.c.user_id, ops.c.seq)
                                  .where(ops.c.created_us < cutoff))).all()
    for op_id, user, seq in expired:
        missed = (await conn.execute(select(inbox.c.replica_id)
                                     .where(inbox.c.op_id == op_id))).scalars().all()
        if missed and seq is not None:
            await conn.execute(update(replicas).where(replicas.c.id.in_(missed))
                               .values(resync_required=True))
        await _forget(conn, user, op_id, seq)
    await conn.execute(delete(delivered).where(delivered.c.created_us < cutoff))
    return len(expired)


async def install(conn: AsyncConnection) -> None:
    await conn.run_sync(metadata.create_all)
