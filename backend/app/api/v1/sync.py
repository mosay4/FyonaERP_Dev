from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from uuid import UUID
from datetime import datetime, timezone
from pydantic import BaseModel
from typing import Optional

from ...core.database import get_db
from ...api.deps import get_current_org_id, get_current_user_uuid, require_permission
from ...api.responses import ok, ok_paginated
from ...domain.models.sync_models import (
    SyncPushRequest, SyncPullRequest, SyncResult, SyncStatusResponse, SyncHealthResponse,
)
from ...domain.services.sync_service import SyncService
from ...domain.services.personal_sync import PERSONAL_MODELS, persist_personal, serialize_row
from ...infrastructure.repositories.sql_alchemy_sync_repository import (
    SQLEntityVersionRepo, SQLSyncBatchRepo, SQLConflictLogRepo, SQLSyncLogRepo,
)

router = APIRouter(tags=["Sync"])


class ResolveConflictBody(BaseModel):
    resolution: str  # client_wins | server_wins | manual
    entity_type: Optional[str] = None
    entity_id: Optional[UUID] = None


def _svc(db):
    return SyncService(SQLEntityVersionRepo(db), SQLSyncBatchRepo(db), SQLConflictLogRepo(db), SQLSyncLogRepo(db))

@router.post("/sync/push", summary="Push local changes to server", response_model=SyncResult)
async def sync_push(data: SyncPushRequest, org_id: str = Depends(get_current_org_id), uid: UUID = Depends(get_current_user_uuid), db: AsyncSession = Depends(get_db), _=Depends(require_permission("sync", "create"))):
    if any(entity.entity_type not in PERSONAL_MODELS for entity in data.entities):
        raise HTTPException(422, "This sync endpoint accepts only personal entities")
    result = await _svc(db).push(UUID(org_id), uid, data)
    errors = list(result.errors)
    conflicted = {(c.entity_type, str(c.entity_id)) for c in result.conflicts}
    for entity in data.entities:
        if entity.entity_type not in PERSONAL_MODELS:
            continue
        if (entity.entity_type, str(entity.entity_id)) in conflicted:
            continue  # Do not overwrite server data with stale client data
        try:
            await persist_personal(db, uid, entity.entity_type, entity.entity_id, entity.data, entity.deleted)
        except Exception as e:
            errors.append(f"{entity.entity_type}/{entity.entity_id}: {e}")
    if errors:
        result.success = False
        result.errors = errors
    await db.flush()
    return result

@router.post("/sync/pull", summary="Pull server changes since last sync")
async def sync_pull(data: SyncPullRequest, org_id: str = Depends(get_current_org_id), db: AsyncSession = Depends(get_db), _=Depends(require_permission("sync", "read"))):
    # Cursor BEFORE the query: any write committed while we read is guaranteed
    # to be > cursor on the next pull (with the service-side safety overlap).
    pull_started_at = datetime.now(timezone.utc)
    personal_types = [kind for kind in (data.entity_types or PERSONAL_MODELS)
                      if kind in PERSONAL_MODELS]
    entities, total = await _svc(db).pull(
        UUID(org_id), data.model_copy(update={"entity_types": personal_types})
    ) if personal_types else ([], 0)
    from ...domain.entities.personal_entities import PersonalDebt, PersonalDebtPayment
    from ...domain.entities.personal_entities import PersonalBudgetCategory
    from sqlalchemy import func as _func

    # ─ Batch-fetch every personal row in ONE query per entity type. The old
    # per-entity `db.get` loop was N+1 and took ~30s for 500 offline ops,
    # which made clients time out mid-pull and re-pull forever.
    by_type: dict = {}
    for e in entities:
        by_type.setdefault(e["entity_type"], []).append(e)
    rows_by_type: dict = {}
    for etype, items in by_type.items():
        model = PERSONAL_MODELS.get(etype)
        if model is None:
            continue
        ids = []
        for i in items:
            try:
                ids.append(UUID(i["entity_id"]))
            except (ValueError, TypeError):
                continue
        if not ids:
            continue
        rows = (await db.execute(
            select(model).where(model.id.in_(ids))
        )).unique().scalars().all()
        rows_by_type[etype] = {str(r.id): r for r in rows}

    # Debt paid/remaining are DERIVED from payment records: batch the sums.
    debt_ids = [UUID(i["entity_id"]) for i in by_type.get("personal_debt", [])
                if i.get("entity_id")]
    paid_map: dict = {}
    if debt_ids:
        pay_rows = (await db.execute(
            select(PersonalDebtPayment.debt_id,
                   _func.coalesce(_func.sum(PersonalDebtPayment.amount), 0))
            .where(
                PersonalDebtPayment.debt_id.in_(debt_ids),
                PersonalDebtPayment.is_deleted == False,
            )
            .group_by(PersonalDebtPayment.debt_id)
        )).all()
        paid_map = {str(r[0]): float(r[1] or 0) for r in pay_rows}

    # Budget categories ride the pull (same batch pattern as above) so a
    # pulled budget row never blanks locally-held categories: the client
    # upserts the pulled row over its mirror, and an empty list would wipe
    # categories the user added (appear/disappear flicker + whole-budget
    # withdrawals with no category picker).
    budget_ids = [UUID(i["entity_id"]) for i in by_type.get("personal_budget", [])
                if i.get("entity_id")]
    cats_map: dict = {}
    if budget_ids:
        cat_rows = (await db.execute(
            select(PersonalBudgetCategory).where(
                PersonalBudgetCategory.budget_id.in_(budget_ids)
            )
        )).scalars().all()
        for c in cat_rows:
            cats_map.setdefault(str(c.budget_id), []).append({
                "id": str(c.id),
                "budget_id": str(c.budget_id),
                "name": c.name,
                "type": c.type,
                "allocated_amount": float(c.allocated_amount) if c.allocated_amount else 0,
                "spent_amount": float(c.spent_amount) if c.spent_amount else 0,
                "currency": c.currency,
                "goal_id": str(c.goal_id) if getattr(c, "goal_id", None) else None,
                "debt_id": str(c.debt_id) if getattr(c, "debt_id", None) else None,
            })

    rows = []
    for e in entities:
        item = dict(e)
        etype = e["entity_type"]
        row = rows_by_type.get(etype, {}).get(str(e["entity_id"]))
        if etype in PERSONAL_MODELS:
            if row is not None and getattr(row, "is_deleted", False):
                item["data"] = None
            else:
                item["data"] = serialize_row(row) if row is not None else None
                if (
                    row is not None
                    and etype == "personal_budget"
                    and isinstance(item["data"], dict)
                ):
                    item["data"]["categories"] = cats_map.get(str(row.id), [])
                if (
                    row is not None
                    and etype == "personal_debt"
                    and isinstance(item["data"], dict)
                ):
                    amt = float(row.amount or 0)
                    paid = paid_map.get(str(row.id), 0.0)
                    item["data"]["paid"] = paid
                    item["data"]["remaining"] = max(amt - paid, 0)
                    item["data"]["debt_type"] = row.debt_type
                    item["data"]["is_paid"] = bool(row.is_paid)
                    item["data"]["status"] = (
                        "paid" if row.is_paid else
                        ("overdue" if row.due_date and row.due_date < datetime.now(timezone.utc).date() else "active")
                    )
                    item["data"]["reminder"] = bool(getattr(row, "reminder", False))
        rows.append(item)
    return ok({"entities": rows, "total": total, "server_time": pull_started_at.isoformat()})

