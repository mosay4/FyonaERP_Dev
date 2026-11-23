"""Reconciliation endpoints (قسم المطابقة) — bank/cash + inventory.

Every route is Business+org scoped and permission-gated:
  read   → browse accounts / archive / details
  create → run a CHECK (inspection only)
  update → approve settlements (مساواة الرصيد / اعتماد الجرد) + save drafts

CHECK never mutates balances. APPROVE is atomic (get_db commits the whole
request) and idempotent; state drift between check and approve returns 409
with fresh values so the client re-confirms.
"""

import json  # noqa: F401  (kept for scope_json debugging in dev tools)
from datetime import datetime
from typing import Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import (get_branch_context, get_branch_scope,
                         get_current_org_id, get_current_user_uuid,
                         require_permission)
from app.api.responses import ok, ok_paginated
from app.core.database import get_db
from app.core.qa_business_ledger import contains_registered_branch
from app.domain.services import reconciliation_service as svc

router = APIRouter(tags=["Reconciliation"])


class ReconEntry(BaseModel):
    account_id: str
    actual: float = Field(ge=0)
    expected_system: Optional[float] = None


class BankCheckRequest(BaseModel):
    entries: list[ReconEntry]
    measured_at: Optional[str] = None
    period_start: Optional[str] = None
    period_end: Optional[str] = None
    notes: Optional[str] = None
    idempotency_key: Optional[str] = None


class BankApproveRequest(BaseModel):
    entries: list[ReconEntry]
    notes: Optional[str] = None


class CountPart(BaseModel):
    """One unit box of a multi-unit count (e.g. 3 cartons + 2 pieces)."""
    qty: float = Field(default=0, ge=0)
    unit_id: Optional[str] = None
    unit_name: Optional[str] = None


class CountEntry(BaseModel):
    product_id: str
    # Either a single (qty, unit_id) — legacy — or a `parts` list with one
    # entry per unit box. The REAL total is the sum converted to base units.
    qty: float = Field(default=0, ge=0)
    unit_id: Optional[str] = None
    parts: Optional[list[CountPart]] = None


class InventoryStartRequest(BaseModel):
    scope: str
    product_id: Optional[str] = None
    category_id: Optional[str] = None
    branch_id: Optional[str] = None
    notes: Optional[str] = None
    idempotency_key: Optional[str] = None


class InventorySaveRequest(BaseModel):
    counts: list[CountEntry]


class SettlementEntry(BaseModel):
    product_id: str
    expected_system: float
    new_qty: float = Field(ge=0)


class InventoryApproveRequest(BaseModel):
    settlements: list[SettlementEntry]
    branch_id: Optional[str] = None
    notes: Optional[str] = None


def _parse_dt(v: Optional[str]) -> Optional[datetime]:
    if not v:
        return None
    try:
        return datetime.fromisoformat(str(v))
    except Exception:
        return None


async def _map_errors(fn):
    # NB: every service call here is async — forgetting the await returned a
    # coroutine and crashed the response with 500 («coroutine not
    # subscriptable»). This was the root cause of the reconciliation
    # endpoints failing from the app.
    try:
        return await fn()
    except svc.ReconciliationConflict as e:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"message": str(e), "fresh": e.fresh},
        )
    except svc.ReconciliationError as e:
        raise HTTPException(status_code=400, detail=str(e))


async def _connected_read_scope(db, scope):
    if not hasattr(scope, "all_mode"):
        return None
    ids = scope.branch_ids if scope.all_mode else [scope.branch_id]
    if await contains_registered_branch(db, ids):
        raise HTTPException(409, detail="اختر فرع الدفتر المحلي لعرض مطابقاته من الجهاز.")
    return ids


@router.get("/reconciliation/accounts", summary="Bank + cash accounts for reconciliation")
async def recon_accounts(
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reconciliation", "read")),
):
    ids = await _connected_read_scope(db, scope)
    return ok(await svc.list_bank_accounts(db, UUID(org_id), ids))


@router.post("/reconciliation/bank/check", summary="Run a bank/cash reconciliation check (inspection only)")
async def bank_check(
    data: BankCheckRequest,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reconciliation", "create")),
):
    record = await _map_errors(lambda: svc.bank_check(
        db,
        UUID(org_id),
        user_id,
        [e.model_dump() for e in data.entries],
        measured_at=_parse_dt(data.measured_at),
        period_start=_parse_dt(data.period_start),
        period_end=_parse_dt(data.period_end),
        notes=data.notes,
        idempotency_key=data.idempotency_key,
        branch_id=(branch.id if branch is not None and hasattr(branch, 'id') else None),
    ))
    await db.commit()
    return ok(record, "تم فحص المطابقة")


