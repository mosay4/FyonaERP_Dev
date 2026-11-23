from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request, status
from sqlalchemy.ext.asyncio import AsyncSession
from typing import Optional
from uuid import UUID

from ...core.database import get_db
from ...api.deps import (get_branch_context, get_branch_scope,
                         get_current_org_id, get_current_user_uuid,
                         require_permission, has_permission)
from ...api.responses import ok, created, no_content, ok_paginated
from ...domain.models.invoice_models import (
    InvoiceCreate,
    InvoiceUpdate,
    PaymentCreate,
    InvoiceStatusTransition,
    SaleIssueRequest,
    SaleReturnRequest,
    PurchaseIssueRequest,
)
from ...domain.services.invoice_service import InvoiceService
from ...infrastructure.repositories.sql_alchemy_invoice_repository import (
    SqlAlchemyInvoiceRepository,
    SqlAlchemyInvoiceItemRepository,
    SqlAlchemyPaymentRepository,
)

router = APIRouter(tags=["Invoices"])


async def _assert_invoice_branch(db: AsyncSession, org_id: UUID,
                                 invoice_id: UUID, branch) -> None:
    from sqlalchemy import select as _sel
    from ...domain.entities.invoice_entities import Invoice as _Inv
    from ...domain.entities.sale_entities import Branch as _Branch
    row = (await db.execute(_sel(_Inv.id, _Inv.branch_id).where(
        _Inv.id == invoice_id, _Inv.organization_id == org_id))).first()
    if row is None:
        raise HTTPException(status_code=404, detail="الفاتورة غير موجودة")
    inv_branch = row[1]
    if inv_branch is not None and inv_branch == branch.id:
        return
    if inv_branch is None:
        is_main = bool((await db.execute(_sel(_Branch.is_default).where(
            _Branch.id == branch.id))).scalar_one_or_none())
        if is_main:
            return
    raise HTTPException(status_code=404, detail="الفاتورة غير موجودة")


def _get_service(db: AsyncSession) -> InvoiceService:
    return InvoiceService(
        invoice_repo=SqlAlchemyInvoiceRepository(db),
        item_repo=SqlAlchemyInvoiceItemRepository(db),
        payment_repo=SqlAlchemyPaymentRepository(db),
    )


# ═══════════════════════════════════════════
# Invoices CRUD
# ═══════════════════════════════════════════


@router.post(
    "/invoices", summary="Create a draft invoice", status_code=status.HTTP_201_CREATED
)
async def create_invoice(
    data: InvoiceCreate,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "create")),
    branch=Depends(get_branch_context),
):
    service = _get_service(db)
    try:
        from ...domain.entities.business_entities import Customer, Supplier, Product
        references = [(Customer, data.customer_id), (Supplier, data.supplier_id)]
        references += [(Product, item.product_id) for item in data.items]
        for model, record_id in references:
            if record_id is None: continue
            row = await db.get(model, record_id)
            if row is None or row.organization_id != UUID(org_id) or (
                    row.branch_id != branch.id and not (row.branch_id is None and branch.is_default)):
                raise HTTPException(404, detail='السجل غير موجود في هذا الفرع')
        result = await service.create_invoice(UUID(org_id), user_id, data, branch_id=branch.id)
        return created(result, "تم إنشاء الفاتورة بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.get(
    "/invoices",
    summary="List invoices with pagination, search, status, and type filters",
)
async def list_invoices(
    search: Optional[str] = None,
    status: Optional[str] = None,
    invoice_type: Optional[str] = None,
    page: int = 1,
    per_page: int = 20,
    returnable_only: bool = False,
    number_only: bool = False,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "read")),
    request: Request = None,
):
    types = getattr(request.state, 'employee_invoice_types', None) if request else None
    if types is not None and len(types) == 1:
        invoice_type = types[0]
    service = _get_service(db)
    items, total = await service.list_invoices(
        UUID(org_id), search, status, invoice_type, page, per_page,
        scope.branch_ids if scope.all_mode else [scope.branch_id],
        number_only=number_only,
    )
    # Returns flow: hide invoices whose every line is already fully returned —
    # only invoices with at least one returnable line are offered.
    if returnable_only:
        items = await _drop_fully_returned(db, UUID(org_id), items)
    return ok_paginated([i.model_dump() for i in items], total, page, per_page)


