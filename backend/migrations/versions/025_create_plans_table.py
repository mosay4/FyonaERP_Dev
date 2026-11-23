"""Create all model tables missing from the migration chain.

Migrations 001-005 create ~15 tables. Migration 002 then drops
subscription_plans and subscription_requests as "unused". However,
the entity models define 38 tables. The remaining tables were created
on production via Base.metadata.create_all() but never by alembic
migrations. This causes migrations 015+ (which ALTER or FK-reference
those tables) to fail on a fresh DB.

This migration runs Base.metadata.create_all() with checkfirst=True,
which creates only tables that don't already exist. It must run before
015, so down_revision = 014.

On production (already at 024), this migration is a no-op because
all tables already exist.

Revision ID: 025
Revises: 014
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "025"
down_revision: Union[str, None] = "014"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    bind = op.get_bind()

    # Import all entity models so Base.metadata is fully populated
    from app.core.database import Base
    import app.domain.entities.accounting_entities  # noqa: F401
    import app.domain.entities.admin_entities  # noqa: F401
    import app.domain.entities.analytics_entities  # noqa: F401
    import app.domain.entities.auth_entities  # noqa: F401
    import app.domain.entities.business_entities  # noqa: F401
    import app.domain.entities.finance_entities  # noqa: F401
    import app.domain.entities.hr_entities  # noqa: F401
    import app.domain.entities.invoice_entities  # noqa: F401
    import app.domain.entities.notification_entities  # noqa: F401
    import app.domain.entities.payment_entities  # noqa: F401
    import app.domain.entities.personal_entities  # noqa: F401
    import app.domain.entities.purchase_entities  # noqa: F401
    import app.domain.entities.push_entities  # noqa: F401
    import app.domain.entities.sales_entities  # noqa: F401
    import app.domain.entities.suggestions_entities  # noqa: F401
    import app.domain.entities.sync_entities  # noqa: F401

    # Create only tables that don't already exist (checkfirst=True)
    Base.metadata.create_all(bind=bind, checkfirst=True)


def downgrade() -> None:
    # Downgrade is not supported for this migration
    # as it would drop tables created by create_all
    # which may contain data
    pass
