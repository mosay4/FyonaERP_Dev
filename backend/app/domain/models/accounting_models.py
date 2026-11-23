from pydantic import BaseModel, ConfigDict, field_validator
from typing import Optional, List
from datetime import datetime, date
from uuid import UUID
from decimal import Decimal

ZERO = Decimal("0")


class AccountCreate(BaseModel):
    code: str
    name: str
    name_ar: Optional[str] = None
    type: str
    parent_id: Optional[UUID] = None
    is_active: bool = True

    @field_validator("type")
    @classmethod
    def validate_type(cls, v: str) -> str:
        allowed = {"asset", "liability", "equity", "income", "expense"}
        if v not in allowed:
            raise ValueError(f"نوع الحساب غير صالح: {v}")
        return v


class AccountUpdate(BaseModel):
    name: Optional[str] = None
    name_ar: Optional[str] = None
    is_active: Optional[bool] = None


class AccountResponse(BaseModel):
    id: UUID
    organization_id: UUID
    code: str
    name: str
    name_ar: Optional[str]
    type: str
    parent_id: Optional[UUID]
    is_active: bool
    balance: Decimal
    created_at: datetime
    model_config = ConfigDict(from_attributes=True)


class JournalEntryLineCreate(BaseModel):
    account_id: UUID
    description: Optional[str] = None
    debit: Decimal = ZERO
    credit: Decimal = ZERO


class JournalEntryCreate(BaseModel):
    entry_date: Optional[date] = None
    description: str
    reference_type: Optional[str] = None
    reference_id: Optional[UUID] = None
    lines: List[JournalEntryLineCreate]


class JournalEntryLineResponse(BaseModel):
    id: UUID
    journal_entry_id: UUID
    account_id: UUID
    account_name: Optional[str] = None
    account_code: Optional[str] = None
    description: Optional[str]
    debit: Decimal
    credit: Decimal
    model_config = ConfigDict(from_attributes=True)


class JournalEntryResponse(BaseModel):
    id: UUID
    organization_id: UUID
    branch_id: Optional[UUID] = None
    entry_number: str
    entry_date: date
    description: str
    reference_type: Optional[str]
    reference_id: Optional[UUID]
    status: str
    created_at: datetime
    posted_at: Optional[datetime]
    lines: List[JournalEntryLineResponse]
    model_config = ConfigDict(from_attributes=True)


class TrialBalanceItem(BaseModel):
    account_id: UUID
    account_code: str
    account_name: str
    account_type: str
    debit: Decimal
    credit: Decimal
    balance: Decimal


class TrialBalanceResponse(BaseModel):
    items: List[TrialBalanceItem]
    total_debit: Decimal
    total_credit: Decimal
    entry_date: date


class ProfitLossItem(BaseModel):
    account_id: UUID
    account_code: str
    account_name: str
    amount: Decimal


class ProfitLossResponse(BaseModel):
    income: List[ProfitLossItem]
    expenses: List[ProfitLossItem]
    total_income: Decimal
    total_expenses: Decimal
    net_profit: Decimal
    entry_date: date


class BalanceSheetItem(BaseModel):
    account_id: UUID
    account_code: str
    account_name: str
    account_type: str
    balance: Decimal


class BalanceSheetResponse(BaseModel):
    assets: List[BalanceSheetItem]
    liabilities: List[BalanceSheetItem]
    equity: List[BalanceSheetItem]
    total_assets: Decimal
    total_liabilities: Decimal
    total_equity: Decimal
    entry_date: date
