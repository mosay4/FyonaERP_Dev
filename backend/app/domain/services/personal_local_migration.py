"""Move a user's existing server-side Personal data onto their devices, once.

For a local Personal user (app.core.personal_local_mode) the rows still held
in the eight legacy Personal tables are exported to the user's device, which
imports them into its encrypted ledger as a baseline and confirms (ack) the
exact bytes it stored. From that moment a grace period starts; the hourly
purge then deletes the user's rows (children first) together with their sync
bookkeeping. Nothing of another user and nothing of Business is touched.

Export bytes are stable: the first export is kept until the device confirms
it; a later export (another device of the same user, after the first ack)
is rebuilt from the same — by then frozen, every write is refused — rows
with the same snapshot id, so it has the same bytes and digest.
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from uuid import UUID, uuid4

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from app.core import personal_local_mode

_TABLE = "public.personal_local_migrations"
FORMAT = "fyona-personal-baseline"
VERSION = 1

# (entity type in the app, table). Children of a row come after it here and
# are deleted before it (reverse order) by the purge.
TABLES: tuple[tuple[str, str], ...] = (
    ("personal_bank_account", "personal_bank_accounts"),
    ("personal_budget", "personal_budgets"),
    ("personal_budget_category", "personal_budget_categories"),
    ("personal_savings_goal", "personal_savings_goals"),
    ("personal_debt", "personal_debts"),
    ("personal_debt_payment", "personal_debt_payments"),
    ("personal_recurring_transaction", "personal_recurring_transactions"),
    ("personal_transaction", "personal_transactions"),
)
# Purge order (children first): every reference to a row is gone before it.
PURGE_ORDER = (
    "personal_transactions",
    "personal_debt_payments",
    "personal_budget_categories",
    "personal_recurring_transactions",
    "personal_savings_goals",
    "personal_debts",
    "personal_budgets",
    "personal_bank_accounts",
)
# Sync bookkeeping of Personal rows (org-scoped tables; matched by the
# user's own row ids, so nothing of another user goes).
PERSONAL_SYNC_TYPES = tuple(t for t, _ in TABLES)


class MigrationRejected(ValueError):
    pass


async def install(conn: AsyncConnection) -> None:
    await conn.execute(text(f"""
        CREATE TABLE IF NOT EXISTS {_TABLE} (
          user_id uuid PRIMARY KEY,
          snapshot_id uuid NOT NULL UNIQUE,
          digest text NOT NULL,
          body bytea NOT NULL,
          created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
          imported_at timestamptz,
          purge_after timestamptz,
          purged_at timestamptz
        )
    """))


def _where(table: str) -> str:
    if table == "personal_budget_categories":
        return ("budget_id IN (SELECT id FROM public.personal_budgets "
                "WHERE user_id = :user)")
    return "user_id = :user"


async def legacy_rows(conn: AsyncConnection, user: UUID) -> int:
    """Rows the server still holds for [user] (soft-deleted ones included)."""
    total = 0
    for _type, table in TABLES:
        if not await conn.scalar(text(f"SELECT to_regclass('public.{table}') IS NOT NULL")):
            continue
        total += await conn.scalar(text(
            f"SELECT COUNT(*) FROM public.{table} WHERE {_where(table)}"
        ), {"user": user}) or 0
    return total


async def _record(conn: AsyncConnection, user: UUID):
    return (await conn.execute(text(f"""
        SELECT snapshot_id, digest, body, imported_at, purge_after, purged_at
        FROM {_TABLE} WHERE user_id = :user
    """), {"user": user})).mappings().one_or_none()


def _iso(value):
    return value.isoformat() if isinstance(value, datetime) else value


async def status(conn: AsyncConnection, *, user: UUID) -> dict:
    row = await _record(conn, user)
    left = await legacy_rows(conn, user)
    out = {"local": True, "rows": left}
    if row is None:
        out.update(needed=left > 0, imported=False)
        return out
    imported = row["imported_at"] is not None
    out.update(
        needed=not imported and row["purged_at"] is None,
        imported=imported,
        snapshot_id=str(row["snapshot_id"]),
        digest=row["digest"],
        purge_after=_iso(row["purge_after"]),
        purged=row["purged_at"] is not None,
    )
    return out


def canonical(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"), allow_nan=False).encode()


def digest_of(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


async def _serialize(conn: AsyncConnection, user: UUID, snapshot_id: UUID) -> dict:
    """Every live Personal row of [user] in the shape the app keeps (the
    REST list serializers), deterministic: sorted by id, no clock fields."""
    from sqlalchemy.ext.asyncio import AsyncSession
    from sqlalchemy import select
    from app.api.v1 import personal_finance as api
    from app.domain.entities.personal_entities import (
        PersonalBankAccount, PersonalBudget, PersonalBudgetCategory,
        PersonalDebt, PersonalDebtPayment, PersonalRecurringTransaction,
        PersonalSavingsGoal, PersonalTransaction,
    )

    session = AsyncSession(bind=conn, expire_on_commit=False)

    async def live(model, *where):
        cond = [getattr(model, "is_deleted") == False] if hasattr(model, "is_deleted") else []  # noqa: E712
        stmt = select(model).where(*where, *cond).order_by(model.id)
        return (await session.execute(stmt)).scalars().all()

    accounts = await live(PersonalBankAccount, PersonalBankAccount.user_id == user)
    budgets = await live(PersonalBudget, PersonalBudget.user_id == user)
    budget_ids = [b.id for b in budgets]
    categories = (await live(PersonalBudgetCategory,
                             PersonalBudgetCategory.budget_id.in_(budget_ids))
                  if budget_ids else [])
    goals = await live(PersonalSavingsGoal, PersonalSavingsGoal.user_id == user)
    debts = await live(PersonalDebt, PersonalDebt.user_id == user)
    payments = await live(PersonalDebtPayment, PersonalDebtPayment.user_id == user)
    recurring = await live(PersonalRecurringTransaction,
                           PersonalRecurringTransaction.user_id == user)
    transactions = await live(PersonalTransaction, PersonalTransaction.user_id == user)

    def cat(c) -> dict:
        return {
            "id": str(c.id), "budget_id": str(c.budget_id), "name": c.name,
            "type": c.type,
            "allocated_amount": float(c.allocated_amount) if c.allocated_amount else 0,
            "spent_amount": float(c.spent_amount) if c.spent_amount else 0,
            "currency": c.currency,
            "goal_id": str(c.goal_id) if c.goal_id else None,
            "debt_id": str(c.debt_id) if c.debt_id else None,
            "created_at": _iso(c.created_at), "updated_at": _iso(c.updated_at),
        }

    cats_by_budget: dict[str, list] = {}
    for c in categories:
        cats_by_budget.setdefault(str(c.budget_id), []).append(cat(c))
    paid: dict[str, float] = {}
    for p in payments:
        paid[str(p.debt_id)] = paid.get(str(p.debt_id), 0.0) + float(p.amount or 0)

    budget_rows = []
    for b in budgets:
        b._categories_loaded = cats_by_budget.get(str(b.id), [])
        budget_rows.append(api._budget_to_dict(b))
    debt_rows = []
    for d in debts:
        row = await api._debt_to_dict(d, _paid_total=paid.get(str(d.id), 0.0))
        # Today's date must not change the bytes; the app derives «overdue».
        row["status"] = "paid" if d.is_paid else "active"
        debt_rows.append(row)

    entities = {
        "personal_bank_account": [api._account_to_dict(a) for a in accounts],
        "personal_budget": budget_rows,
        "personal_budget_category": [cat(c) for c in categories],
        "personal_savings_goal": [api._goal_to_dict(g) for g in goals],
        "personal_debt": debt_rows,
        "personal_debt_payment": [api._payment_to_dict(p) for p in payments],
        "personal_recurring_transaction": [api._recurring_to_dict(r) for r in recurring],
        "personal_transaction": [api._tx_to_dict(t) for t in transactions],
    }
    return {
        "format": FORMAT,
        "v": VERSION,
        "snapshot_id": str(snapshot_id),
        "user_id": str(user),
        "entities": entities,
        "counts": {k: len(v) for k, v in entities.items()},
        # What the device checks after importing (exact server values).
        "balances": {r["id"]: r["balance"] for r in entities["personal_bank_account"]},
    }


async def _build(conn: AsyncConnection, user: UUID, snapshot_id: UUID) -> bytes:
    return canonical(await _serialize(conn, user, snapshot_id))


async def export(conn: AsyncConnection, *, user: UUID) -> dict:
    """The same bytes on every retry; a new export only if none exists."""
    row = await _record(conn, user)
    if row is not None:
        if row["purged_at"] is not None:
            raise MigrationRejected("purged")
        body = bytes(row["body"])
        if not body:
            # Confirmed by a device already: rebuilt from the frozen rows.
            body = await _build(conn, user, row["snapshot_id"])
            if digest_of(body) != row["digest"]:
                await conn.execute(text(f"""
                    UPDATE {_TABLE} SET digest = :digest WHERE user_id = :user
                """), {"digest": digest_of(body), "user": user})
        return {"snapshot_id": str(row["snapshot_id"]), "digest": digest_of(body),
                "body": body}
    snapshot_id = uuid4()
    body = await _build(conn, user, snapshot_id)
    digest = digest_of(body)
    inserted = await conn.scalar(text(f"""
        INSERT INTO {_TABLE} (user_id, snapshot_id, digest, body)
        VALUES (:user, :id, :digest, :body)
        ON CONFLICT (user_id) DO NOTHING
        RETURNING snapshot_id
    """), {"user": user, "id": snapshot_id, "digest": digest, "body": body})
    if inserted is None:  # a concurrent first export won
        return await export(conn, user=user)
    return {"snapshot_id": str(snapshot_id), "digest": digest, "body": body}


async def acknowledge(conn: AsyncConnection, *, user: UUID, snapshot_id: UUID,
                      digest: str, now: datetime | None = None) -> dict:
    """The device stored exactly this export. The first confirmation starts
    the grace period; later ones (other devices) change nothing."""
    now = now or datetime.now(timezone.utc)
    row = (await conn.execute(text(f"""
        UPDATE {_TABLE} SET
          imported_at = COALESCE(imported_at, :now),
          purge_after = COALESCE(purge_after, :after),
          body = ''::bytea
        WHERE user_id = :user AND snapshot_id = :id AND digest = :digest
        RETURNING imported_at, purge_after
    """), {"user": user, "id": snapshot_id, "digest": digest, "now": now,
           "after": now + personal_local_mode.GRACE})).mappings().one_or_none()
    if row is None:
        raise MigrationRejected("No matching export")
    return {"imported_at": _iso(row["imported_at"]),
            "purge_after": _iso(row["purge_after"])}


async def acknowledged(conn: AsyncConnection, user: UUID) -> bool:
    """A device of [user] holds the baseline (the server's copy is retired)."""
    if not await conn.scalar(text(
            "SELECT to_regclass('public.personal_local_migrations') IS NOT NULL")):
        return False
    return bool(await conn.scalar(text(f"""
        SELECT 1 FROM {_TABLE} WHERE user_id = :user AND imported_at IS NOT NULL
    """), {"user": user}))


async def exported(conn: AsyncConnection, user: UUID) -> bool:
    """The baseline was taken: from then on the server rows are frozen."""
    if not await conn.scalar(text(
            "SELECT to_regclass('public.personal_local_migrations') IS NOT NULL")):
        return False
    return bool(await conn.scalar(text(
        f"SELECT 1 FROM {_TABLE} WHERE user_id = :user"), {"user": user}))


async def _purge_user(conn: AsyncConnection, user: UUID) -> int:
    ids: dict[str, list] = {}
    for etype, table in TABLES:
        if not await conn.scalar(text(f"SELECT to_regclass('public.{table}') IS NOT NULL")):
            continue
        ids[etype] = list((await conn.execute(text(
            f"SELECT id FROM public.{table} WHERE {_where(table)}"
        ), {"user": user})).scalars().all())
    org = await conn.scalar(text(
        "SELECT organization_id FROM public.users WHERE id = :user"), {"user": user})
    removed = 0
    async with conn.begin_nested():
        all_ids = [i for v in ids.values() for i in v]
        if org is not None:
            for table, extra in (("sync_logs", ""), ("conflict_logs", ""),
                                 ("entity_versions", " OR last_modified_by = :user")):
                if not await conn.scalar(text(f"SELECT to_regclass('public.{table}') IS NOT NULL")):
                    continue
                result = await conn.execute(text(f"""
                    DELETE FROM public.{table}
                    WHERE organization_id = :org AND entity_type = ANY(:types)
                      AND (entity_id = ANY(:ids){extra})
                """), {"org": org, "types": list(PERSONAL_SYNC_TYPES),
                       "ids": all_ids, "user": user})
                removed += result.rowcount or 0
            # Batch counters carry no data and no user; they are dropped only
            # when the organization is this user's alone.
            others = await conn.scalar(text("""
                SELECT COUNT(*) FROM public.users WHERE organization_id = :org AND id <> :user
            """), {"org": org, "user": user})
            if not others and await conn.scalar(text(
                    "SELECT to_regclass('public.sync_batches') IS NOT NULL")):
                result = await conn.execute(text(
                    "DELETE FROM public.sync_batches WHERE organization_id = :org"
                ), {"org": org})
                removed += result.rowcount or 0
        for table in PURGE_ORDER:
            if not await conn.scalar(text(f"SELECT to_regclass('public.{table}') IS NOT NULL")):
                continue
            result = await conn.execute(text(
                f"DELETE FROM public.{table} WHERE {_where(table)}"
            ), {"user": user})
            removed += result.rowcount or 0
    return removed


async def purge_due(conn: AsyncConnection, *, now: datetime | None = None) -> dict:
    """Delete the legacy rows of every user whose grace period ended.
    Idempotent: a purged user is skipped; a user with new rows (none should
    exist) is purged again."""
    now = now or datetime.now(timezone.utc)
    if not await conn.scalar(text(
            "SELECT to_regclass('public.personal_local_migrations') IS NOT NULL")):
        return {"users": 0, "rows": 0}
    due = (await conn.execute(text(f"""
        SELECT user_id FROM {_TABLE}
        WHERE imported_at IS NOT NULL AND purge_after IS NOT NULL
          AND purge_after <= :now AND purged_at IS NULL
        ORDER BY purge_after
    """), {"now": now})).scalars().all()
    rows = 0
    for user in due:
        rows += await _purge_user(conn, user)
        await conn.execute(text(f"""
            UPDATE {_TABLE} SET purged_at = :now, body = ''::bytea WHERE user_id = :user
        """), {"now": now, "user": user})
    return {"users": len(due), "rows": rows}


async def counts(conn: AsyncConnection) -> dict:
    """Counts only (admin): no user and no amount."""
    if not await conn.scalar(text(
            "SELECT to_regclass('public.personal_local_migrations') IS NOT NULL")):
        return {"exported": 0, "imported": 0, "purged": 0, "waiting_purge": 0}
    row = (await conn.execute(text(f"""
        SELECT COUNT(*) AS exported,
               COUNT(imported_at) AS imported,
               COUNT(purged_at) AS purged,
               COUNT(*) FILTER (WHERE imported_at IS NOT NULL AND purged_at IS NULL)
                 AS waiting_purge
        FROM {_TABLE}
    """))).mappings().one()
    return dict(row)
