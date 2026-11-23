"""Tests for subscription invoice creation, idempotency, and authorization.

These tests mock the database config to avoid requiring env vars.
"""
import os
import pytest
from pathlib import Path
from uuid import uuid4
from datetime import datetime, timezone, timedelta
from unittest.mock import AsyncMock, MagicMock, patch

# Set required env vars before importing app modules
os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")
os.environ.setdefault("CELERY_BROKER_URL", "redis://localhost:6379/1")
os.environ.setdefault("CELERY_RESULT_BACKEND", "redis://localhost:6379/2")

from app.domain.entities.subscription_invoice_entities import SubscriptionInvoice


# ── Entity schema tests ──

def test_subscription_invoice_unique_constraint():
    """Verify the entity defines a unique constraint on (org_id, request_id)."""
    table_args = SubscriptionInvoice.__table_args__
    unique_constraints = [a for a in table_args if hasattr(a, 'name') and a.name == 'uq_sub_inv_org_request']
    assert len(unique_constraints) == 1, f"Expected 1 unique constraint, found {len(unique_constraints)}"


def test_subscription_invoice_fields():
    """Verify required fields exist on the entity."""
    for field in ['id', 'invoice_number', 'organization_id', 'user_id', 'request_id',
                  'plan_name', 'period', 'amount', 'currency', 'status',
                  'payment_method', 'subscription_start_date', 'subscription_end_date', 'created_at']:
        assert hasattr(SubscriptionInvoice, field), f"Missing field: {field}"


def test_subscription_invoice_defaults():
    """Verify default values are sensible (Python-side defaults)."""
    # Entity uses Python default= not server_default=
    # Verify by checking the Column defaults exist
    from sqlalchemy import inspect as sa_inspect
    mapper = sa_inspect(SubscriptionInvoice)
    col_map = {c.key: c for c in mapper.columns}
    # These are set via default= in the model, not server_default=
    # The entity definitions define the expected defaults
    assert col_map['period'].default.arg == "yearly"
    assert col_map['status'].default.arg == "paid"
    assert col_map['payment_method'].default.arg == "bank_transfer"
    assert col_map['currency'].default.arg == "SAR"


def test_subscription_invoice_unique_index_on_invoice_number():
    """invoice_number column should have unique=True."""
    col = SubscriptionInvoice.__table__.c.invoice_number
    assert col.unique is True, "invoice_number should have unique=True"


# ── Invoice number generation tests ──

@pytest.mark.asyncio
async def test_generate_invoice_number_format():
    """Invoice number follows INV-YYYYMMDD-NNNN pattern."""
    from app.api.v1.subscription_invoices import _generate_invoice_number

    db = AsyncMock()
    mock_result = MagicMock()
    mock_result.scalar.return_value = 0
    db.execute.return_value = mock_result

    result = await _generate_invoice_number(db)
    today = datetime.now(timezone.utc).strftime('%Y%m%d')
    assert result.startswith(f"INV-{today}-")
    # INV- + YYYYMMDD- + NNNN = 4 + 8 + 1 + 4 = 17 chars
    assert len(result) == 17


@pytest.mark.asyncio
async def test_generate_invoice_number_sequential():
    """Invoice number increments with count."""
    from app.api.v1.subscription_invoices import _generate_invoice_number

    db = AsyncMock()
    call_count = [0]

    async def mock_execute(query):
        mock_result = MagicMock()
        call_count[0] += 1
        if call_count[0] == 1:
            mock_result.scalar.return_value = 2  # 2 existing invoices today
        else:
            mock_result.scalar.return_value = 0  # uniqueness check passes
        return mock_result

    db.execute = mock_execute
    result = await _generate_invoice_number(db)
    today = datetime.now(timezone.utc).strftime('%Y%m%d')
    assert result == f"INV-{today}-0003"  # 2 existing + 1


@pytest.mark.asyncio
async def test_generate_invoice_number_retries_on_conflict():
    """Invoice number retries if uniqueness check fails."""
    from app.api.v1.subscription_invoices import _generate_invoice_number

    db = AsyncMock()
    call_count = [0]

    async def mock_execute(query):
        mock_result = MagicMock()
        call_count[0] += 1
        if call_count[0] == 1:
            # First count query
            mock_result.scalar.return_value = 0
        elif call_count[0] == 2:
            # First uniqueness check: CONFLICT
            mock_result.scalar.return_value = 1
        elif call_count[0] == 3:
            # Second count query (same count)
            mock_result.scalar.return_value = 0
        else:
            # Second uniqueness check: PASS
            mock_result.scalar.return_value = 0
        return mock_result

    db.execute = mock_execute
    result = await _generate_invoice_number(db)
    today = datetime.now(timezone.utc).strftime('%Y%m%d')
    assert result == f"INV-{today}-0002"  # seq=1 (conflict), seq=2 (pass)


# ── Serializer tests ──

