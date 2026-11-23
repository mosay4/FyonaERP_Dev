"""Private stdio adapter from the Dart test to PostgreSQL; no HTTP listener."""

import asyncio
import json
import os
import sys
from uuid import uuid4

from pydantic import ValidationError
from sqlalchemy import func, insert, select
from sqlalchemy.engine import URL
from sqlalchemy.ext.asyncio import create_async_engine

from app.domain.services import local_business_cash as cash
from app.domain.services import local_business_cutover as fixture
from app.domain.services.local_business_cash_wire import cash_message


def _write(frame):
    print(json.dumps(frame), flush=True)


async def _run(version):
    socket = os.environ.get("FYONA_TEST_CUTOVER_SOCKET")
    if not socket or not fixture.SOCKET_PATH.fullmatch(socket):
        raise RuntimeError("Expected an isolated Business cutover fixture")
    engine = create_async_engine(URL.create(
        "postgresql+asyncpg", username="root", database=fixture.FIXTURE_DB,
        query={"host": socket},
    ))
    scope = cash.CashScope(uuid4(), uuid4())
    account, second_account = uuid4(), uuid4()
    owner, employee = uuid4(), uuid4()
    replicas = {
        "first": cash.CashReplica(owner, uuid4()),
        "second": cash.CashReplica(owner, uuid4()),
        "employee": cash.CashReplica(employee, uuid4()),
        "late": cash.CashReplica(owner, uuid4()),
    }
    try:
        async with engine.begin() as conn:
            await fixture._require_socket(conn, socket)
            await conn.run_sync(cash.metadata.create_all)
            await conn.execute(insert(cash.scopes).values(**scope.key()))
            await conn.execute(insert(cash.resources).values(
                **scope.key(), account_id=account, currency="SAR",
                available_minor=10_000, allow_negative=False,
            ))
            if version == 3:
                await conn.execute(insert(cash.resources).values(
                    **scope.key(), account_id=second_account, currency="USD",
                    available_minor=5_000, allow_negative=False,
                ))
                await cash.enable_settlement_protocol(conn, scope)
            for actor in (owner, employee):
                await cash.replace_grant(
                    conn, scope, actor, version=1, can_read=True, can_withdraw=actor == owner,
                )
            checkpoint = await cash.cash_checkpoint(conn, scope)
            for name, replica in replicas.items():
                if name == "late":
                    continue
                await cash.admit_replica(
                    conn, scope, replica, sequence=checkpoint.sequence, digest=checkpoint.digest,
                    grant_version=1,
                )
        _write({
            "organization_id": str(scope.workspace_id), "branch_id": str(scope.branch_id),
            "account_id": str(account),
            **({"second_account_id": str(second_account)} if version == 3 else {}),
            "devices": {key: {"actor_id": str(r.actor_id), "session_id": str(r.session_id)}
                        for key, r in replicas.items()},
            "checkpoint": {"sequence": checkpoint.sequence, "digest": checkpoint.digest},
        })
        while line := await asyncio.to_thread(sys.stdin.readline):
            frame = json.loads(line)
            action = frame["action"]
            if action == "stats":
                async with engine.begin() as conn:
                    count = await conn.scalar(
                        select(func.count()).select_from(cash.payloads).where(scope.where(cash.payloads))
                    )
                _write({"count": count})
                continue
            if action == "fixture_revoke":
                async with engine.begin() as conn:
                    await cash.retire_replica(conn, scope, replicas[frame["actor"]])
                _write({"revoked": True})
                continue
            # Internal-only rehearsal. There is no network endpoint that
            # offers a snapshot or allows a device to enroll itself.
            if action == "fixture_checkpoint":
                async with engine.begin() as conn:
                    point = await cash.cash_checkpoint(conn, scope)
                _write({"sequence": point.sequence, "digest": point.digest, "accounts": point.accounts})
                continue
            if action == "fixture_admit" and frame["actor"] == "late":
                try:
                    async with engine.begin() as conn:
                        await cash.admit_replica(conn, scope, replicas["late"], grant_version=1,
                                                 **frame["body"])
                except cash.CashCheckpointChanged:
                    _write({"error": "stale_checkpoint"})
                else:
                    _write({"admitted": True})
                continue
            try:
                reply = await cash_message(
                    engine, scope, replicas[frame["actor"]], action, frame["body"],
                    version=version, live_can_equalize=frame["actor"] in ("first", "second"),
                )
            except ValidationError:
                _write({"error": "invalid_body"})
            except cash.CashAccessDenied:
                _write({"error": "denied"})
            except cash.CashReplayConflict:
                _write({"error": "conflict"})
            else:
                _write(reply)
    finally:
        await engine.dispose()


if __name__ == "__main__":
    asyncio.run(_run(3 if sys.argv[1:] == ["settlement"] else 2))
