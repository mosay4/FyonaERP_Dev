"""Self-service cash admission for every device of the account that owns the
branch. There is no operator plan and no named-device allowlist.

The numbers always come from the till holder's own counted reconciliation:
the device that already holds the measured cash reports it, and every other
device of the same account adopts exactly those facts after saving its own
reservation. The authority creates nothing until the reporter and at least
one other device have both saved their reservations. A device that brings an
old account, balance or history is refused and never merged.
"""

from datetime import datetime, timezone
from hashlib import sha256
import json
import os
import re
from uuid import UUID, uuid4, uuid5

from sqlalchemy import (BigInteger, Boolean, CheckConstraint, Column, String,
                        Table, Uuid, insert, select, text, update)
from sqlalchemy.dialects.postgresql import insert as pg_insert

from . import local_business_cash as cash

NAMESPACE = UUID("6f9619ff-8b86-d011-b42d-00c04fc964ff")


orders = Table(
    "local_cash_link_plans", cash.metadata,
    Column("branch_id", Uuid, primary_key=True),
    Column("workspace_id", Uuid, nullable=False),
    Column("id", Uuid, unique=True, nullable=False),
    Column("actor_id", Uuid, nullable=False),
    Column("primary_session", Uuid),
    Column("account_id", Uuid),
    Column("currency", String(10)),
    Column("balance_minor", BigInteger),
    Column("check_ref", String(21)),
    Column("digest", String(64)),
    Column("primary_prepared", Boolean, nullable=False, server_default="false"),
    Column("state", String(8), nullable=False, server_default="pending"),
    CheckConstraint("state IN ('pending', 'ready', 'canceled')"),
    CheckConstraint("balance_minor IS NULL OR balance_minor BETWEEN 0 AND " + str(cash.MAX_MINOR)),
)

joins = Table(
    "local_cash_link_joins", cash.metadata,
    Column("branch_id", Uuid, primary_key=True),
    Column("workspace_id", Uuid, nullable=False),
    Column("session_id", Uuid, primary_key=True),
    Column("prepared", Boolean, nullable=False, server_default="false"),
    Column("admitted", Boolean, nullable=False, server_default="false"),
)


def enabled():
    return os.getenv("FYONA_QA_CASH_RELAY") == "1" and os.getenv("FYONA_QA_CASH_LINK") == "1"


def plan_id(scope) -> UUID:
    return uuid5(NAMESPACE, f"{scope.workspace_id}:{scope.branch_id}")


async def scope_claim(db, branch, actor, session):
    """The link plan for every live session of the account owning the branch.
    None when this branch is not a device ledger branch of this account."""
    if not enabled():
        return None
    scope = cash.CashScope(branch.organization_id, branch.id)
    if not await _owner(db, scope, actor, session):
        return None
    return plan_id(scope)


def _digest(scope, account_id, currency, balance, sequence=0):
    body = ["fyona.cash.checkpoint.v2", str(scope.workspace_id), str(scope.branch_id),
            sequence, [[str(account_id), currency, balance, False]]]
    return sha256(json.dumps(body, separators=(",", ":")).encode()).hexdigest()


async def _sessions_current(conn, actor, sessions):
    sessions = [s for s in sessions if s is not None]
    if not sessions:
        return False
    count = (await conn.execute(text("""
        SELECT s.id FROM public.user_sessions s JOIN public.users u ON u.id=s.user_id
         WHERE s.id = ANY(CAST(:sessions AS uuid[])) AND s.user_id = :actor
           AND s.is_active AND s.expires_at > now() AND u.status='active'
           AND (u.tokens_valid_after IS NULL OR s.created_at >= u.tokens_valid_after)
         ORDER BY s.id FOR SHARE OF s
    """), {"sessions": sessions, "actor": actor})).all()
    return len(count) == len(sessions)


async def _owner(db, scope, actor, session):
    """Every live session of the account that owns this registered branch."""
    row = (await db.execute(text("""
        SELECT 1 FROM public.fyona_qa_business_ledger_scope l
        JOIN public.fyona_qa_directory_scope d USING (organization_id, account_id, branch_id)
        JOIN public.users u ON u.id=l.account_id AND u.organization_id=l.organization_id
        WHERE l.organization_id=:org AND l.branch_id=:branch AND l.account_id=:actor
          AND u.status='active' AND u.role='owner'
    """), {"org": scope.workspace_id, "branch": scope.branch_id, "actor": actor})).scalar()
    return bool(row) and await _sessions_current(conn=db, actor=actor, sessions=(session,))


async def _frame(scope, session, row):
    if row is None:
        return None
    reported = row["account_id"] is not None
    primary = reported and row["primary_session"] == session
    return {
        "id": str(row["id"]), "state": row["state"],
        "organization_id": str(scope.workspace_id), "branch_id": str(scope.branch_id),
        "actor_id": str(row["actor_id"]), "session_id": str(session),
        "role": "primary" if (primary or not reported) else "replica",
        "account_id": str(row["account_id"]) if row["account_id"] else None,
        "currency": row["currency"],
        "balance_minor": row["balance_minor"],
        "check_ref": row["check_ref"] if primary else None,
        "checkpoint": {"sequence": 0, "digest": row["digest"]} if reported else None,
    }


async def _order(conn, scope, actor):
    key = {"branch_id": scope.branch_id, "workspace_id": scope.workspace_id}
    row = (await conn.execute(select(orders).where(
        orders.c.branch_id == scope.branch_id,
        orders.c.workspace_id == scope.workspace_id,
        orders.c.actor_id == actor,
    ).with_for_update())).mappings().one_or_none()
    if row is not None:
        return dict(row)
    await conn.execute(insert(orders).values(
        **key, id=plan_id(scope), actor_id=actor,
    ))
    return dict((await conn.execute(select(orders).where(
        orders.c.branch_id == scope.branch_id,
        orders.c.workspace_id == scope.workspace_id,
    ))).mappings().one())


