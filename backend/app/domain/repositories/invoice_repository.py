from abc import ABC, abstractmethod
from typing import Optional, List, Tuple
from uuid import UUID
from datetime import date
from app.domain.entities.invoice_entities import Invoice, InvoiceItem, Payment


class InvoiceRepository(ABC):
    @abstractmethod
    async def create(self, invoice: Invoice) -> Invoice: ...

    @abstractmethod
    async def get_by_id(
        self, invoice_id: UUID, org_id: UUID, lock: bool = False
    ) -> Optional[Invoice]: ...

    @abstractmethod
    async def update(self, invoice: Invoice) -> Invoice: ...

    @abstractmethod
    async def cancel(self, invoice: Invoice, actor_id: UUID) -> Invoice:
        """Persist cancellation, its debt mirrors and linked outbox atomically."""
        ...

    @abstractmethod
    async def soft_delete(self, invoice_id: UUID, org_id: UUID) -> None: ...

    @abstractmethod
    async def list(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        status: Optional[str] = None,
        invoice_type: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
    ) -> Tuple[List[Invoice], int]: ...

    @abstractmethod
    async def get_next_sequence(
        self, org_id: UUID, prefix: str, date_val: date
    ) -> int: ...


class InvoiceItemRepository(ABC):
    @abstractmethod
    async def bulk_create(
        self, invoice_id: UUID, items: List[InvoiceItem]
    ) -> List[InvoiceItem]: ...

    @abstractmethod
    async def delete_by_invoice(self, invoice_id: UUID) -> None: ...

    @abstractmethod
    async def list_by_invoice(self, invoice_id: UUID) -> List[InvoiceItem]: ...


class PaymentRepository(ABC):
    @abstractmethod
    async def create(self, payment: Payment) -> Payment: ...

    @abstractmethod
    async def get_by_id(self, payment_id: UUID, org_id: UUID) -> Optional[Payment]: ...

    @abstractmethod
    async def list_by_invoice(
        self, invoice_id: UUID, org_id: UUID
    ) -> List[Payment]: ...

    @abstractmethod
    async def delete(self, payment_id: UUID, org_id: UUID) -> None: ...
