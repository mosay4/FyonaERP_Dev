"""Staged cash arbitration: account grants, per-session replicas and transit.

QA transport only. Admit a replica only after a reconciled checkpoint. The
transport supplies a verified actor and session, never one claimed by a
request body. Commit the transaction before returning a frame.
"""

import json
from dataclasses import dataclass
from hashlib import sha256
from uuid import UUID, uuid4

from sqlalchemy import (
    BigInteger, Boolean, CheckConstraint, Column, ForeignKeyConstraint, Index,
    JSON, MetaData, String, Table, Uuid, and_, delete, insert, select, text, update,
)
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncConnection


MAX_MINOR = 999_999_999_999
metadata = MetaData()


def _scope_columns():
    return (
        Column("workspace_id", Uuid, primary_key=True),
        Column("branch_id", Uuid, primary_key=True),
    )


def _scope_fk():
    return ForeignKeyConstraint(
        ["workspace_id", "branch_id"],
        ["local_cash_scopes.workspace_id", "local_cash_scopes.branch_id"],
    )


scopes = Table(
    "local_cash_scopes", metadata, *_scope_columns(),
    Column("sequence", BigInteger, nullable=False, server_default="0"),
)
grants = Table(
    "local_cash_grants", metadata, *_scope_columns(),
    Column("actor_id", Uuid, primary_key=True),
    Column("version", BigInteger, nullable=False),
    Column("can_withdraw", Boolean, nullable=False),
    Column("can_read", Boolean, nullable=False),
    _scope_fk(),
)
replicas = Table(
    "local_cash_replicas", metadata, *_scope_columns(),
    Column("session_id", Uuid, primary_key=True),
    Column("actor_id", Uuid, nullable=False),
    Column("membership_revision", String(64)),
    Column("checkpoint_sequence", BigInteger, nullable=False),
    Column("checkpoint_digest", String(64), nullable=False),
    Column("retired", Boolean, nullable=False, server_default="false"),
    ForeignKeyConstraint(
        ["workspace_id", "branch_id", "actor_id"],
        ["local_cash_grants.workspace_id", "local_cash_grants.branch_id",
         "local_cash_grants.actor_id"],
    ),
)
resources = Table(
    "local_cash_resources", metadata, *_scope_columns(),
    Column("account_id", Uuid, primary_key=True),
    Column("currency", String(10), nullable=False),
    Column("available_minor", BigInteger, nullable=False),
    Column("allow_negative", Boolean, nullable=False),
    Column("last_spend", Uuid, nullable=True),
    Column("availability_before_last_spend", BigInteger, nullable=True),
    CheckConstraint(f"abs(available_minor) <= {MAX_MINOR}"),
    _scope_fk(),
)
receipts = Table(
    "local_cash_receipts", metadata, *_scope_columns(),
    Column("command_id", Uuid, primary_key=True),
    Column("actor_id", Uuid, nullable=False),
    Column("session_id", Uuid, nullable=False),
    Column("digest", String(64), nullable=False),
    Column("sequence", BigInteger, nullable=False),
    Column("decision", String(32), nullable=False),
    Column("blocked_by", Uuid, nullable=True),
    _scope_fk(),
)
payloads = Table(
    "local_cash_transit", metadata, *_scope_columns(),
    Column("command_id", Uuid, primary_key=True),
    Column("account_id", Uuid, nullable=False),
    Column("currency", String(10), nullable=False),
    Column("delta_minor", BigInteger, nullable=False),
    Column("sequence", BigInteger, nullable=False),
    ForeignKeyConstraint(
        ["workspace_id", "branch_id", "command_id"],
        ["local_cash_receipts.workspace_id", "local_cash_receipts.branch_id",
         "local_cash_receipts.command_id"],
    ),
)
destinations = Table(
    "local_cash_destinations", metadata, *_scope_columns(),
    Column("command_id", Uuid, primary_key=True),
    Column("session_id", Uuid, primary_key=True),
    Column("delivery_key", Uuid, nullable=False),
    ForeignKeyConstraint(
        ["workspace_id", "branch_id", "command_id"],
        ["local_cash_transit.workspace_id", "local_cash_transit.branch_id",
         "local_cash_transit.command_id"],
        ondelete="CASCADE",
    ),
    ForeignKeyConstraint(
        ["workspace_id", "branch_id", "session_id"],
        ["local_cash_replicas.workspace_id", "local_cash_replicas.branch_id",
         "local_cash_replicas.session_id"],
    ),
)
Index("local_cash_destination_poll", destinations.c.workspace_id,
       destinations.c.branch_id, destinations.c.session_id)

