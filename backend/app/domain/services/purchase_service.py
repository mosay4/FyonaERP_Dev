from uuid import UUID
from typing import Optional, List, Tuple
from datetime import date, datetime, timezone
from decimal import Decimal
from app.domain.models.purchase_models import (
    PurchaseOrderCreate,
    PurchaseOrderUpdate,
    PurchaseOrderResponse,
    PurchaseOrderItemResponse,
    PurchaseReceiptCreate,
    PurchaseReceiptResponse,
    SupplierBillCreate,
    SupplierBillResponse,
)
from app.domain.entities.purchase_entities import (
    PurchaseOrder,
    PurchaseOrderItem,
    PurchaseReceipt,
    PurchaseReceiptItem,
    SupplierBill,
)
from app.domain.repositories.m4_repository import (
    PurchaseOrderRepository,
    PurchaseOrderItemRepository,
    PurchaseReceiptRepository,
    PurchaseReceiptItemRepository,
    PurchaseReturnRepository,
    PurchaseReturnItemRepository,
    SupplierBillRepository,
)

ZERO = Decimal("0")


def _calc(items, discount_type, discount_value, tax_type, tax_rate):
    subtotal = (
        sum(
            (Decimal(str(i.quantity)) * i.unit_price - getattr(i, "discount", ZERO))
            for i in items
        )
        if items
        else ZERO
    )
    disc_amt = (
        subtotal * discount_value / Decimal("100")
        if discount_type == "percentage"
        else discount_value if discount_type == "fixed" else ZERO
    )
    after = subtotal - disc_amt
    tax_amt = (
        after * tax_rate / Decimal("100")
        if tax_type == "percentage"
        else tax_rate if tax_type == "fixed" else ZERO
    )
    total = after + tax_amt
    return {
        "subtotal": subtotal.quantize(Decimal("0.01")),
        "discount_amount": disc_amt.quantize(Decimal("0.01")),
        "tax_amount": tax_amt.quantize(Decimal("0.01")),
        "total": total.quantize(Decimal("0.01")),
    }


