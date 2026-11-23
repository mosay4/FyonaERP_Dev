"""Personal budget v2: multi-budget, periods, categories

Revision ID: 032
Revises: 031
Create Date: 2026-09-03
"""
from alembic import op
import sqlalchemy as sa

revision = "032"
down_revision = "031"
branch_labels = None
depends_on = None


def _existing_columns(table: str) -> set:
    insp = sa.inspect(op.get_bind())
    return {c["name"] for c in insp.get_columns(table)}


def _existing_tables() -> set:
    insp = sa.inspect(op.get_bind())
    return set(insp.get_table_names())


def _add_column_if_missing(table: str, column: sa.Column) -> None:
    """Idempotent ADD COLUMN: migration 025 (create_all from metadata) already
    creates current-model columns on a FRESH database, while older databases
    genuinely need them added here."""
    if column.name not in _existing_columns(table):
        op.add_column(table, column)


def upgrade():
    # Add new columns to personal_budgets
    _add_column_if_missing("personal_budgets", sa.Column("name", sa.String(200), nullable=True))
    _add_column_if_missing("personal_budgets", sa.Column("period_type", sa.String(30), server_default="monthly", nullable=False))
    _add_column_if_missing("personal_budgets", sa.Column("start_date", sa.DateTime(timezone=True), nullable=True))
    _add_column_if_missing("personal_budgets", sa.Column("end_date", sa.DateTime(timezone=True), nullable=True))
    _add_column_if_missing("personal_budgets", sa.Column("custom_days", sa.Integer(), nullable=True))
    _add_column_if_missing("personal_budgets", sa.Column("total_amount", sa.Numeric(12, 2), nullable=True))
    _add_column_if_missing("personal_budgets", sa.Column("bank_account_ids", sa.JSON(), server_default="[]", nullable=False))
    _add_column_if_missing("personal_budgets", sa.Column("budget_types", sa.JSON(), server_default='["expenses"]', nullable=False))

    # Migrate legacy data: category -> name, amount -> total_amount
    op.execute("""
        UPDATE personal_budgets
        SET name = COALESCE(name, category),
            total_amount = COALESCE(total_amount, amount)
        WHERE name IS NULL OR total_amount IS NULL
    """)

    # Make legacy columns nullable
    op.alter_column("personal_budgets", "category", nullable=True)
    op.alter_column("personal_budgets", "amount", nullable=True)
    op.alter_column("personal_budgets", "month", nullable=True)
    op.alter_column("personal_budgets", "year", nullable=True)

    # Create budget categories table
    if "personal_budget_categories" not in _existing_tables():
        op.create_table(
            "personal_budget_categories",
            sa.Column("id", sa.UUID(), primary_key=True),
            sa.Column("budget_id", sa.UUID(), sa.ForeignKey("personal_budgets.id", ondelete="CASCADE"), nullable=False, index=True),
            sa.Column("name", sa.String(100), nullable=False),
            sa.Column("type", sa.String(20), nullable=False),
            sa.Column("allocated_amount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("spent_amount", sa.Numeric(12, 2), server_default="0"),
            sa.Column("currency", sa.String(10), server_default="SAR"),
            sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
            sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        )


def downgrade():
    op.drop_table("personal_budget_categories")
    op.drop_column("personal_budgets", "budget_types")
    op.drop_column("personal_budgets", "bank_account_ids")
    op.drop_column("personal_budgets", "total_amount")
    op.drop_column("personal_budgets", "custom_days")
    op.drop_column("personal_budgets", "end_date")
    op.drop_column("personal_budgets", "start_date")
    op.drop_column("personal_budgets", "period_type")
    op.drop_column("personal_budgets", "name")
