from uuid import UUID
from typing import Optional, List, Tuple
from datetime import datetime, timezone, date
from decimal import Decimal
from app.domain.models.invoice_models import (
    InvoiceCreate,
    InvoiceUpdate,
    InvoiceResponse,
    InvoiceItemResponse,
    PaymentCreate,
    PaymentResponse,
)
from app.domain.entities.invoice_entities import Invoice, InvoiceItem, Payment
from app.domain.repositories.invoice_repository import (
    InvoiceRepository,
    InvoiceItemRepository,
    PaymentRepository,
)

ZERO = Decimal("0")
TAU = Decimal("0.005")


class InvoiceService:
    VALID_TRANSITIONS = {
        "draft": {"confirm", "cancel"},
        "confirmed": {"cancel"},
    }

    def __init__(
        self,
        invoice_repo: InvoiceRepository,
        item_repo: InvoiceItemRepository,
        payment_repo: PaymentRepository,
    ):
        self._invoice_repo = invoice_repo
        self._item_repo = item_repo
        self._payment_repo = payment_repo

    async def _generate_invoice_number(self, org_id: UUID) -> str:
        today = date.today()
        prefix = f"INV-{today.strftime('%Y%m%d')}"
        seq = await self._invoice_repo.get_next_sequence(org_id, prefix, today)
        return f"{prefix}-{seq:04d}"

    def _calculate_totals(
        self,
        items: list,
        discount_type: Optional[str],
        discount_value: Decimal,
        tax_type: Optional[str],
        tax_rate: Decimal,
    ) -> dict:
        subtotal = ZERO
        for item in items:
            qty = Decimal(str(item.quantity))
            line_total = qty * item.unit_price - item.discount
            subtotal += line_total

        discount_amount = ZERO
        if discount_type == "percentage":
            discount_amount = subtotal * discount_value / Decimal("100")
        elif discount_type == "fixed":
            discount_amount = discount_value

        after_discount = subtotal - discount_amount

        tax_amount = ZERO
        if tax_type == "percentage":
            tax_amount = after_discount * tax_rate / Decimal("100")
        elif tax_type == "fixed":
            tax_amount = tax_rate

        total = after_discount + tax_amount

        return {
            "subtotal": subtotal.quantize(Decimal("0.01")),
            "discount_amount": discount_amount.quantize(Decimal("0.01")),
            "tax_amount": tax_amount.quantize(Decimal("0.01")),
            "total": total.quantize(Decimal("0.01")),
        }

    def _item_to_response(self, item: InvoiceItem) -> InvoiceItemResponse:
        return InvoiceItemResponse(
            id=item.id,
            invoice_id=item.invoice_id,
            product_id=item.product_id,
            product_name=item.product.name if item.product else None,
            description=item.description,
            quantity=item.quantity,
            unit_price=item.unit_price,
            discount=item.discount,
            tax_rate=item.tax_rate,
            total=item.total,
            unit_id=getattr(item, "unit_id", None),
            unit_name=getattr(item, "unit_name", None),
            base_quantity=float(getattr(item, "base_quantity", 0) or 0),
            is_service=bool(getattr(item, "is_service", False)),
        )

    def _invoice_to_response(self, invoice: Invoice) -> InvoiceResponse:
        return InvoiceResponse(
            id=invoice.id,
            organization_id=invoice.organization_id,
            invoice_number=invoice.invoice_number,
            invoice_type=invoice.invoice_type,
            customer_id=invoice.customer_id,
            customer_name=invoice.customer.name if invoice.customer else None,
            supplier_id=invoice.supplier_id,
            supplier_name=invoice.supplier.name if invoice.supplier else None,
            invoice_date=invoice.invoice_date,
            due_date=invoice.due_date,
            status=invoice.status,
            subtotal=invoice.subtotal,
            discount_type=invoice.discount_type,
            discount_value=invoice.discount_value,
            discount_amount=invoice.discount_amount,
            tax_type=invoice.tax_type,
            tax_rate=invoice.tax_rate,
            tax_amount=invoice.tax_amount,
            total=invoice.total,
            paid_amount=invoice.paid_amount,
            balance=invoice.balance,
            notes=invoice.notes,
            terms=invoice.terms,
            currency=getattr(invoice, "currency", None) or "SAR",
            branch_id=getattr(invoice, "branch_id", None),
            branch_name=None,
            created_at=invoice.created_at,
            updated_at=invoice.updated_at,
            confirmed_at=invoice.confirmed_at,
            cancelled_at=invoice.cancelled_at,
            items=[self._item_to_response(i) for i in invoice.items],
            payments=[
                PaymentResponse(
                    id=p.id,
                    invoice_id=p.invoice_id,
                    amount=p.amount,
                    payment_date=p.payment_date,
                    payment_method=p.payment_method,
                    reference=p.reference,
                    notes=p.notes,
                    created_at=p.created_at,
                    bank_account_id=getattr(p, "bank_account_id", None),
                    bank_account_name=(
                        p.bank_account.bank_name
                        if getattr(p, "bank_account", None) else None
                    ),
                )
                for p in invoice.payments
            ],
        )

    # ═══════════════════════════════════════════
    # CRUD
    # ═══════════════════════════════════════════

    async def create_invoice(
        self, org_id: UUID, user_id: UUID, data: InvoiceCreate,
        branch_id: Optional[UUID] = None,
    ) -> InvoiceResponse:
        items = []
        for item_data in data.items:
            qty = Decimal(str(item_data.quantity))
            item_total = qty * item_data.unit_price - item_data.discount
            item = InvoiceItem(
                product_id=item_data.product_id,
                description=item_data.description,
                quantity=item_data.quantity,
                unit_price=item_data.unit_price,
                discount=item_data.discount,
                tax_rate=item_data.tax_rate,
                total=item_total.quantize(Decimal("0.01")),
            )
            items.append(item)

        if not items:
            raise ValueError("يجب إضافة بند واحد على الأقل")

        totals = self._calculate_totals(
            items,
            data.discount_type,
            data.discount_value,
            data.tax_type,
            data.tax_rate,
        )

        invoice_number = await self._generate_invoice_number(org_id)

        invoice = Invoice(
            organization_id=org_id,
            branch_id=branch_id,
            invoice_number=invoice_number,
            invoice_type=data.invoice_type,
            customer_id=data.customer_id,
            supplier_id=data.supplier_id,
            invoice_date=data.invoice_date or date.today(),
            due_date=data.due_date,
            status="draft",
            subtotal=totals["subtotal"],
            discount_type=data.discount_type,
            discount_value=data.discount_value,
            discount_amount=totals["discount_amount"],
            tax_type=data.tax_type,
            tax_rate=data.tax_rate,
            tax_amount=totals["tax_amount"],
            total=totals["total"],
            paid_amount=ZERO,
            balance=totals["total"],
            notes=data.notes,
            terms=data.terms,
            created_by=user_id,
        )

        result = await self._invoice_repo.create(invoice)
        await self._item_repo.bulk_create(result.id, items)
        result = await self._invoice_repo.get_by_id(result.id, org_id)
        return self._invoice_to_response(result)

    async def get_invoice(self, invoice_id: UUID, org_id: UUID) -> InvoiceResponse:
        invoice = await self._invoice_repo.get_by_id(invoice_id, org_id)
        if not invoice:
            raise ValueError("الفاتورة غير موجودة")
        return self._invoice_to_response(invoice)

    async def update_invoice(
        self, invoice_id: UUID, org_id: UUID, user_id: UUID, data: InvoiceUpdate
    ) -> InvoiceResponse:
        invoice = await self._invoice_repo.get_by_id(invoice_id, org_id)
        if not invoice:
            raise ValueError("الفاتورة غير موجودة")

        if invoice.status != "draft":
            raise ValueError("لا يمكن تعديل فاتورة مؤكدة أو ملغية")

        if data.items is not None:
            if not data.items:
                raise ValueError("يجب إضافة بند واحد على الأقل")
            await self._item_repo.delete_by_invoice(invoice_id)
            items = []
            for item_data in data.items:
                qty = Decimal(str(item_data.quantity))
                item_total = qty * item_data.unit_price - item_data.discount
                item = InvoiceItem(
                    product_id=item_data.product_id,
                    description=item_data.description,
                    quantity=item_data.quantity,
                    unit_price=item_data.unit_price,
                    discount=item_data.discount,
                    tax_rate=item_data.tax_rate,
                    total=item_total.quantize(Decimal("0.01")),
                )
                items.append(item)
            await self._item_repo.bulk_create(invoice_id, items)

        update_data = data.model_dump(exclude_unset=True, exclude={"items"})
        for key, value in update_data.items():
            if value is not None:
                setattr(invoice, key, value)

        items = await self._item_repo.list_by_invoice(invoice_id)
        totals = self._calculate_totals(
            items,
            invoice.discount_type,
            invoice.discount_value,
            invoice.tax_type,
            invoice.tax_rate,
        )
        invoice.subtotal = totals["subtotal"]
        invoice.discount_amount = totals["discount_amount"]
        invoice.tax_amount = totals["tax_amount"]
        invoice.total = totals["total"]
        invoice.balance = totals["total"] - invoice.paid_amount

        result = await self._invoice_repo.update(invoice)
        result = await self._invoice_repo.get_by_id(result.id, org_id)
        return self._invoice_to_response(result)

    async def delete_invoice(self, invoice_id: UUID, org_id: UUID) -> None:
        invoice = await self._invoice_repo.get_by_id(invoice_id, org_id)
        if not invoice:
            raise ValueError("الفاتورة غير موجودة")
        if invoice.status != "draft":
            raise ValueError("لا يمكن حذف فاتورة مؤكدة أو ملغية")
        await self._invoice_repo.soft_delete(invoice_id, org_id)

    async def list_invoices(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        status: Optional[str] = None,
        invoice_type: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
        branch_ids: Optional[list] = None,
        number_only: bool = False,
    ) -> Tuple[List[InvoiceResponse], int]:
        items, total = await self._invoice_repo.list(
            org_id, search, status, invoice_type, page, per_page, branch_ids,
            number_only,
        )
        return [self._invoice_to_response(i) for i in items], total

    # ═══════════════════════════════════════════
    # Status Workflow
    # ═══════════════════════════════════════════

    async def confirm_invoice(
        self, invoice_id: UUID, org_id: UUID, user_id: UUID
    ) -> InvoiceResponse:
        invoice = await self._invoice_repo.get_by_id(invoice_id, org_id, lock=True)
        if not invoice:
            raise ValueError("الفاتورة غير موجودة")

        if invoice.status != "draft":
            raise ValueError("يمكن تأكيد الفواتير المسودة فقط")

        if not invoice.items:
            raise ValueError("لا يمكن تأكيد فاتورة بدون بنود")

        if invoice.paid_amount > invoice.total:
            raise ValueError("المبلغ المدفوع يتجاوز إجمالي الفاتورة")

        invoice.status = "confirmed"
        invoice.confirmed_at = datetime.now(timezone.utc)
        invoice.balance = invoice.total - invoice.paid_amount

        result = await self._invoice_repo.update(invoice)
        result = await self._invoice_repo.get_by_id(result.id, org_id)
        return self._invoice_to_response(result)

    async def cancel_invoice(
        self, invoice_id: UUID, org_id: UUID, user_id: UUID
    ) -> InvoiceResponse:
        invoice = await self._invoice_repo.get_by_id(invoice_id, org_id, lock=True)
        if not invoice:
            raise ValueError("الفاتورة غير موجودة")

        allowed = self.VALID_TRANSITIONS.get(invoice.status, set())
        if "cancel" not in allowed:
            raise ValueError(f"لا يمكن إلغاء فاتورة بحالة {invoice.status}")

        invoice.status = "cancelled"
        invoice.cancelled_at = datetime.now(timezone.utc)
        invoice.balance = ZERO

        result = await self._invoice_repo.cancel(invoice, user_id)
        result = await self._invoice_repo.get_by_id(result.id, org_id)
        return self._invoice_to_response(result)

    # ═══════════════════════════════════════════
    # Payments
    # ═══════════════════════════════════════════

    async def add_payment(
        self, invoice_id: UUID, org_id: UUID, user_id: UUID, data: PaymentCreate
    ) -> InvoiceResponse:
        invoice = await self._invoice_repo.get_by_id(invoice_id, org_id, lock=True)
        if not invoice:
            raise ValueError("الفاتورة غير موجودة")

        if invoice.status != "confirmed":
            raise ValueError("يمكن إضافة دفعات للفواتير المؤكدة فقط")

        if data.amount > invoice.balance:
            raise ValueError(f"المبلغ يتجاوز الرصيد المتبقي ({invoice.balance})")

        payment = Payment(
            organization_id=org_id,
            branch_id=getattr(invoice, "branch_id", None),
            invoice_id=invoice_id,
            amount=data.amount,
            payment_date=data.payment_date or date.today(),
            payment_method=data.payment_method,
            reference=data.reference,
            notes=data.notes,
            created_by=user_id,
        )
        await self._payment_repo.create(payment)

        invoice.paid_amount += data.amount
        invoice.balance = invoice.total - invoice.paid_amount

        if invoice.balance <= TAU:
            invoice.status = "paid"
        else:
            invoice.status = "partially_paid"

        await self._invoice_repo.update(invoice)
        result = await self._invoice_repo.get_by_id(invoice_id, org_id)
        return self._invoice_to_response(result)
