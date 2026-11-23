"""Personal-entity persistence bridge for the generic sync engine.

The generic sync ledger (`/sync/push`, `/sync/pull`) is org-scoped and only
records version metadata. The personal finance module is user-scoped, so this
module gives the sync endpoints the ability to actually carry personal finance
rows (transactions, savings goals, bank accounts, debts, budgets) instead of
just version bookkeeping.

Writes are flushed (not committed) here; the request-scoped session commits in
`get_db` teardown.
"""
from datetime import date, datetime, timezone
from typing import Any, Dict, Optional, Type
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.personal_entities import (
    PersonalBankAccount,
    PersonalBudget,
    PersonalDebt,
    PersonalRecurringTransaction,
    PersonalSavingsGoal,
    PersonalTransaction,
)
from app.domain.entities.sync_entities import EntityVersion

PERSONAL_MODELS: Dict[str, Type[Any]] = {
    "personal_transaction": PersonalTransaction,
    "personal_savings_goal": PersonalSavingsGoal,
    "personal_bank_account": PersonalBankAccount,
    "personal_debt": PersonalDebt,
    "personal_budget": PersonalBudget,
    "personal_recurring_transaction": PersonalRecurringTransaction,
}


def _iso_dt(value: Any) -> Optional[datetime]:
    if value is None or value == "":
        return None
    if isinstance(value, datetime):
        return value
    try:
        d = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        return d
    except (ValueError, TypeError):
        return None


def _iso_date(value: Any) -> Optional[date]:
    if value is None or value == "":
        return None
    if isinstance(value, date) and not isinstance(value, datetime):
        return value
    d = _iso_dt(value)
    return d.date() if d else None


def _dec(value: Any, default: Any = 0) -> float:
    if value is None:
        return float(default)
    try:
        return float(value)
    except (TypeError, ValueError):
        return float(default)


def _bool(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, (bool, int)):
        return bool(value)
    return str(value).lower() in ("1", "true", "yes")


def _str(value: Any, default: str = "") -> str:
    return value if isinstance(value, str) else (default if value is None else str(value))


def _try_uuid(value: Any):
    """Return a UUID for an id-looking value, else None."""
    if isinstance(value, UUID):
        return value
    if not value:
        return None
    try:
        return UUID(str(value))
    except (ValueError, TypeError):
        return None


VALID_TX_TYPES = ("income", "expense")
VALID_FREQUENCIES = ("daily", "weekly", "monthly", "yearly")


async def record_entity_version(
    db: AsyncSession,
    org_id,
    user_id,
    entity_type: str,
    entity_id,
    data: Dict[str, Any],
    *,
    deleted: bool = False,
    operation_id: Optional[str] = None,
) -> None:
    """Record a version entry in the sync ledger for a server-side mutation.

    Called by CRUD handlers (personal finance and business modules) so that
    changes made through the normal API are visible to OTHER devices during
    their next incremental pull — not only pushes that flow through /sync/push.

    Best-effort: any failure is logged, never raised (the write must never
    fail because a version record failed).
    """
    try:
        result = await db.execute(
            select(EntityVersion).where(
                EntityVersion.organization_id == org_id,
                EntityVersion.entity_type == entity_type,
                EntityVersion.entity_id == entity_id,
            )
        )
        existing = result.unique().scalar_one_or_none()
        now = datetime.now(timezone.utc)
        checksum = _checksum(data)
        if existing:
            existing.version = (existing.version or 1) + 1
            existing.checksum = checksum
            existing.data_hash = checksum
            if operation_id:
                existing.operation_id = operation_id
            existing.last_modified_at = now
            existing.last_modified_by = user_id
            existing.is_deleted = deleted
        else:
            db.add(
                EntityVersion(
                    organization_id=org_id,
                    entity_type=entity_type,
                    entity_id=entity_id,
                    version=1,
                    checksum=checksum,
                    data_hash=checksum,
                    operation_id=operation_id,
                    last_modified_at=now,
                    last_modified_by=user_id,
                    is_deleted=deleted,
                )
            )
        await db.flush()
    except Exception:  # noqa: BLE001 - never break the mutation
        pass


def _checksum(data: Dict[str, Any]) -> str:
    import hashlib
    import json

    raw = json.dumps(data, sort_keys=True, default=str).encode()
    return hashlib.sha256(raw).hexdigest()[:16]