# A v3 scope uses the *same* ordered cash authority, with typed deliveries.
# Keep v2 table shapes unchanged. A v2 reader must never interpret an
# equalization as a withdrawal.
settlement_scopes = Table(
    "local_cash_settlement_scopes", metadata, *_scope_columns(), _scope_fk(),
)
settlement_observations = Table(
    "local_cash_settlement_observations", metadata, *_scope_columns(),
    Column("session_id", Uuid, primary_key=True),
    Column("sequence", BigInteger, nullable=False),
    ForeignKeyConstraint(
        ["workspace_id", "branch_id", "session_id"],
        ["local_cash_replicas.workspace_id", "local_cash_replicas.branch_id",
         "local_cash_replicas.session_id"], ondelete="CASCADE",
    ),
)
settlement_payloads = Table(
    "local_cash_settlement_payloads", metadata, *_scope_columns(),
    Column("command_id", Uuid, primary_key=True),
    Column("entries", JSON, nullable=False),
    ForeignKeyConstraint(
        ["workspace_id", "branch_id", "command_id"],
        ["local_cash_transit.workspace_id", "local_cash_transit.branch_id",
         "local_cash_transit.command_id"], ondelete="CASCADE",
    ),
)


@dataclass(frozen=True)
class CashScope:
    workspace_id: UUID
    branch_id: UUID

    def key(self):
        return {"workspace_id": self.workspace_id, "branch_id": self.branch_id}

    def where(self, table):
        return and_(table.c.workspace_id == self.workspace_id,
                    table.c.branch_id == self.branch_id)


@dataclass(frozen=True)
class CashReplica:
    actor_id: UUID
    session_id: UUID
    membership_revision: str | None = None


@dataclass(frozen=True)
class CashCheckpoint:
    sequence: int
    digest: str
    accounts: tuple[tuple[str, str, int, bool], ...]


@dataclass(frozen=True)
class CashDecision:
    command_id: UUID
    sequence: int
    decision: str
    blocked_by: UUID | None = None


@dataclass(frozen=True)
class CashSettlementLine:
    account_id: UUID
    currency: str
    expected_minor: int
    actual_minor: int

    def wire(self):
        return {
            "account_id": str(self.account_id), "currency": self.currency,
            "expected_minor": self.expected_minor, "actual_minor": self.actual_minor,
        }


class CashAccessDenied(Exception):
    pass


class CashReplayConflict(Exception):
    pass


class CashCheckpointChanged(Exception):
    pass


async def _lock_scope(conn: AsyncConnection, scope: CashScope) -> int:
    if conn.dialect.name != "postgresql" or not conn.in_transaction():
        raise RuntimeError("Cash authority requires a PostgreSQL transaction")
    sequence = await conn.scalar(
        select(scopes.c.sequence).where(scope.where(scopes)).with_for_update()
    )
    if sequence is None:
        raise CashAccessDenied
    return sequence


async def _uses_settlement_protocol(conn: AsyncConnection, scope: CashScope) -> bool:
    if not await conn.scalar(text("SELECT to_regclass('public.local_cash_settlement_scopes')")):
        return False
    return await conn.scalar(select(settlement_scopes.c.branch_id).where(
        scope.where(settlement_scopes),
    )) is not None


async def enable_settlement_protocol(conn: AsyncConnection, scope: CashScope) -> None:
    """Internal fixture provisioning, not an upgrade or admission endpoint.

    An existing v2 replica cannot consume v3 events. Do not rebind or
    migrate its history by flipping a flag.
    """
    sequence = await _lock_scope(conn, scope)
    if await _uses_settlement_protocol(conn, scope):
        return
    if sequence != 0 or await conn.scalar(select(replicas.c.session_id).where(
        scope.where(replicas),
    ).limit(1)) is not None:
        raise CashCheckpointChanged
    await conn.execute(insert(settlement_scopes).values(**scope.key()))


async def require_wire_protocol(conn: AsyncConnection, scope: CashScope, version: int) -> None:
    if version not in (2, 3) or (version == 3) != await _uses_settlement_protocol(conn, scope):
        raise CashAccessDenied