async def _drop_fully_returned(db: AsyncSession, org_id: UUID, invoices: list) -> list:
    """Keep only invoices that still have at least one line with remaining qty."""
    from sqlalchemy import select, func

    from ...domain.entities.invoice_entities import InvoiceItem
    from ...domain.entities.sale_entities import InvoiceReturn, InvoiceReturnItem
    from ...domain.entities.purchase_entities import PurchaseReturn, PurchaseReturnItem

    if not invoices:
        return invoices
    ids = [i.id for i in invoices]
    item_rows = (
        await db.execute(
            select(InvoiceItem.invoice_id, InvoiceItem.id, InvoiceItem.quantity)
            .where(InvoiceItem.invoice_id.in_(ids))
        )
    ).all()
    if not item_rows:
        return invoices
    item_qty: dict = {}
    inv_items: dict = {}
    for inv_id, item_id, q in item_rows:
        item_qty[item_id] = float(q or 0)
        inv_items.setdefault(inv_id, []).append(item_id)
    item_ids = list(item_qty.keys())

    returned: dict = {}
    rsale = (
        await db.execute(
            select(InvoiceReturnItem.invoice_item_id,
                   func.sum(InvoiceReturnItem.quantity))
            .join(InvoiceReturn, InvoiceReturn.id == InvoiceReturnItem.return_id)
            .where(
                InvoiceReturn.organization_id == org_id,
                InvoiceReturn.status == "confirmed",
                InvoiceReturnItem.invoice_item_id.in_(item_ids),
            )
            .group_by(InvoiceReturnItem.invoice_item_id)
        )
    ).all()
    for item_id, q in rsale:
        returned[item_id] = returned.get(item_id, 0.0) + float(q or 0)
    rpur = (
        await db.execute(
            select(PurchaseReturnItem.invoice_item_id,
                   func.sum(PurchaseReturnItem.quantity))
            .join(PurchaseReturn,
                  PurchaseReturn.id == PurchaseReturnItem.purchase_return_id)
            .where(
                PurchaseReturn.organization_id == org_id,
                PurchaseReturn.status == "confirmed",
                PurchaseReturnItem.invoice_item_id.in_(item_ids),
            )
            .group_by(PurchaseReturnItem.invoice_item_id)
        )
    ).all()
    for item_id, q in rpur:
        returned[item_id] = returned.get(item_id, 0.0) + float(q or 0)

    out = []
    for inv in invoices:
        lines = inv_items.get(inv.id, [])
        if not lines:
            continue
        remaining = sum(
            max(0.0, item_qty[i] - returned.get(i, 0.0)) for i in lines
        )
        if remaining > 1e-6:
            out.append(inv)
    return out