async def persist_personal(
    db: AsyncSession,
    user_id: UUID,
    entity_type: str,
    entity_id: UUID,
    data: Dict[str, Any],
    deleted: bool,
) -> None:
    """Upsert a single personal row from a pushed sync entity."""
    model = PERSONAL_MODELS.get(entity_type)
    if model is None:
        raise ValueError(f"Unsupported personal entity type: {entity_type}")

    stmt = select(model).where(model.id == entity_id, model.user_id == user_id)
    row = (await db.execute(stmt)).unique().scalar_one_or_none()
    created = row is None

    # If the row was already hard-deleted (by the CRUD endpoint) and the sync
    # push arrives with deleted=True, do NOT recreate a soft-deleted ghost row.
    # The EntityVersion tombstone is already set by _resolve_entity; creating a
    # row here would cause the transaction to "resurrect" on the next pull.
    if created and deleted:
        return

    if created:
        row = model(id=entity_id, user_id=user_id)

    if entity_type == "personal_transaction":
        tx_type = _str(data.get("tx_type"))
        row.tx_type = tx_type if tx_type in VALID_TX_TYPES else "expense"
        row.amount = _dec(data.get("amount"))
        row.currency = _str(data.get("currency"), "SAR")
        row.category = _str(data.get("category"))
        row.description = _str(data.get("description")) or None
        row.date = _iso_dt(data.get("date")) or datetime.now(timezone.utc)
        if data.get("exchange_rate") is not None:
            row.exchange_rate = _dec(data.get("exchange_rate"))
        if data.get("exchange_rate_currency"):
            row.exchange_rate_currency = _str(data.get("exchange_rate_currency")).upper()
        if data.get("fx_source"):
            row.fx_source = _str(data.get("fx_source"))
        # Re-link relational FKs so a synced transaction points back to its
        # account/goal/debt/budget exactly like the CRUD path does.
        for col, key in (
            ("bank_account_id", "bank_account_id"),
            ("goal_id", "goal_id"),
            ("debt_id", "debt_id"),
            ("budget_id", "budget_id"),
            ("budget_category_id", "budget_category_id"),
        ):
            raw = data.get(key)
            if raw:
                _uuid = _try_uuid(raw)
                if _uuid is not None:
                    setattr(row, col, _uuid)
            elif raw == "" or (raw is not None and not _try_uuid(raw)):
                # Explicit clear or invalid value → drop the link.
                setattr(row, col, None)
        if data.get("goal_amount") is not None:
            try:
                row.goal_amount = _dec(data.get("goal_amount"))
            except Exception:
                pass
    elif entity_type == "personal_savings_goal":
        row.name = _str(data.get("name"))
        row.target_amount = _dec(data.get("target_amount"))
        row.current_amount = _dec(data.get("current_amount"))
        row.currency = _str(data.get("currency"), "SAR")
        row.deadline = _iso_date(data.get("deadline"))
        row.icon = _str(data.get("icon"), "SAVINGS")
        row.notes = _str(data.get("notes")) or None
        row.is_completed = _bool(data.get("is_completed"))
    elif entity_type == "personal_bank_account":
        row.bank_name = _str(data.get("bank_name"))
        row.currency = _str(data.get("currency"), "SAR")
        row.balance = _dec(data.get("balance"))
        row.notes = _str(data.get("notes")) or None
        row.is_active = _bool(data.get("is_active"), True)
    elif entity_type == "personal_debt":
        debt_type = _str(data.get("debt_type"))
        row.debt_type = debt_type if debt_type in ("payable", "receivable") else "payable"
        row.person_name = _str(data.get("person_name"))
        row.amount = _dec(data.get("amount"))
        row.currency = _str(data.get("currency"), "SAR")
        row.description = _str(data.get("description")) or None
        row.due_date = _iso_date(data.get("due_date"))
        row.is_paid = _bool(data.get("is_paid"))
        row.paid_date = _iso_date(data.get("paid_date"))
    elif entity_type == "personal_budget":
        row.category = _str(data.get("category"))
        row.amount = _dec(data.get("amount"))
        row.spent = _dec(data.get("spent"))
        row.month = int(_dec(data.get("month")))
        row.year = int(_dec(data.get("year")))
        row.currency = _str(data.get("currency"), "SAR")
    elif entity_type == "personal_recurring_transaction":
        recurring_type = _str(data.get("tx_type"))
        row.tx_type = recurring_type if recurring_type in VALID_TX_TYPES else "expense"
        row.amount = _dec(data.get("amount"))
        row.currency = _str(data.get("currency"), "SAR")
        row.category = _str(data.get("category"))
        row.description = _str(data.get("description")) or None
        frequency = _str(data.get("frequency"))
        row.frequency = frequency if frequency in VALID_FREQUENCIES else "monthly"
        row.interval_value = int(_dec(data.get("interval_value"), 1))
        row.next_run_date = _iso_date(data.get("next_run_date") or data.get("next_date"))
        row.is_active = _bool(data.get("is_active"), True)

    if not created:
        row.updated_at = datetime.now(timezone.utc)
    row.is_deleted = deleted

    if created:
        db.add(row)
    await db.flush()


