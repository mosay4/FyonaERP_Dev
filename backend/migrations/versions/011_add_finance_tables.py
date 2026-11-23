"""Add finance tables: bank_accounts, bank_transactions, payments, expenses, cheques

Revision ID: 011
Revises: 010
Create Date: 2026-07-17
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision: str = "011"
down_revision: Union[str, None] = "010"
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
    # ── Bank Accounts ──
    if not _exists("bank_accounts"):
        op.create_table(
            "bank_accounts",
            sa.Column("id", postgresql.UUID(), primary_key=True),
            sa.Column("organization_id", postgresql.UUID(), sa.ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True),
            sa.Column("bank_name", sa.String(200), nullable=False),
            sa.Column("account_name", sa.String(200), nullable=False),
            sa.Column("account_number", sa.String(100), nullable=False),
            sa.Column("iban", sa.String(50), nullable=True),
            sa.Column("balance", sa.Numeric(12, 2), server_default="0"),
            sa.Column("currency", sa.String(10), server_default="SAR"),
            sa.Column("is_active", sa.Boolean(), server_default="true"),
            sa.Column("is_deleted", sa.Boolean(), server_default="false"),
            sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        )

    # ── Bank Transactions ──
    if not _exists("bank_transactions"):
        op.create_table(
            "bank_transactions",
            sa.Column("id", postgresql.UUID(), primary_key=True),
            sa.Column("organization_id", postgresql.UUID(), sa.ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True),
            sa.Column("bank_account_id", postgresql.UUID(), sa.ForeignKey("bank_accounts.id", ondelete="CASCADE"), nullable=False, index=True),
            sa.Column("date", sa.DateTime(timezone=True), nullable=True),
            sa.Column("description", sa.Text(), server_default=""),
            sa.Column("tx_type", sa.String(20), nullable=False),
            sa.Column("amount", sa.Numeric(12, 2), nullable=False),
            sa.Column("running_balance", sa.Numeric(12, 2), server_default="0"),
            sa.Column("reference", sa.Text(), nullable=True),
            sa.Column("is_deleted", sa.Boolean(), server_default="false"),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        )

    # ── Financial Payments (standalone, not invoice-linked) ──
    if not _exists("financial_payments"):
        op.create_table(
            "financial_payments",
            sa.Column("id", postgresql.UUID(), primary_key=True),
            sa.Column("organization_id", postgresql.UUID(), sa.ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True),
            sa.Column("payment_no", sa.String(50), nullable=False),
            sa.Column("payment_type", sa.String(20), server_default="incoming"),
            sa.Column("payment_method", sa.String(20), server_default="cash"),
            sa.Column("amount", sa.Numeric(12, 2), nullable=False),
            sa.Column("notes", sa.Text(), nullable=True),
            sa.Column("payment_date", sa.DateTime(timezone=True), nullable=True),
            sa.Column("is_deleted", sa.Boolean(), server_default="false"),
            sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        )

    # ── Expenses ──
    if not _exists("expenses"):
        op.create_table(
            "expenses",
            sa.Column("id", postgresql.UUID(), primary_key=True),
            sa.Column("organization_id", postgresql.UUID(), sa.ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True),
            sa.Column("expense_no", sa.String(50), nullable=False),
            sa.Column("category", sa.String(100), server_default=""),
            sa.Column("amount", sa.Numeric(12, 2), nullable=False),
            sa.Column("description", sa.Text(), server_default=""),
            sa.Column("payment_method", sa.String(20), server_default="cash"),
            sa.Column("expense_date", sa.DateTime(timezone=True), nullable=True),
            sa.Column("is_deleted", sa.Boolean(), server_default="false"),
            sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        )

    # ── Cheques ──
    if not _exists("cheques"):
        op.create_table(
            "cheques",
            sa.Column("id", postgresql.UUID(), primary_key=True),
            sa.Column("organization_id", postgresql.UUID(), sa.ForeignKey("organizations.id", ondelete="CASCADE"), nullable=False, index=True),
            sa.Column("cheque_number", sa.String(50), nullable=False),
            sa.Column("amount", sa.Numeric(12, 2), nullable=False),
            sa.Column("status", sa.String(20), server_default="pending"),
            sa.Column("payee_name", sa.String(200), nullable=True),
            sa.Column("bank_name", sa.String(200), nullable=True),
            sa.Column("issue_date", sa.DateTime(timezone=True), nullable=True),
            sa.Column("due_date", sa.DateTime(timezone=True), nullable=True),
            sa.Column("is_deleted", sa.Boolean(), server_default="false"),
            sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        )


def downgrade():
    for table in ("cheques", "expenses", "financial_payments", "bank_transactions", "bank_accounts"):
        if _exists(table):
            op.drop_table(table)
