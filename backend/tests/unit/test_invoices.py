import pytest
from uuid import uuid4
from datetime import datetime, timezone, date
from unittest.mock import AsyncMock, MagicMock
from app.domain.models.invoice_models import (
    InvoiceCreate,
    InvoiceUpdate,
    InvoiceItemCreate,
    PaymentCreate,
)
from app.domain.services.invoice_service import InvoiceService
from app.domain.entities.invoice_entities import Invoice, InvoiceItem, Payment
# Invoice / Payment relate to models in other modules (Customer, Supplier,
# BankAccount…): register every mapper before a Payment is built, also when
# this file runs on its own.
import importlib
import pkgutil

import app.domain.entities as _entities

for _m in pkgutil.iter_modules(_entities.__path__):
    importlib.import_module(f"app.domain.entities.{_m.name}")


@pytest.fixture
def org_id():
    return uuid4()


@pytest.fixture
def user_id():
    return uuid4()


@pytest.fixture
def service():
    return InvoiceService(
        invoice_repo=AsyncMock(),
        item_repo=AsyncMock(),
        payment_repo=AsyncMock(),
    )


def make_mock_item(**overrides):
    item = MagicMock(spec=InvoiceItem)
    item.id = uuid4()
    item.invoice_id = uuid4()
    item.product_id = None
    item.product = None
    item.description = "test item"
    item.quantity = 1
    item.unit_price = 100
    item.discount = 0
    item.tax_rate = 0
    item.total = 100
    # Unit columns added to InvoiceItem later: a spec'd MagicMock would
    # otherwise hand the response a mock where it expects a value.
    item.unit_id = None
    item.unit_name = None
    item.base_quantity = 0
    item.is_service = False
    for k, v in overrides.items():
        setattr(item, k, v)
    return item


def make_mock_payment(**overrides):
    p = MagicMock(spec=Payment)
    p.id = uuid4()
    p.invoice_id = uuid4()
    p.amount = 100
    p.payment_date = date.today()
    p.payment_method = "cash"
    p.reference = None
    p.notes = None
    p.created_at = datetime.now(timezone.utc)
    # Bank columns added to Payment later (cash payment: none).
    p.bank_account_id = None
    p.bank_account = None
    p.bank_account_name = None
    for k, v in overrides.items():
        setattr(p, k, v)
    return p


def make_mock_invoice(org_id, **overrides):
    inv = MagicMock(spec=Invoice)
    inv.id = uuid4()
    inv.organization_id = org_id
    inv.invoice_number = "INV-20260714-0001"
    inv.invoice_type = "sale"
    inv.currency = "SAR"
    inv.branch_id = None
    inv.customer_id = None
    inv.customer = None
    inv.supplier_id = None
    inv.supplier = None
    inv.invoice_date = date.today()
    inv.due_date = None
    inv.status = "draft"
    inv.subtotal = 100
    inv.discount_type = None
    inv.discount_value = 0
    inv.discount_amount = 0
    inv.tax_type = None
    inv.tax_rate = 0
    inv.tax_amount = 0
    inv.total = 100
    inv.paid_amount = 0
    inv.balance = 100
    inv.notes = None
    inv.terms = None
    inv.created_at = datetime.now(timezone.utc)
    inv.updated_at = datetime.now(timezone.utc)
    inv.confirmed_at = None
    inv.cancelled_at = None
    inv.items = []
    inv.payments = []
    for k, v in overrides.items():
        setattr(inv, k, v)
    return inv


