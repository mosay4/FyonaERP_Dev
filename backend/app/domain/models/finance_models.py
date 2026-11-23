from datetime import datetime
from decimal import Decimal
from typing import Optional, List
from uuid import UUID
from pydantic import BaseModel, ConfigDict, field_validator


# ── Bank Account ──

class BankAccountCreate(BaseModel):
    bank_name: str
    account_name: str
    account_number: str
    iban: Optional[str] = None
    currency: str = "SAR"
    account_type: str = "checking"
    # The OPENING balance typed by the user when creating the account. It was
    # previously dropped here (extra field) and hardcoded to 0 in the route —
    # that was the root cause of "opening balance never appears".
    balance: float = 0

    @field_validator("bank_name")
    @classmethod
    def validate_bank_name(cls, v: str) -> str:
        if len(v.strip()) < 2:
            raise ValueError("اسم البنك يجب أن يكون حرفين على الأقل")
        return v.strip()


class BankAccountUpdate(BaseModel):
    bank_name: Optional[str] = None
    account_name: Optional[str] = None
    account_number: Optional[str] = None
    iban: Optional[str] = None
    currency: Optional[str] = None
    account_type: Optional[str] = None
    balance: Optional[Decimal] = None
    is_active: Optional[bool] = None


class BankAccountResponse(BaseModel):
    id: UUID
    organization_id: UUID
    branch_id: Optional[UUID] = None
    bank_name: str
    account_name: str
    account_number: str
    iban: Optional[str]
    bank_group_key: Optional[str] = None
    balance: Decimal
    currency: str
    account_type: str = "checking"
    is_active: bool
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ── Bank Transaction ──

class BankTransactionResponse(BaseModel):
    id: UUID
    bank_account_id: UUID
    date: datetime
    description: str
    tx_type: str
    amount: Decimal
    running_balance: Decimal
    reference: Optional[str]
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class TransferRequest(BaseModel):
    from_account_id: str
    to_account_id: str
    amount: Decimal
    description: Optional[str] = None
    # Cross-currency transfers: the client converts with a live rate and sends
    # the destination amount explicitly (same pattern as the personal section,
    # where conversion is computed app-side). Same-currency transfers omit it.
    to_amount: Optional[Decimal] = None
    exchange_rate: Optional[float] = None

    @field_validator("amount")
    @classmethod
    def validate_amount(cls, v: Decimal) -> Decimal:
        if v <= 0:
            raise ValueError("المبلغ يجب أن يكون أكبر من صفر")
        return v

    @field_validator("to_amount")
    @classmethod
    def validate_to_amount(cls, v: Optional[Decimal]) -> Optional[Decimal]:
        if v is not None and v <= 0:
            raise ValueError("المبلغ المستلم يجب أن يكون أكبر من صفر")
        return v


class AmountRequest(BaseModel):
    amount: Decimal
    description: Optional[str] = None
    # When a Business withdrawal is a real categorized expense (not a plain
    # cash move), the client marks it so the backend records an Expense row
    # atomically in the SAME transaction — otherwise reports' expenses can
    # never see Business spending.
    is_expense: bool = False
    category: Optional[str] = None

    @field_validator("amount")
    @classmethod
    def validate_amount(cls, v: Decimal) -> Decimal:
        if v <= 0:
            raise ValueError("المبلغ يجب أن يكون أكبر من صفر")
        return v


# ── Payment ──

class PaymentCreate(BaseModel):
    payment_no: Optional[str] = None
    payment_type: str = "incoming"
    payment_method: str = "cash"
    amount: Decimal = Decimal("0")
    notes: Optional[str] = None
    payment_date: Optional[datetime] = None

    @field_validator("amount")
    @classmethod
    def validate_amount(cls, v: Decimal) -> Decimal:
        if v <= 0:
            raise ValueError("المبلغ يجب أن يكون أكبر من صفر")
        return v


class PaymentResponse(BaseModel):
    id: UUID
    organization_id: UUID
    branch_id: Optional[UUID] = None
    payment_no: str
    payment_type: str
    payment_method: str
    amount: Decimal
    notes: Optional[str]
    payment_date: Optional[datetime]
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ── Expense ──

class ExpenseCreate(BaseModel):
    expense_no: Optional[str] = None
    category: str = ""
    amount: Decimal = Decimal("0")
    currency: Optional[str] = None
    description: str = ""
    payment_method: str = "cash"
    expense_date: Optional[datetime] = None

    @field_validator("amount")
    @classmethod
    def validate_amount(cls, v: Decimal) -> Decimal:
        if v <= 0:
            raise ValueError("المبلغ يجب أن يكون أكبر من صفر")
        return v


class ExpenseResponse(BaseModel):
    id: UUID
    organization_id: UUID
    branch_id: Optional[UUID] = None
    expense_no: str
    category: str
    amount: Decimal
    currency: Optional[str] = None
    bank_account_id: Optional[UUID] = None
    is_deleted: bool = False
    deleted_at: Optional[datetime] = None
    description: str
    payment_method: str
    expense_date: Optional[datetime]
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


# ── Cheque ──

class ChequeCreate(BaseModel):
    cheque_number: str
    amount: Decimal = Decimal("0")
    status: str = "pending"
    payee_name: Optional[str] = None
    bank_name: Optional[str] = None
    issue_date: Optional[datetime] = None
    due_date: Optional[datetime] = None

    @field_validator("cheque_number")
    @classmethod
    def validate_cheque_number(cls, v: str) -> str:
        if len(v.strip()) < 1:
            raise ValueError("رقم الشيك مطلوب")
        return v.strip()


class ChequeStatusUpdate(BaseModel):
    status: str

    @field_validator("status")
    @classmethod
    def validate_status(cls, v: str) -> str:
        allowed = {"pending", "cashed", "bounced", "cancelled"}
        if v not in allowed:
            raise ValueError(f"الحالة يجب أن تكون واحدة من: {', '.join(allowed)}")
        return v


class ChequeResponse(BaseModel):
    id: UUID
    organization_id: UUID
    branch_id: Optional[UUID] = None
    cheque_number: str
    amount: Decimal
    status: str
    payee_name: Optional[str]
    bank_name: Optional[str]
    issue_date: Optional[datetime]
    due_date: Optional[datetime]
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)