@router.get("/sync/status", summary="Get sync status", response_model=SyncStatusResponse)
async def sync_status(org_id: str = Depends(get_current_org_id), db: AsyncSession = Depends(get_db), _=Depends(require_permission("sync", "read"))):
    return await _svc(db).status(UUID(org_id))

@router.get("/sync/health", summary="Sync engine health check", response_model=SyncHealthResponse)
async def sync_health(db: AsyncSession = Depends(get_db)):
    return await _svc(db).health()

@router.get("/sync/conflicts", summary="List sync conflicts")
async def list_conflicts(unresolved_only: bool = False, page: int = 1, per_page: int = 20, org_id: str = Depends(get_current_org_id), db: AsyncSession = Depends(get_db), _=Depends(require_permission("sync", "read"))):
    items, total = await _svc(db).list_conflicts(UUID(org_id), unresolved_only, page, per_page)
    return ok_paginated([{"id": str(i.id), "entity_type": i.entity_type, "entity_id": str(i.entity_id), "client_version": i.client_version, "server_version": i.server_version, "resolution": i.resolution, "created_at": i.created_at.isoformat() if i.created_at else None} for i in items], total, page, per_page)

@router.post("/sync/conflicts/{conflict_id}/resolve", summary="Resolve a sync conflict")
async def resolve_conflict(conflict_id: UUID, body: ResolveConflictBody, org_id: str = Depends(get_current_org_id), uid: UUID = Depends(get_current_user_uuid), db: AsyncSession = Depends(get_db), _=Depends(require_permission("sync", "update"))):
    if body.resolution not in ("client_wins", "server_wins", "manual"):
        raise HTTPException(status_code=422, detail="resolution must be one of: client_wins, server_wins, manual")
    try:
        await _svc(db).resolve_conflict(UUID(org_id), conflict_id, body.resolution, resolved_by=str(uid))
    except ValueError:
        raise HTTPException(status_code=404, detail="Conflict not found")
    await db.flush()
    return ok({"resolved": True, "id": str(conflict_id), "resolution": body.resolution})

@router.get("/sync/logs", summary="View sync logs")
async def sync_logs(page: int = 1, per_page: int = 50, org_id: str = Depends(get_current_org_id), db: AsyncSession = Depends(get_db), _=Depends(require_permission("sync", "read"))):
    items, total = await _svc(db).list_logs(UUID(org_id), page, per_page)
    return ok_paginated([{"id": str(i.id), "entity_type": i.entity_type, "entity_id": str(i.entity_id) if i.entity_id else None, "action": i.action, "status": i.status, "details": i.details, "created_at": i.created_at.isoformat() if i.created_at else None} for i in items], total, page, per_page)
