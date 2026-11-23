import uuid
from datetime import date, datetime, timezone
from uuid import UUID
from typing import Optional, List, Tuple
from sqlalchemy import select, func, update
from sqlalchemy.ext.asyncio import AsyncSession

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
from app.domain.entities.purchase_entities import (
    PurchaseOrder,
    PurchaseOrderItem,
    PurchaseReceipt,
    PurchaseReceiptItem,
    PurchaseReturn,
    PurchaseReturnItem,
    SupplierBill,
)
from app.domain.entities.accounting_entities import Account, JournalEntry
from app.domain.repositories.m4_repository import (
    SalesOrderRepository,
    SalesOrderItemRepository,
    SalesReturnRepository,
    SalesReturnItemRepository,
    SalesQuoteRepository,
    QuoteItemRepository,
    DeliveryNoteRepository,
    DeliveryNoteItemRepository,
    PurchaseOrderRepository,
    PurchaseOrderItemRepository,
    PurchaseReceiptRepository,
    PurchaseReceiptItemRepository,
    PurchaseReturnRepository,
    PurchaseReturnItemRepository,
    SupplierBillRepository,
    AccountRepository,
    JournalEntryRepository,
    JournalEntryLineRepository,
)


def utcnow():
    return datetime.now(timezone.utc)


class SqlAlchemySequenceMixin:
    """Mixin for invoice-style sequences."""

    _session: AsyncSession
    _entity: type
    _org_col: str = "organization_id"

    async def get_next_sequence(self, org_id: UUID, prefix: str, date_val: date) -> int:
        from app.domain.entities.invoice_entities import InvoiceSequence

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
            type(
                "_InsSeq",
                (),
                {
                    "id": uuid.uuid4(),
                    "organization_id": org_id,
                    "prefix": prefix,
                    "last_sequence": 1,
                    "date": date_val,
                },
            )()
            # manually insert since InvoiceSequence is in another file
            from sqlalchemy import insert
            from app.domain.entities.invoice_entities import InvoiceSequence

            await self._session.execute(
                insert(InvoiceSequence).values(
                    id=uuid.uuid4(),
                    organization_id=org_id,
                    prefix=prefix,
                    last_sequence=1,
                    date=date_val,
                )
            )
            await self._session.flush()
            return 1


# ═══════════════════════════════════════════
# Sales Order
# ═══════════════════════════════════════════


