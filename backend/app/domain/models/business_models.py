from pydantic import BaseModel, ConfigDict, field_validator
from typing import Optional
from datetime import datetime, date
from uuid import UUID
from decimal import Decimal

# ═══════════════════════════════════════════
# Customers
# ═══════════════════════════════════════════


class CustomerCreate(BaseModel):
    name: str
    phone: Optional[str] = None
    email: Optional[str] = None
    tax_number: Optional[str] = None
    cr_number: Optional[str] = None
    address: Optional[str] = None
    contact_person: Optional[str] = None
    notes: Optional[str] = None
    credit_limit: Decimal = Decimal("0")

    @field_validator("name")
    @classmethod
    def validate_name(cls, v: str) -> str:
        if len(v.strip()) < 2:
            raise ValueError("الاسم يجب أن يكون حرفين على الأقل")
        return v.strip()


class CustomerUpdate(BaseModel):
    name: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    tax_number: Optional[str] = None
    cr_number: Optional[str] = None
    address: Optional[str] = None
    contact_person: Optional[str] = None
    notes: Optional[str] = None
    credit_limit: Optional[Decimal] = None
    is_active: Optional[bool] = None


class CustomerResponse(BaseModel):
    id: UUID
    organization_id: UUID
    branch_id: Optional[UUID] = None
    name: str
    phone: Optional[str]
    email: Optional[str]
    tax_number: Optional[str]
    cr_number: Optional[str]
    address: Optional[str]
    contact_person: Optional[str]
    notes: Optional[str]
    credit_limit: Decimal
    is_active: bool
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ═══════════════════════════════════════════
# Suppliers
# ═══════════════════════════════════════════


class SupplierCreate(BaseModel):
    name: str
    phone: Optional[str] = None
    email: Optional[str] = None
    tax_number: Optional[str] = None
    cr_number: Optional[str] = None
    address: Optional[str] = None
    contact_person: Optional[str] = None
    notes: Optional[str] = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, v: str) -> str:
        if len(v.strip()) < 2:
            raise ValueError("الاسم يجب أن يكون حرفين على الأقل")
        return v.strip()


class SupplierUpdate(BaseModel):
    name: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    tax_number: Optional[str] = None
    cr_number: Optional[str] = None
    address: Optional[str] = None
    contact_person: Optional[str] = None
    notes: Optional[str] = None
    is_active: Optional[bool] = None


class SupplierResponse(BaseModel):
    id: UUID
    organization_id: UUID
    branch_id: Optional[UUID] = None
    name: str
    phone: Optional[str]
    email: Optional[str]
    tax_number: Optional[str]
    cr_number: Optional[str]
    address: Optional[str]
    contact_person: Optional[str]
    notes: Optional[str]
    is_active: bool
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ═══════════════════════════════════════════
# Product Categories
# ═══════════════════════════════════════════


class CategoryCreate(BaseModel):
    name: str
    name_ar: Optional[str] = None
    description: Optional[str] = None


class CategoryUpdate(BaseModel):
    name: Optional[str] = None
    name_ar: Optional[str] = None
    description: Optional[str] = None
    is_active: Optional[bool] = None


class CategoryResponse(BaseModel):
    id: UUID
    organization_id: UUID
    name: str
    name_ar: Optional[str]
    description: Optional[str]
    image: Optional[str] = None
    is_active: bool
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ═══════════════════════════════════════════
# Products
# ═══════════════════════════════════════════


class ProductCreate(BaseModel):
    name: str
    name_ar: Optional[str] = None
    category_id: Optional[UUID] = None
    sku: Optional[str] = None
    barcode: Optional[str] = None
    description: Optional[str] = None
    unit: str = "قطعة"
    price: Decimal = Decimal("0")
    cost_price: Decimal = Decimal("0")
    stock: float = 0
    min_stock: float = 0
    is_service: bool = False
    image: Optional[str] = None
    notes: Optional[str] = None
    expiry_date: Optional[date] = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, v: str) -> str:
        if len(v.strip()) < 2:
            raise ValueError("الاسم يجب أن يكون حرفين على الأقل")
        return v.strip()

    @field_validator("price")
    @classmethod
    def validate_price(cls, v: Decimal) -> Decimal:
        if v < Decimal("0"):
            raise ValueError("السعر لا يمكن أن يكون سالباً")
        return v


class ProductUpdate(BaseModel):
    name: Optional[str] = None
    name_ar: Optional[str] = None
    category_id: Optional[UUID] = None
    sku: Optional[str] = None
    barcode: Optional[str] = None
    description: Optional[str] = None
    unit: Optional[str] = None
    price: Optional[Decimal] = None
    cost_price: Optional[Decimal] = None
    stock: Optional[float] = None
    min_stock: Optional[float] = None
    is_service: Optional[bool] = None
    image: Optional[str] = None
    notes: Optional[str] = None
    is_active: Optional[bool] = None
    expiry_date: Optional[date] = None