@router.get(
    "/invoices/{invoice_id}",
    summary="Get a single invoice by ID with items and payments",
)
async def get_invoice(
    invoice_id: UUID,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "read")),
    can_view_profit: bool = Depends(has_permission("inventory_profit", "read")),
):
    service = _get_service(db)
    try:
        result = await service.get_invoice(invoice_id, UUID(org_id))
        _inv_branch = result.branch_id if hasattr(result, "branch_id") else (
            result.get("branch_id") if isinstance(result, dict) else None)
        from .business import _row_branch_allowed
        if not await _row_branch_allowed(db, _inv_branch, scope):
            raise HTTPException(404, detail='الفاتورة غير موجودة')
        if not scope.all_mode:
            if _inv_branch is None:
                from sqlalchemy import select as _sel
                from ...domain.entities.sale_entities import Branch as _Branch
                is_main = bool((await db.execute(_sel(_Branch.is_default).where(
                    _Branch.id == scope.branch_id))).scalar_one_or_none())
                if not is_main:
                    raise HTTPException(status_code=404,
                                        detail="الفاتورة غير موجودة")
            elif str(_inv_branch) != str(scope.branch_id):
                raise HTTPException(status_code=404,
                                    detail="الفاتورة غير موجودة")
        if not can_view_profit:
            data = result
            if hasattr(data, "model_dump"):
                data = data.model_dump()
            if isinstance(data, dict):
                for it in data.get("items", []) or []:
                    if isinstance(it, dict):
                        it.pop("cost_total", None)
                        it.pop("profit", None)
            return ok(data)
        return ok(result)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.put(
    "/invoices/{invoice_id}", summary="Update a draft invoice (items, discounts, taxes)"
)
async def update_invoice(
    invoice_id: UUID,
    data: InvoiceUpdate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "update")),
):
    service = _get_service(db)
    try:
        await _assert_invoice_branch(db, UUID(org_id), invoice_id, branch)
        from ...domain.entities.invoice_entities import (
            InvoiceItem as _Item, InvoiceItemChange as _Change)
        from sqlalchemy import select as _sel
        before = (await db.execute(_sel(_Item).where(
            _Item.invoice_id == invoice_id))).scalars().all()
        result = await service.update_invoice(invoice_id, UUID(org_id), user_id, data)
        # Track line edits so the linked party sees «before → after» per item.
        if data.items is not None:
            after = (await db.execute(_sel(_Item).where(
                _Item.invoice_id == invoice_id))).scalars().all()
            used = set()
            for old in before:
                match = next((n for i, n in enumerate(after)
                              if i not in used and
                              (n.description or '') == (old.description or '')),
                             None)
                if match is None:
                    continue
                used.add(after.index(match))
                qty_changed = abs(float(old.quantity or 0) -
                                  float(match.quantity or 0)) > 1e-6
                price_changed = abs(float(old.unit_price or 0) -
                                    float(match.unit_price or 0)) > 1e-6
                if qty_changed or price_changed:
                    db.add(_Change(
                        organization_id=UUID(org_id), invoice_id=invoice_id,
                        item_id=match.id, description=match.description,
                        old_quantity=old.quantity if qty_changed else None,
                        new_quantity=match.quantity if qty_changed else None,
                        old_unit_price=old.unit_price if price_changed else None,
                        new_unit_price=match.unit_price if price_changed else None,
                        changed_by=user_id,
                    ))
            await db.commit()
        return ok(result, "تم تحديث الفاتورة بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.delete("/invoices/{invoice_id}", summary="Delete a draft invoice (soft-delete)")
async def delete_invoice(
    invoice_id: UUID,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "delete")),
):
    service = _get_service(db)
    try:
        await _assert_invoice_branch(db, UUID(org_id), invoice_id, branch)
        await service.delete_invoice(invoice_id, UUID(org_id))
        return no_content("تم حذف الفاتورة بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


# ═══════════════════════════════════════════
# Status Workflow
# ═══════════════════════════════════════════


@router.post(
    "/invoices/{invoice_id}/status",
    summary="Transition invoice status (confirm/cancel)",
)
async def transition_invoice_status(
    invoice_id: UUID,
    data: InvoiceStatusTransition,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "update")),
):
    service = _get_service(db)
    try:
        await _assert_invoice_branch(db, UUID(org_id), invoice_id, branch)
        if data.action == "confirm":
            result = await service.confirm_invoice(invoice_id, UUID(org_id), user_id)
            return ok(result, "تم تأكيد الفاتورة بنجاح")
        elif data.action == "cancel":
            result = await service.cancel_invoice(invoice_id, UUID(org_id), user_id)
            return ok(result, "تم إلغاء الفاتورة بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


# ═══════════════════════════════════════════
# Atomic sale issue (no drafts) + returns
# ═══════════════════════════════════════════


@router.post(
    "/invoices/issue-sale",
    summary="Issue a sale invoice atomically (invoice + stock + accounts + debt)",
    status_code=status.HTTP_201_CREATED,
)
async def issue_sale(
    data: SaleIssueRequest,
    tasks: BackgroundTasks,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "create")),
):
    from ...domain.services import sale_service

    try:
        if data.branch_id is not None and data.branch_id != branch.id:
            raise ValueError("الفاتورة تخص فرعًا آخر")
        data.branch_id = branch.id
        result = await sale_service.issue_sale(db, UUID(org_id), user_id, data)
        service_pushes = result.pop('_notification_pushes', [])
        # Commercial-debt notification: emit now (same txn, outbox), push
        # AFTER commit via background task — never before persistence.
        try:
            from ...domain.entities.invoice_entities import Invoice
            from ...domain.services import merchant_link_service as mls
            from sqlalchemy import select as _sel
            inv = (await db.execute(
                _sel(Invoice).where(Invoice.id == UUID(result['id']))
            )).scalar_one_or_none()
            if inv is not None and inv.customer_id and float(inv.balance or 0) > 0:
                pushes = service_pushes or await mls.notify_party(
                    db, UUID(org_id), 'customer', inv.customer_id,
                    event_id=f"debt_created:{inv.id}",
                    title="دين جديد",
                    message=f"أُضيف دين جديد إلى حسابك بقيمة "
                            f"{inv.balance} {inv.currency}",
                    route_for=lambda link: (
                        f"/personal/merchant-partner?link={link.id}"
                        f"&op={inv.id}"),
                    actor_user_id=user_id)
                if pushes:
                    tasks.add_task(mls.deliver_pushes, pushes, UUID(org_id))
        except Exception:  # noqa: BLE001 — never break the financial op
            pass
        return created(result, f"تم إصدار الفاتورة {result['invoice_number']} بنجاح")
    except ValueError as e:
        await db.rollback()
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post(
    "/invoices/issue-purchase",
    summary="Issue a purchase invoice atomically (invoice + stock in + account out + payable)",
    status_code=status.HTTP_201_CREATED,
)
async def issue_purchase(
    data: PurchaseIssueRequest,
    tasks: BackgroundTasks,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "create")),
):
    from ...domain.services import sale_service

    try:
        if data.branch_id is not None and data.branch_id != branch.id:
            raise ValueError("الفاتورة تخص فرعًا آخر")
        data.branch_id = branch.id
        result = await sale_service.issue_purchase(db, UUID(org_id), user_id, data)
        service_pushes = result.pop('_notification_pushes', [])
        try:
            from ...domain.entities.invoice_entities import Invoice
            from ...domain.services import merchant_link_service as mls
            from sqlalchemy import select as _sel
            inv = (await db.execute(
                _sel(Invoice).where(Invoice.id == UUID(result['id']))
            )).scalar_one_or_none()
            if inv is not None and inv.supplier_id and float(inv.balance or 0) > 0:
                pushes = service_pushes or await mls.notify_party(
                    db, UUID(org_id), 'supplier', inv.supplier_id,
                    event_id=f"debt_created:{inv.id}",
                    title="دين جديد",
                    message=f"سُجّل دين جديد بقيمة "
                            f"{inv.balance} {inv.currency}",
                    route_for=lambda link: (
                        f"/personal/merchant-partner?link={link.id}"
                        f"&op={inv.id}"),
                    actor_user_id=user_id)
                if pushes:
                    tasks.add_task(mls.deliver_pushes, pushes, UUID(org_id))
        except Exception:  # noqa: BLE001 — never break the financial op
            pass
        return created(result, f"تم إصدار فاتورة الشراء {result['invoice_number']} بنجاح")
    except ValueError as e:
        await db.rollback()
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post(
    "/invoices/{invoice_id}/returns",
    summary="Confirm a return linked to the original invoice",
)
async def confirm_return(
    invoice_id: UUID,
    data: SaleReturnRequest,
    tasks: BackgroundTasks,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "update")),
):
    from ...domain.services import returns_service

    try:
        await _assert_invoice_branch(db, UUID(org_id), invoice_id, branch)
        result = await returns_service.confirm_any_return(
            db, UUID(org_id), user_id, invoice_id, data
        )
        from ...domain.services import merchant_link_service as mls
        pushes = result.pop('_notification_pushes', [])
        if pushes:
            tasks.add_task(mls.deliver_pushes, pushes, UUID(org_id))
        return created(result, "تم تسجيل المرتجع بنجاح")
    except ValueError as e:
        await db.rollback()
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


