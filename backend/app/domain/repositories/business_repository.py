from abc import ABC, abstractmethod
from typing import Optional, List, Tuple
from uuid import UUID
from app.domain.entities.business_entities import (
    Customer,
    Supplier,
    ProductCategory,
    Product,
    InventoryMovement,
)


class CustomerRepository(ABC):
    @abstractmethod
    async def create(self, customer: Customer) -> Customer: ...

    @abstractmethod
    async def get_by_id(
        self, customer_id: UUID, org_id: UUID
    ) -> Optional[Customer]: ...

    @abstractmethod
    async def update(self, customer: Customer) -> Customer: ...

    @abstractmethod
    async def soft_delete(self, customer_id: UUID, org_id: UUID) -> None: ...

    @abstractmethod
    async def list(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
    ) -> Tuple[List[Customer], int]: ...


class SupplierRepository(ABC):
    @abstractmethod
    async def create(self, supplier: Supplier) -> Supplier: ...

    @abstractmethod
    async def get_by_id(
        self, supplier_id: UUID, org_id: UUID
    ) -> Optional[Supplier]: ...

    @abstractmethod
    async def update(self, supplier: Supplier) -> Supplier: ...

    @abstractmethod
    async def soft_delete(self, supplier_id: UUID, org_id: UUID) -> None: ...

    @abstractmethod
    async def list(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
    ) -> Tuple[List[Supplier], int]: ...


class ProductCategoryRepository(ABC):
    @abstractmethod
    async def create(self, category: ProductCategory) -> ProductCategory: ...

    @abstractmethod
    async def get_by_id(
        self, category_id: UUID, org_id: UUID
    ) -> Optional[ProductCategory]: ...

    @abstractmethod
    async def update(self, category: ProductCategory) -> ProductCategory: ...

    @abstractmethod
    async def soft_delete(self, category_id: UUID, org_id: UUID) -> bool: ...

    @abstractmethod
    async def list(
        self, org_id: UUID, only_active: bool = False
    ) -> List[ProductCategory]: ...


class ProductRepository(ABC):
    @abstractmethod
    async def create(self, product: Product) -> Product: ...

    @abstractmethod
    async def get_by_id(
        self, product_id: UUID, org_id: UUID, lock: bool = False
    ) -> Optional[Product]: ...

    @abstractmethod
    async def get_by_sku(self, sku: str, org_id: UUID) -> Optional[Product]: ...

    @abstractmethod
    async def get_by_barcode(self, barcode: str, org_id: UUID) -> Optional[Product]: ...

    @abstractmethod
    async def update(self, product: Product) -> Product: ...

    @abstractmethod
    async def soft_delete(self, product_id: UUID, org_id: UUID) -> None: ...

    @abstractmethod
    async def list(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        category_id: Optional[UUID] = None,
        page: int = 1,
        per_page: int = 20,
        stock_status: Optional[str] = None,
        expiry: Optional[str] = None,
        expiry_days: int = 30,
        uncategorized: bool = False,
    ) -> Tuple[List[Product], int]: ...


class InventoryMovementRepository(ABC):
    @abstractmethod
    async def create(self, movement: InventoryMovement) -> InventoryMovement: ...

    @abstractmethod
    async def get_by_id(
        self, movement_id: UUID, org_id: UUID
    ) -> Optional[InventoryMovement]: ...

    @abstractmethod
    async def list_by_product(
        self, product_id: UUID, org_id: UUID, limit: int = 50
    ) -> List[InventoryMovement]: ...

    @abstractmethod
    async def list(
        self,
        org_id: UUID,
        product_id: Optional[UUID] = None,
        movement_type: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
    ) -> Tuple[List[InventoryMovement], int]: ...