class TestInvoiceService:
    async def test_create_invoice(self, service, org_id, user_id):
        mock_inv = make_mock_invoice(org_id, items=[make_mock_item()], payments=[])
        service._invoice_repo.create.return_value = mock_inv
        service._invoice_repo.get_by_id.return_value = mock_inv
        service._invoice_repo.get_next_sequence.return_value = 1

        items = [InvoiceItemCreate(description="item 1", quantity=2, unit_price=50)]
        data = InvoiceCreate(items=items)
        result = await service.create_invoice(org_id, user_id, data)
        assert result.invoice_number is not None
        service._invoice_repo.create.assert_awaited_once()

    async def test_create_invoice_no_items(self, service, org_id, user_id):
        data = InvoiceCreate(items=[])
        with pytest.raises(ValueError, match="بند واحد على الأقل"):
            await service.create_invoice(org_id, user_id, data)

    async def test_get_invoice_not_found(self, service, org_id):
        service._invoice_repo.get_by_id.return_value = None
        with pytest.raises(ValueError, match="الفاتورة غير موجودة"):
            await service.get_invoice(uuid4(), org_id)

    async def test_get_invoice_found(self, service, org_id):
        mock_inv = make_mock_invoice(org_id, items=[], payments=[])
        service._invoice_repo.get_by_id.return_value = mock_inv
        result = await service.get_invoice(mock_inv.id, org_id)
        assert result.id == mock_inv.id

    async def test_delete_draft_invoice(self, service, org_id):
        mock_inv = make_mock_invoice(org_id, status="draft")
        service._invoice_repo.get_by_id.return_value = mock_inv
        await service.delete_invoice(mock_inv.id, org_id)
        service._invoice_repo.soft_delete.assert_awaited_once()

    async def test_delete_confirmed_invoice_fails(self, service, org_id):
        mock_inv = make_mock_invoice(org_id, status="confirmed")
        service._invoice_repo.get_by_id.return_value = mock_inv
        with pytest.raises(ValueError, match="لا يمكن حذف"):
            await service.delete_invoice(mock_inv.id, org_id)

    async def test_list_invoices(self, service, org_id):
        service._invoice_repo.list.return_value = ([], 0)
        items, total = await service.list_invoices(org_id)
        assert total == 0

    async def test_confirm_invoice(self, service, org_id, user_id):
        mock_inv = make_mock_invoice(
            org_id, status="draft", items=[make_mock_item()], payments=[]
        )
        service._invoice_repo.get_by_id.return_value = mock_inv
        service._invoice_repo.update.return_value = mock_inv

        result = await service.confirm_invoice(mock_inv.id, org_id, user_id)
        assert result.status == "confirmed"

    async def test_confirm_already_confirmed_fails(self, service, org_id, user_id):
        mock_inv = make_mock_invoice(
            org_id, status="confirmed", items=[make_mock_item()], payments=[]
        )
        service._invoice_repo.get_by_id.return_value = mock_inv
        with pytest.raises(ValueError, match="المسودة فقط"):
            await service.confirm_invoice(mock_inv.id, org_id, user_id)

    async def test_cancel_invoice(self, service, org_id, user_id):
        mock_inv = make_mock_invoice(
            org_id,
            status="confirmed",
            items=[make_mock_item()],
            payments=[],
        )
        service._invoice_repo.get_by_id.return_value = mock_inv
        service._invoice_repo.cancel.return_value = mock_inv
        mock_inv.currency = 'SAR'
        mock_inv.branch_id = None
        # Explicit optional fields: MagicMock attributes are not valid UUIDs or
        # strings under the current Original invoice response schema.
        mock_inv.items[0].unit_id = None
        mock_inv.items[0].unit_name = None

        result = await service.cancel_invoice(mock_inv.id, org_id, user_id)
        assert result.status == "cancelled"
        service._invoice_repo.cancel.assert_awaited_once_with(mock_inv, user_id)
        assert service._invoice_repo.get_by_id.await_args_list[0].kwargs == {'lock': True}

    async def test_cancel_already_cancelled_fails(self, service, org_id, user_id):
        mock_inv = make_mock_invoice(
            org_id, status="cancelled", items=[make_mock_item()], payments=[]
        )
        service._invoice_repo.get_by_id.return_value = mock_inv
        with pytest.raises(ValueError, match="لا يمكن إلغاء"):
            await service.cancel_invoice(mock_inv.id, org_id, user_id)

    async def test_add_payment(self, service, org_id, user_id):
        mock_inv = make_mock_invoice(
            org_id,
            status="confirmed",
            total=200,
            paid_amount=0,
            balance=200,
            items=[make_mock_item()],
            payments=[make_mock_payment()],
        )
        service._invoice_repo.get_by_id.return_value = mock_inv
        service._payment_repo.create.return_value = MagicMock(spec=Payment)
        service._invoice_repo.update.return_value = mock_inv

        data = PaymentCreate(amount=100)
        result = await service.add_payment(mock_inv.id, org_id, user_id, data)
        assert result is not None

    async def test_add_payment_exceeds_balance(self, service, org_id, user_id):
        mock_inv = make_mock_invoice(
            org_id,
            status="confirmed",
            total=100,
            paid_amount=0,
            balance=100,
            items=[],
            payments=[],
        )
        service._invoice_repo.get_by_id.return_value = mock_inv
        data = PaymentCreate(amount=200)
        with pytest.raises(ValueError, match="الرصيد المتبقي"):
            await service.add_payment(mock_inv.id, org_id, user_id, data)

    async def test_add_payment_to_draft_fails(self, service, org_id, user_id):
        mock_inv = make_mock_invoice(org_id, status="draft", items=[], payments=[])
        service._invoice_repo.get_by_id.return_value = mock_inv
        data = PaymentCreate(amount=50)
        with pytest.raises(ValueError, match="المؤكدة فقط"):
            await service.add_payment(mock_inv.id, org_id, user_id, data)

    async def test_update_invoice_not_found(self, service, org_id, user_id):
        service._invoice_repo.get_by_id.return_value = None
        data = InvoiceUpdate()
        with pytest.raises(ValueError, match="الفاتورة غير موجودة"):
            await service.update_invoice(uuid4(), org_id, user_id, data)

    async def test_update_confirmed_invoice_fails(self, service, org_id, user_id):
        mock_inv = make_mock_invoice(org_id, status="confirmed", items=[], payments=[])
        service._invoice_repo.get_by_id.return_value = mock_inv
        data = InvoiceUpdate()
        with pytest.raises(ValueError, match="مؤكدة أو ملغية"):
            await service.update_invoice(mock_inv.id, org_id, user_id, data)
