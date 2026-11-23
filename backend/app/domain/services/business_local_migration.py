"""Move a branch's existing server-side Business data onto its devices, once.

For a local-mode business, a branch that still holds legacy rows on the
server is exported (same serializer and integrity controls as the cutover
rehearsal) to the owner's device, which imports it into its ledger; the relay
then carries it to the other devices. The server records the device receipt.
Deleting the legacy rows from the server is a separate, explicit step.
"""

from __future__ import annotations

import json
from uuid import UUID, uuid4

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

from app.domain.services import local_business_cutover as cutover

_TABLE = "public.business_local_migrations"


class MigrationRejected(ValueError):
    pass


async def install(conn: AsyncConnection) -> None:
    await conn.execute(text(f"""
        CREATE TABLE IF NOT EXISTS {_TABLE} (
          branch_id uuid PRIMARY KEY,
          organization_id uuid NOT NULL,
          account_id uuid NOT NULL,
          snapshot_id uuid NOT NULL UNIQUE,
          digest text NOT NULL,
          body bytea NOT NULL,
          created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
          imported_at timestamptz
        )
    """))
    exists = await conn.scalar(text(
        f"SELECT to_regproc('{cutover._branch_function}') IS NOT NULL"))
    if not exists:
        await conn.execute(text(cutover._row_branches_sql()))


async def legacy_rows(conn: AsyncConnection, branch_id: UUID) -> int:
    total = 0
    for name, rule in sorted(cutover._rules.items()):
        # The branch's own row is not Business data to move.
        if not rule.archive or name == "branches":
            continue
        total += await conn.scalar(text(f"""
            SELECT COUNT(*) FROM public.{name} src
            WHERE :branch = ANY({cutover._branch_function}('{name}', to_jsonb(src)))
        """), {"branch": branch_id}) or 0
    return total


async def status(conn: AsyncConnection, *, org: UUID, branch: UUID) -> dict:
    row = (await conn.execute(text(f"""
        SELECT snapshot_id, digest, imported_at FROM {_TABLE}
        WHERE branch_id = :branch AND organization_id = :org
    """), {"branch": branch, "org": org})).mappings().one_or_none()
    if row is not None:
        imported = row["imported_at"] is not None
        return {"needed": not imported, "snapshot_id": str(row["snapshot_id"]),
                "digest": row["digest"], "imported": imported,
                # Imported but the server still holds the legacy rows: the
                # device asks again to delete them.
                "purge_pending": imported and await legacy_rows(conn, branch) > 0}
    return {"needed": await legacy_rows(conn, branch) > 0, "imported": False}


async def export(conn: AsyncConnection, *, org: UUID, account: UUID, branch: UUID,
                 server: str, allow_negative: bool = False) -> dict:
    """The same bytes on every retry; a new export only if none exists."""
    row = (await conn.execute(text(f"""
        SELECT snapshot_id, digest, body, organization_id FROM {_TABLE}
        WHERE branch_id = :branch
    """), {"branch": branch})).mappings().one_or_none()
    if row is not None:
        if row["organization_id"] != org:
            raise MigrationRejected("Another organization")
        return {"snapshot_id": str(row["snapshot_id"]), "digest": row["digest"],
                "body": bytes(row["body"])}
    scope = cutover.CutoverScope(organization_id=org, account_id=account, branch_id=branch)
    settings = await conn.scalar(text("""
        SELECT settings FROM public.business_project_settings WHERE organization_id = :org
    """), {"org": org})
    try:
        allow_negative = bool((json.loads(settings) if settings else {}).get("allow_negative", False))
    except (ValueError, AttributeError):
        allow_negative = False
    try:
        snap = await cutover._snapshot(conn, scope, uuid4(), allow_negative,
                                       capture_catalog=True, server=server)
    except cutover.CutoverRejected as exc:
        raise MigrationRejected(str(exc)) from exc
    await conn.execute(text(f"""
        INSERT INTO {_TABLE} (branch_id, organization_id, account_id, snapshot_id, digest, body)
        VALUES (:branch, :org, :account, :id, :digest, :body)
    """), {"branch": branch, "org": org, "account": account, "id": snap.id,
           "digest": snap.digest, "body": snap.body})
    return {"snapshot_id": str(snap.id), "digest": snap.digest, "body": snap.body}


async def acknowledge(conn: AsyncConnection, *, org: UUID, branch: UUID,
                      snapshot_id: UUID, digest: str) -> bool:
    done = await conn.scalar(text(f"""
        UPDATE {_TABLE} SET imported_at = COALESCE(imported_at, clock_timestamp()),
          body = ''::bytea
        WHERE branch_id = :branch AND organization_id = :org
          AND snapshot_id = :id AND digest = :digest
        RETURNING imported_at
    """), {"branch": branch, "org": org, "id": snapshot_id, "digest": digest})
    if done is None:
        raise MigrationRejected("No matching export")
    return True


async def purge(conn: AsyncConnection, *, org: UUID, branch: UUID,
                snapshot_id: UUID, digest: str) -> int:
    """Delete the branch's legacy Business rows from the server — only after
    the device stored exactly this export. Children first; one transaction:
    any failure leaves everything as it was. Returns the number of rows."""
    imported = await conn.scalar(text(f"""
        SELECT imported_at FROM {_TABLE}
        WHERE branch_id = :branch AND organization_id = :org
          AND snapshot_id = :id AND digest = :digest
    """), {"branch": branch, "org": org, "id": snapshot_id, "digest": digest})
    if imported is None:
        raise MigrationRejected("The device has not confirmed this export")
    tables = [name for name, rule in cutover._rules.items()
              if rule.archive and name != "branches"]
    removed = 0
    async with conn.begin_nested():
        for name in reversed(tables):
            result = await conn.execute(text(f"""
                DELETE FROM public.{name} src
                WHERE :branch = ANY({cutover._branch_function}('{name}', to_jsonb(src)))
            """), {"branch": branch})
            removed += result.rowcount or 0
    await conn.execute(text(f"""
        UPDATE {_TABLE} SET body = ''::bytea WHERE branch_id = :branch
    """), {"branch": branch})
    return removed
