import uuid
from datetime import datetime, timezone
from sqlalchemy import (
    Column,
    String,
    Boolean,
    DateTime,
    Date,
    ForeignKey,
    Text,
    Float,
    Integer,
    Numeric,
    UniqueConstraint,
    CheckConstraint,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from app.core.database import Base


class Department(Base):
    __tablename__ = "departments"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    name = Column(String(200), nullable=False)
    name_ar = Column(String(200))
    description = Column(Text)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
    updated_at = Column(
        DateTime(timezone=True),
        default=datetime.now(timezone.utc),
        onupdate=datetime.now(timezone.utc),
    )


class Position(Base):
    __tablename__ = "positions"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    department_id = Column(
        UUID(as_uuid=True),
        ForeignKey("departments.id", ondelete="SET NULL"),
        index=True,
    )
    title = Column(String(200), nullable=False)
    title_ar = Column(String(200))
    description = Column(Text)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))


class Employee(Base):
    __tablename__ = "employees"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    department_id = Column(
        UUID(as_uuid=True),
        ForeignKey("departments.id", ondelete="SET NULL"),
        index=True,
    )
    position_id = Column(
        UUID(as_uuid=True), ForeignKey("positions.id", ondelete="SET NULL"), index=True
    )
    employee_code = Column(String(50), nullable=False)
    full_name = Column(String(200), nullable=False)
    email = Column(String(100))
    phone = Column(String(50))
    hire_date = Column(Date)
    termination_date = Column(Date)
    salary = Column(Numeric(12, 2), default=0)
    status = Column(String(20), default="active")
    id_number = Column(String(50))
    id_type = Column(String(20))
    gender = Column(String(10))
    date_of_birth = Column(Date)
    address = Column(Text)
    emergency_contact = Column(String(100))
    emergency_phone = Column(String(50))
    bank_name = Column(String(200))
    bank_account = Column(String(100))
    iban = Column(String(50))
    notes = Column(Text)
    created_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
    updated_at = Column(
        DateTime(timezone=True),
        default=datetime.now(timezone.utc),
        onupdate=datetime.now(timezone.utc),
    )
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))
    department = relationship("Department", lazy="selectin")
    position = relationship("Position", lazy="selectin")
    __table_args__ = (
        UniqueConstraint("organization_id", "employee_code", name="uq_emp_code"),
        CheckConstraint(
            "status IN ('active','terminated','suspended')", name="ck_emp_status"
        ),
    )


class EmployeeDocument(Base):
    __tablename__ = "employee_documents"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    employee_id = Column(
        UUID(as_uuid=True),
        ForeignKey("employees.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    document_type = Column(String(100))
    document_name = Column(String(200), nullable=False)
    file_path = Column(String(500))
    expiry_date = Column(Date)
    notes = Column(Text)
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))


class EmployeeContract(Base):
    __tablename__ = "employee_contracts"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    employee_id = Column(
        UUID(as_uuid=True),
        ForeignKey("employees.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    contract_type = Column(String(50))
    start_date = Column(Date, nullable=False)
    end_date = Column(Date)
    salary = Column(Numeric(12, 2), default=0)
    working_hours = Column(Float, default=8)
    notes = Column(Text)
    status = Column(String(20), default="active")
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
    updated_at = Column(
        DateTime(timezone=True),
        default=datetime.now(timezone.utc),
        onupdate=datetime.now(timezone.utc),
    )


class Attendance(Base):
    __tablename__ = "attendances"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    employee_id = Column(
        UUID(as_uuid=True),
        ForeignKey("employees.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    date = Column(Date, nullable=False)
    check_in = Column(DateTime(timezone=True))
    check_out = Column(DateTime(timezone=True))
    status = Column(String(20), default="present")
    notes = Column(Text)
    created_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
    __table_args__ = (
        UniqueConstraint("employee_id", "date", name="uq_att_emp_date"),
        CheckConstraint(
            "status IN ('present','absent','late','half_day','overtime')",
            name="ck_att_status",
        ),
    )


class Leave(Base):
    __tablename__ = "leaves"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    employee_id = Column(
        UUID(as_uuid=True),
        ForeignKey("employees.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    leave_type = Column(String(50), nullable=False)
    start_date = Column(Date, nullable=False)
    end_date = Column(Date, nullable=False)
    days = Column(Float, nullable=False)
    reason = Column(Text)
    status = Column(String(20), default="pending")
    approved_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
    updated_at = Column(
        DateTime(timezone=True),
        default=datetime.now(timezone.utc),
        onupdate=datetime.now(timezone.utc),
    )
    __table_args__ = (
        CheckConstraint(
            "leave_type IN ('sick','annual','emergency','unpaid','maternity','hajj')",
            name="ck_leave_type",
        ),
        CheckConstraint(
            "status IN ('pending','approved','rejected','cancelled')",
            name="ck_leave_status",
        ),
    )


class Payroll(Base):
    __tablename__ = "payrolls"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    month = Column(Integer, nullable=False)
    year = Column(Integer, nullable=False)
    status = Column(String(20), default="draft")
    total_salary = Column(Numeric(12, 2), default=0)
    total_deductions = Column(Numeric(12, 2), default=0)
    total_bonuses = Column(Numeric(12, 2), default=0)
    net_total = Column(Numeric(12, 2), default=0)
    notes = Column(Text)
    processed_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    processed_at = Column(DateTime(timezone=True))
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
    items = relationship(
        "PayrollItem",
        back_populates="payroll",
        lazy="select",
        cascade="all, delete-orphan",
    )
    __table_args__ = (
        UniqueConstraint("organization_id", "month", "year", name="uq_payroll_period"),
        CheckConstraint(
            "status IN ('draft','processed','paid','cancelled')",
            name="ck_payroll_status",
        ),
        CheckConstraint("month >= 1 AND month <= 12", name="ck_payroll_month"),
    )


class PayrollItem(Base):
    __tablename__ = "payroll_items"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    payroll_id = Column(
        UUID(as_uuid=True),
        ForeignKey("payrolls.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    employee_id = Column(
        UUID(as_uuid=True), ForeignKey("employees.id", ondelete="SET NULL"), index=True
    )
    basic_salary = Column(Numeric(12, 2), default=0)
    allowances = Column(Numeric(12, 2), default=0)
    deductions = Column(Numeric(12, 2), default=0)
    bonus = Column(Numeric(12, 2), default=0)
    overtime = Column(Numeric(12, 2), default=0)
    net_salary = Column(Numeric(12, 2), default=0)
    total_days = Column(Float, default=30)
    working_days = Column(Float, default=30)
    absence_days = Column(Float, default=0)
    payroll = relationship("Payroll", back_populates="items")
    employee = relationship("Employee", lazy="select")
