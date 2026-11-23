"""Convert Float columns to Numeric(12,2) for all monetary fields

Revision ID: 006
Revises: 005
Create Date: 2026-07-14
"""

from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "006"
down_revision: Union[str, None] = "005"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _col_exists(table: str, column: str) -> bool:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT column_name FROM information_schema.columns WHERE table_name = :t AND column_name = :c"
        ),
        {"t": table, "c": column},
    )
    return result.scalar() is not None


def _get_type(table: str, column: str) -> str:
    conn = op.get_bind()
    result = conn.execute(
        sa.text(
            "SELECT data_type FROM information_schema.columns WHERE table_name = :t AND column_name = :c"
        ),
        {"t": table, "c": column},
    )
    return result.scalar() or ""


def _alter(table: str, column: str, type_str: str) -> None:
    if (
        _col_exists(table, column)
        and _get_type(table, column)
        != type_str.replace("(", "").replace(")", "").split("(")[0]
    ):
        op.alter_column(
            table,
            column,
            type_=sa.Text(type_str),
            postgresql_using=f"{column}::numeric(12,2)",
        )


def upgrade() -> None:
    # Customers
    if _col_exists("customers", "credit_limit"):
        op.alter_column(
            "customers",
            "credit_limit",
            type_=sa.Numeric(12, 2),
            postgresql_using="credit_limit::numeric(12,2)",
        )

    # Products
    for col in ["price", "cost_price"]:
        if _col_exists("products", col):
            op.alter_column(
                "products",
                col,
                type_=sa.Numeric(12, 2),
                postgresql_using=f"{col}::numeric(12,2)",
            )

    # Inventory Movements
    for col in ["unit_price", "total"]:
        if _col_exists("inventory_movements", col):
            op.alter_column(
                "inventory_movements",
                col,
                type_=sa.Numeric(12, 2),
                postgresql_using=f"{col}::numeric(12,2)",
            )

    # Invoices
    for col in [
        "subtotal",
        "discount_value",
        "discount_amount",
        "tax_amount",
        "total",
        "paid_amount",
        "balance",
    ]:
        if _col_exists("invoices", col):
            op.alter_column(
                "invoices",
                col,
                type_=sa.Numeric(12, 2),
                postgresql_using=f"{col}::numeric(12,2)",
            )

    # Invoice tax_rate (5,2)
    if _col_exists("invoices", "tax_rate"):
        op.alter_column(
            "invoices",
            "tax_rate",
            type_=sa.Numeric(5, 2),
            postgresql_using="tax_rate::numeric(5,2)",
        )

    # Invoice Items
    for col in ["unit_price", "discount", "total"]:
        if _col_exists("invoice_items", col):
            op.alter_column(
                "invoice_items",
                col,
                type_=sa.Numeric(12, 2),
                postgresql_using=f"{col}::numeric(12,2)",
            )
    if _col_exists("invoice_items", "tax_rate"):
        op.alter_column(
            "invoice_items",
            "tax_rate",
            type_=sa.Numeric(5, 2),
            postgresql_using="tax_rate::numeric(5,2)",
        )

    # Payments
    if _col_exists("payments", "amount"):
        op.alter_column(
            "payments",
            "amount",
            type_=sa.Numeric(12, 2),
            postgresql_using="amount::numeric(12,2)",
        )

    # Add server_default for new schema columns
    with op.get_context().autocommit_block():
        for col in [
            "subtotal",
            "discount_value",
            "discount_amount",
            "tax_amount",
            "total",
            "paid_amount",
            "balance",
            "credit_limit",
            "price",
            "cost_price",
            "unit_price",
            "discount",
            "amount",
        ]:
            pass  # defaults handled by ORM + CheckConstraint


def downgrade() -> None:
    pass
