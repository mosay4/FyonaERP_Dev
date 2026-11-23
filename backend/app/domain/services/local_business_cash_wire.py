"""Business cash wire. A checkpoint is a comparison, never a scope selector."""

from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StrictInt
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

from . import local_business_cash as cash


class _Checkpoint(BaseModel):
    model_config = ConfigDict(extra="forbid")
    sequence: StrictInt = Field(ge=0, le=2**63 - 1)
    digest: str = Field(pattern=r"^[a-f0-9]{64}$")


class _Message(BaseModel):
    model_config = ConfigDict(extra="forbid")
    checkpoint: _Checkpoint


class _Command(_Message):
    command_id: UUID


class _Withdrawal(_Command):
    account_id: UUID
    currency: str = Field(pattern=r"^[A-Z]{3}(_[A-Z]{3})?$")
    amount_minor: StrictInt = Field(gt=0, le=cash.MAX_MINOR)
    grant_version: StrictInt = Field(gt=0, le=2**63 - 1)


class _Acknowledgement(_Command):
    delivery_key: UUID


class _SettlementLine(BaseModel):
    model_config = ConfigDict(extra="forbid")
    account_id: UUID
    currency: str = Field(pattern=r"^[A-Z]{3}(_[A-Z]{3})?$")
    expected_minor: StrictInt = Field(ge=-cash.MAX_MINOR, le=cash.MAX_MINOR)
    actual_minor: StrictInt = Field(ge=0, le=cash.MAX_MINOR)


class _Settlement(_Command):
    observed_through: StrictInt = Field(ge=0, le=2**63 - 1)
    grant_version: StrictInt = Field(gt=0, le=2**63 - 1)
    entries: list[_SettlementLine] = Field(min_length=1, max_length=100)


CashAction = Literal["withdraw", "poll", "ack", "settle"]
WIRE_VERSION = 2
_REQUESTS = {
    "withdraw": _Withdrawal, "poll": _Message, "ack": _Acknowledgement, "settle": _Settlement,
}


async def cash_message(
    engine: AsyncEngine, scope: cash.CashScope, replica: cash.CashReplica,
    action: CashAction, body: dict, *, version=WIRE_VERSION, live_can_equalize=False,
):
    async with engine.begin() as conn:
        return await apply_message(
            conn, scope, replica, action, body, version=version, live_can_equalize=live_can_equalize,
        )


async def apply_message(
    conn: AsyncConnection, scope: cash.CashScope, replica: cash.CashReplica,
    action: CashAction, body: dict, *, live_can_withdraw: bool = True,
    live_can_reference: bool = True, stale_destinations=None,
    version: int = WIRE_VERSION, live_can_equalize: bool = False,
):
    """Caller supplies verified auth and commits before returning the frame."""
    request = _REQUESTS[action].model_validate(body)
    checkpoint_sequence, checkpoint_digest = await cash.replica_checkpoint(conn, scope, replica)
    await cash.require_wire_protocol(conn, scope, version)
    if (request.checkpoint.sequence, request.checkpoint.digest) != (checkpoint_sequence, checkpoint_digest):
        raise cash.CashAccessDenied
    # A relay cannot acknowledge a write whose WAL commit may still be pending.
    await conn.execute(text("SET LOCAL synchronous_commit = on"))
    if stale_destinations is not None:
        await cash.retire_stale_destinations(conn, scope, stale_destinations)
    if action in {"withdraw", "settle"}:
        if action == "withdraw":
            receipt = await cash.decide_withdrawal(
                conn, scope, replica=replica, live_can_withdraw=live_can_withdraw,
                live_can_reference=live_can_reference,
                **request.model_dump(exclude={"checkpoint"}),
            )
        elif version == 3:
            receipt = await cash.decide_settlement(
                conn, scope, replica=replica, live_can_equalize=live_can_equalize,
                entries=[cash.CashSettlementLine(**line.model_dump()) for line in request.entries],
                **request.model_dump(exclude={"checkpoint", "entries"}),
            )
        else:
            raise cash.CashAccessDenied
        data = {
            "command_id": str(receipt.command_id),
            "sequence": receipt.sequence,
            "decision": receipt.decision,
            "blocked_by": str(receipt.blocked_by) if receipt.blocked_by else None,
        }
    elif action == "poll":
        rows = await cash.poll(conn, scope, replica)
        deliveries = []
        for row in rows:
            common = {
                "command_id": str(row["command_id"]), "sequence": row["sequence"],
                "delivery_key": str(row["delivery_key"]),
            }
            if row["delta_minor"] == 0 and version == 3:
                lines = await conn.scalar(select(cash.settlement_payloads.c.entries).where(
                    scope.where(cash.settlement_payloads),
                    cash.settlement_payloads.c.command_id == row["command_id"],
                ))
                if not lines:
                    raise RuntimeError("Missing settlement delivery")
                deliveries.append({**common, "kind": "settlement", "entries": lines})
            elif row["delta_minor"] < 0:
                deliveries.append({
                    **common, "account_id": str(row["account_id"]),
                    "currency": row["currency"], "amount_minor": -row["delta_minor"],
                    **({"kind": "withdrawal"} if version == 3 else {}),
                })
            else:
                raise RuntimeError("Invalid cash delivery")
        data = deliveries if version == 2 else {
            "deliveries": deliveries,
            "observed_through": None if rows else await cash.issue_settlement_head(conn, scope, replica),
        }
    elif action == "ack":
        await cash.acknowledge(conn, scope, replica, request.command_id, request.delivery_key)
        data = {"command_id": str(request.command_id), "delivery_key": str(request.delivery_key)}
    return {
        "version": version,
        "organization_id": str(scope.workspace_id),
        "branch_id": str(scope.branch_id),
        "account_id": str(replica.actor_id),
        "session_id": str(replica.session_id),
        "checkpoint": {"sequence": checkpoint_sequence, "digest": checkpoint_digest},
        "data": data,
    }
