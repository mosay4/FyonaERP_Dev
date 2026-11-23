import pytest
from uuid import uuid4
from datetime import datetime, timezone, date
from unittest.mock import AsyncMock, MagicMock
from decimal import Decimal
from app.domain.models.sales_models import SalesOrderCreate, SalesOrderItemCreate
from app.domain.services.sales_service import SalesService
from app.domain.entities.sales_entities import SalesOrder, SalesOrderItem


@pytest.fixture
def org_id():
    return uuid4()


@pytest.fixture
def user_id():
    return uuid4()


@pytest.fixture
def service():
    return SalesService(
        AsyncMock(),
        AsyncMock(),
        AsyncMock(),
        AsyncMock(),
        AsyncMock(),
        AsyncMock(),
        AsyncMock(),
        AsyncMock(),
    )


def mock_so(org_id, **kw):
    o = MagicMock(spec=SalesOrder)
    o.id = uuid4()
    o.organization_id = org_id
    o.order_number = "SO-001"
    o.customer_id = None
    o.customer = None
    o.order_date = date.today()
    o.status = "draft"
    o.subtotal = Decimal("100")
    o.discount_type = None
    o.discount_value = Decimal("0")
    o.discount_amount = Decimal("0")
    o.tax_type = None
    o.tax_rate = Decimal("0")
    o.tax_amount = Decimal("0")
    o.total = Decimal("100")
    o.paid_amount = Decimal("0")
    o.balance = Decimal("100")
    o.notes = None
    o.terms = None
    o.created_at = datetime.now(timezone.utc)
    o.updated_at = datetime.now(timezone.utc)
    o.confirmed_at = None
    o.delivered_at = None
    o.cancelled_at = None
    o.items = []
    for k, v in kw.items():
        setattr(o, k, v)
    return o


def mock_item(**kw):
    i = MagicMock(spec=SalesOrderItem)
    i.id = uuid4()
    i.sales_order_id = uuid4()
    i.product_id = None
    i.product = None
    i.description = "test item"
    i.quantity = 1
    i.unit_price = Decimal("100")
    i.discount = Decimal("0")
    i.tax_rate = Decimal("0")
    i.total = Decimal("100")
    for k, v in kw.items():
        setattr(i, k, v)
    return i


class TestSalesOrderService:
    async def test_create_so(self, service, org_id, user_id):
        m = mock_so(org_id, items=[mock_item()], total=Decimal("100"))
        service._so_repo.create.return_value = m
        service._so_repo.get_by_id.return_value = m
        service._so_repo.get_next_sequence.return_value = 1
        data = SalesOrderCreate(
            items=[
                SalesOrderItemCreate(
                    description="item", quantity=2, unit_price=Decimal("50")
                )
            ]
        )
        r = await service.create_sales_order(org_id, user_id, data)
        assert r is not None

    async def test_create_so_no_items(self, service, org_id, user_id):
        with pytest.raises(ValueError, match="بند"):
            await service.create_sales_order(
                org_id, user_id, SalesOrderCreate(items=[])
            )

    async def test_get_so_not_found(self, service, org_id):
        service._so_repo.get_by_id.return_value = None
        with pytest.raises(ValueError):
            await service.get_sales_order(uuid4(), org_id)

    async def test_confirm_so(self, service, org_id, user_id):
        mock = mock_so(org_id, status="draft", items=[mock_item()])
        service._so_repo.get_by_id.return_value = mock
        service._so_repo.update.return_value = mock
        r = await service.confirm_sales_order(mock.id, org_id, user_id)
        assert r.status == "confirmed"

    async def test_cancel_so(self, service, org_id, user_id):
        mock = mock_so(org_id, status="confirmed", items=[mock_item()])
        service._so_repo.get_by_id.return_value = mock
        service._so_repo.update.return_value = mock
        r = await service.cancel_sales_order(mock.id, org_id, user_id)
        assert r.status == "cancelled"

    async def test_delete_draft_so(self, service, org_id):
        mock = mock_so(org_id, status="draft", items=[])
        service._so_repo.get_by_id.return_value = mock
        await service.delete_sales_order(mock.id, org_id)
        service._so_repo.soft_delete.assert_awaited_once()

    async def test_delete_confirmed_so_fails(self, service, org_id):
        mock = mock_so(org_id, status="confirmed", items=[])
        service._so_repo.get_by_id.return_value = mock
        with pytest.raises(ValueError):
            await service.delete_sales_order(mock.id, org_id)