def _pending_for_replica(scope, replica):
    return select(destinations.c.command_id).where(
        scope.where(destinations), destinations.c.session_id == replica.session_id,
    )


async def issue_settlement_head(conn: AsyncConnection, scope: CashScope, replica: CashReplica) -> int:
    """Pin the last empty, ordered poll to this authenticated session."""
    sequence = await _lock_scope(conn, scope)
    await _authorized_replica(conn, scope, replica)
    if await conn.scalar(_pending_for_replica(scope, replica).limit(1)) is not None:
        raise CashCheckpointChanged
    await conn.execute(pg_insert(settlement_observations).values(
        **scope.key(), session_id=replica.session_id, sequence=sequence,
    ).on_conflict_do_update(
        index_elements=list(settlement_observations.primary_key),
        set_={"sequence": sequence},
    ))
    return sequence


async def _grant(conn: AsyncConnection, scope: CashScope, actor: UUID):
    return (await conn.execute(
        select(grants).where(scope.where(grants), grants.c.actor_id == actor)
    )).mappings().one_or_none()


async def _replica(conn, scope, session_id):
    return (await conn.execute(select(replicas).where(
        scope.where(replicas), replicas.c.session_id == session_id,
    ))).mappings().one_or_none()


def _matches_replica(row, replica: CashReplica) -> bool:
    return (
        row is not None and not row["retired"]
        and row["actor_id"] == replica.actor_id
        and row["membership_revision"] == replica.membership_revision
    )


async def _authorized_replica(conn, scope, replica):
    row = await _replica(conn, scope, replica.session_id)
    if not _matches_replica(row, replica):
        raise CashAccessDenied
    grant = await _grant(conn, scope, replica.actor_id)
    if grant is None or not grant["can_read"]:
        raise CashAccessDenied
    return row, grant


async def _checkpoint(conn, scope, sequence):
    rows = (await conn.execute(select(
        resources.c.account_id, resources.c.currency,
        resources.c.available_minor, resources.c.allow_negative,
    ).where(scope.where(resources)).order_by(resources.c.account_id))).all()
    accounts = tuple((str(row.account_id), row.currency, row.available_minor,
                      row.allow_negative) for row in rows)
    # The wire/checkpoint contains just the authoritative resource facts,
    # never the Business ledger history or bank descriptions.
    canonical = json.dumps(["fyona.cash.checkpoint.v2", str(scope.workspace_id),
                            str(scope.branch_id), sequence, accounts], separators=(",", ":"))
    return CashCheckpoint(sequence, sha256(canonical.encode()).hexdigest(), accounts)


async def cash_checkpoint(conn: AsyncConnection, scope: CashScope) -> CashCheckpoint:
    """Internal snapshot boundary. Not an endpoint that provisions accounts."""
    return await _checkpoint(conn, scope, await _lock_scope(conn, scope))


async def admit_replica(
    conn: AsyncConnection, scope: CashScope, replica: CashReplica, *,
    sequence: int, digest: str, grant_version: int,
) -> None:
    """Internal activation after the device durably reconciles its snapshot.

    If anything was adjudicated in the meantime, refresh and reconcile again.
    Never silently skip a change that predates this recipient's enrollment.
    """
    current_sequence = await _lock_scope(conn, scope)
    grant = await _grant(conn, scope, replica.actor_id)
    if grant is None or not grant["can_read"] or grant["version"] != grant_version:
        raise CashAccessDenied
    old = await _replica(conn, scope, replica.session_id)
    if old is not None:
        if not _matches_replica(old, replica):
            raise CashAccessDenied
        if old["checkpoint_sequence"] != sequence or old["checkpoint_digest"] != digest:
            raise CashCheckpointChanged
        return
    if sequence != current_sequence:
        raise CashCheckpointChanged
    current = await _checkpoint(conn, scope, current_sequence)
    if not current.accounts or digest != current.digest:
        raise CashCheckpointChanged
    await conn.execute(insert(replicas).values(
        **scope.key(), session_id=replica.session_id, actor_id=replica.actor_id,
        membership_revision=replica.membership_revision,
        checkpoint_sequence=sequence, checkpoint_digest=digest,
    ))


