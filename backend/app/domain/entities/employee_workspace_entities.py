import uuid
from datetime import datetime, timezone
from sqlalchemy import Column, DateTime, ForeignKey, Numeric, String, Text, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class EmployeeWorkspace(Base):
    __tablename__ = "employee_workspace"
    employee_id = Column(UUID(as_uuid=True), ForeignKey("employees.id", ondelete="CASCADE"), primary_key=True)
    organization_id = Column(UUID(as_uuid=True), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True)
    linked_user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True, index=True)
    photo_url = Column(Text)
    salary_currency = Column(String(20), nullable=False, default="SAR")
    permissions = Column(Text, nullable=False, default="{}")
    branch_ids = Column(Text, nullable=True)
    last_seen_at = Column(DateTime(timezone=True))
    active_organization_id = Column(UUID(as_uuid=True), nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class EmployeeInvitation(Base):
    __tablename__ = "employee_invitations"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(UUID(as_uuid=True), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True)
    employee_id = Column(UUID(as_uuid=True), ForeignKey("employees.id", ondelete="CASCADE"), nullable=False, index=True)
    invited_user_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    invited_by = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    status = Column(String(20), nullable=False, default="pending")
    permissions = Column(Text, nullable=False, default="{}")
    branch_ids = Column(Text, nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    responded_at = Column(DateTime(timezone=True))
    __table_args__ = (UniqueConstraint("employee_id", "invited_user_id", "status", name="uq_employee_invite_state"),)


class EmployeeSalaryPayment(Base):
    __tablename__ = "employee_salary_payments"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(UUID(as_uuid=True), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True)
    employee_id = Column(UUID(as_uuid=True), ForeignKey("employees.id", ondelete="CASCADE"), nullable=False, index=True)
    operation_no = Column(String(60), nullable=False, unique=True, index=True)
    amount = Column(Numeric(18, 2), nullable=False, default=0)
    currency = Column(String(20), nullable=False, default="SAR")
    paid_at = Column(DateTime(timezone=True), default=utcnow)
    notes = Column(Text)
    bank_account_id = Column(UUID(as_uuid=True), nullable=True)
    branch_id = Column(UUID(as_uuid=True), nullable=True)
    bank_name = Column(String(200))
    branch_name = Column(String(200))
    base_salary = Column(Numeric(18, 2))
    remaining_salary = Column(Numeric(18, 2))
    invoice_no = Column(String(60))
    receipt_snapshot = Column(Text)
    created_by = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True)


class EmployeeDebt(Base):
    __tablename__ = "employee_debts"
    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(UUID(as_uuid=True), ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True)
    employee_id = Column(UUID(as_uuid=True), ForeignKey("employees.id", ondelete="CASCADE"), nullable=False, index=True)
    direction = Column(String(30), nullable=False)
    kind = Column(String(20), nullable=False, default="charge")
    amount = Column(Numeric(18, 2), nullable=False, default=0)
    currency = Column(String(20), nullable=False, default="SAR")
    notes = Column(Text)
    bank_account_id = Column(UUID(as_uuid=True), nullable=True)
    branch_id = Column(UUID(as_uuid=True), nullable=True)
    bank_name = Column(String(200))
    branch_name = Column(String(200))
    invoice_no = Column(String(60))
    receipt_snapshot = Column(Text)
    created_by = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), nullable=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