# ═══════════════════════════════════════════
# Returns (customer / supplier) — read
# ═══════════════════════════════════════════


@router.get("/returns", summary="Unified customer/supplier returns list")
async def list_returns(
    kind: Optional[str] = None,
    search: Optional[str] = None,
    invoice_id: Optional[str] = None,
    page: int = 1,
    per_page: int = 20,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "read")),
    request: Request = None,
):
    types = getattr(request.state, 'employee_invoice_types', None) if request else None
    if types is not None and len(types) == 1:
        kind = types[0]
    from ...domain.services import returns_service

    data = await returns_service.list_returns(
        db, UUID(org_id), kind=kind, search=search, invoice_id=invoice_id,
        page=page, per_page=per_page,
        branch_ids=scope.branch_ids if scope.all_mode else [scope.branch_id],
    )
    return ok_paginated(data["items"], data["total"], data["page"], data["per_page"])


@router.get("/returns/{kind}/{return_id}", summary="One return with its lines")
async def get_return(
    kind: str,
    return_id: UUID,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "read")),
):
    from ...domain.services import returns_service
    from sqlalchemy import select as _sel
    from ...domain.entities.sale_entities import InvoiceReturn as _IR
    from ...domain.entities.purchase_entities import PurchaseReturn as _PR
    from ...domain.entities.invoice_entities import Invoice as _Inv
    from ...domain.entities.sale_entities import Branch as _Branch

    if kind in ("purchase", "purchase_return"):
        bid = (await db.execute(_sel(_Inv.branch_id).join(
            _PR, _PR.invoice_id == _Inv.id).where(
            _PR.id == return_id, _PR.organization_id == UUID(org_id)))).scalar_one_or_none()
    else:
        bid = (await db.execute(_sel(_Inv.branch_id).join(
            _IR, _IR.invoice_id == _Inv.id).where(
            _IR.id == return_id, _IR.organization_id == UUID(org_id)))).scalar_one_or_none()
    from .business import _row_branch_allowed
    if not await _row_branch_allowed(db, bid, scope):
        raise HTTPException(404, detail='المرتجع غير موجود')
    if not scope.all_mode:
        if bid is None:
            is_main = bool((await db.execute(_sel(_Branch.is_default).where(
                _Branch.id == scope.branch_id))).scalar_one_or_none())
            if not is_main:
                raise HTTPException(status_code=404, detail="المرتجع غير موجود")
        elif str(bid) != str(scope.branch_id):
            raise HTTPException(status_code=404, detail="المرتجع غير موجود")
    result = await returns_service.get_return_detail(
        db, UUID(org_id), kind, return_id
    )
    if result is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="المرتجع غير موجود")
    return ok(result)