async def replica_checkpoint(conn: AsyncConnection, scope: CashScope, replica: CashReplica):
    await _lock_scope(conn, scope)
    row, _ = await _authorized_replica(conn, scope, replica)
    return row["checkpoint_sequence"], row["checkpoint_digest"]


async def decide_withdrawal(
    conn: AsyncConnection, scope: CashScope, *,
    replica: CashReplica, grant_version: int, command_id: UUID, account_id: UUID,
    currency: str, amount_minor: int, live_can_withdraw: bool = True,
    live_can_reference: bool = True,
) -> CashDecision:
    """First valid arrival wins. No client timestamp or negative override."""
    if type(amount_minor) is not int or not 0 < amount_minor <= MAX_MINOR:
        raise ValueError("Invalid cash amount")
    if (not isinstance(currency, str) or not 3 <= len(currency) <= 10
            or not currency.isascii() or not currency.replace("_", "").isalpha()
            or currency != currency.upper()):
        raise ValueError("Invalid cash currency")
    digest = sha256(f"withdrawal/v1:{account_id}:{currency}:{amount_minor}".encode()).hexdigest()
    sequence = await _lock_scope(conn, scope)
    _, grant = await _authorized_replica(conn, scope, replica)

    receipt = (await conn.execute(select(receipts).where(
        scope.where(receipts), receipts.c.command_id == command_id,
    ))).mappings().one_or_none()
    if receipt is not None:
        if receipt["actor_id"] != replica.actor_id or receipt["session_id"] != replica.session_id:
            raise CashAccessDenied
        if receipt["digest"] != digest:
            raise CashReplayConflict
        return CashDecision(command_id, receipt["sequence"], receipt["decision"],
                            receipt["blocked_by"] if live_can_reference else None)

    blocked_by = None
    if not live_can_withdraw or not grant["can_withdraw"] or grant["version"] != grant_version:
        decision = "permission_changed"
    elif await conn.scalar(select(destinations.c.command_id).join(
        payloads, and_(
            destinations.c.workspace_id == payloads.c.workspace_id,
            destinations.c.branch_id == payloads.c.branch_id,
            destinations.c.command_id == payloads.c.command_id,
        ),
    ).where(
        scope.where(destinations), destinations.c.session_id == replica.session_id,
        payloads.c.delta_minor == 0,
    ).limit(1)) is not None:
        # Its provisional cash post did not see an earlier equalization.
        # Return a receipt that reverses it before the device applies that event.
        decision = "stale_measurement"
    else:
        account = (await conn.execute(select(resources).where(
            scope.where(resources), resources.c.account_id == account_id,
        ))).mappings().one_or_none()
        if account is None or account["currency"] != currency:
            decision = "unavailable_resource"
        else:
            next_balance = account["available_minor"] - amount_minor
            if next_balance < 0 and not account["allow_negative"]:
                decision = "insufficient_balance"
                before = account["availability_before_last_spend"]
                if before is not None and before >= amount_minor:
                    blocked_by = account["last_spend"]
            elif next_balance < -MAX_MINOR:
                decision = "amount_out_of_range"
            else:
                decision = "accepted"
                await conn.execute(update(resources).where(
                    scope.where(resources), resources.c.account_id == account_id,
                ).values(available_minor=next_balance, last_spend=command_id,
                         availability_before_last_spend=account["available_minor"]))

    return await _save_decision(
        conn, scope, replica, command_id, digest, sequence, decision, blocked_by,
        event=(account_id, currency, -amount_minor) if decision == "accepted" else None,
        live_can_reference=live_can_reference,
    )


