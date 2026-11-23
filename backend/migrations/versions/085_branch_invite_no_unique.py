"""Allow re-inviting after an expired/revoked invitation.

Pending duplicates are still prevented by an application-level check; the
old UNIQUE(branch, user, status) also blocked a second historical row.

Revision ID: 085
Revises: 084
"""
from alembic import op

revision = "085"
down_revision = "084"
branch_labels = None
depends_on = None


def upgrade():
    op.drop_constraint("uq_branch_invite_pending", "branch_invitations",
                       type_="unique")


def downgrade():
    op.create_unique_constraint("uq_branch_invite_pending", "branch_invitations",
                                ["branch_id", "invited_user_id", "status"])