# ═══════════════════════════════════════════
# Payments
# ═══════════════════════════════════════════


@router.post(
    "/invoices/{invoice_id}/payments", summary="Add a payment to a confirmed invoice"
)
async def add_payment(
    invoice_id: UUID,
    data: PaymentCreate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "update")),
):
    service = _get_service(db)
    try:
        await _assert_invoice_branch(db, UUID(org_id), invoice_id, branch)
        result = await service.add_payment(invoice_id, UUID(org_id), user_id, data)
        return ok(result, "تم إضافة الدفعة بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


# ═══════════════════════════════════════════
# Merchant A4 invoice design (synced to the server so the LINKED party sees
# the exact same customized invoice: colours, logo, signature, stamp, footer).
# ═══════════════════════════════════════════
from pydantic import BaseModel as _BaseModel  # noqa: E402
import json as _json  # noqa: E402
from datetime import datetime as _dt, timezone as _tz  # noqa: E402
from sqlalchemy import select as _select  # noqa: E402
from ...domain.entities.invoice_entities import OrgInvoiceDesign as _Design  # noqa: E402


class InvoiceDesignSave(_BaseModel):
    payload: dict


@router.get("/invoices/designs/{template_id}", summary="تصميم الفاتورة المحفوظ")
async def get_invoice_design(
    template_id: str,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission('invoices', 'read')),
):
    from ...domain.services import branch_service as _bs
    branch_id = None if scope.all_mode else scope.branch_id
    main = await _bs.main_branch(db, UUID(org_id))
    if branch_id is None:
        branch_id = main.id
    row = (await db.execute(_select(_Design).where(
        _Design.organization_id == UUID(org_id),
        _Design.branch_id == branch_id,
        _Design.template_id == template_id))).scalar_one_or_none()
    # Extra branches inherit the main branch design until customized.
    if row is None and branch_id != main.id:
        row = (await db.execute(_select(_Design).where(
            _Design.organization_id == UUID(org_id),
            _Design.branch_id == main.id,
            _Design.template_id == template_id))).scalar_one_or_none()
    if row is None:
        row = (await db.execute(_select(_Design).where(
            _Design.organization_id == UUID(org_id),
            _Design.branch_id.is_(None),
            _Design.template_id == template_id))).scalar_one_or_none()
    payload = None
    if row is not None:
        try:
            payload = _json.loads(row.payload)
        except Exception:
            payload = None
    return ok({"template_id": template_id, "payload": payload,
               "branch_id": str(branch_id)})


@router.put("/invoices/designs/{template_id}", summary="حفظ تصميم الفاتورة")
async def save_invoice_design(
    template_id: str,
    data: InvoiceDesignSave,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "update")),
):
    payload = _json.dumps(data.payload, ensure_ascii=False)
    row = (await db.execute(_select(_Design).where(
        _Design.organization_id == UUID(org_id),
        _Design.branch_id == branch.id,
        _Design.template_id == template_id))).scalar_one_or_none()
    if row is None:
        db.add(_Design(organization_id=UUID(org_id),
                       branch_id=branch.id, template_id=template_id,
                       payload=payload))
    else:
        row.payload = payload
        row.updated_at = _dt.now(_tz.utc)
    await db.commit()
    return ok({"saved": True, "branch_id": str(branch.id)})