async def decide_settlement(
    conn: AsyncConnection, scope: CashScope, *, replica: CashReplica,
    command_id: UUID, observed_through: int, grant_version: int,
    entries: list[CashSettlementLine], live_can_equalize: bool,
) -> CashDecision:
    """One CAS for every measured account and the branch's authority order."""
    ordered = sorted(entries, key=lambda line: line.account_id)
    if (not 1 <= len(ordered) <= 100
            or len({line.account_id for line in ordered}) != len(ordered)
            or type(observed_through) is not int or observed_through < 0
            or any(
                type(line.expected_minor) is not int or abs(line.expected_minor) > MAX_MINOR
                or type(line.actual_minor) is not int or not 0 <= line.actual_minor <= MAX_MINOR
                or not 0 < abs(line.actual_minor - line.expected_minor) <= MAX_MINOR
                for line in ordered
            )):
        raise ValueError("Invalid cash settlement")
    payload = [line.wire() for line in ordered]
    digest = sha256(json.dumps(
        ["equalize/v1", observed_through, grant_version, payload], separators=(",", ":"),
    ).encode()).hexdigest()
    sequence = await _lock_scope(conn, scope)
    await require_wire_protocol(conn, scope, 3)
    admitted, grant = await _authorized_replica(conn, scope, replica)
    receipt = (await conn.execute(select(receipts).where(
        scope.where(receipts), receipts.c.command_id == command_id,
    ))).mappings().one_or_none()
    if receipt is not None:
        if (receipt["actor_id"], receipt["session_id"]) != (replica.actor_id, replica.session_id):
            raise CashAccessDenied
        if receipt["digest"] != digest:
            raise CashReplayConflict
        return CashDecision(command_id, receipt["sequence"], receipt["decision"])

    # Poll/ACK must be complete for this replica. A client can't pass a
    # newer sequence to skip an earlier accepted movement (including ABA).
    pending = await conn.scalar(_pending_for_replica(scope, replica).limit(1))
    issued = await conn.scalar(select(settlement_observations.c.sequence).where(
        scope.where(settlement_observations), settlement_observations.c.session_id == replica.session_id,
    ))
    if issued is None:
        issued = admitted["checkpoint_sequence"]
    decision = "accepted"
    if not live_can_equalize or grant["version"] != grant_version:
        decision = "permission_changed"
    elif observed_through != sequence or observed_through != issued or pending is not None:
        decision = "stale_measurement"
    else:
        rows = {r["account_id"]: r for r in (await conn.execute(select(resources).where(
            scope.where(resources), resources.c.account_id.in_([line.account_id for line in ordered]),
        ))).mappings()}
        if any(line.account_id not in rows or rows[line.account_id]["currency"] != line.currency
               for line in ordered):
            decision = "unavailable_resource"
        elif any(rows[line.account_id]["available_minor"] != line.expected_minor for line in ordered):
            decision = "stale_measurement"
        else:
            for line in ordered:
                await conn.execute(update(resources).where(
                    scope.where(resources), resources.c.account_id == line.account_id,
                ).values(available_minor=line.actual_minor, last_spend=None,
                         availability_before_last_spend=None))
    first = ordered[0]
    return await _save_decision(
        conn, scope, replica, command_id, digest, sequence, decision, None,
        # A zero delta is a reserved v3 envelope, never a cash movement.
        event=(first.account_id, first.currency, 0) if decision == "accepted" else None,
        settlement=payload if decision == "accepted" else None,
    )


async def _save_decision(
    conn, scope, replica, command_id, digest, sequence, decision, blocked_by, *,
    event=None, settlement=None, live_can_reference=True,
):
    sequence += 1
    await conn.execute(update(scopes).where(scope.where(scopes)).values(sequence=sequence))
    await conn.execute(insert(receipts).values(
        **scope.key(), command_id=command_id, actor_id=replica.actor_id,
        session_id=replica.session_id, digest=digest,
        sequence=sequence, decision=decision, blocked_by=blocked_by,
    ))

    if event is not None:
        account_id, currency, delta = event
        sessions = (await conn.scalars(select(replicas.c.session_id).where(
            scope.where(replicas), replicas.c.retired.is_(False),
        ))).all()
        if sessions:
            await conn.execute(insert(payloads).values(
                **scope.key(), command_id=command_id, account_id=account_id,
                currency=currency, delta_minor=delta, sequence=sequence,
            ))
            if settlement is not None:
                await conn.execute(insert(settlement_payloads).values(
                    **scope.key(), command_id=command_id, entries=settlement,
                ))
            await conn.execute(insert(destinations), [
                {**scope.key(), "command_id": command_id,
                 "session_id": session_id, "delivery_key": uuid4()}
                for session_id in sessions
            ])
    return CashDecision(command_id, sequence, decision,
                        blocked_by if live_can_reference else None)


