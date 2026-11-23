"""Preserve schema used by the connected Business workflow."""

from alembic import op

revision = "118"
down_revision = "117"
branch_labels = None
depends_on = None


def upgrade():
    if op.get_context().dialect.name == "postgresql":
        op.execute("""
CREATE TABLE IF NOT EXISTS branch_transfer_lot_moves (
 id uuid PRIMARY KEY,
 transfer_item_id uuid NOT NULL REFERENCES branch_transfer_items(id) ON DELETE CASCADE,
 source_lot_id uuid NOT NULL REFERENCES inventory_lots(id) ON DELETE RESTRICT,
 target_lot_id uuid NOT NULL REFERENCES inventory_lots(id) ON DELETE RESTRICT,
 source_quantity numeric(24,8) NOT NULL,
 target_quantity numeric(24,8) NOT NULL,
 returned_quantity numeric(24,8) NOT NULL DEFAULT 0
)
""")
        op.execute("CREATE INDEX IF NOT EXISTS ix_branch_transfer_lot_moves_transfer_item_id ON branch_transfer_lot_moves(transfer_item_id)")


def downgrade():
    pass
