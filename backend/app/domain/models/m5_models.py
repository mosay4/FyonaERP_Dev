from pydantic import BaseModel, ConfigDict, field_validator
from typing import Optional, List
from datetime import datetime, date
from uuid import UUID
from decimal import Decimal

ZERO = Decimal("0")


# ═══ Department ═══
class DepartmentCreate(BaseModel):
    name: str
    name_ar: Optional[str] = None
    description: Optional[str] = None


class DepartmentUpdate(BaseModel):
    name: Optional[str] = None
    name_ar: Optional[str] = None
    description: Optional[str] = None
    is_active: Optional[bool] = None


class DepartmentResponse(BaseModel):
    id: UUID
    organization_id: UUID
    name: str
    name_ar: Optional[str]
    description: Optional[str]
    is_active: bool
    created_at: datetime
    model_config = ConfigDict(from_attributes=True)


# ═══ Position ═══
class PositionCreate(BaseModel):
    department_id: Optional[UUID] = None
    title: str
    title_ar: Optional[str] = None
    description: Optional[str] = None


class PositionUpdate(BaseModel):
    department_id: Optional[UUID] = None
    title: Optional[str] = None
    title_ar: Optional[str] = None
    description: Optional[str] = None
    is_active: Optional[bool] = None


class PositionResponse(BaseModel):
    id: UUID
    organization_id: UUID
    department_id: Optional[UUID]
    department_name: Optional[str] = None
    title: str
    title_ar: Optional[str]
    description: Optional[str]
    is_active: bool
    created_at: datetime
    model_config = ConfigDict(from_attributes=True)


# ═══ Employee ═══
class EmployeeCreate(BaseModel):
    employee_code: str
    full_name: str
    email: Optional[str] = None
    phone: Optional[str] = None
    department_id: Optional[UUID] = None
    position_id: Optional[UUID] = None
    hire_date: Optional[date] = None
    salary: Decimal = ZERO
    id_number: Optional[str] = None
    gender: Optional[str] = None
    date_of_birth: Optional[date] = None
    address: Optional[str] = None
    emergency_contact: Optional[str] = None
    emergency_phone: Optional[str] = None
    bank_name: Optional[str] = None
    bank_account: Optional[str] = None
    iban: Optional[str] = None
    notes: Optional[str] = None


class EmployeeUpdate(BaseModel):
    full_name: Optional[str] = None
    email: Optional[str] = None
    phone: Optional[str] = None
    department_id: Optional[UUID] = None
    position_id: Optional[UUID] = None
    salary: Optional[Decimal] = None
    address: Optional[str] = None
    notes: Optional[str] = None
    status: Optional[str] = None
    bank_name: Optional[str] = None
    bank_account: Optional[str] = None
    iban: Optional[str] = None


class EmployeeResponse(BaseModel):
    id: UUID
    organization_id: UUID
    employee_code: str
    full_name: str
    email: Optional[str]
    phone: Optional[str]
    department_id: Optional[UUID]
    department_name: Optional[str] = None
    position_id: Optional[UUID]
    position_name: Optional[str] = None
    hire_date: Optional[date]
    salary: Decimal
    status: str
    id_number: Optional[str]
    gender: Optional[str]
    date_of_birth: Optional[date]
    address: Optional[str]
    emergency_contact: Optional[str]
    emergency_phone: Optional[str]
    bank_name: Optional[str]
    bank_account: Optional[str]
    iban: Optional[str]
    notes: Optional[str]
    created_at: datetime
    updated_at: datetime
    model_config = ConfigDict(from_attributes=True)


# ═══ Attendance ═══
class AttendanceCreate(BaseModel):
    employee_id: UUID
    date: date
    check_in: Optional[datetime] = None
    check_out: Optional[datetime] = None
    status: str = "present"
    notes: Optional[str] = None

    @field_validator("status")
    @classmethod
    def v(cls, s):
        allowed = {"present", "absent", "late", "half_day", "overtime"}
        if s not in allowed:
            raise ValueError(f"حالة غير صالحة: {s}")
        return s


class AttendanceResponse(BaseModel):
    id: UUID
    employee_id: UUID
    employee_name: Optional[str] = None
    date: date
    check_in: Optional[datetime]
    check_out: Optional[datetime]
    status: str
    notes: Optional[str]
    created_at: datetime
    model_config = ConfigDict(from_attributes=True)


