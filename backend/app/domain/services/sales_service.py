from uuid import UUID
from typing import Optional, List, Tuple
from datetime import date, datetime, timezone
from decimal import Decimal
from app.domain.models.sales_models import (
    SalesOrderCreate,
    SalesOrderUpdate,
    SalesOrderResponse,
    SalesOrderItemResponse,
    SalesReturnCreate,
    SalesReturnResponse,
    SalesQuoteCreate,
    SalesQuoteResponse,
    DeliveryNoteCreate,
    DeliveryNoteResponse,
)
from app.domain.entities.sales_entities import (
    SalesOrder,
    SalesOrderItem,
    SalesReturn,
    SalesReturnItem,
    SalesQuote,
    QuoteItem,
    DeliveryNote,
    DeliveryNoteItem,
)
from app.domain.repositories.m4_repository import (
    SalesOrderRepository,
    SalesOrderItemRepository,
    SalesReturnRepository,
    SalesReturnItemRepository,
    SalesQuoteRepository,
    QuoteItemRepository,
    DeliveryNoteRepository,
    DeliveryNoteItemRepository,
)

ZERO = Decimal("0")


class SalesService:
    VALID_SO_TRANSITIONS = {
        "draft": {"confirm", "cancel"},
        "confirmed": {"deliver", "cancel"},
    }
    VALID_SR_TRANSITIONS = {"draft": {"confirm", "cancel"}}
    VALID_SQ_TRANSITIONS = {
        "draft": {"send"},
        "sent": {"accept", "reject"},
        "accepted": {"convert"},
    }
    VALID_DN_TRANSITIONS = {"draft": {"confirm", "cancel"}}

    def __init__(
        self,
        so_repo: SalesOrderRepository,
        soi_repo: SalesOrderItemRepository,
        sr_repo: SalesReturnRepository,
        sri_repo: SalesReturnItemRepository,
        sq_repo: SalesQuoteRepository,
        qi_repo: QuoteItemRepository,
        dn_repo: DeliveryNoteRepository,
        dni_repo: DeliveryNoteItemRepository,
    ):
        self._so_repo = so_repo
        self._soi_repo = soi_repo
        self._sr_repo = sr_repo
        self._sri_repo = sri_repo
        self._sq_repo = sq_repo
        self._qi_repo = qi_repo
        self._dn_repo = dn_repo
        self._dni_repo = dni_repo

    def _calc(
        self,
        items: list,
        discount_type: Optional[str],
        discount_value: Decimal,
        tax_type: Optional[str],
        tax_rate: Decimal,
    ) -> dict:
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

    # ═══ Sales Orders ═══

    async def create_sales_order(
        self, org_id: UUID, user_id: UUID, data: SalesOrderCreate
    ) -> SalesOrderResponse:
        items = []
        for d in data.items:
            qty = Decimal(str(d.quantity))
            item_total = qty * d.unit_price - d.discount
            items.append(
                SalesOrderItem(
                    product_id=d.product_id,
                    description=d.description,
                    quantity=d.quantity,
                    unit_price=d.unit_price,
                    discount=d.discount,
                    tax_rate=d.tax_rate,
                    total=item_total.quantize(Decimal("0.01")),
                )
            )
        if not items:
            raise ValueError("يجب إضافة بند واحد على الأقل")
        totals = self._calc(
            items, data.discount_type, data.discount_value, data.tax_type, data.tax_rate
        )
        num = await self._so_repo.get_next_sequence(
            org_id, f"SO-{date.today().strftime('%Y%m%d')}", date.today()
        )
        order = SalesOrder(
            organization_id=org_id,
            order_number=f"SO-{date.today().strftime('%Y%m%d')}-{num:04d}",
            customer_id=data.customer_id,
            order_date=data.order_date or date.today(),
            discount_type=data.discount_type,
            discount_value=data.discount_value,
            tax_type=data.tax_type,
            tax_rate=data.tax_rate,
            notes=data.notes,
            terms=data.terms,
            created_by=user_id,
            **totals,
            paid_amount=ZERO,
            balance=totals["total"],
        )
        result = await self._so_repo.create(order)
        await self._soi_repo.bulk_create(result.id, items)
        result = await self._so_repo.get_by_id(result.id, org_id)
        return self._so_to_resp(result)

    def _so_to_resp(self, o: SalesOrder) -> SalesOrderResponse:
        return SalesOrderResponse(
            id=o.id,
            organization_id=o.organization_id,
            customer_id=o.customer_id,
            customer_name=o.customer.name if o.customer else None,
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
            updated_at=o.updated_at,
            confirmed_at=o.confirmed_at,
            delivered_at=o.delivered_at,
            cancelled_at=o.cancelled_at,
            items=[self._so_item_resp(i) for i in (o.items or [])],
        )

    def _so_item_resp(self, i: SalesOrderItem) -> SalesOrderItemResponse:
        return SalesOrderItemResponse(
            id=i.id,
            sales_order_id=i.sales_order_id,
            product_id=i.product_id,
            product_name=i.product.name if i.product else None,
            description=i.description,
            quantity=i.quantity,
            unit_price=i.unit_price,
            discount=i.discount,
            tax_rate=i.tax_rate,
            total=i.total,
        )

    async def get_sales_order(self, order_id: UUID, org_id: UUID) -> SalesOrderResponse:
        o = await self._so_repo.get_by_id(order_id, org_id)
        if not o:
            raise ValueError("أمر البيع غير موجود")
        return self._so_to_resp(o)

    async def update_sales_order(
        self, order_id: UUID, org_id: UUID, user_id: UUID, data: SalesOrderUpdate
    ) -> SalesOrderResponse:
        o = await self._so_repo.get_by_id(order_id, org_id)
        if not o:
            raise ValueError("أمر البيع غير موجود")
        if o.status != "draft":
            raise ValueError("لا يمكن تعديل أمر بيع مؤكد")
        if data.items is not None:
            if not data.items:
                raise ValueError("يجب إضافة بند واحد على الأقل")
            await self._soi_repo.delete_by_order(order_id)
            items = []
            for d in data.items:
                qty = Decimal(str(d.quantity))
                items.append(
                    SalesOrderItem(
                        product_id=d.product_id,
                        description=d.description,
                        quantity=d.quantity,
                        unit_price=d.unit_price,
                        discount=d.discount,
                        tax_rate=d.tax_rate,
                        total=(qty * d.unit_price - d.discount).quantize(
                            Decimal("0.01")
                        ),
                    )
                )
            await self._soi_repo.bulk_create(order_id, items)
        upd = data.model_dump(exclude_unset=True, exclude={"items"})
        for k, v in upd.items():
            if v is not None:
                setattr(o, k, v)
        items = await self._soi_repo.list_by_order(order_id)
        t = self._calc(items, o.discount_type, o.discount_value, o.tax_type, o.tax_rate)
        o.subtotal, o.discount_amount, o.tax_amount, o.total = (
            t["subtotal"],
            t["discount_amount"],
            t["tax_amount"],
            t["total"],
        )
        o.balance = o.total - o.paid_amount
        result = await self._so_repo.update(o)
        result = await self._so_repo.get_by_id(result.id, org_id)
        return self._so_to_resp(result)

    async def delete_sales_order(self, order_id: UUID, org_id: UUID) -> None:
        o = await self._so_repo.get_by_id(order_id, org_id)
        if not o:
            raise ValueError("أمر البيع غير موجود")
        if o.status != "draft":
            raise ValueError("لا يمكن حذف أمر بيع مؤكد")
        await self._so_repo.soft_delete(order_id, org_id)

    async def list_sales_orders(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        status: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
    ) -> Tuple[List[SalesOrderResponse], int]:
        items, total = await self._so_repo.list(org_id, search, status, page, per_page)
        return [self._so_to_resp(i) for i in items], total

    async def confirm_sales_order(
        self, order_id: UUID, org_id: UUID, user_id: UUID
    ) -> SalesOrderResponse:
        o = await self._so_repo.get_by_id(order_id, org_id, lock=True)
        if not o:
            raise ValueError("أمر البيع غير موجود")
        if o.status != "draft":
            raise ValueError("يمكن تأكيد أوامر البيع المسودة فقط")
        if not o.items:
            raise ValueError("لا يمكن تأكيد أمر بدون بنود")
        o.status, o.confirmed_at = "confirmed", datetime.now(timezone.utc)
        o.balance = o.total - o.paid_amount
        result = await self._so_repo.update(o)
        result = await self._so_repo.get_by_id(result.id, org_id)
        return self._so_to_resp(result)

    async def cancel_sales_order(
        self, order_id: UUID, org_id: UUID, user_id: UUID
    ) -> SalesOrderResponse:
        o = await self._so_repo.get_by_id(order_id, org_id, lock=True)
        if not o:
            raise ValueError("أمر البيع غير موجود")
        if "cancel" not in self.VALID_SO_TRANSITIONS.get(o.status, set()):
            raise ValueError(f"لا يمكن إلغاء أمر بحالة {o.status}")
        o.status, o.cancelled_at, o.balance = (
            "cancelled",
            datetime.now(timezone.utc),
            ZERO,
        )
        result = await self._so_repo.update(o)
        result = await self._so_repo.get_by_id(result.id, org_id)
        return self._so_to_resp(result)

    async def deliver_sales_order(
        self, order_id: UUID, org_id: UUID, user_id: UUID
    ) -> SalesOrderResponse:
        o = await self._so_repo.get_by_id(order_id, org_id, lock=True)
        if not o:
            raise ValueError("أمر البيع غير موجود")
        if o.status != "confirmed":
            raise ValueError("يمكن تسليم أوامر البيع المؤكدة فقط")
        o.status, o.delivered_at = "delivered", datetime.now(timezone.utc)
        result = await self._so_repo.update(o)
        result = await self._so_repo.get_by_id(result.id, org_id)
        return self._so_to_resp(result)

    # ═══ Sales Returns ═══

    async def create_sales_return(
        self, org_id: UUID, user_id: UUID, data: SalesReturnCreate
    ) -> SalesReturnResponse:
        items = []
        for d in data.items:
            qty = Decimal(str(d.quantity))
            items.append(
                SalesReturnItem(
                    product_id=d.product_id,
                    description=d.description,
                    quantity=d.quantity,
                    unit_price=d.unit_price,
                    total=(qty * d.unit_price).quantize(Decimal("0.01")),
                )
            )
        if not items:
            raise ValueError("يجب إضافة بند واحد على الأقل")
        total = sum(i.total for i in items) if items else ZERO
        num = await self._sr_repo.get_next_sequence(
            org_id, f"SR-{date.today().strftime('%Y%m%d')}", date.today()
        )
        r = SalesReturn(
            organization_id=org_id,
            return_number=f"SR-{date.today().strftime('%Y%m%d')}-{num:04d}",
            customer_id=data.customer_id,
            sales_order_id=data.sales_order_id,
            return_date=data.return_date or date.today(),
            reason=data.reason,
            notes=data.notes,
            total=total.quantize(Decimal("0.01")),
            created_by=user_id,
        )
        result = await self._sr_repo.create(r)
        await self._sri_repo.bulk_create(result.id, items)
        result = await self._sr_repo.get_by_id(result.id, org_id)
        return SalesReturnResponse.model_validate(result)

    # ═══ Sales Quotes ═══

    async def create_sales_quote(
        self, org_id: UUID, user_id: UUID, data: SalesQuoteCreate
    ) -> SalesQuoteResponse:
        items = []
        for d in data.items:
            qty = Decimal(str(d.quantity))
            items.append(
                QuoteItem(
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
        t = self._calc(
            items, data.discount_type, data.discount_value, data.tax_type, data.tax_rate
        )
        num = await self._sq_repo.get_next_sequence(
            org_id, f"Q-{date.today().strftime('%Y%m%d')}", date.today()
        )
        q = SalesQuote(
            organization_id=org_id,
            quote_number=f"Q-{date.today().strftime('%Y%m%d')}-{num:04d}",
            customer_id=data.customer_id,
            quote_date=data.quote_date or date.today(),
            expiry_date=data.expiry_date,
            discount_type=data.discount_type,
            discount_value=data.discount_value,
            tax_type=data.tax_type,
            tax_rate=data.tax_rate,
            notes=data.notes,
            terms=data.terms,
            created_by=user_id,
            **t,
        )
        result = await self._sq_repo.create(q)
        await self._qi_repo.bulk_create(result.id, items)
        result = await self._sq_repo.get_by_id(result.id, org_id)
        return SalesQuoteResponse.model_validate(result)

    async def list_sales_quotes(
        self, org_id: UUID, page: int = 1, per_page: int = 20
    ) -> Tuple[List[SalesQuoteResponse], int]:
        items, total = await self._sq_repo.list(org_id, page, per_page)
        return [SalesQuoteResponse.model_validate(i) for i in items], total

    # ═══ Delivery Notes ═══

    async def create_delivery_note(
        self, org_id: UUID, user_id: UUID, data: DeliveryNoteCreate
    ) -> DeliveryNoteResponse:
        items = []
        for d in data.items:
            qty = Decimal(str(d.quantity))
            items.append(
                DeliveryNoteItem(
                    product_id=d.product_id,
                    description=d.description,
                    quantity=d.quantity,
                    unit_price=d.unit_price,
                    total=(qty * d.unit_price).quantize(Decimal("0.01")),
                )
            )
        if not items:
            raise ValueError("يجب إضافة بند واحد على الأقل")
        num = await self._dn_repo.get_next_sequence(
            org_id, f"DN-{date.today().strftime('%Y%m%d')}", date.today()
        )
        n = DeliveryNote(
            organization_id=org_id,
            delivery_number=f"DN-{date.today().strftime('%Y%m%d')}-{num:04d}",
            customer_id=data.customer_id,
            sales_order_id=data.sales_order_id,
            delivery_date=data.delivery_date or date.today(),
            notes=data.notes,
            created_by=user_id,
        )
        result = await self._dn_repo.create(n)
        await self._dni_repo.bulk_create(result.id, items)
        result = await self._dn_repo.get_by_id(result.id, org_id)
        return DeliveryNoteResponse.model_validate(result)

    async def list_delivery_notes(
        self, org_id: UUID, page: int = 1, per_page: int = 20
    ) -> Tuple[List[DeliveryNoteResponse], int]:
        items, total = await self._dn_repo.list(org_id, page, per_page)
        return [DeliveryNoteResponse.model_validate(i) for i in items], total
