from pydantic import BaseModel, ConfigDict, field_validator
from typing import Optional, List
from datetime import datetime, date
from uuid import UUID
from decimal import Decimal

# ═══════════════════════════════════════════
# Invoice Items
# ═══════════════════════════════════════════


class InvoiceItemCreate(BaseModel):
    product_id: Optional[UUID] = None
    description: str
    quantity: float = 1
    unit_price: Decimal = Decimal("0")
    discount: Decimal = Decimal("0")
    tax_rate: Decimal = Decimal("0")

    @field_validator("quantity")
    @classmethod
    def validate_quantity(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("الكمية يجب أن تكون أكبر من صفر")
        return v

    @field_validator("unit_price")
    @classmethod
    def validate_price(cls, v: Decimal) -> Decimal:
        if v < Decimal("0"):
            raise ValueError("السعر لا يمكن أن يكون سالباً")
        return v


class InvoiceItemUpdate(BaseModel):
    product_id: Optional[UUID] = None
    description: Optional[str] = None
    quantity: Optional[float] = None
    unit_price: Optional[Decimal] = None
    discount: Optional[Decimal] = None
    tax_rate: Optional[Decimal] = None


class InvoiceItemResponse(BaseModel):
    id: UUID
    invoice_id: UUID
    product_id: Optional[UUID]
    product_name: Optional[str] = None
    description: str
    quantity: float
    unit_price: Decimal
    discount: Decimal
    tax_rate: Decimal
    total: Decimal
    unit_id: Optional[UUID] = None
    unit_name: Optional[str] = None
    base_quantity: float = 0
    is_service: bool = False

    model_config = ConfigDict(from_attributes=True)


# ═══════════════════════════════════════════
# Payments
# ═══════════════════════════════════════════


class PaymentCreate(BaseModel):
    amount: Decimal
    payment_date: Optional[date] = None
    payment_method: str = "cash"
    reference: Optional[str] = None
    notes: Optional[str] = None

    @field_validator("amount")
    @classmethod
    def validate_amount(cls, v: Decimal) -> Decimal:
        if v <= Decimal("0"):
            raise ValueError("المبلغ يجب أن يكون أكبر من صفر")
        return v

    @field_validator("payment_method")
    @classmethod
    def validate_method(cls, v: str) -> str:
        allowed = {"cash", "bank", "card", "transfer", "cheque"}
        if v not in allowed:
            raise ValueError(f"طريقة الدفع غير صالحة: {v}")
        return v


class PaymentResponse(BaseModel):
    id: UUID
    invoice_id: UUID
    amount: Decimal
    payment_date: date
    payment_method: str
    reference: Optional[str]
    notes: Optional[str]
    created_at: datetime
    bank_account_id: Optional[UUID] = None
    bank_account_name: Optional[str] = None

    model_config = ConfigDict(from_attributes=True)


# ═══════════════════════════════════════════
# Invoices
# ═══════════════════════════════════════════


class InvoiceCreate(BaseModel):
    invoice_type: str = "sale"
    customer_id: Optional[UUID] = None
    supplier_id: Optional[UUID] = None
    invoice_date: Optional[date] = None
    due_date: Optional[date] = None
    discount_type: Optional[str] = None
    discount_value: Decimal = Decimal("0")
    tax_type: Optional[str] = None
    tax_rate: Decimal = Decimal("0")
    notes: Optional[str] = None
    terms: Optional[str] = None
    items: List[InvoiceItemCreate]

    @field_validator("invoice_type")
    @classmethod
    def validate_type(cls, v: str) -> str:
        if v not in {"sale", "purchase"}:
            raise ValueError("نوع الفاتورة يجب أن يكون sale أو purchase")
        return v

    @field_validator("discount_type")
    @classmethod
    def validate_discount_type(cls, v: Optional[str]) -> Optional[str]:
        if v is not None and v not in {"percentage", "fixed"}:
            raise ValueError("نوع الخصم يجب أن يكون percentage أو fixed")
        return v

    @field_validator("tax_type")
    @classmethod
    def validate_tax_type(cls, v: Optional[str]) -> Optional[str]:
        if v is not None and v not in {"percentage", "fixed"}:
            raise ValueError("نوع الضريبة يجب أن يكون percentage أو fixed")
        return v

    @field_validator("discount_value")
    @classmethod
    def validate_discount(cls, v: Decimal) -> Decimal:
        if v < Decimal("0"):
            raise ValueError("قيمة الخصم لا يمكن أن تكون سالبة")
        return v

    @field_validator("tax_rate")
    @classmethod
    def validate_tax(cls, v: Decimal) -> Decimal:
        if v < Decimal("0"):
            raise ValueError("نسبة الضريبة لا يمكن أن تكون سالبة")
        return v


class InvoiceUpdate(BaseModel):
    invoice_date: Optional[date] = None
    due_date: Optional[date] = None
    discount_type: Optional[str] = None
    discount_value: Optional[Decimal] = None
    tax_type: Optional[str] = None
    tax_rate: Optional[Decimal] = None
    notes: Optional[str] = None
    terms: Optional[str] = None
    items: Optional[List[InvoiceItemCreate]] = None


class InvoiceResponse(BaseModel):
    id: UUID
    organization_id: UUID
    invoice_number: str
    invoice_type: str
    customer_id: Optional[UUID]
    customer_name: Optional[str] = None
    supplier_id: Optional[UUID]
    supplier_name: Optional[str] = None
    invoice_date: date
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
    terms: Optional[str]
    currency: str = "SAR"
    branch_id: Optional[UUID] = None
    branch_name: Optional[str] = None
    created_at: datetime
    updated_at: datetime
    confirmed_at: Optional[datetime]
    cancelled_at: Optional[datetime]
    items: List[InvoiceItemResponse]
    payments: List[PaymentResponse]

    model_config = ConfigDict(from_attributes=True)


class InvoiceStatusTransition(BaseModel):
    action: str

    @field_validator("action")
    @classmethod
    def validate_action(cls, v: str) -> str:
        if v not in {"confirm", "cancel"}:
            raise ValueError("الإجراء يجب أن يكون confirm أو cancel")
        return v


# ═══════════════════════════════════════════
# Atomic sale issue (no drafts: issued or nothing)
# ═══════════════════════════════════════════


class SaleIssueLine(BaseModel):
    product_id: Optional[UUID] = None
    unit_id: Optional[UUID] = None
    description: str = ""
    quantity: float = 1
    unit_price: Decimal = Decimal("0")
    discount: Decimal = Decimal("0")
    # Sell-price snapshot (original price + its currency + FX used to reach the
    # invoice currency). Optional; stored verbatim on the invoice line.
    original_price: Optional[Decimal] = None
    price_currency: Optional[str] = None
    exchange_rate: Optional[Decimal] = None
    # Optional inline quick-add (sale side): creates a real product exactly
    # like the purchase quick-add so it persists in inventory.
    new_product: Optional[dict] = None

    @field_validator("quantity")
    @classmethod
    def validate_quantity(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("الكمية يجب أن تكون أكبر من صفر")
        return v

    @field_validator("unit_price", "discount")
    @classmethod
    def validate_non_negative(cls, v: Decimal) -> Decimal:
        if v < Decimal("0"):
            raise ValueError("القيمة لا يمكن أن تكون سالبة")
        return v


class SaleIssuePayment(BaseModel):
    bank_account_id: UUID
    amount: Decimal
    payment_method: str = "cash"
    reference: Optional[str] = None
    # Multi-currency split payments. `currency` is the account's own currency
    # (the money actually received); when it differs from the invoice currency
    # `exchange_rate` is the frozen snapshot (1 currency = rate invoice
    # currency) and `equivalent_amount` is the converted value counted toward
    # the invoice. The client may omit them for same-currency payments.
    currency: Optional[str] = None
    exchange_rate: Optional[Decimal] = None
    equivalent_amount: Optional[Decimal] = None
    exchange_rate_source: Optional[str] = None
    exchange_rate_timestamp: Optional[datetime] = None

    @field_validator("amount")
    @classmethod
    def validate_amount(cls, v: Decimal) -> Decimal:
        if v <= Decimal("0"):
            raise ValueError("المبلغ يجب أن يكون أكبر من صفر")
        return v

    @field_validator("exchange_rate")
    @classmethod
    def validate_rate(cls, v: Optional[Decimal]) -> Optional[Decimal]:
        if v is not None and v <= Decimal("0"):
            raise ValueError("سعر الصرف يجب أن يكون أكبر من صفر")
        return v

    @field_validator("payment_method")
    @classmethod
    def validate_method(cls, v: str) -> str:
        allowed = {"cash", "bank", "card", "transfer", "cheque"}
        if v not in allowed:
            raise ValueError(f"طريقة الدفع غير صالحة: {v}")
        return v


class SaleIssueRequest(BaseModel):
    customer_id: Optional[UUID] = None
    debt_group_id: Optional[UUID] = None
    currency: str = "SAR"
    branch_id: Optional[UUID] = None
    discount_type: Optional[str] = None
    discount_value: Decimal = Decimal("0")
    tax_type: Optional[str] = None
    tax_rate: Decimal = Decimal("0")
    notes: Optional[str] = None
    due_date: Optional[date] = None
    idempotency_key: Optional[str] = None
    items: List[SaleIssueLine]
    payments: List[SaleIssuePayment] = []

    @field_validator("currency")
    @classmethod
    def validate_currency(cls, v: str) -> str:
        v = (v or "").strip().upper()
        if not v or len(v) > 10:
            raise ValueError("العملة غير صالحة")
        return v

    @field_validator("discount_type", "tax_type")
    @classmethod
    def validate_pct_or_fixed(cls, v: Optional[str]) -> Optional[str]:
        if v is not None and v not in {"percentage", "fixed"}:
            raise ValueError("النوع يجب أن يكون percentage أو fixed")
        return v


# ═══════════════════════════════════════════
# Purchase invoices (mirror of sale issue, reversed direction)
# ═══════════════════════════════════════════


class PurchaseIssuePayment(SaleIssuePayment):
    """Same multi-currency split payment shape as a sale, but the money leaves
    the chosen account and settles a supplier payable instead of a receivable."""


class PurchaseIssueLine(BaseModel):
    product_id: Optional[UUID] = None
    unit_id: Optional[UUID] = None
    description: str = ""
    quantity: float = 1
    unit_price: Decimal = Decimal("0")
    discount: Decimal = Decimal("0")
    # Buy-price snapshot (original price + its currency + FX used to reach the
    # invoice currency), mirroring SaleIssueLine. Optional; stored verbatim.
    original_price: Optional[Decimal] = None
    price_currency: Optional[str] = None
    exchange_rate: Optional[Decimal] = None
    # Optional batch/expiry for lot tracking (FEFO).
    expiry_date: Optional[date] = None
    lot_number: Optional[str] = None
    # Optional inline quick-add: when present and `save_to_inventory` is true a
    # real Business product is created atomically with the purchase.
    new_product: Optional[dict] = None

    @field_validator("quantity")
    @classmethod
    def validate_quantity(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("الكمية يجب أن تكون أكبر من صفر")
        return v

    @field_validator("unit_price", "discount")
    @classmethod
    def validate_non_negative(cls, v: Decimal) -> Decimal:
        if v < Decimal("0"):
            raise ValueError("القيمة لا يمكن أن تكون سالبة")
        return v


class PurchaseIssueRequest(BaseModel):
    supplier_id: Optional[UUID] = None
    debt_group_id: Optional[UUID] = None
    currency: str = "SAR"
    branch_id: Optional[UUID] = None
    discount_type: Optional[str] = None
    discount_value: Decimal = Decimal("0")
    tax_type: Optional[str] = None
    tax_rate: Decimal = Decimal("0")
    notes: Optional[str] = None
    due_date: Optional[date] = None
    idempotency_key: Optional[str] = None
    items: List[PurchaseIssueLine]
    payments: List[PurchaseIssuePayment] = []

    @field_validator("currency")
    @classmethod
    def validate_currency(cls, v: str) -> str:
        v = (v or "").strip().upper()
        if not v or len(v) > 10:
            raise ValueError("العملة غير صالحة")
        return v

    @field_validator("discount_type", "tax_type")
    @classmethod
    def validate_pct_or_fixed(cls, v: Optional[str]) -> Optional[str]:
        if v is not None and v not in {"percentage", "fixed"}:
            raise ValueError("النوع يجب أن يكون percentage أو fixed")
        return v


class PartyPaymentRequest(BaseModel):
    """Supplier payment / customer collection: one account+currency+amount,
    applied to the open debts of that same currency (oldest first)."""

    bank_account_id: UUID
    amount: Decimal
    currency: Optional[str] = None
    payment_method: str = "cash"
    reference: Optional[str] = None
    notes: Optional[str] = None
    idempotency_key: Optional[str] = None
    # Scope the payment to ONE debt section or ONE invoice (optional).
    debt_group_id: Optional[UUID] = None
    invoice_id: Optional[UUID] = None
    # When the account currency differs from the debt currency, this frozen
    # rate (1 payment currency = rate debt currency) converts the payment.
    exchange_rate: Optional[Decimal] = None

    @field_validator("amount")
    @classmethod
    def validate_amount(cls, v: Decimal) -> Decimal:
        if v <= Decimal("0"):
            raise ValueError("المبلغ يجب أن يكون أكبر من صفر")
        return v

    @field_validator("payment_method")
    @classmethod
    def validate_method(cls, v: str) -> str:
        allowed = {"cash", "bank", "card", "transfer", "cheque"}
        if v not in allowed:
            raise ValueError(f"طريقة الدفع غير صالحة: {v}")
        return v


class SaleReturnLine(BaseModel):
    invoice_item_id: UUID
    quantity: float
    # When false the returned units are NOT put back into / taken out of
    # stock (e.g. a damaged product the user does not want to re-stock).
    restock: bool = True

    @field_validator("quantity")
    @classmethod
    def validate_quantity(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("الكمية المرتجعة يجب أن تكون أكبر من صفر")
        return v


class SaleReturnRequest(BaseModel):
    lines: List[SaleReturnLine]
    reason: Optional[str] = None
    refund_account_id: Optional[UUID] = None
    # Cross-currency refund: base values stay in the invoice currency; when the
    # refund account uses another currency the client sends the converted
    # amount (in the account currency) + the frozen rate it used.
    refund_currency: Optional[str] = None
    refund_amount: Optional[Decimal] = None
    refund_exchange_rate: Optional[Decimal] = None
    refund_exchange_rate_source: Optional[str] = None
    refund_exchange_rate_timestamp: Optional[str] = None
    # Mirrors the customer/supplier settlement «الدفع بالسالب» allowance: when
    # true the account may go negative for the cash refund.
    allow_negative: bool = False


# ═══════════════════════════════════════════
# Product units & barcodes (managed in Inventory)
# ═══════════════════════════════════════════


class ProductUnitCreate(BaseModel):
    name: str
    factor: Decimal = Decimal("1")
    barcode: Optional[str] = None
    sale_price: Optional[Decimal] = None
    purchase_price: Optional[Decimal] = None
    # Measurement family of the unit (count/weight/volume/length/area/time/
    # service). Used to block incompatible pairings; never persisted.
    group: Optional[str] = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, v: str) -> str:
        if len(v.strip()) < 1:
            raise ValueError("اسم الوحدة مطلوب")
        return v.strip()

    @field_validator("factor")
    @classmethod
    def validate_factor(cls, v: Decimal) -> Decimal:
        if v <= Decimal("0"):
            raise ValueError("معامل الوحدة يجب أن يكون أكبر من صفر")
        return v


class ProductUnitUpdate(BaseModel):
    name: Optional[str] = None
    factor: Optional[Decimal] = None
    barcode: Optional[str] = None
    sale_price: Optional[Decimal] = None
    purchase_price: Optional[Decimal] = None
    is_active: Optional[bool] = None
    group: Optional[str] = None


class ProductBarcodeCreate(BaseModel):
    barcode: str
    unit_id: Optional[UUID] = None

    @field_validator("barcode")
    @classmethod
    def validate_barcode(cls, v: str) -> str:
        if len(v.strip()) < 1:
            raise ValueError("الباركود مطلوب")
        return v.strip()