async def poll(conn: AsyncConnection, scope: CashScope, replica: CashReplica, *, limit: int = 100):
    await replica_checkpoint(conn, scope, replica)
    rows = (await conn.execute(
        select(payloads.c.command_id, payloads.c.account_id, payloads.c.currency,
               payloads.c.delta_minor, payloads.c.sequence, destinations.c.delivery_key)
        .join(destinations, and_(
            payloads.c.workspace_id == destinations.c.workspace_id,
            payloads.c.branch_id == destinations.c.branch_id,
            payloads.c.command_id == destinations.c.command_id,
        )).where(scope.where(payloads), destinations.c.session_id == replica.session_id)
        .order_by(payloads.c.sequence)
        .limit(min(max(1, limit), 100))
    )).mappings()
    return [dict(row) for row in rows]


async def _purge_if_delivered(conn: AsyncConnection, scope: CashScope, command_id: UUID):
    pending = await conn.scalar(select(destinations.c.session_id).where(
        scope.where(destinations), destinations.c.command_id == command_id,
    ).limit(1))
    if pending is None:
        await conn.execute(delete(payloads).where(
            scope.where(payloads), payloads.c.command_id == command_id,
        ))


async def acknowledge(
    conn: AsyncConnection, scope: CashScope, replica: CashReplica,
    command_id: UUID, delivery_key: UUID,
) -> None:
    """Only assigned recipients can remove their own delivery. Retry is a no-op."""
    await replica_checkpoint(conn, scope, replica)
    assigned = await conn.scalar(select(destinations.c.delivery_key).where(
        scope.where(destinations), destinations.c.command_id == command_id,
        destinations.c.session_id == replica.session_id,
    ))
    if assigned is None:
        return  # Lost acknowledgement; other devices are untouched.
    if assigned != delivery_key:
        raise CashAccessDenied
    await conn.execute(delete(destinations).where(
        scope.where(destinations), destinations.c.command_id == command_id,
        destinations.c.session_id == replica.session_id,
    ))
    await _purge_if_delivered(conn, scope, command_id)


async def _retire_sessions(conn, scope, sessions):
    if not sessions:
        return
    await conn.execute(update(replicas).where(
        scope.where(replicas), replicas.c.session_id.in_(sessions),
    ).values(retired=True))
    affected = (await conn.scalars(delete(destinations).where(
        scope.where(destinations), destinations.c.session_id.in_(sessions),
    ).returning(destinations.c.command_id))).all()
    for command in set(affected):
        await _purge_if_delivered(conn, scope, command)


async def retire_replica(conn: AsyncConnection, scope: CashScope, replica: CashReplica):
    """Internal retirement (revocation or a lost/retired phone); never an ACK."""
    await _lock_scope(conn, scope)
    row = await _replica(conn, scope, replica.session_id)
    if row is None or row["actor_id"] != replica.actor_id:
        raise CashAccessDenied
    await _retire_sessions(conn, scope, [replica.session_id])


async def retire_stale_destinations(conn: AsyncConnection, scope: CashScope, stale_sessions):
    """Only the verified transport may supply this check, never a device.

    Retirement is final for that replica and is not proof of delivery. Keep
    absence/temporary offline separate from explicit auth losses.
    """
    await _lock_scope(conn, scope)
    rows = (await conn.execute(select(replicas).where(
        scope.where(replicas), replicas.c.retired.is_(False),
    ))).mappings().all()
    gone = await stale_sessions(rows)
    await _retire_sessions(conn, scope, gone)


async def replace_grant(
    conn: AsyncConnection, scope: CashScope, actor: UUID, *,
    version: int, can_read: bool, can_withdraw: bool,
) -> None:
    """Internal authority update (not a client operation).

    Revoking readability removes that account from delivery. It must be
    provisioned from a fresh snapshot if it regains the grant.
    """
    await _lock_scope(conn, scope)
    old = await _grant(conn, scope, actor)
    if version < 1 or (old is not None and old["version"] >= version):
        raise ValueError("Grant version must advance")
    if old is None:
        await conn.execute(insert(grants).values(
            **scope.key(), actor_id=actor, version=version,
            can_read=can_read, can_withdraw=can_withdraw,
        ))
    else:
        await conn.execute(update(grants).where(
            scope.where(grants), grants.c.actor_id == actor,
        ).values(version=version, can_read=can_read, can_withdraw=can_withdraw))
    if not can_read:
        sessions = (await conn.scalars(select(replicas.c.session_id).where(
            scope.where(replicas), replicas.c.actor_id == actor,
            replicas.c.retired.is_(False),
        ))).all()
        await _retire_sessions(conn, scope, sessions)
