"""Fix inverted nullable columns from migration 008

Migration 008 used `nullable=(not c[2])` which inverted nullability:
- True (nullable) was created as NOT NULL
- False (NOT NULL) was created as NULL

This migration corrects the affected columns where True meant nullable.
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "010"
down_revision: Union[str, None] = "009"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# Columns that should be NULLABLE but were created as NOT NULL
# Format: (table, column)
NULLABLE_COLS = [
    # employees
    ("employees", "email"),
    ("employees", "phone"),
    ("employees", "hire_date"),
    ("employees", "termination_date"),
    ("employees", "salary"),
    ("employees", "status"),
    ("employees", "id_number"),
    ("employees", "id_type"),
    ("employees", "gender"),
    ("employees", "date_of_birth"),
    ("employees", "address"),
    ("employees", "emergency_contact"),
    ("employees", "emergency_phone"),
    ("employees", "bank_name"),
    ("employees", "bank_account"),
    ("employees", "iban"),
    ("employees", "notes"),
    ("employees", "department_id"),
    ("employees", "position_id"),
    ("employees", "created_by"),
    ("employees", "created_at"),
    ("employees", "updated_at"),
    ("employees", "is_deleted"),
    ("employees", "deleted_at"),
    # employee_documents
    ("employee_documents", "document_type"),
    ("employee_documents", "file_path"),
    ("employee_documents", "expiry_date"),
    ("employee_documents", "notes"),
    ("employee_documents", "created_at"),
    # employee_contracts
    ("employee_contracts", "contract_type"),
    ("employee_contracts", "end_date"),
    ("employee_contracts", "salary"),
    ("employee_contracts", "working_hours"),
    ("employee_contracts", "notes"),
    ("employee_contracts", "status"),
    ("employee_contracts", "created_at"),
    ("employee_contracts", "updated_at"),
    # attendances
    ("attendances", "check_in"),
    ("attendances", "check_out"),
    ("attendances", "status"),
    ("attendances", "notes"),
    ("attendances", "created_by"),
    ("attendances", "created_at"),
    # leaves
    ("leaves", "reason"),
    ("leaves", "status"),
    ("leaves", "approved_by"),
    ("leaves", "created_at"),
    ("leaves", "updated_at"),
    # payrolls
    ("payrolls", "status"),
    ("payrolls", "total_salary"),
    ("payrolls", "total_deductions"),
    ("payrolls", "total_bonuses"),
    ("payrolls", "net_total"),
    ("payrolls", "notes"),
    ("payrolls", "processed_by"),
    ("payrolls", "processed_at"),
    ("payrolls", "created_at"),
    # payroll_items
    ("payroll_items", "employee_id"),
    ("payroll_items", "basic_salary"),
    ("payroll_items", "allowances"),
    ("payroll_items", "deductions"),
    ("payroll_items", "bonus"),
    ("payroll_items", "overtime"),
    ("payroll_items", "net_salary"),
    ("payroll_items", "total_days"),
    ("payroll_items", "working_days"),
    ("payroll_items", "absence_days"),
]


def _col_exists(table: str, column: str) -> bool:
    conn = op.get_bind()
    r = conn.execute(
        sa.text("SELECT column_name FROM information_schema.columns WHERE table_name = :t AND column_name = :c"),
        {"t": table, "c": column},
    )
    return r.scalar() is not None


def _is_not_null(table: str, column: str) -> bool:
    conn = op.get_bind()
    r = conn.execute(
        sa.text("SELECT is_nullable FROM information_schema.columns WHERE table_name = :t AND column_name = :c"),
        {"t": table, "c": column},
    )
    row = r.scalar()
    return row == "NO" if row else False


def upgrade() -> None:
    for table, col in NULLABLE_COLS:
        if _col_exists(table, col) and _is_not_null(table, col):
            op.alter_column(table, col, nullable=True)


def downgrade() -> None:
    pass