def serialize_row(row: Any) -> Dict[str, Any]:
    """Serialize a personal ORM row to the shape the Flutter app expects."""
    t = row.__tablename__
    out: Dict[str, Any] = {"id": str(row.id)}
    if t == PersonalTransaction.__tablename__:
        out.update({
            "tx_type": row.tx_type,
            "amount": _dec(row.amount),
            "currency": row.currency or "SAR",
            "category": row.category,
            "description": row.description or "",
            "date": row.date.isoformat() if row.date else None,
            "bank_account_id": str(row.bank_account_id) if row.bank_account_id else None,
            "payment_method": getattr(row, "payment_method", None),
            "budget_id": str(row.budget_id) if getattr(row, "budget_id", None) else None,
            "budget_category_id": str(row.budget_category_id) if getattr(row, "budget_category_id", None) else None,
            "goal_id": str(row.goal_id) if getattr(row, "goal_id", None) else None,
            "debt_id": str(row.debt_id) if getattr(row, "debt_id", None) else None,
            "goal_amount": float(row.goal_amount) if getattr(row, "goal_amount", None) is not None else None,
            "debt_amount": float(row.debt_amount) if getattr(row, "debt_amount", None) is not None else None,
            "exchange_rate": float(row.exchange_rate) if getattr(row, "exchange_rate", None) is not None else None,
            "exchange_rate_currency": getattr(row, "exchange_rate_currency", None),
            "fx_source": getattr(row, "fx_source", None),
            "created_at": row.created_at.isoformat() if row.created_at else None,
        })
    elif t == PersonalSavingsGoal.__tablename__:
        target = _dec(row.target_amount)
        current = _dec(row.current_amount)
        out.update({
            "name": row.name,
            "target_amount": target,
            "current_amount": current,
            "currency": row.currency or "SAR",
            "deadline": row.deadline.isoformat() if row.deadline else None,
            "icon": row.icon or "SAVINGS",
            "notes": row.notes or "",
            "is_completed": bool(row.is_completed),
            "created_at": row.created_at.isoformat() if row.created_at else None,
            "progress_pct": round(current / target * 100, 1) if target and target > 0 else 0,
        })
    elif t == PersonalBankAccount.__tablename__:
        out.update({
            "bank_name": row.bank_name,
            "currency": row.currency or "SAR",
            "balance": _dec(row.balance),
            "notes": row.notes,
            "is_active": bool(row.is_active),
            "created_at": row.created_at.isoformat() if row.created_at else None,
            "updated_at": row.updated_at.isoformat() if row.updated_at else None,
        })
    elif t == PersonalDebt.__tablename__:
        out.update({
            "debt_type": row.debt_type,
            "person_name": row.person_name,
            "amount": _dec(row.amount),
            "currency": row.currency or "SAR",
            "description": row.description or "",
            "due_date": row.due_date.isoformat() if row.due_date else None,
            "is_paid": bool(row.is_paid),
            "paid_date": row.paid_date.isoformat() if row.paid_date else None,
            "created_at": row.created_at.isoformat() if row.created_at else None,
        })
    elif t == PersonalBudget.__tablename__:
        out.update({
            "name": row.name or row.category or "",
            "period_type": getattr(row, "period_type", None) or "monthly",
            "start_date": row.start_date.isoformat() if getattr(row, "start_date", None) and row.start_date else None,
            "end_date": row.end_date.isoformat() if getattr(row, "end_date", None) and row.end_date else None,
            "custom_days": getattr(row, "custom_days", None),
            "total_amount": _dec(getattr(row, "total_amount", None) or row.amount),
            "amount": _dec(getattr(row, "total_amount", None) or row.amount),
            "spent": _dec(row.spent),
            "currency": row.currency or "SAR",
            "bank_account_ids": getattr(row, "bank_account_ids", None) or [],
            "budget_types": getattr(row, "budget_types", None) or ["expenses"],
            "categories": [],
            "category": row.category,
            "month": row.month,
            "year": row.year,
            "created_at": row.created_at.isoformat() if row.created_at else None,
        })
    elif t == PersonalRecurringTransaction.__tablename__:
        out.update({
            "tx_type": row.tx_type,
            "amount": _dec(row.amount),
            "currency": row.currency or "SAR",
            "category": row.category,
            "description": row.description or "",
            "frequency": row.frequency,
            "interval_value": row.interval_value,
            "next_run_date": row.next_run_date.isoformat() if row.next_run_date else None,
            "is_active": bool(row.is_active),
            "created_at": row.created_at.isoformat() if row.created_at else None,
        })
    return out