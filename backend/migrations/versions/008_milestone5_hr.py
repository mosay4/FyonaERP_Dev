"""Add HR tables for Milestone 5 (employees, departments, positions, attendance, leaves, payroll)

Revision ID: 008
Revises: 007
Create Date: 2026-07-14
"""

from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "008"
down_revision = "007"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _exists(table):
    conn = op.get_bind()
    r = conn.execute(
        sa.text(
            "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_name = :n)"
        ),
        {"n": table},
    )
    return r.scalar()


def upgrade():
    tables = {
        "departments": [
            ("id", postgresql.UUID, True),
            ("organization_id", postgresql.UUID, False),
            ("name", sa.String(200), False),
            ("name_ar", sa.String(200), True),
            ("description", sa.Text, True),
            ("is_active", sa.Boolean, True),
            ("created_at", sa.DateTime(timezone=True), True),
            ("updated_at", sa.DateTime(timezone=True), True),
        ],
        "positions": [
            ("id", postgresql.UUID, True),
            ("organization_id", postgresql.UUID, False),
            ("department_id", postgresql.UUID, True),
            ("title", sa.String(200), False),
            ("title_ar", sa.String(200), True),
            ("description", sa.Text, True),
            ("is_active", sa.Boolean, True),
            ("created_at", sa.DateTime(timezone=True), True),
        ],
        "employees": [
            ("id", postgresql.UUID, True),
            ("organization_id", postgresql.UUID, False),
            ("department_id", postgresql.UUID, True),
            ("position_id", postgresql.UUID, True),
            ("employee_code", sa.String(50), False),
            ("full_name", sa.String(200), False),
            ("email", sa.String(100), True),
            ("phone", sa.String(50), True),
            ("hire_date", sa.Date, True),
            ("termination_date", sa.Date, True),
            ("salary", sa.Numeric(12, 2), True),
            ("status", sa.String(20), True),
            ("id_number", sa.String(50), True),
            ("id_type", sa.String(20), True),
            ("gender", sa.String(10), True),
            ("date_of_birth", sa.Date, True),
            ("address", sa.Text, True),
            ("emergency_contact", sa.String(100), True),
            ("emergency_phone", sa.String(50), True),
            ("bank_name", sa.String(200), True),
            ("bank_account", sa.String(100), True),
            ("iban", sa.String(50), True),
            ("notes", sa.Text, True),
            ("created_by", postgresql.UUID, True),
            ("created_at", sa.DateTime(timezone=True), True),
            ("updated_at", sa.DateTime(timezone=True), True),
            ("is_deleted", sa.Boolean, True),
            ("deleted_at", sa.DateTime(timezone=True), True),
        ],
        "employee_documents": [
            ("id", postgresql.UUID, True),
            ("employee_id", postgresql.UUID, False),
            ("document_type", sa.String(100), True),
            ("document_name", sa.String(200), False),
            ("file_path", sa.String(500), True),
            ("expiry_date", sa.Date, True),
            ("notes", sa.Text, True),
            ("created_at", sa.DateTime(timezone=True), True),
        ],
        "employee_contracts": [
            ("id", postgresql.UUID, True),
            ("employee_id", postgresql.UUID, False),
            ("contract_type", sa.String(50), True),
            ("start_date", sa.Date, False),
            ("end_date", sa.Date, True),
            ("salary", sa.Numeric(12, 2), True),
            ("working_hours", sa.Float, True),
            ("notes", sa.Text, True),
            ("status", sa.String(20), True),
            ("created_at", sa.DateTime(timezone=True), True),
            ("updated_at", sa.DateTime(timezone=True), True),
        ],
        "attendances": [
            ("id", postgresql.UUID, True),
            ("employee_id", postgresql.UUID, False),
            ("date", sa.Date, False),
            ("check_in", sa.DateTime(timezone=True), True),
            ("check_out", sa.DateTime(timezone=True), True),
            ("status", sa.String(20), True),
            ("notes", sa.Text, True),
            ("created_by", postgresql.UUID, True),
            ("created_at", sa.DateTime(timezone=True), True),
        ],
        "leaves": [
            ("id", postgresql.UUID, True),
            ("employee_id", postgresql.UUID, False),
            ("leave_type", sa.String(50), False),
            ("start_date", sa.Date, False),
            ("end_date", sa.Date, False),
            ("days", sa.Float, False),
            ("reason", sa.Text, True),
            ("status", sa.String(20), True),
            ("approved_by", postgresql.UUID, True),
            ("created_at", sa.DateTime(timezone=True), True),
            ("updated_at", sa.DateTime(timezone=True), True),
        ],
        "payrolls": [
            ("id", postgresql.UUID, True),
            ("organization_id", postgresql.UUID, False),
            ("month", sa.Integer, False),
            ("year", sa.Integer, False),
            ("status", sa.String(20), True),
            ("total_salary", sa.Numeric(12, 2), True),
            ("total_deductions", sa.Numeric(12, 2), True),
            ("total_bonuses", sa.Numeric(12, 2), True),
            ("net_total", sa.Numeric(12, 2), True),
            ("notes", sa.Text, True),
            ("processed_by", postgresql.UUID, True),
            ("processed_at", sa.DateTime(timezone=True), True),
            ("created_at", sa.DateTime(timezone=True), True),
        ],
        "payroll_items": [
            ("id", postgresql.UUID, True),
            ("payroll_id", postgresql.UUID, False),
            ("employee_id", postgresql.UUID, True),
            ("basic_salary", sa.Numeric(12, 2), True),
            ("allowances", sa.Numeric(12, 2), True),
            ("deductions", sa.Numeric(12, 2), True),
            ("bonus", sa.Numeric(12, 2), True),
            ("overtime", sa.Numeric(12, 2), True),
            ("net_salary", sa.Numeric(12, 2), True),
            ("total_days", sa.Float, True),
            ("working_days", sa.Float, True),
            ("absence_days", sa.Float, True),
        ],
    }
    for tname, cols in tables.items():
        if not _exists(tname):
            op.create_table(
                tname,
                *[
                    sa.Column(
                        c[0],
                        c[1],
                        primary_key=(i == 0),
                        nullable=c[2] if i > 0 else False,
                    )
                    for i, c in enumerate(cols)
                ],
                *(
                    sa.ForeignKeyConstraint([c[0]], [f"{fk}.id"], ondelete="CASCADE")
                    for c, fk in [
                        ("organization_id", "organizations"),
                        ("department_id", "departments"),
                        ("position_id", "positions"),
                        ("employee_id", "employees"),
                        ("created_by", "users"),
                        ("processed_by", "users"),
                        ("approved_by", "users"),
                        ("payroll_id", "payrolls"),
                    ]
                    if any(c[0] == f[0] for f in cols) and _exists(fk)
                ),
            )


def downgrade():
    for t in [
        "payroll_items",
        "payrolls",
        "leaves",
        "attendances",
        "employee_contracts",
        "employee_documents",
        "employees",
        "positions",
        "departments",
    ]:
        if _exists(t):
            op.drop_table(t)
