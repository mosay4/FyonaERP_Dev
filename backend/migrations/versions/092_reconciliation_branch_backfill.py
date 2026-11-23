"""Attach legacy null-branch reconciliations to their real branch.

Revision ID: 092
Revises: 091
"""
import json

from alembic import op
from sqlalchemy import text

revision = "092"
down_revision = "091"
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    rows = bind.execute(text(
        "select id, rtype, lines_json from reconciliations "
        "where branch_id is null"
    )).fetchall()
    for rid, rtype, lines_raw in rows:
        try:
            lines = json.loads(lines_raw or "[]")
        except Exception:
            continue
        if not isinstance(lines, list) or not lines:
            continue
        branch_id = None
        if rtype == "bank":
            acc = lines[0].get("account_id") if isinstance(lines[0], dict) else None
            if acc:
                branch_id = bind.execute(text(
                    "select branch_id from bank_accounts where id=:id"
                ), {"id": acc}).scalar()
        elif rtype == "inventory":
            pid = lines[0].get("product_id") if isinstance(lines[0], dict) else None
            if pid:
                branch_id = bind.execute(text(
                    "select branch_id from products where id=:id"
                ), {"id": pid}).scalar()
        if branch_id is not None:
            bind.execute(text(
                "update reconciliations set branch_id=:b where id=:id"
            ), {"b": branch_id, "id": rid})


def downgrade():
    pass