class PurchaseService:
    VALID_PO = {"draft": {"confirm", "cancel"}, "confirmed": {"receive", "cancel"}}
    VALID_PR = {"draft": {"confirm", "cancel"}}
    VALID_PUR = {"draft": {"confirm", "cancel"}}
    VALID_SB = {"draft": {"confirm", "cancel"}, "confirmed": {"pay"}}

    def __init__(
        self,
        po_repo: PurchaseOrderRepository,
        poi_repo: PurchaseOrderItemRepository,
        prec_repo: PurchaseReceiptRepository,
        preci_repo: PurchaseReceiptItemRepository,
        pur_repo: PurchaseReturnRepository,
        puri_repo: PurchaseReturnItemRepository,
        sb_repo: SupplierBillRepository,
    ):
        self._po = po_repo
        self._poi = poi_repo
        self._prec = prec_repo
        self._preci = preci_repo
        self._pur = pur_repo
        self._puri = puri_repo
        self._sb = sb_repo

    def _po_item_resp(self, i):
        return PurchaseOrderItemResponse(
            id=i.id,
            purchase_order_id=i.purchase_order_id,
            product_id=i.product_id,
            product_name=i.product.name if i.product else None,
            description=i.description,
            quantity=i.quantity,
            unit_price=i.unit_price,
            discount=i.discount,
            total=i.total,
        )

    def _po_resp(self, o):
        return PurchaseOrderResponse(
            id=o.id,
            organization_id=o.organization_id,
            supplier_id=o.supplier_id,
            supplier_name=o.supplier.name if o.supplier else None,
            order_number=o.order_number,
            order_date=o.order_date,
            status=o.status,
            subtotal=o.subtotal,
            discount_type=o.discount_type,
            discount_value=o.discount_value,
            discount_amount=o.discount_amount,
            tax_type=o.tax_type,
            tax_rate=o.tax_rate,
            tax_amount=o.tax_amount,
            total=o.total,
            paid_amount=o.paid_amount,
            balance=o.balance,
            notes=o.notes,
            terms=o.terms,
            created_at=o.created_at,
            confirmed_at=o.confirmed_at,
            received_at=o.received_at,
            cancelled_at=o.cancelled_at,
            items=[self._po_item_resp(i) for i in (o.items or [])],
        )

    async def create_purchase_order(
        self, org_id: UUID, user_id: UUID, data: PurchaseOrderCreate
    ) -> PurchaseOrderResponse:
        items = []
        for d in data.items:
            qty = Decimal(str(d.quantity))
            items.append(
                PurchaseOrderItem(
                    product_id=d.product_id,
                    description=d.description,
                    quantity=d.quantity,
                    unit_price=d.unit_price,
                    discount=d.discount,
                    total=(qty * d.unit_price - d.discount).quantize(Decimal("0.01")),
                )
            )
        if not items:
            raise ValueError("يجب إضافة بند واحد على الأقل")
        t = _calc(
            items, data.discount_type, data.discount_value, data.tax_type, data.tax_rate
        )
        num = await self._po.get_next_sequence(
            org_id, f"PO-{date.today().strftime('%Y%m%d')}", date.today()
        )
        o = PurchaseOrder(
            organization_id=org_id,
            order_number=f"PO-{date.today().strftime('%Y%m%d')}-{num:04d}",
            supplier_id=data.supplier_id,
            order_date=data.order_date or date.today(),
            discount_type=data.discount_type,
            discount_value=data.discount_value,
            tax_type=data.tax_type,
            tax_rate=data.tax_rate,
            notes=data.notes,
            terms=data.terms,
            created_by=user_id,
            **t,
            paid_amount=ZERO,
            balance=t["total"],
        )
        r = await self._po.create(o)
        await self._poi.bulk_create(r.id, items)
        r = await self._po.get_by_id(r.id, org_id)
        return self._po_resp(r)

    async def get_purchase_order(
        self, oid: UUID, org_id: UUID
    ) -> PurchaseOrderResponse:
        o = await self._po.get_by_id(oid, org_id)
        if not o:
            raise ValueError("أمر الشراء غير موجود")
        return self._po_resp(o)

    async def update_purchase_order(
        self, oid: UUID, org_id: UUID, uid: UUID, data: PurchaseOrderUpdate
    ) -> PurchaseOrderResponse:
        o = await self._po.get_by_id(oid, org_id)
        if not o:
            raise ValueError("أمر الشراء غير موجود")
        if o.status != "draft":
            raise ValueError("لا يمكن تعديل أمر شراء مؤكد")
        if data.items is not None:
            if not data.items:
                raise ValueError("يجب إضافة بند واحد على الأقل")
            await self._poi.delete_by_order(oid)
            items = []
            for d in data.items:
                qty = Decimal(str(d.quantity))
                items.append(
                    PurchaseOrderItem(
                        product_id=d.product_id,
                        description=d.description,
                        quantity=d.quantity,
                        unit_price=d.unit_price,
                        discount=d.discount,
                        total=(qty * d.unit_price - d.discount).quantize(
                            Decimal("0.01")
                        ),
                    )
                )
            await self._poi.bulk_create(oid, items)
        upd = data.model_dump(exclude_unset=True, exclude={"items"})
        for k, v in upd.items():
            if v is not None:
                setattr(o, k, v)
        items = await self._poi.list_by_order(oid)
        t = _calc(items, o.discount_type, o.discount_value, o.tax_type, o.tax_rate)
        o.subtotal, o.discount_amount, o.tax_amount, o.total = (
            t["subtotal"],
            t["discount_amount"],
            t["tax_amount"],
            t["total"],
        )
        o.balance = o.total - o.paid_amount
        r = await self._po.update(o)
        r = await self._po.get_by_id(r.id, org_id)
        return self._po_resp(r)

    async def delete_purchase_order(self, oid: UUID, org_id: UUID) -> None:
        o = await self._po.get_by_id(oid, org_id)
        if not o:
            raise ValueError("أمر الشراء غير موجود")
        if o.status != "draft":
            raise ValueError("لا يمكن حذف أمر شراء مؤكد")
        await self._po.soft_delete(oid, org_id)

    async def list_purchase_orders(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        status: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
    ) -> Tuple[List[PurchaseOrderResponse], int]:
        items, total = await self._po.list(org_id, search, status, page, per_page)
        return [self._po_resp(i) for i in items], total

    async def confirm_purchase_order(
        self, oid: UUID, org_id: UUID, uid: UUID
    ) -> PurchaseOrderResponse:
        o = await self._po.get_by_id(oid, org_id, lock=True)
        if not o:
            raise ValueError("أمر الشراء غير موجود")
        if o.status != "draft":
            raise ValueError("يمكن تأكيد مسودة فقط")
        if not o.items:
            raise ValueError("لا يوجد بنود")
        o.status, o.confirmed_at, o.balance = (
            "confirmed",
            datetime.now(timezone.utc),
            o.total - o.paid_amount,
        )
        r = await self._po.update(o)
        r = await self._po.get_by_id(r.id, org_id)
        return self._po_resp(r)

    async def cancel_purchase_order(
        self, oid: UUID, org_id: UUID, uid: UUID
    ) -> PurchaseOrderResponse:
        o = await self._po.get_by_id(oid, org_id, lock=True)
        if not o:
            raise ValueError("أمر الشراء غير موجود")
        if "cancel" not in self.VALID_PO.get(o.status, set()):
            raise ValueError("لا يمكن الإلغاء")
        o.status, o.cancelled_at, o.balance = (
            "cancelled",
            datetime.now(timezone.utc),
            ZERO,
        )
        r = await self._po.update(o)
        r = await self._po.get_by_id(r.id, org_id)
        return self._po_resp(r)

    async def receive_purchase_order(
        self, oid: UUID, org_id: UUID, uid: UUID
    ) -> PurchaseOrderResponse:
        o = await self._po.get_by_id(oid, org_id, lock=True)
        if not o:
            raise ValueError("أمر الشراء غير موجود")
        if o.status != "confirmed":
            raise ValueError("يمكن استلام المؤكد فقط")
        o.status, o.received_at = "received", datetime.now(timezone.utc)
        r = await self._po.update(o)
        r = await self._po.get_by_id(r.id, org_id)
        return self._po_resp(r)

    # ═══ Purchase Receipts ═══

    async def create_receipt(
        self, org_id: UUID, uid: UUID, data: PurchaseReceiptCreate
    ) -> PurchaseReceiptResponse:
        items = []
        for d in data.items:
            qty = Decimal(str(d.quantity))
            items.append(
                PurchaseReceiptItem(
                    product_id=d.product_id,
                    description=d.description,
                    quantity=d.quantity,
                    unit_price=d.unit_price,
                    total=(qty * d.unit_price).quantize(Decimal("0.01")),
                )
            )
        if not items:
            raise ValueError("يجب إضافة بند")
        num = await self._prec.get_next_sequence(
            org_id, f"PREC-{date.today().strftime('%Y%m%d')}", date.today()
        )
        r = PurchaseReceipt(
            organization_id=org_id,
            receipt_number=f"PREC-{date.today().strftime('%Y%m%d')}-{num:04d}",
            supplier_id=data.supplier_id,
            purchase_order_id=data.purchase_order_id,
            receipt_date=data.receipt_date or date.today(),
            notes=data.notes,
            created_by=uid,
        )
        r2 = await self._prec.create(r)
        await self._preci.bulk_create(r2.id, items)
        r2 = await self._prec.get_by_id(r2.id, org_id)
        return PurchaseReceiptResponse.model_validate(r2)

    async def confirm_receipt(
        self, rid: UUID, org_id: UUID, uid: UUID
    ) -> PurchaseReceiptResponse:
        r = await self._prec.get_by_id(rid, org_id)
        if not r:
            raise ValueError("الإيصال غير موجود")
        if r.status != "draft":
            raise ValueError("يمكن تأكيد المسودة فقط")
        r.status = "confirmed"
        r2 = await self._prec.update(r)
        r2 = await self._prec.get_by_id(r2.id, org_id)
        return PurchaseReceiptResponse.model_validate(r2)

    # ═══ Supplier Bills ═══

    async def create_supplier_bill(
        self, org_id: UUID, uid: UUID, data: SupplierBillCreate
    ) -> SupplierBillResponse:
        num = await self._sb.get_next_sequence(
            org_id, f"BILL-{date.today().strftime('%Y%m%d')}", date.today()
        )
        t = _calc(
            [], data.discount_type, data.discount_value, data.tax_type, data.tax_rate
        )
        b = SupplierBill(
            organization_id=org_id,
            bill_number=f"BILL-{date.today().strftime('%Y%m%d')}-{num:04d}",
            supplier_id=data.supplier_id,
            purchase_order_id=data.purchase_order_id,
            bill_date=data.bill_date or date.today(),
            due_date=data.due_date,
            discount_type=data.discount_type,
            discount_value=data.discount_value,
            tax_type=data.tax_type,
            tax_rate=data.tax_rate,
            notes=data.notes,
            created_by=uid,
            **t,
        )
        b.balance = b.total
        r = await self._sb.create(b)
        r = await self._sb.get_by_id(r.id, org_id)
        return SupplierBillResponse.model_validate(r)

    async def confirm_supplier_bill(
        self, bid: UUID, org_id: UUID, uid: UUID
    ) -> SupplierBillResponse:
        b = await self._sb.get_by_id(bid, org_id, lock=True)
        if not b:
            raise ValueError("الفاتورة غير موجودة")
        if b.status != "draft":
            raise ValueError("يمكن تأكيد المسودة فقط")
        b.status, b.balance = "confirmed", b.total - b.paid_amount
        r = await self._sb.update(b)
        r = await self._sb.get_by_id(r.id, org_id)
        return SupplierBillResponse.model_validate(r)

    async def pay_supplier_bill(
        self, bid: UUID, org_id: UUID, amount: Decimal
    ) -> SupplierBillResponse:
        b = await self._sb.get_by_id(bid, org_id, lock=True)
        if not b:
            raise ValueError("الفاتورة غير موجودة")
        if b.status not in ("confirmed", "partially_paid"):
            raise ValueError("لا يمكن الدفع")
        if amount > b.balance:
            raise ValueError(f"المبلغ يتجاوز الرصيد ({b.balance})")
        b.paid_amount += amount
        b.balance = b.total - b.paid_amount
        b.status = "paid" if b.balance <= Decimal("0.005") else "partially_paid"
        r = await self._sb.update(b)
        r = await self._sb.get_by_id(r.id, org_id)
        return SupplierBillResponse.model_validate(r)