async def read_plan(conn, scope, replica):
    """The frame for any live session of the owning account."""
    if not enabled() or not await _owner(conn, scope, replica.actor_id, replica.session_id):
        return None
    row = await _order(conn, scope, replica.actor_id)
    if row["state"] == "ready":
        frame = await cash.cash_checkpoint(conn, scope)
        account, currency, balance, negative = frame.accounts[0]
        row = {**row, "account_id": UUID(account), "currency": currency,
               "balance_minor": balance, "digest": frame.digest}
        data = await _frame(scope, replica.session_id, row)
        data["checkpoint"] = {"sequence": frame.sequence, "digest": frame.digest}
        return data
    return await _frame(scope, replica.session_id, row)


async def prepared(conn, scope, replica, *, plan, account_id, digest,
                   currency=None, balance_minor=None, check_ref=None):
    """Record the measured report, or acknowledge it. Nothing is created
    locally or remotely before the caller saved its own reservation."""
    if not enabled() or not await _owner(conn, scope, replica.actor_id, replica.session_id):
        raise cash.CashAccessDenied
    row = await _order(conn, scope, replica.actor_id)
    if str(row["id"]) != str(plan):
        raise cash.CashAccessDenied
    if row["state"] == "ready":
        return await read_plan(conn, scope, replica)
    if row["state"] != "pending":
        raise cash.CashAccessDenied
    sessions = (await conn.execute(text("""
        SELECT id FROM public.user_sessions
        WHERE user_id=:actor AND is_active AND expires_at > now() ORDER BY id FOR SHARE
    """), {"actor": row["actor_id"]})).scalars().all()
    if replica.session_id not in sessions:
        raise cash.CashAccessDenied

    if row["account_id"] is None:
        # The till holder reports what it counted; this is the only source of
        # the opening facts, never a request body balance guess.
        if (replica.session_id != row["primary_session"]
                and row["primary_session"] is not None):
            raise cash.CashAccessDenied
        if (not isinstance(balance_minor, int) or type(balance_minor) is not int
                or not 0 <= balance_minor <= cash.MAX_MINOR
                or not isinstance(currency, str)
                or not re.fullmatch(r"[A-Z]{3}(?:_[A-Z]{3})?", currency)
                or not isinstance(check_ref, str)
                or not re.fullmatch(r"RCN-[0-9]{8}-[A-F0-9]{8}", check_ref)
                or digest != _digest(scope, account_id, currency, balance_minor)):
            raise cash.CashAccessDenied
        await conn.execute(update(orders).where(
            orders.c.branch_id == scope.branch_id,
            orders.c.workspace_id == scope.workspace_id,
        ).values(
            primary_session=replica.session_id, account_id=account_id,
            currency=currency, balance_minor=balance_minor, check_ref=check_ref,
            digest=digest, primary_prepared=True,
        ))
        row.update(primary_session=replica.session_id, account_id=account_id,
                   currency=currency, balance_minor=balance_minor,
                   check_ref=check_ref, digest=digest, primary_prepared=True)
    else:
        if row["digest"] != digest or row["account_id"] != account_id:
            raise cash.CashAccessDenied
        if replica.session_id == row["primary_session"]:
            await conn.execute(update(orders).where(
                orders.c.branch_id == scope.branch_id,
                orders.c.workspace_id == scope.workspace_id,
            ).values(primary_prepared=True))
            row["primary_prepared"] = True
        else:
            await conn.execute(pg_insert(joins).values(
                branch_id=scope.branch_id, workspace_id=scope.workspace_id,
                session_id=replica.session_id, prepared=True,
            ).on_conflict_do_update(
                index_elements=[joins.c.branch_id, joins.c.session_id],
                set_={"prepared": True},
            ))

    ready = row["primary_prepared"] and await conn.scalar(select(joins.c.session_id).where(
        joins.c.branch_id == scope.branch_id,
        joins.c.workspace_id == scope.workspace_id,
        joins.c.prepared.is_(True),
    ).limit(1)) is not None
    if ready:
        await conn.execute(insert(cash.scopes).values(**scope.key()))
        await cash.enable_settlement_protocol(conn, scope)
        await conn.execute(insert(cash.resources).values(
            **scope.key(), account_id=row["account_id"], currency=row["currency"],
            available_minor=row["balance_minor"], allow_negative=False,
        ))
        await cash.replace_grant(conn, scope, row["actor_id"], version=1,
                                 can_read=True, can_withdraw=True)
        for session in (row["primary_session"], *(await conn.execute(select(
            joins.c.session_id,
        ).where(
            joins.c.branch_id == scope.branch_id,
            joins.c.workspace_id == scope.workspace_id,
            joins.c.prepared.is_(True),
        ))).scalars().all()):
            await cash.admit_replica(conn, scope, cash.CashReplica(row["actor_id"], session),
                                     sequence=0, digest=row["digest"], grant_version=1)
            await conn.execute(update(joins).where(
                joins.c.branch_id == scope.branch_id,
                joins.c.workspace_id == scope.workspace_id,
                joins.c.session_id == session,
            ).values(admitted=True))
        await conn.execute(update(orders).where(
            orders.c.branch_id == scope.branch_id,
            orders.c.workspace_id == scope.workspace_id,
        ).values(state="ready"))
        row["state"] = "ready"
    return await read_plan(conn, scope, replica)