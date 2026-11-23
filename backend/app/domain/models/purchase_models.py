from pydantic import BaseModel, ConfigDict, field_validator
from typing import Optional, List
from datetime import datetime, date
from uuid import UUID
from decimal import Decimal

ZERO = Decimal("0")


class PurchaseOrderItemCreate(BaseModel):
    product_id: Optional[UUID] = None
    description: str
    quantity: float = 1
    unit_price: Decimal = ZERO
    discount: Decimal = ZERO

    @field_validator("quantity")
    @classmethod
    def validate_qty(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("الكمية يجب أن تكون أكبر من صفر")
        return v


class PurchaseOrderCreate(BaseModel):
    supplier_id: Optional[UUID] = None
    order_date: Optional[date] = None
    discount_type: Optional[str] = None
    discount_value: Decimal = ZERO
    tax_type: Optional[str] = None
    tax_rate: Decimal = ZERO
    notes: Optional[str] = None
    terms: Optional[str] = None
    items: List[PurchaseOrderItemCreate]


class PurchaseOrderUpdate(BaseModel):
    supplier_id: Optional[UUID] = None
    order_date: Optional[date] = None
    discount_type: Optional[str] = None
    discount_value: Optional[Decimal] = None
    tax_type: Optional[str] = None
    tax_rate: Optional[Decimal] = None
    notes: Optional[str] = None
    terms: Optional[str] = None
    items: Optional[List[PurchaseOrderItemCreate]] = None


class PurchaseOrderItemResponse(BaseModel):
    id: UUID
    purchase_order_id: UUID
    product_id: Optional[UUID]
    product_name: Optional[str] = None
    description: str
    quantity: float
    unit_price: Decimal
    discount: Decimal
    total: Decimal
    model_config = ConfigDict(from_attributes=True)


class PurchaseOrderResponse(BaseModel):
    id: UUID
    organization_id: UUID
    supplier_id: Optional[UUID]
    supplier_name: Optional[str] = None
    order_number: str
    order_date: date
    status: str
    subtotal: Decimal
    discount_type: Optional[str]
    discount_value: Decimal
    discount_amount: Decimal
    tax_type: Optional[str]
    tax_rate: Decimal
    tax_amount: Decimal
    total: Decimal
    paid_amount: Decimal
    balance: Decimal
    notes: Optional[str]
    terms: Optional[str]
    created_at: datetime
    confirmed_at: Optional[datetime]
    received_at: Optional[datetime]
    cancelled_at: Optional[datetime]
    items: List[PurchaseOrderItemResponse]
    model_config = ConfigDict(from_attributes=True)


class PurchaseReceiptItemCreate(BaseModel):
    product_id: Optional[UUID] = None
    description: str
    quantity: float = 1
    unit_price: Decimal = ZERO

    @field_validator("quantity")
    @classmethod
    def validate_qty(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("الكمية يجب أن تكون أكبر من صفر")
        return v


class PurchaseReceiptCreate(BaseModel):
    supplier_id: Optional[UUID] = None
    purchase_order_id: Optional[UUID] = None
    receipt_date: Optional[date] = None
    notes: Optional[str] = None
    items: List[PurchaseReceiptItemCreate]


class PurchaseReceiptResponse(BaseModel):
    id: UUID
    organization_id: UUID
    supplier_id: Optional[UUID]
    supplier_name: Optional[str] = None
    purchase_order_id: Optional[UUID]
    receipt_number: str
    receipt_date: date
    status: str
    notes: Optional[str]
    created_at: datetime
    items: list
    model_config = ConfigDict(from_attributes=True)


class PurchaseReturnItemCreate(BaseModel):
    product_id: Optional[UUID] = None
    description: str
    quantity: float = 1
    unit_price: Decimal = ZERO

    @field_validator("quantity")
    @classmethod
    def validate_qty(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("الكمية يجب أن تكون أكبر من صفر")
        return v


class PurchaseReturnCreate(BaseModel):
    supplier_id: Optional[UUID] = None
    purchase_order_id: Optional[UUID] = None
    return_date: Optional[date] = None
    reason: Optional[str] = None
    notes: Optional[str] = None
    items: List[PurchaseReturnItemCreate]


class PurchaseReturnResponse(BaseModel):
    id: UUID
    organization_id: UUID
    supplier_id: Optional[UUID]
    supplier_name: Optional[str] = None
    purchase_order_id: Optional[UUID]
    return_number: str
    return_date: date
    status: str
    reason: Optional[str]
    total: Decimal
    notes: Optional[str]
    created_at: datetime
    items: list
    model_config = ConfigDict(from_attributes=True)


class SupplierBillCreate(BaseModel):
    supplier_id: Optional[UUID] = None
    purchase_order_id: Optional[UUID] = None
    bill_date: Optional[date] = None
    due_date: Optional[date] = None
    discount_type: Optional[str] = None
    discount_value: Decimal = ZERO
    tax_type: Optional[str] = None
    tax_rate: Decimal = ZERO
    notes: Optional[str] = None


class SupplierBillResponse(BaseModel):
    id: UUID
    organization_id: UUID
    supplier_id: Optional[UUID]
    supplier_name: Optional[str] = None
    purchase_order_id: Optional[UUID]
    bill_number: str
    bill_date: date
    due_date: Optional[date]
    status: str
    subtotal: Decimal
    discount_type: Optional[str]
    discount_value: Decimal
    discount_amount: Decimal
    tax_type: Optional[str]
    tax_rate: Decimal
    tax_amount: Decimal
    total: Decimal
    paid_amount: Decimal
    balance: Decimal
    notes: Optional[str]
    created_at: datetime
    model_config = ConfigDict(from_attributes=True)


class StatusAction(BaseModel):
    action: str

    @field_validator("action")
    @classmethod
    def validate(cls, v: str) -> str:
        if v not in {"confirm", "cancel"}:
            raise ValueError("الإجراء يجب أن يكون confirm أو cancel")
        return v
