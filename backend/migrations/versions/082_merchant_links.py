"""Merchant ↔ Personal accounts: unique 6-digit user codes + link invitations
+ settlement-proof requests + debt groups + a real audit log.

Safe & additive:
  * `users.public_code` (nullable, UNIQUE) — backfilled for existing users from
    a permutation of a dedicated sequence (bijective on 0..999_999 → no
    collisions, capacity 1,000,000; beyond that a 7-digit code would be used).
  * new tables, no existing column is modified or removed.

Revision ID: 082
Revises: 081
"""

from alembic import op
import sqlalchemy as sa

revision = "082"
down_revision = "081"
branch_labels = None
depends_on = None

# bijective permutation of 0..999_999 (odd, not divisible by 5)
_A = 387420489


def upgrade():
    op.add_column("users", sa.Column("public_code", sa.String(6), nullable=True))
    op.create_unique_constraint("uq_users_public_code", "users", ["public_code"])
    op.create_index("ix_users_public_code", "users", ["public_code"])

    op.create_table(
        "user_code_seq",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("next_val", sa.BigInteger(), nullable=False, server_default="0"),
    )
    op.execute("INSERT INTO user_code_seq (id, next_val) VALUES (1, 0)")

    # Backfill existing users (deterministic, collision-free).
    op.execute(
        f"""
        WITH ordered AS (
            SELECT id, row_number() OVER (ORDER BY created_at, id) - 1 AS n
            FROM users
        )
        UPDATE users u
        SET public_code = lpad((((o.n * {_A}) % 1000000))::text, 6, '0')
        FROM ordered o
        WHERE u.id = o.id
        """
    )
    op.execute("UPDATE user_code_seq SET next_val = (SELECT count(*) FROM users)")

    op.create_table(
        "merchant_links",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column("merchant_org_id", sa.UUID(), nullable=False),
        sa.Column("party_kind", sa.String(10), nullable=False),  # customer|supplier
        sa.Column("party_id", sa.UUID(), nullable=False),
        sa.Column("external_user_id", sa.UUID(), nullable=True),
        sa.Column("phone", sa.String(50), nullable=True),
        sa.Column("public_code", sa.String(6), nullable=True),
        sa.Column("status", sa.String(12), nullable=False, server_default="pending"),
        sa.Column("display_name", sa.String(200), nullable=True),
        sa.Column("invited_by", sa.UUID(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("responded_at", sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint("merchant_org_id", "party_kind", "party_id",
                            name="uq_merchant_link_party"),
    )
    op.create_index("ix_merchant_links_external_user", "merchant_links",
                    ["external_user_id"])
    op.create_index("ix_merchant_links_phone", "merchant_links", ["phone"])

    op.create_table(
        "settlement_requests",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column("organization_id", sa.UUID(), nullable=False),
        sa.Column("party_kind", sa.String(10), nullable=False),
        sa.Column("party_id", sa.UUID(), nullable=False),
        sa.Column("link_id", sa.UUID(), nullable=True),
        sa.Column("external_user_id", sa.UUID(), nullable=True),
        sa.Column("amount", sa.Numeric(18, 4), nullable=False),
        sa.Column("currency", sa.String(10), nullable=False),
        sa.Column("method", sa.String(20), nullable=True),
        sa.Column("reference", sa.String(100), nullable=True),
        sa.Column("receipt_url", sa.String(500), nullable=True),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("status", sa.String(12), nullable=False, server_default="pending"),
        sa.Column("reject_reason", sa.Text(), nullable=True),
        sa.Column("idempotency_key", sa.String(80), nullable=True, unique=True),
        sa.Column("payment_id", sa.UUID(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("decided_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_settlement_requests_org_party", "settlement_requests",
                    ["organization_id", "party_kind", "party_id"])

    op.create_table(
        "debt_groups",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column("organization_id", sa.UUID(), nullable=False),
        sa.Column("party_kind", sa.String(10), nullable=False),
        sa.Column("party_id", sa.UUID(), nullable=False),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column("kind", sa.String(10), nullable=False, server_default="manual"),
        sa.Column("period", sa.String(10), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_debt_groups_org_party", "debt_groups",
                    ["organization_id", "party_kind", "party_id"])

    op.add_column("invoices", sa.Column("debt_group_id", sa.UUID(), nullable=True))

    op.create_table(
        "shared_audit_log",
        sa.Column("id", sa.UUID(), primary_key=True),
        sa.Column("organization_id", sa.UUID(), nullable=False),
        sa.Column("entity_type", sa.String(30), nullable=False),
        sa.Column("entity_id", sa.String(60), nullable=True),
        sa.Column("action", sa.String(30), nullable=False),
        sa.Column("before_json", sa.Text(), nullable=True),
        sa.Column("after_json", sa.Text(), nullable=True),
        sa.Column("reason", sa.Text(), nullable=True),
        sa.Column("actor_user_id", sa.UUID(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_shared_audit_org", "shared_audit_log", ["organization_id"])


def downgrade():
    op.drop_table("shared_audit_log")
    op.drop_column("invoices", "debt_group_id")
    op.drop_table("debt_groups")
    op.drop_table("settlement_requests")
    op.drop_table("merchant_links")
    op.drop_table("user_code_seq")
    op.drop_index("ix_users_public_code", table_name="users")
    op.drop_constraint("uq_users_public_code", "users", type_="unique")
    op.drop_column("users", "public_code")
