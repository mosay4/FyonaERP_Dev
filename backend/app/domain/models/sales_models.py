from pydantic import BaseModel, ConfigDict, field_validator
from typing import Optional, List
from datetime import datetime, date
from uuid import UUID
from decimal import Decimal

ZERO = Decimal("0")


# ═══════════════════════════════════════════
# Sales Orders
# ═══════════════════════════════════════════


class SalesOrderItemCreate(BaseModel):
    product_id: Optional[UUID] = None
    description: str
    quantity: float = 1
    unit_price: Decimal = ZERO
    discount: Decimal = ZERO
    tax_rate: Decimal = ZERO

    @field_validator("quantity")
    @classmethod
    def validate_qty(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("الكمية يجب أن تكون أكبر من صفر")
        return v


class SalesOrderItemResponse(BaseModel):
    id: UUID
    sales_order_id: UUID
    product_id: Optional[UUID]
    product_name: Optional[str] = None
    description: str
    quantity: float
    unit_price: Decimal
    discount: Decimal
    tax_rate: Decimal
    total: Decimal
    model_config = ConfigDict(from_attributes=True)


class SalesOrderCreate(BaseModel):
    customer_id: Optional[UUID] = None
    order_date: Optional[date] = None
    discount_type: Optional[str] = None
    discount_value: Decimal = ZERO
    tax_type: Optional[str] = None
    tax_rate: Decimal = ZERO
    notes: Optional[str] = None
    terms: Optional[str] = None
    items: List[SalesOrderItemCreate]


class SalesOrderUpdate(BaseModel):
    customer_id: Optional[UUID] = None
    order_date: Optional[date] = None
    discount_type: Optional[str] = None
    discount_value: Optional[Decimal] = None
    tax_type: Optional[str] = None
    tax_rate: Optional[Decimal] = None
    notes: Optional[str] = None
    terms: Optional[str] = None
    items: Optional[List[SalesOrderItemCreate]] = None


class SalesOrderResponse(BaseModel):
    id: UUID
    organization_id: UUID
    customer_id: Optional[UUID]
    customer_name: Optional[str] = None
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
    updated_at: datetime
    confirmed_at: Optional[datetime]
    delivered_at: Optional[datetime]
    cancelled_at: Optional[datetime]
    items: List[SalesOrderItemResponse]
    model_config = ConfigDict(from_attributes=True)


# ═══════════════════════════════════════════
# Sales Returns
# ═══════════════════════════════════════════


class SalesReturnItemCreate(BaseModel):
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


class SalesReturnCreate(BaseModel):
    customer_id: Optional[UUID] = None
    sales_order_id: Optional[UUID] = None
    return_date: Optional[date] = None
    reason: Optional[str] = None
    notes: Optional[str] = None
    items: List[SalesReturnItemCreate]


class SalesReturnResponse(BaseModel):
    id: UUID
    organization_id: UUID
    customer_id: Optional[UUID]
    customer_name: Optional[str] = None
    sales_order_id: Optional[UUID]
    return_number: str
    return_date: date
    status: str
    reason: Optional[str]
    total: Decimal
    notes: Optional[str]
    created_at: datetime
    items: list
    model_config = ConfigDict(from_attributes=True)


# ═══════════════════════════════════════════
# Sales Quotes
# ═══════════════════════════════════════════


class QuoteItemCreate(BaseModel):
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


class SalesQuoteCreate(BaseModel):
    customer_id: Optional[UUID] = None
    quote_date: Optional[date] = None
    expiry_date: Optional[date] = None
    discount_type: Optional[str] = None
    discount_value: Decimal = ZERO
    tax_type: Optional[str] = None
    tax_rate: Decimal = ZERO
    notes: Optional[str] = None
    terms: Optional[str] = None
    items: List[QuoteItemCreate]


class SalesQuoteResponse(BaseModel):
    id: UUID
    organization_id: UUID
    customer_id: Optional[UUID]
    customer_name: Optional[str] = None
    quote_number: str
    quote_date: date
    expiry_date: Optional[date]
    status: str
    subtotal: Decimal
    discount_type: Optional[str]
    discount_value: Decimal
    discount_amount: Decimal
    tax_type: Optional[str]
    tax_rate: Decimal
    tax_amount: Decimal
    total: Decimal
    notes: Optional[str]
    terms: Optional[str]
    created_at: datetime
    items: list
    model_config = ConfigDict(from_attributes=True)


# ═══════════════════════════════════════════
# Delivery Notes
# ═══════════════════════════════════════════


class DeliveryNoteItemCreate(BaseModel):
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


class DeliveryNoteCreate(BaseModel):
    customer_id: Optional[UUID] = None
    sales_order_id: Optional[UUID] = None
    delivery_date: Optional[date] = None
    notes: Optional[str] = None
    items: List[DeliveryNoteItemCreate]


class DeliveryNoteResponse(BaseModel):
    id: UUID
    organization_id: UUID
    customer_id: Optional[UUID]
    customer_name: Optional[str] = None
    sales_order_id: Optional[UUID]
    delivery_number: str
    delivery_date: date
    status: str
    notes: Optional[str]
    created_at: datetime
    items: list
    model_config = ConfigDict(from_attributes=True)


# ═══════════════════════════════════════════
# Common
# ═══════════════════════════════════════════


class StatusAction(BaseModel):
    action: str

    @field_validator("action")
    @classmethod
    def validate(cls, v: str) -> str:
        if v not in {"confirm", "cancel"}:
            raise ValueError("الإجراء يجب أن يكون confirm أو cancel")
        return v