@router.post("/reconciliation/bank/{recon_id}/approve", summary="Equalize balances (مساواة الرصيد)")
async def bank_approve(
    recon_id: UUID,
    data: BankApproveRequest,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reconciliation", "update")),
):
    record = await _map_errors(lambda: svc.bank_approve(
        db, UUID(org_id), user_id, recon_id,
        [e.model_dump() for e in data.entries], notes=data.notes,
    ))
    await db.commit()
    return ok(record, "تمت مساواة الأرصدة")


async def _ctx_branch(db: AsyncSession, org_id: str, branch):
    """HTTP dependency or a direct-call placeholder → concrete active branch."""
    if branch is not None and hasattr(branch, "id"):
        return branch
    from app.domain.services import branch_service as _bs
    return await _bs.main_branch(db, UUID(org_id))


@router.post("/reconciliation/inventory/start", summary="Open an inventory counting session (snapshot)")
async def inventory_start(
    data: InventoryStartRequest,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reconciliation", "create")),
):
    branch = await _ctx_branch(db, org_id, branch)
    if data.branch_id is not None and UUID(data.branch_id) != branch.id:
        raise HTTPException(status_code=403, detail="هذا الفرع لا يطابق سياق العمل")
    record = await _map_errors(lambda: svc.inventory_start(
        db,
        UUID(org_id),
        user_id,
        data.scope,
        product_id=UUID(data.product_id) if data.product_id else None,
        category_id=UUID(data.category_id) if data.category_id else None,
        branch_id=branch.id,
        notes=data.notes,
        idempotency_key=data.idempotency_key,
    ))
    await db.commit()
    return ok(record, "بدأ جلسة الجرد")


@router.post("/reconciliation/inventory/{recon_id}/save", summary="Save counted quantities (partial allowed)")
async def inventory_save(
    recon_id: UUID,
    data: InventorySaveRequest,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reconciliation", "update")),
):
    record = await _map_errors(lambda: svc.inventory_save(
        db, UUID(org_id), user_id, recon_id,
        [c.model_dump() for c in data.counts],
    ))
    await db.commit()
    return ok(record, "تم حفظ الجرد")


@router.post("/reconciliation/inventory/{recon_id}/check", summary="Compare counted vs current quantities")
async def inventory_check(
    recon_id: UUID,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reconciliation", "update")),
):
    record = await _map_errors(lambda: svc.inventory_check(
        db, UUID(org_id), user_id, recon_id
    ))
    await db.commit()
    return ok(record, "تم فحص الجرد")


@router.post("/reconciliation/inventory/{recon_id}/approve", summary="Approve inventory settlements")
async def inventory_approve(
    recon_id: UUID,
    data: InventoryApproveRequest,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reconciliation", "update")),
):
    branch = await _ctx_branch(db, org_id, branch)
    if data.branch_id is not None and UUID(data.branch_id) != branch.id:
        raise HTTPException(status_code=403, detail="هذا الفرع لا يطابق سياق العمل")
    record = await _map_errors(lambda: svc.inventory_approve(
        db, UUID(org_id), user_id, recon_id,
        [s.model_dump() for s in data.settlements],
        branch_id=branch.id,
        notes=data.notes,
    ))
    await db.commit()
    return ok(record, "تم اعتماد تسوية الجرد")


@router.get("/reconciliation", summary="Reconciliation archive (search + filters)")
async def list_reconciliations(
    rtype: Optional[str] = None,
    status: Optional[str] = None,
    date_from: Optional[str] = None,
    date_to: Optional[str] = None,
    search: Optional[str] = None,
    page: int = 1,
    per_page: int = 20,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reconciliation", "read")),
    request: Request = None,
):
    ids = await _connected_read_scope(db, scope)
    types = getattr(request.state, 'employee_recon_types', None) if request else None
    if types is not None and len(types) == 1:
        rtype = types[0]
    out = await _map_errors(lambda: svc.list_reconciliations(
        db, UUID(org_id), rtype=rtype, status=status,
        date_from=_parse_dt(date_from), date_to=_parse_dt(date_to),
        search=search, page=page, per_page=per_page,
        branch_ids=ids,
    ))
    await svc.resolve_executor_names(db, UUID(org_id), out["items"])
    return ok_paginated(out["items"], out["total"], out["page"], out["per_page"])


@router.get("/reconciliation/{recon_id}", summary="Full reconciliation record")
async def get_reconciliation(
    recon_id: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("reconciliation", "read")),
):
    record = await _map_errors(lambda: svc.get_reconciliation(db, UUID(org_id), recon_id))
    await svc.resolve_executor_names(db, UUID(org_id), [record])
    return ok(record)
