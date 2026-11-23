"""Preserve schema used by the connected Business workflow."""

from alembic import op

revision = "116"
down_revision = "115"
branch_labels = None
depends_on = None


def upgrade():
    if op.get_context().dialect.name == "postgresql":
        op.execute("ALTER TABLE cheques ADD COLUMN IF NOT EXISTS branch_id uuid REFERENCES branches(id)")
        op.execute("CREATE INDEX IF NOT EXISTS ix_cheques_branch_id ON cheques(branch_id)")


def downgrade():
    pass
