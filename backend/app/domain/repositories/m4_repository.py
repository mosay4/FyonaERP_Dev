from abc import ABC, abstractmethod
from typing import Optional, List, Tuple
from uuid import UUID
from datetime import date
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


class SalesOrderRepository(ABC):
    @abstractmethod
    async def create(self, order: SalesOrder) -> SalesOrder: ...
    @abstractmethod
    async def get_by_id(
        self, order_id: UUID, org_id: UUID, lock: bool = False
    ) -> Optional[SalesOrder]: ...
    @abstractmethod
    async def update(self, order: SalesOrder) -> SalesOrder: ...
    @abstractmethod
    async def soft_delete(self, order_id: UUID, org_id: UUID) -> None: ...
    @abstractmethod
    async def list(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        status: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
    ) -> Tuple[List[SalesOrder], int]: ...
    @abstractmethod
    async def get_next_sequence(
        self, org_id: UUID, prefix: str, date_val: date
    ) -> int: ...


class SalesOrderItemRepository(ABC):
    @abstractmethod
    async def bulk_create(
        self, order_id: UUID, items: List[SalesOrderItem]
    ) -> List[SalesOrderItem]: ...
    @abstractmethod
    async def delete_by_order(self, order_id: UUID) -> None: ...
    @abstractmethod
    async def list_by_order(self, order_id: UUID) -> List[SalesOrderItem]: ...


class SalesReturnRepository(ABC):
    @abstractmethod
    async def create(self, return_: SalesReturn) -> SalesReturn: ...
    @abstractmethod
    async def get_by_id(
        self, return_id: UUID, org_id: UUID
    ) -> Optional[SalesReturn]: ...
    @abstractmethod
    async def update(self, return_: SalesReturn) -> SalesReturn: ...
    @abstractmethod
    async def list(
        self, org_id: UUID, page: int = 1, per_page: int = 20
    ) -> Tuple[List[SalesReturn], int]: ...
    @abstractmethod
    async def get_next_sequence(
        self, org_id: UUID, prefix: str, date_val: date
    ) -> int: ...


class SalesReturnItemRepository(ABC):
    @abstractmethod
    async def bulk_create(
        self, return_id: UUID, items: List[SalesReturnItem]
    ) -> List[SalesReturnItem]: ...


class SalesQuoteRepository(ABC):
    @abstractmethod
    async def create(self, quote: SalesQuote) -> SalesQuote: ...
    @abstractmethod
    async def get_by_id(self, quote_id: UUID, org_id: UUID) -> Optional[SalesQuote]: ...
    @abstractmethod
    async def update(self, quote: SalesQuote) -> SalesQuote: ...
    @abstractmethod
    async def list(
        self, org_id: UUID, page: int = 1, per_page: int = 20
    ) -> Tuple[List[SalesQuote], int]: ...
    @abstractmethod
    async def get_next_sequence(
        self, org_id: UUID, prefix: str, date_val: date
    ) -> int: ...


class QuoteItemRepository(ABC):
    @abstractmethod
    async def bulk_create(
        self, quote_id: UUID, items: List[QuoteItem]
    ) -> List[QuoteItem]: ...
    @abstractmethod
    async def delete_by_quote(self, quote_id: UUID) -> None: ...


class DeliveryNoteRepository(ABC):
    @abstractmethod
    async def create(self, note: DeliveryNote) -> DeliveryNote: ...
    @abstractmethod
    async def get_by_id(
        self, note_id: UUID, org_id: UUID
    ) -> Optional[DeliveryNote]: ...
    @abstractmethod
    async def update(self, note: DeliveryNote) -> DeliveryNote: ...
    @abstractmethod
    async def list(
        self, org_id: UUID, page: int = 1, per_page: int = 20
    ) -> Tuple[List[DeliveryNote], int]: ...
    @abstractmethod
    async def get_next_sequence(
        self, org_id: UUID, prefix: str, date_val: date
    ) -> int: ...


class DeliveryNoteItemRepository(ABC):
    @abstractmethod
    async def bulk_create(
        self, note_id: UUID, items: List[DeliveryNoteItem]
    ) -> List[DeliveryNoteItem]: ...


class PurchaseOrderRepository(ABC):
    @abstractmethod
    async def create(self, order: PurchaseOrder) -> PurchaseOrder: ...
    @abstractmethod
    async def get_by_id(
        self, order_id: UUID, org_id: UUID, lock: bool = False
    ) -> Optional[PurchaseOrder]: ...
    @abstractmethod
    async def update(self, order: PurchaseOrder) -> PurchaseOrder: ...
    @abstractmethod
    async def soft_delete(self, order_id: UUID, org_id: UUID) -> None: ...
    @abstractmethod
    async def list(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        status: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
    ) -> Tuple[List[PurchaseOrder], int]: ...
    @abstractmethod
    async def get_next_sequence(
        self, org_id: UUID, prefix: str, date_val: date
    ) -> int: ...