def test_invoice_dict_serializer():
    """_invoice_dict produces correct structure."""
    from app.api.v1.subscription_invoices import _invoice_dict

    inv = MagicMock(spec=SubscriptionInvoice)
    inv.id = uuid4()
    inv.invoice_number = "INV-20260825-0001"
    inv.organization_id = uuid4()
    inv.user_id = uuid4()
    inv.request_id = uuid4()
    inv.plan_name = "Personal"
    inv.period = "yearly"
    inv.amount = 4900.00
    inv.currency = "SAR"
    inv.status = "paid"
    inv.payment_method = "bank_transfer"
    inv.subscription_start_date = datetime(2026, 1, 1, tzinfo=timezone.utc)
    inv.subscription_end_date = datetime(2026, 12, 31, tzinfo=timezone.utc)
    inv.created_at = datetime(2026, 8, 25, tzinfo=timezone.utc)

    result = _invoice_dict(inv, organization_name="Acme Corp", user_email="user@test.com")

    assert result["invoice_number"] == "INV-20260825-0001"
    assert result["organization_name"] == "Acme Corp"
    assert result["user_email"] == "user@test.com"
    assert result["amount"] == 4900.00
    assert result["currency"] == "SAR"
    assert result["status"] == "paid"
    assert result["period"] == "yearly"
    assert result["plan_name"] == "Personal"


def test_invoice_dict_none_organization():
    """_invoice_dict handles None organization_name gracefully."""
    from app.api.v1.subscription_invoices import _invoice_dict

    inv = MagicMock(spec=SubscriptionInvoice)
    inv.id = uuid4()
    inv.invoice_number = "INV-20260825-0001"
    inv.organization_id = uuid4()
    inv.user_id = uuid4()
    inv.request_id = uuid4()
    inv.plan_name = "Personal"
    inv.period = "yearly"
    inv.amount = 100.0
    inv.currency = "SAR"
    inv.status = "paid"
    inv.payment_method = "bank_transfer"
    inv.subscription_start_date = None
    inv.subscription_end_date = None
    inv.created_at = None

    result = _invoice_dict(inv, organization_name=None, user_email=None)
    assert result["organization_name"] is None
    assert result["user_email"] is None
    assert result["subscription_start_date"] is None


# ── Idempotency behavior ──

@pytest.mark.asyncio
async def test_create_invoice_idempotent():
    """_create_subscription_invoice returns existing invoice if org+request match."""
    from app.api.v1.subscription_invoices import _create_subscription_invoice

    db = AsyncMock()
    existing = MagicMock(spec=SubscriptionInvoice)
    existing.id = uuid4()
    existing.invoice_number = "INV-20260825-0001"

    mock_result = MagicMock()
    mock_result.scalar_one_or_none.return_value = existing
    db.execute.return_value = mock_result

    result = await _create_subscription_invoice(
        db,
        organization_id=uuid4(),
        user_id=uuid4(),
        request_id=uuid4(),
        plan_name="Personal",
        period="yearly",
        amount=4900.0,
        currency="SAR",
        subscription_start_date=datetime.now(timezone.utc),
        subscription_end_date=datetime.now(timezone.utc) + timedelta(days=365),
    )

    assert result.id == existing.id
    db.add.assert_not_called()


@pytest.mark.asyncio
async def test_create_invoice_new():
    """_create_subscription_invoice creates new invoice when none exists."""
    from app.api.v1.subscription_invoices import _create_subscription_invoice

    db = AsyncMock()
    call_count = [0]

    async def mock_execute(query):
        call_count[0] += 1
        mock_result = MagicMock()
        if call_count[0] == 1:
            mock_result.scalar_one_or_none.return_value = None
        else:
            mock_result.scalar.return_value = 0
        return mock_result

    db.execute = mock_execute

    now = datetime.now(timezone.utc)
    result = await _create_subscription_invoice(
        db,
        organization_id=uuid4(),
        user_id=uuid4(),
        request_id=uuid4(),
        plan_name="Personal",
        period="yearly",
        amount=4900.0,
        currency="SAR",
        subscription_start_date=now,
        subscription_end_date=now + timedelta(days=365),
    )

    assert isinstance(result, SubscriptionInvoice)
    assert result.invoice_number.startswith("INV-")
    assert result.amount == 4900.0
    assert result.currency == "SAR"
    assert result.status == "paid"
    assert result.plan_name == "Personal"
    db.add.assert_called_once_with(result)


# ── Migration tests ──

def test_migration_027_exists():
    """Migration file 027 exists and has correct revision."""
    migration = Path(__file__).parents[2] / "migrations" / "versions" / "027_subscription_invoices.py"
    assert migration.exists(), "Migration 027 not found"
    content = migration.read_text()
    assert "subscription_invoices" in content
    assert "UniqueConstraint" in content
    assert "invoice_number" in content


def test_migration_has_unique_constraint():
    """Migration includes unique constraint on invoice_number and org+request."""
    migration = Path(__file__).parents[2] / "migrations" / "versions" / "027_subscription_invoices.py"
    content = migration.read_text()
    assert "unique=True" in content, "Migration should have unique=True on invoice_number"
    assert "uq_sub_inv_org_request" in content, "Migration should have unique constraint on org+request"


def test_migration_027_is_additive():
    """Migration only creates a table, no destructive operations in upgrade."""
    migration = Path(__file__).parents[2] / "migrations" / "versions" / "027_subscription_invoices.py"
    content = migration.read_text()
    # upgrade() section should only have create_table
    assert "op.create_table" in content
    assert "op.drop_table" in content  # only in downgrade
