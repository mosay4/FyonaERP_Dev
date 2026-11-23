from uuid import UUID
from typing import Optional, List, Tuple
from datetime import date
from sqlalchemy import select, func, or_, update
from sqlalchemy.ext.asyncio import AsyncSession
from app.domain.entities.invoice_entities import (
    Invoice,
    InvoiceItem,
    Payment,
    InvoiceSequence,
)
from app.domain.repositories.invoice_repository import (
    InvoiceRepository,
    InvoiceItemRepository,
    PaymentRepository,
)


class SqlAlchemyInvoiceRepository(InvoiceRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, invoice: Invoice) -> Invoice:
        self._session.add(invoice)
        await self._session.flush()
        return invoice

    async def get_by_id(
        self, invoice_id: UUID, org_id: UUID, lock: bool = False
    ) -> Optional[Invoice]:
        stmt = select(Invoice).where(
            Invoice.id == invoice_id,
            Invoice.organization_id == org_id,
            ~Invoice.is_deleted,
        )
        if lock:
            stmt = stmt.with_for_update()
        result = await self._session.execute(stmt)
        return result.unique().scalar_one_or_none()

    async def update(self, invoice: Invoice) -> Invoice:
        self._session.add(invoice)
        await self._session.flush()
        return invoice

    async def cancel(self, invoice: Invoice, actor_id: UUID) -> Invoice:
        # Original cancellation already sets document balance to zero. Keep the
        # existing receivable/payable mirror in that same cancelled state, rather
        # than leaving a second contradictory linked-party debt open. No stock,
        # cash, amount, payment or allowed-transition rule is changed here.
        from app.domain.entities.sale_entities import CustomerReceivable, SupplierPayable
        from app.domain.services import merchant_link_service as links
        await self.update(invoice)
        for model in (CustomerReceivable, SupplierPayable):
            await self._session.execute(update(model).where(
                model.organization_id == invoice.organization_id,
                model.invoice_id == invoice.id).values(status='cancelled'))
        kind = 'supplier' if invoice.invoice_type == 'purchase' else 'customer'
        party_id = invoice.supplier_id if kind == 'supplier' else invoice.customer_id
        if party_id:
            await links.notify_party(self._session, invoice.organization_id, kind, party_id,
                event_id=f'debt_cancelled:{invoice.id}', title='إلغاء الدين',
                message=f'أُلغيت الفاتورة {invoice.invoice_number}',
                route_for=lambda link: f'/personal/merchant-partner?link={link.id}&op={invoice.id}',
                actor_user_id=actor_id)
        await self._session.flush()
        return invoice

    async def soft_delete(self, invoice_id: UUID, org_id: UUID) -> None:
        from datetime import datetime, timezone

        stmt = (
            update(Invoice)
            .where(Invoice.id == invoice_id, Invoice.organization_id == org_id)
            .values(is_deleted=True, deleted_at=datetime.now(timezone.utc))
        )
        await self._session.execute(stmt)
        await self._session.flush()

    async def list(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        status: Optional[str] = None,
        invoice_type: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
        branch_ids: Optional[list] = None,
        number_only: bool = False,
    ) -> Tuple[List[Invoice], int]:
        query = select(Invoice).where(
            Invoice.organization_id == org_id, ~Invoice.is_deleted
        )
        count_query = select(func.count(Invoice.id)).where(
            Invoice.organization_id == org_id, ~Invoice.is_deleted
        )
        if branch_ids is not None:
            query = query.where(Invoice.branch_id.in_(branch_ids))
            count_query = count_query.where(Invoice.branch_id.in_(branch_ids))

        # When the search is an EXACT barcode, the caller wants every invoice
        # that contains that product — across BOTH invoice types (the app then
        # warns if a customer-return search matched a supplier invoice). A
        # normal text search matches the invoice number AND the party name.
        apply_type = True
        if search:
            term = search.strip()
            if term and number_only:
                like = f"%{term}%"
                query = query.where(Invoice.invoice_number.ilike(like))
                count_query = count_query.where(
                    Invoice.invoice_number.ilike(like))
            elif term and await self._is_barcode(org_id, term):
                subq = self._barcode_invoice_subq(org_id, term)
                query = query.where(Invoice.id.in_(subq))
                count_query = count_query.where(Invoice.id.in_(subq))
                apply_type = False
            elif term:
                like = f"%{term}%"
                from app.domain.entities.business_entities import (
                    Customer as _Customer,
                    Supplier as _Supplier,
                )

                cust_subq = select(_Customer.id).where(
                    _Customer.organization_id == org_id,
                    or_(_Customer.name.ilike(like), _Customer.phone.ilike(like)),
                )
                sup_subq = select(_Supplier.id).where(
                    _Supplier.organization_id == org_id,
                    or_(_Supplier.name.ilike(like), _Supplier.phone.ilike(like)),
                )
                search_filter = or_(
                    Invoice.invoice_number.ilike(like),
                    Invoice.customer_id.in_(cust_subq),
                    Invoice.supplier_id.in_(sup_subq),
                )
                query = query.where(search_filter)
                count_query = count_query.where(search_filter)

        if status:
            query = query.where(Invoice.status == status)
            count_query = count_query.where(Invoice.status == status)

        if invoice_type and apply_type:
            query = query.where(Invoice.invoice_type == invoice_type)
            count_query = count_query.where(Invoice.invoice_type == invoice_type)

        count_result = await self._session.execute(count_query)
        total = count_result.scalar() or 0

        query = (
            query.order_by(Invoice.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        result = await self._session.execute(query)
        items = list(result.unique().scalars().all())

        return items, total

    async def _is_barcode(self, org_id: UUID, code: str) -> bool:
        from app.domain.entities.business_entities import Product
        from app.domain.entities.sale_entities import ProductBarcode

        n = (
            await self._session.execute(
                select(func.count())
                .select_from(ProductBarcode)
                .where(
                    ProductBarcode.organization_id == org_id,
                    ProductBarcode.barcode == code,
                )
            )
        ).scalar() or 0
        if n:
            return True
        n = (
            await self._session.execute(
                select(func.count())
                .select_from(Product)
                .where(
                    Product.organization_id == org_id,
                    Product.barcode == code,
                    ~Product.is_deleted,
                )
            )
        ).scalar() or 0
        return n > 0

    def _barcode_invoice_subq(self, org_id: UUID, code: str):
        from app.domain.entities.business_entities import Product
        from app.domain.entities.sale_entities import ProductBarcode

        prod_ids = select(ProductBarcode.product_id).where(
            ProductBarcode.organization_id == org_id,
            ProductBarcode.barcode == code,
        )
        return (
            select(InvoiceItem.invoice_id)
            .join(Product, Product.id == InvoiceItem.product_id)
            .where(
                Product.organization_id == org_id,
                or_(Product.barcode == code, Product.id.in_(prod_ids)),
            )
        )

    async def get_next_sequence(self, org_id: UUID, prefix: str, date_val: date) -> int:
        stmt = (
            select(InvoiceSequence)
            .where(
                InvoiceSequence.organization_id == org_id,
                InvoiceSequence.prefix == prefix,
                InvoiceSequence.date == date_val,
            )
            .with_for_update()
        )
        result = await self._session.execute(stmt)
        seq = result.unique().scalar_one_or_none()

        if seq:
            seq.last_sequence += 1
            self._session.add(seq)
            await self._session.flush()
            return seq.last_sequence
        else:
            new_seq = InvoiceSequence(
                organization_id=org_id,
                prefix=prefix,
                last_sequence=1,
                date=date_val,
            )
            self._session.add(new_seq)
            await self._session.flush()
            return 1


class SqlAlchemyInvoiceItemRepository(InvoiceItemRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def bulk_create(
        self, invoice_id: UUID, items: List[InvoiceItem]
    ) -> List[InvoiceItem]:
        for item in items:
            item.invoice_id = invoice_id
            self._session.add(item)
        await self._session.flush()
        return items

    async def delete_by_invoice(self, invoice_id: UUID) -> None:
        stmt = select(InvoiceItem).where(InvoiceItem.invoice_id == invoice_id)
        result = await self._session.execute(stmt)
        items = result.unique().scalars().all()
        for item in items:
            await self._session.delete(item)
        await self._session.flush()

    async def list_by_invoice(self, invoice_id: UUID) -> List[InvoiceItem]:
        stmt = select(InvoiceItem).where(InvoiceItem.invoice_id == invoice_id)
        result = await self._session.execute(stmt)
        return list(result.unique().scalars().all())


class SqlAlchemyPaymentRepository(PaymentRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, payment: Payment) -> Payment:
        self._session.add(payment)
        await self._session.flush()
        return payment

    async def get_by_id(self, payment_id: UUID, org_id: UUID) -> Optional[Payment]:
        stmt = select(Payment).where(
            Payment.id == payment_id,
            Payment.organization_id == org_id,
        )
        result = await self._session.execute(stmt)
        return result.unique().scalar_one_or_none()

    async def list_by_invoice(self, invoice_id: UUID, org_id: UUID) -> List[Payment]:
        stmt = (
            select(Payment)
            .where(
                Payment.invoice_id == invoice_id,
                Payment.organization_id == org_id,
            )
            .order_by(Payment.created_at.desc())
        )
        result = await self._session.execute(stmt)
        return list(result.unique().scalars().all())

    async def delete(self, payment_id: UUID, org_id: UUID) -> None:
        stmt = select(Payment).where(
            Payment.id == payment_id, Payment.organization_id == org_id
        )
        result = await self._session.execute(stmt)
        payment = result.unique().scalar_one_or_none()
        if payment:
            await self._session.delete(payment)
            await self._session.flush()
