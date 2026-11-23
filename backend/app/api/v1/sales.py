from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from typing import Optional
from uuid import UUID

from ...core.database import get_db
from ...api.deps import get_current_org_id, get_current_user_uuid, require_permission
from ...api.responses import ok, created, no_content, ok_paginated
from ...domain.models.sales_models import (
    SalesOrderCreate,
    SalesOrderUpdate,
    SalesReturnCreate,
    SalesQuoteCreate,
    DeliveryNoteCreate,
    StatusAction,
)
from ...domain.services.sales_service import SalesService
from ...infrastructure.repositories.sql_alchemy_m4_repository import (
    SqlAlchemySalesOrderRepository,
    SqlAlchemySalesOrderItemRepository,
    SqlAlchemySalesReturnRepository,
    SqlAlchemySalesReturnItemRepository,
    SqlAlchemySalesQuoteRepository,
    SqlAlchemyQuoteItemRepository,
    SqlAlchemyDeliveryNoteRepository,
    SqlAlchemyDeliveryNoteItemRepository,
)

router = APIRouter(tags=["Sales"])


def _svc(db):
    return SalesService(
        SqlAlchemySalesOrderRepository(db),
        SqlAlchemySalesOrderItemRepository(db),
        SqlAlchemySalesReturnRepository(db),
        SqlAlchemySalesReturnItemRepository(db),
        SqlAlchemySalesQuoteRepository(db),
        SqlAlchemyQuoteItemRepository(db),
        SqlAlchemyDeliveryNoteRepository(db),
        SqlAlchemyDeliveryNoteItemRepository(db),
    )


# ── Sales Orders ──


@router.post("/sales/orders", summary="Create a sales order", status_code=201)
async def create_so(
    data: SalesOrderCreate,
    org_id: str = Depends(get_current_org_id),
    uid: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("sales", "create")),
):
    try:
        r = await _svc(db).create_sales_order(UUID(org_id), uid, data)
        return created(r, "تم إنشاء أمر البيع")
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.get("/sales/orders", summary="List sales orders")
async def list_so(
    search: Optional[str] = None,
    status: Optional[str] = None,
    page: int = 1,
    per_page: int = 20,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("sales", "read")),
):
    items, total = await _svc(db).list_sales_orders(
        UUID(org_id), search, status, page, per_page
    )
    return ok_paginated([i.model_dump() for i in items], total, page, per_page)


@router.get("/sales/orders/{oid}", summary="Get a sales order")
async def get_so(
    oid: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("sales", "read")),
):
    try:
        r = await _svc(db).get_sales_order(oid, UUID(org_id))
        return ok(r)
    except ValueError as e:
        raise HTTPException(404, str(e))


@router.put("/sales/orders/{oid}", summary="Update a sales order")
async def update_so(
    oid: UUID,
    data: SalesOrderUpdate,
    org_id: str = Depends(get_current_org_id),
    uid: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("sales", "update")),
):
    try:
        r = await _svc(db).update_sales_order(oid, UUID(org_id), uid, data)
        return ok(r, "تم التحديث")
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.delete("/sales/orders/{oid}", summary="Delete a sales order")
async def delete_so(
    oid: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("sales", "delete")),
):
    try:
        await _svc(db).delete_sales_order(oid, UUID(org_id))
        return no_content("تم الحذف")
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.post(
    "/sales/orders/{oid}/status",
    summary="Change sales order status (confirm/cancel/deliver)",
)
async def so_status(
    oid: UUID,
    data: StatusAction,
    org_id: str = Depends(get_current_org_id),
    uid: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("sales", "update")),
):
    svc = _svc(db)
    try:
        if data.action == "confirm":
            r = await svc.confirm_sales_order(oid, UUID(org_id), uid)
        elif data.action == "cancel":
            r = await svc.cancel_sales_order(oid, UUID(org_id), uid)
        elif data.action == "deliver":
            r = await svc.deliver_sales_order(oid, UUID(org_id), uid)
        else:
            raise HTTPException(400, "إجراء غير معروف")
        return ok(r, "تم تغيير الحالة")
    except ValueError as e:
        raise HTTPException(400, str(e))


# ── Sales Returns ──


@router.post("/sales/returns", summary="Create a sales return", status_code=201)
async def create_sr(
    data: SalesReturnCreate,
    org_id: str = Depends(get_current_org_id),
    uid: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("sales", "create")),
):
    try:
        r = await _svc(db).create_sales_return(UUID(org_id), uid, data)
        return created(r, "تم إنشاء مرتجع البيع")
    except ValueError as e:
        raise HTTPException(400, str(e))


# ── Sales Quotes ──


@router.post("/sales/quotes", summary="Create a sales quote", status_code=201)
async def create_sq(
    data: SalesQuoteCreate,
    org_id: str = Depends(get_current_org_id),
    uid: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("sales", "create")),
):
    try:
        r = await _svc(db).create_sales_quote(UUID(org_id), uid, data)
        return created(r, "تم إنشاء عرض السعر")
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.get("/sales/quotes", summary="List sales quotes")
async def list_sq(
    page: int = 1,
    per_page: int = 20,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("sales", "read")),
):
    items, total = await _svc(db).list_sales_quotes(UUID(org_id), page, per_page)
    return ok_paginated([i.model_dump() for i in items], total, page, per_page)


# ── Delivery Notes ──


@router.post("/sales/deliveries", summary="Create a delivery note", status_code=201)
async def create_dn(
    data: DeliveryNoteCreate,
    org_id: str = Depends(get_current_org_id),
    uid: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("sales", "create")),
):
    try:
        r = await _svc(db).create_delivery_note(UUID(org_id), uid, data)
        return created(r, "تم إنشاء إذن التسليم")
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.get("/sales/deliveries", summary="List delivery notes")
async def list_dn(
    page: int = 1,
    per_page: int = 20,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("sales", "read")),
):
    items, total = await _svc(db).list_delivery_notes(UUID(org_id), page, per_page)
    return ok_paginated([i.model_dump() for i in items], total, page, per_page)