# ═══ Leave ═══
class LeaveCreate(BaseModel):
    employee_id: UUID
    leave_type: str
    start_date: date
    end_date: date
    reason: Optional[str] = None

    @field_validator("leave_type")
    @classmethod
    def v(cls, s):
        allowed = {"sick", "annual", "emergency", "unpaid", "maternity", "hajj"}
        if s not in allowed:
            raise ValueError(f"نوع إجازة غير صالح: {s}")
        return s


class LeaveResponse(BaseModel):
    id: UUID
    employee_id: UUID
    employee_name: Optional[str] = None
    leave_type: str
    start_date: date
    end_date: date
    days: float
    reason: Optional[str]
    status: str
    created_at: datetime
    model_config = ConfigDict(from_attributes=True)


class LeaveAction(BaseModel):
    action: str

    @field_validator("action")
    @classmethod
    def v(cls, s):
        if s not in {"approve", "reject"}:
            raise ValueError("يجب أن يكون approve أو reject")
            return s


# ═══ Payroll ═══
class PayrollCreate(BaseModel):
    month: int
    year: int
    notes: Optional[str] = None

    @field_validator("month")
    @classmethod
    def v(cls, m):
        if m < 1 or m > 12:
            raise ValueError("الشهر يجب أن يكون بين 1 و 12")
            return m


class PayrollItemResponse(BaseModel):
    id: UUID
    payroll_id: UUID
    employee_id: Optional[UUID]
    employee_name: Optional[str] = None
    basic_salary: Decimal
    allowances: Decimal
    deductions: Decimal
    bonus: Decimal
    overtime: Decimal
    net_salary: Decimal
    total_days: float
    working_days: float
    absence_days: float
    model_config = ConfigDict(from_attributes=True)


class PayrollResponse(BaseModel):
    id: UUID
    organization_id: UUID
    month: int
    year: int
    status: str
    total_salary: Decimal
    total_deductions: Decimal
    total_bonuses: Decimal
    net_total: Decimal
    notes: Optional[str]
    created_at: datetime
    processed_at: Optional[datetime]
    items: List[PayrollItemResponse] = []
    model_config = ConfigDict(from_attributes=True)


# ═══ Reports ═══
class KPIResponse(BaseModel):
    total_customers: int
    total_products: int
    total_sales_orders: int
    total_purchase_orders: int
    total_sales_amount: Decimal
    total_purchases_amount: Decimal
    total_invoices: int
    total_revenue: Decimal
    total_expenses: Decimal
    net_profit: Decimal
    active_employees: int
    pending_leaves: int
    low_stock_products: int
    monthly_revenue: List[Decimal] = []
    monthly_expenses: List[Decimal] = []


class SalesReportItem(BaseModel):
    period: str
    order_count: int
    total_amount: Decimal
    total_tax: Decimal


class SalesReportResponse(BaseModel):
    items: List[SalesReportItem]
    grand_total: Decimal
    from_date: date
    to_date: date


class InventoryReportItem(BaseModel):
    product_id: UUID
    product_name: str
    sku: Optional[str]
    stock: float
    min_stock: float
    unit_price: Decimal
    stock_value: Decimal


class InventoryReportResponse(BaseModel):
    items: List[InventoryReportItem]
    total_value: Decimal
    total_products: int
    low_stock_count: int


# ═══ AI ═══
class AIInsight(BaseModel):
    type: str
    title: str
    description: str
    severity: str
    value: Optional[str] = None


class AIInsightsResponse(BaseModel):
    insights: List[AIInsight]
    generated_at: datetime


class AIQuery(BaseModel):
    query: str
    user_name: Optional[str] = ""
    account_type: Optional[str] = "personal"
    company_name: Optional[str] = None
    current_screen: Optional[str] = ""
    language: Optional[str] = None  # ISO code from the app: "ar" | "en"
    history: Optional[list] = None

    # ── App Awareness (live application state) ──
    subscription_plan: Optional[str] = None
    subscription_status: Optional[str] = None
    network_status: Optional[str] = "online"
    current_tab: Optional[str] = ""
    last_screen: Optional[str] = ""
    last_operation: Optional[str] = ""
    pending_operations: Optional[list] = None
    # Live screen catalog streamed by the installed app: every route the
    # current build ships (route/title/summary). Lets Sara discover screens
    # added later without any backend update.
    screen_catalog: Optional[list] = None


class AIQueryResponse(BaseModel):
    answer: str
    confidence: float
    sql_query: Optional[str] = None
    data: Optional[list] = None


class ForecastItem(BaseModel):
    period: str
    predicted_value: float
    lower_bound: Optional[float] = None
    upper_bound: Optional[float] = None


class ForecastResponse(BaseModel):
    items: List[ForecastItem]
    metric: str
    periods: int