class PurchaseOrderItemRepository(ABC):
    @abstractmethod
    async def bulk_create(
        self, order_id: UUID, items: List[PurchaseOrderItem]
    ) -> List[PurchaseOrderItem]: ...
    @abstractmethod
    async def delete_by_order(self, order_id: UUID) -> None: ...
    @abstractmethod
    async def list_by_order(self, order_id: UUID) -> List[PurchaseOrderItem]: ...


class PurchaseReceiptRepository(ABC):
    @abstractmethod
    async def create(self, receipt: PurchaseReceipt) -> PurchaseReceipt: ...
    @abstractmethod
    async def get_by_id(
        self, receipt_id: UUID, org_id: UUID
    ) -> Optional[PurchaseReceipt]: ...
    @abstractmethod
    async def update(self, receipt: PurchaseReceipt) -> PurchaseReceipt: ...
    @abstractmethod
    async def list(
        self, org_id: UUID, page: int = 1, per_page: int = 20
    ) -> Tuple[List[PurchaseReceipt], int]: ...
    @abstractmethod
    async def get_next_sequence(
        self, org_id: UUID, prefix: str, date_val: date
    ) -> int: ...


class PurchaseReceiptItemRepository(ABC):
    @abstractmethod
    async def bulk_create(
        self, receipt_id: UUID, items: List[PurchaseReceiptItem]
    ) -> List[PurchaseReceiptItem]: ...


class PurchaseReturnRepository(ABC):
    @abstractmethod
    async def create(self, return_: PurchaseReturn) -> PurchaseReturn: ...
    @abstractmethod
    async def get_by_id(
        self, return_id: UUID, org_id: UUID
    ) -> Optional[PurchaseReturn]: ...
    @abstractmethod
    async def update(self, return_: PurchaseReturn) -> PurchaseReturn: ...
    @abstractmethod
    async def get_next_sequence(
        self, org_id: UUID, prefix: str, date_val: date
    ) -> int: ...


class PurchaseReturnItemRepository(ABC):
    @abstractmethod
    async def bulk_create(
        self, return_id: UUID, items: List[PurchaseReturnItem]
    ) -> List[PurchaseReturnItem]: ...


class SupplierBillRepository(ABC):
    @abstractmethod
    async def create(self, bill: SupplierBill) -> SupplierBill: ...
    @abstractmethod
    async def get_by_id(
        self, bill_id: UUID, org_id: UUID, lock: bool = False
    ) -> Optional[SupplierBill]: ...
    @abstractmethod
    async def update(self, bill: SupplierBill) -> SupplierBill: ...
    @abstractmethod
    async def list(
        self, org_id: UUID, page: int = 1, per_page: int = 20
    ) -> Tuple[List[SupplierBill], int]: ...
    @abstractmethod
    async def get_next_sequence(
        self, org_id: UUID, prefix: str, date_val: date
    ) -> int: ...


class AccountRepository(ABC):
    @abstractmethod
    async def create(self, account: Account) -> Account: ...
    @abstractmethod
    async def get_by_id(self, account_id: UUID, org_id: UUID) -> Optional[Account]: ...
    @abstractmethod
    async def update(self, account: Account) -> Account: ...
    @abstractmethod
    async def get_by_code(self, code: str, org_id: UUID) -> Optional[Account]: ...
    @abstractmethod
    async def list(
        self, org_id: UUID, type_filter: Optional[str] = None
    ) -> List[Account]: ...
    @abstractmethod
    async def list_by_type(self, org_id: UUID, type_: str) -> List[Account]: ...


class JournalEntryRepository(ABC):
    @abstractmethod
    async def create(self, entry: JournalEntry) -> JournalEntry: ...
    @abstractmethod
    async def get_by_id(
        self, entry_id: UUID, org_id: UUID
    ) -> Optional[JournalEntry]: ...
    @abstractmethod
    async def update(self, entry: JournalEntry) -> JournalEntry: ...
    @abstractmethod
    async def list(
        self, org_id: UUID, page: int = 1, per_page: int = 20
    ) -> Tuple[List[JournalEntry], int]: ...
    @abstractmethod
    async def get_next_sequence(
        self, org_id: UUID, prefix: str, date_val: date
    ) -> int: ...
    @abstractmethod
    async def get_entries_in_range(
        self, org_id: UUID, from_date: date, to_date: date
    ) -> List[JournalEntry]: ...


class JournalEntryLineRepository(ABC):
    @abstractmethod
    async def bulk_create(self, entry_id: UUID, lines: list) -> list: ...
