from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from typing import Optional
from uuid import UUID
from decimal import Decimal

from ...core.database import get_db
from ...api.deps import get_current_org_id, get_current_user_uuid, require_permission
from ...api.responses import ok, created, no_content, ok_paginated
from ...domain.models.purchase_models import (
    PurchaseOrderCreate,
    PurchaseOrderUpdate,
    PurchaseReceiptCreate,
    SupplierBillCreate,
    StatusAction,
)
from ...domain.services.purchase_service import PurchaseService
from ...infrastructure.repositories.sql_alchemy_m4_repository import (
    SqlAlchemyPurchaseOrderRepository,
    SqlAlchemyPurchaseOrderItemRepository,
    SqlAlchemyPurchaseReceiptRepository,
    SqlAlchemyPurchaseReceiptItemRepository,
    SqlAlchemyPurchaseReturnRepository,
    SqlAlchemyPurchaseReturnItemRepository,
    SqlAlchemySupplierBillRepository,
)

router = APIRouter(tags=["Purchases"])


def _svc(db):
    return PurchaseService(
        SqlAlchemyPurchaseOrderRepository(db),
        SqlAlchemyPurchaseOrderItemRepository(db),
        SqlAlchemyPurchaseReceiptRepository(db),
        SqlAlchemyPurchaseReceiptItemRepository(db),
        SqlAlchemyPurchaseReturnRepository(db),
        SqlAlchemyPurchaseReturnItemRepository(db),
        SqlAlchemySupplierBillRepository(db),
    )


# ── Purchase Orders ──


@router.post("/purchases/orders", summary="Create a purchase order", status_code=201)
async def create_po(
    data: PurchaseOrderCreate,
    org_id: str = Depends(get_current_org_id),
    uid: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("purchases", "create")),
):
    try:
        r = await _svc(db).create_purchase_order(UUID(org_id), uid, data)
        return created(r, "تم إنشاء أمر الشراء")
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.get("/purchases/orders", summary="List purchase orders")
async def list_po(
    search: Optional[str] = None,
    status: Optional[str] = None,
    page: int = 1,
    per_page: int = 20,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("purchases", "read")),
):
    items, total = await _svc(db).list_purchase_orders(
        UUID(org_id), search, status, page, per_page
    )
    return ok_paginated([i.model_dump() for i in items], total, page, per_page)


@router.get("/purchases/orders/{oid}", summary="Get a purchase order")
async def get_po(
    oid: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("purchases", "read")),
):
    try:
        r = await _svc(db).get_purchase_order(oid, UUID(org_id))
        return ok(r)
    except ValueError as e:
        raise HTTPException(404, str(e))


@router.put("/purchases/orders/{oid}", summary="Update a purchase order")
async def update_po(
    oid: UUID,
    data: PurchaseOrderUpdate,
    org_id: str = Depends(get_current_org_id),
    uid: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("purchases", "update")),
):
    try:
        r = await _svc(db).update_purchase_order(oid, UUID(org_id), uid, data)
        return ok(r, "تم التحديث")
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.delete("/purchases/orders/{oid}", summary="Delete a purchase order")
async def delete_po(
    oid: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("purchases", "delete")),
):
    try:
        await _svc(db).delete_purchase_order(oid, UUID(org_id))
        return no_content("تم الحذف")
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.post("/purchases/orders/{oid}/status", summary="Change purchase order status")
async def po_status(
    oid: UUID,
    data: StatusAction,
    org_id: str = Depends(get_current_org_id),
    uid: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("purchases", "update")),
):
    svc = _svc(db)
    try:
        if data.action == "confirm":
            r = await svc.confirm_purchase_order(oid, UUID(org_id), uid)
        elif data.action == "cancel":
            r = await svc.cancel_purchase_order(oid, UUID(org_id), uid)
        elif data.action == "receive":
            r = await svc.receive_purchase_order(oid, UUID(org_id), uid)
        else:
            raise HTTPException(400, "إجراء غير معروف")
        return ok(r, "تم تغيير الحالة")
    except ValueError as e:
        raise HTTPException(400, str(e))


# ── Purchase Receipts ──


@router.post(
    "/purchases/receipts", summary="Create a purchase receipt", status_code=201
)
async def create_receipt(
    data: PurchaseReceiptCreate,
    org_id: str = Depends(get_current_org_id),
    uid: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("purchases", "create")),
):
    try:
        r = await _svc(db).create_receipt(UUID(org_id), uid, data)
        return created(r, "تم إنشاء إيصال الاستلام")
    except ValueError as e:
        raise HTTPException(400, str(e))


# ── Supplier Bills ──


@router.post("/purchases/bills", summary="Create a supplier bill", status_code=201)
async def create_bill(
    data: SupplierBillCreate,
    org_id: str = Depends(get_current_org_id),
    uid: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("purchases", "create")),
):
    try:
        r = await _svc(db).create_supplier_bill(UUID(org_id), uid, data)
        return created(r, "تم إنشاء فاتورة المورد")
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.post("/purchases/bills/{bid}/pay", summary="Pay a supplier bill")
async def pay_bill(
    bid: UUID,
    amount: Decimal,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _=Depends(require_permission("purchases", "update")),
):
    try:
        r = await _svc(db).pay_supplier_bill(bid, UUID(org_id), amount)
        return ok(r, "تم تسجيل الدفعة")
    except ValueError as e:
        raise HTTPException(400, str(e))