class ProductResponse(BaseModel):
    id: UUID
    organization_id: UUID
    branch_id: Optional[UUID] = None
    category_id: Optional[UUID]
    category_name: Optional[str] = None
    name: str
    name_ar: Optional[str]
    sku: Optional[str]
    barcode: Optional[str]
    description: Optional[str]
    unit: str
    price: Decimal
    cost_price: Decimal
    cost_currency: Optional[str] = None
    stock: float
    min_stock: float
    is_service: bool
    is_active: bool
    image: Optional[str]
    notes: Optional[str]
    expiry_date: Optional[date] = None
    # Independent per-currency SELL prices (never auto-converted).
    prices: list = []
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ═══════════════════════════════════════════
# Inventory
# ═══════════════════════════════════════════


class InventoryMovementCreate(BaseModel):
    product_id: UUID
    movement_type: str
    quantity: float
    unit_price: Decimal = Decimal("0")
    notes: Optional[str] = None
    reference_type: Optional[str] = None
    reference_id: Optional[UUID] = None

    @field_validator("quantity")
    @classmethod
    def validate_quantity(cls, v: float) -> float:
        if v == 0:
            raise ValueError("الكمية لا يمكن أن تكون صفراً")
        return v


class InventoryMovementResponse(BaseModel):
    id: UUID
    product_id: UUID
    movement_type: str
    quantity: float
    unit_price: Decimal
    total: Decimal
    reference_type: Optional[str]
    reference_id: Optional[UUID]
    notes: Optional[str]
    reason: Optional[str] = None
    old_quantity: Optional[float] = None
    new_quantity: Optional[float] = None
    difference: Optional[float] = None
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class WarehouseSettingsUpdate(BaseModel):
    expiry_enabled: bool = False
    expiry_warn_days: int = 60


class FalconAnalyzeRequest(BaseModel):
    scope: str = "inventory"  # product | category | inventory
    ref_id: Optional[UUID] = None
    lang: str = "ar"
    report_currency: Optional[str] = None
    # Device-ledger branch: the phone's own per-product figures (already in
    # report_currency). The server analyses them; it holds no stock data.
    device_items: Optional[list] = None
    device_category: Optional[str] = None
    # Or the phone's own deterministic summary of those rows (compact; the
    # same rules as the server's device dataset).
    device_summary: Optional[dict] = None


class FalconChatRequest(BaseModel):
    scope: str = "inventory"
    ref_id: Optional[UUID] = None
    question: str
    history: list = []
    lang: str = "ar"
    report_currency: Optional[str] = None
    # Device-ledger branch: the phone's own per-product figures (already in
    # report_currency). The server analyses them; it holds no stock data.
    device_items: Optional[list] = None
    device_category: Optional[str] = None


class InventoryTransferRequest(BaseModel):
    product_id: UUID
    from_branch_id: Optional[UUID] = None
    to_branch_id: Optional[UUID] = None
    quantity: float

    @field_validator("quantity")
    @classmethod
    def _qty(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("الكمية يجب أن تكون أكبر من صفر")
        return v


class ProductPriceItem(BaseModel):
    currency: str
    price: Decimal = Decimal("0")
    buy_price: Optional[Decimal] = None

    @field_validator("currency")
    @classmethod
    def _cur(cls, v: str) -> str:
        v = (v or "").strip().upper()
        if not v or len(v) > 10:
            raise ValueError("العملة غير صالحة")
        return v

    @field_validator("price")
    @classmethod
    def _price(cls, v: Decimal) -> Decimal:
        if v < Decimal("0"):
            raise ValueError("السعر لا يمكن أن يكون سالباً")
        return v


class ProductPricesUpdate(BaseModel):
    prices: list[ProductPriceItem] = []


class InventoryAdjustRequest(BaseModel):
    """Plain-language stock adjustment: «زود / نقص / عدّل الكمية».

    `mode` is add | remove | set. The backend computes old/new/difference and
    records an auditable movement; nothing technical is shown to the merchant.
    """

    product_id: UUID
    mode: str = "add"
    amount: float
    reason: Optional[str] = None
    notes: Optional[str] = None
    branch_id: Optional[UUID] = None

    @field_validator("mode")
    @classmethod
    def _mode(cls, v: str) -> str:
        v = (v or "").strip().lower()
        if v not in {"add", "remove", "set"}:
            raise ValueError("نوع التعديل غير صالح")
        return v

    @field_validator("amount")
    @classmethod
    def _amount(cls, v: float) -> float:
        if v < 0:
            raise ValueError("الكمية لا يمكن أن تكون سالبة")
        return v


# ═══════════════════════════════════════════
# Pagination
# ═══════════════════════════════════════════


class PaginatedResponse(BaseModel):
    items: list
    total: int
    page: int
    per_page: int
    total_pages: int