class SqlAlchemySalesOrderRepository(SalesOrderRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, order: SalesOrder) -> SalesOrder:
        self._session.add(order)
        await self._session.flush()
        return order

    async def get_by_id(
        self, order_id: UUID, org_id: UUID, lock: bool = False
    ) -> Optional[SalesOrder]:
        stmt = select(SalesOrder).where(
            SalesOrder.id == order_id,
            SalesOrder.organization_id == org_id,
            ~SalesOrder.is_deleted,
        )
        if lock:
            stmt = stmt.with_for_update()
        r = await self._session.execute(stmt)
        return r.unique().scalar_one_or_none()

    async def update(self, order: SalesOrder) -> SalesOrder:
        self._session.add(order)
        await self._session.flush()
        return order

    async def soft_delete(self, order_id: UUID, org_id: UUID) -> None:
        stmt = (
            update(SalesOrder)
            .where(SalesOrder.id == order_id, SalesOrder.organization_id == org_id)
            .values(is_deleted=True, deleted_at=utcnow())
        )
        await self._session.execute(stmt)
        await self._session.flush()

    async def list(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        status: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
    ) -> Tuple[List[SalesOrder], int]:
        q = select(SalesOrder).where(
            SalesOrder.organization_id == org_id, ~SalesOrder.is_deleted
        )
        cq = select(func.count(SalesOrder.id)).where(
            SalesOrder.organization_id == org_id, ~SalesOrder.is_deleted
        )
        if search:
            f = SalesOrder.order_number.ilike(f"%{search}%")
            q, cq = q.where(f), cq.where(f)
        if status:
            q, cq = q.where(SalesOrder.status == status), cq.where(
                SalesOrder.status == status
            )
        total = (await self._session.execute(cq)).scalar() or 0
        r = await self._session.execute(
            q.order_by(SalesOrder.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        return list(r.unique().scalars().all()), total

    async def get_next_sequence(self, org_id: UUID, prefix: str, date_val: date) -> int:
        from app.domain.entities.invoice_entities import InvoiceSequence

        stmt = (
            select(InvoiceSequence)
            .where(
                InvoiceSequence.organization_id == org_id,
                InvoiceSequence.prefix == prefix,
                InvoiceSequence.date == date_val,
            )
            .with_for_update()
        )
        seq = (await self._session.execute(stmt)).unique().scalar_one_or_none()
        if seq:
            seq.last_sequence += 1
            self._session.add(seq)
            await self._session.flush()
            return seq.last_sequence
        from sqlalchemy import insert

        await self._session.execute(
            insert(InvoiceSequence).values(
                id=uuid.uuid4(),
                organization_id=org_id,
                prefix=prefix,
                last_sequence=1,
                date=date_val,
            )
        )
        await self._session.flush()
        return 1


class SqlAlchemySalesOrderItemRepository(SalesOrderItemRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def bulk_create(
        self, order_id: UUID, items: List[SalesOrderItem]
    ) -> List[SalesOrderItem]:
        for i in items:
            i.sales_order_id = order_id
            self._session.add(i)
        await self._session.flush()
        return items

    async def delete_by_order(self, order_id: UUID) -> None:
        r = await self._session.execute(
            select(SalesOrderItem).where(SalesOrderItem.sales_order_id == order_id)
        )
        for i in r.unique().scalars().all():
            await self._session.delete(i)
        await self._session.flush()

    async def list_by_order(self, order_id: UUID) -> List[SalesOrderItem]:
        r = await self._session.execute(
            select(SalesOrderItem).where(SalesOrderItem.sales_order_id == order_id)
        )
        return list(r.unique().scalars().all())


class SqlAlchemySalesReturnRepository(SalesReturnRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, return_: SalesReturn) -> SalesReturn:
        self._session.add(return_)
        await self._session.flush()
        return return_

    async def get_by_id(self, return_id: UUID, org_id: UUID) -> Optional[SalesReturn]:
        r = await self._session.execute(
            select(SalesReturn).where(
                SalesReturn.id == return_id, SalesReturn.organization_id == org_id
            )
        )
        return r.unique().scalar_one_or_none()

    async def update(self, return_: SalesReturn) -> SalesReturn:
        self._session.add(return_)
        await self._session.flush()
        return return_

    async def list(
        self, org_id: UUID, page: int = 1, per_page: int = 20
    ) -> Tuple[List[SalesReturn], int]:
        total = (
            await self._session.execute(
                select(func.count(SalesReturn.id)).where(
                    SalesReturn.organization_id == org_id
                )
            )
        ).scalar() or 0
        r = await self._session.execute(
            select(SalesReturn)
            .where(SalesReturn.organization_id == org_id)
            .order_by(SalesReturn.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        return list(r.unique().scalars().all()), total

    async def get_next_sequence(self, org_id: UUID, prefix: str, date_val: date) -> int:
        return await SqlAlchemySalesOrderRepository(self._session).get_next_sequence(
            org_id, prefix, date_val
        )


class SqlAlchemySalesReturnItemRepository(SalesReturnItemRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def bulk_create(
        self, return_id: UUID, items: List[SalesReturnItem]
    ) -> List[SalesReturnItem]:
        for i in items:
            i.sales_return_id = return_id
            self._session.add(i)
        await self._session.flush()
        return items


class SqlAlchemySalesQuoteRepository(SalesQuoteRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, quote: SalesQuote) -> SalesQuote:
        self._session.add(quote)
        await self._session.flush()
        return quote

    async def get_by_id(self, quote_id: UUID, org_id: UUID) -> Optional[SalesQuote]:
        r = await self._session.execute(
            select(SalesQuote).where(
                SalesQuote.id == quote_id, SalesQuote.organization_id == org_id
            )
        )
        return r.unique().scalar_one_or_none()

    async def update(self, quote: SalesQuote) -> SalesQuote:
        self._session.add(quote)
        await self._session.flush()
        return quote

    async def list(
        self, org_id: UUID, page: int = 1, per_page: int = 20
    ) -> Tuple[List[SalesQuote], int]:
        total = (
            await self._session.execute(
                select(func.count(SalesQuote.id)).where(
                    SalesQuote.organization_id == org_id
                )
            )
        ).scalar() or 0
        r = await self._session.execute(
            select(SalesQuote)
            .where(SalesQuote.organization_id == org_id)
            .order_by(SalesQuote.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        return list(r.unique().scalars().all()), total

    async def get_next_sequence(self, org_id: UUID, prefix: str, date_val: date) -> int:
        return await SqlAlchemySalesOrderRepository(self._session).get_next_sequence(
            org_id, prefix, date_val
        )


class SqlAlchemyQuoteItemRepository(QuoteItemRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def bulk_create(
        self, quote_id: UUID, items: List[QuoteItem]
    ) -> List[QuoteItem]:
        for i in items:
            i.quote_id = quote_id
            self._session.add(i)
        await self._session.flush()
        return items

    async def delete_by_quote(self, quote_id: UUID) -> None:
        r = await self._session.execute(
            select(QuoteItem).where(QuoteItem.quote_id == quote_id)
        )
        for i in r.unique().scalars().all():
            await self._session.delete(i)
        await self._session.flush()


class SqlAlchemyDeliveryNoteRepository(DeliveryNoteRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, note: DeliveryNote) -> DeliveryNote:
        self._session.add(note)
        await self._session.flush()
        return note

    async def get_by_id(self, note_id: UUID, org_id: UUID) -> Optional[DeliveryNote]:
        r = await self._session.execute(
            select(DeliveryNote).where(
                DeliveryNote.id == note_id, DeliveryNote.organization_id == org_id
            )
        )
        return r.unique().scalar_one_or_none()

    async def update(self, note: DeliveryNote) -> DeliveryNote:
        self._session.add(note)
        await self._session.flush()
        return note

    async def list(
        self, org_id: UUID, page: int = 1, per_page: int = 20
    ) -> Tuple[List[DeliveryNote], int]:
        total = (
            await self._session.execute(
                select(func.count(DeliveryNote.id)).where(
                    DeliveryNote.organization_id == org_id
                )
            )
        ).scalar() or 0
        r = await self._session.execute(
            select(DeliveryNote)
            .where(DeliveryNote.organization_id == org_id)
            .order_by(DeliveryNote.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        return list(r.unique().scalars().all()), total

    async def get_next_sequence(self, org_id: UUID, prefix: str, date_val: date) -> int:
        return await SqlAlchemySalesOrderRepository(self._session).get_next_sequence(
            org_id, prefix, date_val
        )


class SqlAlchemyDeliveryNoteItemRepository(DeliveryNoteItemRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def bulk_create(
        self, note_id: UUID, items: List[DeliveryNoteItem]
    ) -> List[DeliveryNoteItem]:
        for i in items:
            i.delivery_note_id = note_id
            self._session.add(i)
        await self._session.flush()
        return items


# ═══════════════════════════════════════════
# Purchase Order
# ═══════════════════════════════════════════


class SqlAlchemyPurchaseOrderRepository(PurchaseOrderRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, order: PurchaseOrder) -> PurchaseOrder:
        self._session.add(order)
        await self._session.flush()
        return order

    async def get_by_id(
        self, order_id: UUID, org_id: UUID, lock: bool = False
    ) -> Optional[PurchaseOrder]:
        stmt = select(PurchaseOrder).where(
            PurchaseOrder.id == order_id,
            PurchaseOrder.organization_id == org_id,
            ~PurchaseOrder.is_deleted,
        )
        if lock:
            stmt = stmt.with_for_update()
        r = await self._session.execute(stmt)
        return r.unique().scalar_one_or_none()

    async def update(self, order: PurchaseOrder) -> PurchaseOrder:
        self._session.add(order)
        await self._session.flush()
        return order

    async def soft_delete(self, order_id: UUID, org_id: UUID) -> None:
        stmt = (
            update(PurchaseOrder)
            .where(
                PurchaseOrder.id == order_id, PurchaseOrder.organization_id == org_id
            )
            .values(is_deleted=True, deleted_at=utcnow())
        )
        await self._session.execute(stmt)
        await self._session.flush()

    async def list(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        status: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
    ) -> Tuple[List[PurchaseOrder], int]:
        q = select(PurchaseOrder).where(
            PurchaseOrder.organization_id == org_id, ~PurchaseOrder.is_deleted
        )
        cq = select(func.count(PurchaseOrder.id)).where(
            PurchaseOrder.organization_id == org_id, ~PurchaseOrder.is_deleted
        )
        if search:
            f = PurchaseOrder.order_number.ilike(f"%{search}%")
            q, cq = q.where(f), cq.where(f)
        if status:
            q, cq = q.where(PurchaseOrder.status == status), cq.where(
                PurchaseOrder.status == status
            )
        total = (await self._session.execute(cq)).scalar() or 0
        r = await self._session.execute(
            q.order_by(PurchaseOrder.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        return list(r.unique().scalars().all()), total

    async def get_next_sequence(self, org_id: UUID, prefix: str, date_val: date) -> int:
        return await SqlAlchemySalesOrderRepository(self._session).get_next_sequence(
            org_id, prefix, date_val
        )


class SqlAlchemyPurchaseOrderItemRepository(PurchaseOrderItemRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def bulk_create(
        self, order_id: UUID, items: List[PurchaseOrderItem]
    ) -> List[PurchaseOrderItem]:
        for i in items:
            i.purchase_order_id = order_id
            self._session.add(i)
        await self._session.flush()
        return items

    async def delete_by_order(self, order_id: UUID) -> None:
        r = await self._session.execute(
            select(PurchaseOrderItem).where(
                PurchaseOrderItem.purchase_order_id == order_id
            )
        )
        for i in r.unique().scalars().all():
            await self._session.delete(i)
        await self._session.flush()

    async def list_by_order(self, order_id: UUID) -> List[PurchaseOrderItem]:
        r = await self._session.execute(
            select(PurchaseOrderItem).where(
                PurchaseOrderItem.purchase_order_id == order_id
            )
        )
        return list(r.unique().scalars().all())


class SqlAlchemyPurchaseReceiptRepository(PurchaseReceiptRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, receipt: PurchaseReceipt) -> PurchaseReceipt:
        self._session.add(receipt)
        await self._session.flush()
        return receipt

    async def get_by_id(
        self, receipt_id: UUID, org_id: UUID
    ) -> Optional[PurchaseReceipt]:
        r = await self._session.execute(
            select(PurchaseReceipt).where(
                PurchaseReceipt.id == receipt_id,
                PurchaseReceipt.organization_id == org_id,
            )
        )
        return r.unique().scalar_one_or_none()

    async def update(self, receipt: PurchaseReceipt) -> PurchaseReceipt:
        self._session.add(receipt)
        await self._session.flush()
        return receipt

    async def list(
        self, org_id: UUID, page: int = 1, per_page: int = 20
    ) -> Tuple[List[PurchaseReceipt], int]:
        total = (
            await self._session.execute(
                select(func.count(PurchaseReceipt.id)).where(
                    PurchaseReceipt.organization_id == org_id
                )
            )
        ).scalar() or 0
        r = await self._session.execute(
            select(PurchaseReceipt)
            .where(PurchaseReceipt.organization_id == org_id)
            .order_by(PurchaseReceipt.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        return list(r.unique().scalars().all()), total

    async def get_next_sequence(self, org_id: UUID, prefix: str, date_val: date) -> int:
        return await SqlAlchemySalesOrderRepository(self._session).get_next_sequence(
            org_id, prefix, date_val
        )


class SqlAlchemyPurchaseReceiptItemRepository(PurchaseReceiptItemRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def bulk_create(
        self, receipt_id: UUID, items: List[PurchaseReceiptItem]
    ) -> List[PurchaseReceiptItem]:
        for i in items:
            i.purchase_receipt_id = receipt_id
            self._session.add(i)
        await self._session.flush()
        return items


class SqlAlchemyPurchaseReturnRepository(PurchaseReturnRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, return_: PurchaseReturn) -> PurchaseReturn:
        self._session.add(return_)
        await self._session.flush()
        return return_

    async def get_by_id(
        self, return_id: UUID, org_id: UUID
    ) -> Optional[PurchaseReturn]:
        r = await self._session.execute(
            select(PurchaseReturn).where(
                PurchaseReturn.id == return_id, PurchaseReturn.organization_id == org_id
            )
        )
        return r.unique().scalar_one_or_none()

    async def update(self, return_: PurchaseReturn) -> PurchaseReturn:
        self._session.add(return_)
        await self._session.flush()
        return return_

    async def get_next_sequence(self, org_id: UUID, prefix: str, date_val: date) -> int:
        return await SqlAlchemySalesOrderRepository(self._session).get_next_sequence(
            org_id, prefix, date_val
        )


class SqlAlchemyPurchaseReturnItemRepository(PurchaseReturnItemRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def bulk_create(
        self, return_id: UUID, items: List[PurchaseReturnItem]
    ) -> List[PurchaseReturnItem]:
        for i in items:
            i.purchase_return_id = return_id
            self._session.add(i)
        await self._session.flush()
        return items


class SqlAlchemySupplierBillRepository(SupplierBillRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, bill: SupplierBill) -> SupplierBill:
        self._session.add(bill)
        await self._session.flush()
        return bill

    async def get_by_id(
        self, bill_id: UUID, org_id: UUID, lock: bool = False
    ) -> Optional[SupplierBill]:
        stmt = select(SupplierBill).where(
            SupplierBill.id == bill_id, SupplierBill.organization_id == org_id
        )
        if lock:
            stmt = stmt.with_for_update()
        r = await self._session.execute(stmt)
        return r.unique().scalar_one_or_none()

    async def update(self, bill: SupplierBill) -> SupplierBill:
        self._session.add(bill)
        await self._session.flush()
        return bill

    async def list(
        self, org_id: UUID, page: int = 1, per_page: int = 20
    ) -> Tuple[List[SupplierBill], int]:
        total = (
            await self._session.execute(
                select(func.count(SupplierBill.id)).where(
                    SupplierBill.organization_id == org_id
                )
            )
        ).scalar() or 0
        r = await self._session.execute(
            select(SupplierBill)
            .where(SupplierBill.organization_id == org_id)
            .order_by(SupplierBill.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        return list(r.unique().scalars().all()), total

    async def get_next_sequence(self, org_id: UUID, prefix: str, date_val: date) -> int:
        return await SqlAlchemySalesOrderRepository(self._session).get_next_sequence(
            org_id, prefix, date_val
        )


# ═══════════════════════════════════════════
# Accounting
# ═══════════════════════════════════════════


class SqlAlchemyAccountRepository(AccountRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, account: Account) -> Account:
        self._session.add(account)
        await self._session.flush()
        return account

    async def get_by_id(self, account_id: UUID, org_id: UUID) -> Optional[Account]:
        r = await self._session.execute(
            select(Account).where(
                Account.id == account_id, Account.organization_id == org_id
            )
        )
        return r.unique().scalar_one_or_none()

    async def update(self, account: Account) -> Account:
        self._session.add(account)
        await self._session.flush()
        return account

    async def get_by_code(self, code: str, org_id: UUID) -> Optional[Account]:
        r = await self._session.execute(
            select(Account).where(
                Account.code == code, Account.organization_id == org_id
            )
        )
        return r.unique().scalar_one_or_none()

    async def list(
        self, org_id: UUID, type_filter: Optional[str] = None
    ) -> List[Account]:
        q = select(Account).where(Account.organization_id == org_id)
        if type_filter:
            q = q.where(Account.type == type_filter)
        r = await self._session.execute(q.order_by(Account.code))
        return list(r.unique().scalars().all())

    async def list_by_type(self, org_id: UUID, type_: str) -> List[Account]:
        r = await self._session.execute(
            select(Account)
            .where(Account.organization_id == org_id, Account.type == type_)
            .order_by(Account.code)
        )
        return list(r.unique().scalars().all())


class SqlAlchemyJournalEntryRepository(JournalEntryRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, entry: JournalEntry) -> JournalEntry:
        self._session.add(entry)
        await self._session.flush()
        return entry

    async def get_by_id(self, entry_id: UUID, org_id: UUID) -> Optional[JournalEntry]:
        r = await self._session.execute(
            select(JournalEntry).where(
                JournalEntry.id == entry_id, JournalEntry.organization_id == org_id
            )
        )
        return r.unique().scalar_one_or_none()

    async def update(self, entry: JournalEntry) -> JournalEntry:
        self._session.add(entry)
        await self._session.flush()
        return entry

    async def list(
        self, org_id: UUID, page: int = 1, per_page: int = 20,
        branch_id: Optional[UUID] = None,
        branch_ids: Optional[list] = None,
    ) -> Tuple[List[JournalEntry], int]:
        conds = [JournalEntry.organization_id == org_id]
        if branch_ids is not None:
            conds.append(JournalEntry.branch_id.in_(branch_ids))
        elif branch_id is not None:
            conds.append(JournalEntry.branch_id == branch_id)
        total = (
            await self._session.execute(
                select(func.count(JournalEntry.id)).where(*conds)
            )
        ).scalar() or 0
        r = await self._session.execute(
            select(JournalEntry)
            .where(*conds)
            .order_by(JournalEntry.entry_date.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        return list(r.unique().scalars().all()), total

    async def get_next_sequence(self, org_id: UUID, prefix: str, date_val: date) -> int:
        return await SqlAlchemySalesOrderRepository(self._session).get_next_sequence(
            org_id, prefix, date_val
        )

    async def get_entries_in_range(
        self, org_id: UUID, from_date: date, to_date: date
    ) -> List[JournalEntry]:
        r = await self._session.execute(
            select(JournalEntry)
            .where(
                JournalEntry.organization_id == org_id,
                JournalEntry.status == "posted",
                JournalEntry.entry_date >= from_date,
                JournalEntry.entry_date <= to_date,
            )
            .order_by(JournalEntry.entry_date)
        )
        return list(r.unique().scalars().all())


class SqlAlchemyJournalEntryLineRepository(JournalEntryLineRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def bulk_create(self, entry_id: UUID, lines: list) -> list:
        for l in lines:
            l.journal_entry_id = entry_id
            self._session.add(l)
        await self._session.flush()
        return lines
