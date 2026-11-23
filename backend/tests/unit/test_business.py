import pytest
from uuid import uuid4
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock
from types import SimpleNamespace
from app.domain.models.business_models import (
    CustomerCreate,
    CustomerUpdate,
    SupplierCreate,
    CategoryCreate,
    ProductCreate,
    InventoryMovementCreate,
)
from app.domain.services.business_service import BusinessService
from app.domain.entities.business_entities import (
    Customer,
    Supplier,
    ProductCategory,
    Product,
    InventoryMovement,
)
from app.domain.entities.sale_entities import Branch, BranchStock


@pytest.fixture
def org_id():
    return uuid4()


@pytest.fixture
def user_id():
    return uuid4()


def make_mock_customer(org_id, **overrides):
    c = MagicMock(spec=Customer)
    c.id = uuid4()
    c.organization_id = org_id
    c.branch_id = None
    c.name = "test customer"
    c.phone = None
    c.email = None
    c.tax_number = None
    c.cr_number = None
    c.address = None
    c.contact_person = None
    c.notes = None
    c.credit_limit = 0
    c.is_active = True
    c.created_at = datetime.now(timezone.utc)
    c.updated_at = datetime.now(timezone.utc)
    for k, v in overrides.items():
        setattr(c, k, v)
    return c


def make_mock_product(org_id, **overrides):
    p = MagicMock(spec=Product)
    p.id = uuid4()
    p.organization_id = org_id
    p.branch_id = None
    p.category_id = None
    p.category = None
    p.name = "test product"
    p.name_ar = None
    p.sku = None
    p.barcode = None
    p.description = None
    p.unit = "قطعة"
    p.price = 100
    p.cost_price = 0
    p.cost_currency = ''
    p.stock = 10
    p.min_stock = 0
    p.is_service = False
    p.is_active = True
    p.image = None
    p.notes = None
    p.expiry_date = None
    p.created_at = datetime.now(timezone.utc)
    p.updated_at = datetime.now(timezone.utc)
    for k, v in overrides.items():
        setattr(p, k, v)
    return p


def make_mock_movement(org_id, user_id, product_id, **overrides):
    m = MagicMock(spec=InventoryMovement)
    m.id = uuid4()
    m.organization_id = org_id
    m.product_id = product_id
    m.movement_type = "sale"
    m.quantity = -5
    m.unit_price = 100
    m.total = 500
    m.reference_type = None
    m.reference_id = None
    m.notes = None
    m.reason = None
    m.old_quantity = None
    m.new_quantity = None
    m.difference = None
    m.created_at = datetime.now(timezone.utc)
    for k, v in overrides.items():
        setattr(m, k, v)
    return m


@pytest.fixture
def service(org_id):
    # AsyncSession.execute is async; its Result/scalar/scalars accessors are
    # synchronous. Modeling both as AsyncMock used to produce false duplicates,
    # invalid Pydantic field values and coroutine-as-branch errors.
    session = MagicMock()
    session.bind = SimpleNamespace(dialect=SimpleNamespace(name='sqlite'))
    session.flush = AsyncMock()
    session.refresh = AsyncMock()
    branch = Branch(id=uuid4(), organization_id=org_id, name='Main', is_default=True)
    stock = {}
    def add(row):
        if isinstance(row, BranchStock):
            stock[row.product_id] = row
    session.add.side_effect = add
    async def execute(statement):
        result = MagicMock()
        result.all.return_value = []
        result.scalars.return_value.all.return_value = []
        result.scalar_one_or_none.return_value = None
        descriptions = getattr(statement, 'column_descriptions', [])
        expression = descriptions[0].get('expr') if descriptions else None
        if expression is Branch:
            result.scalar_one_or_none.return_value = branch
        elif expression is Branch.is_default:
            result.scalar_one_or_none.return_value = True
        elif expression is BranchStock:
            params = statement.compile().params
            product_id = next((value for key, value in params.items()
                               if key.startswith('product_id')), None)
            result.scalar_one_or_none.return_value = stock.get(product_id)
        return result
    session.execute = AsyncMock(side_effect=execute)
    service = BusinessService(
        customer_repo=AsyncMock(),
        supplier_repo=AsyncMock(),
        category_repo=AsyncMock(),
        product_repo=AsyncMock(),
        inventory_repo=AsyncMock(),
    )
    for repo in (service._customer_repo, service._supplier_repo, service._category_repo,
                 service._product_repo, service._inventory_repo):
        repo._session = session
    return service


class TestCustomerService:
    async def test_create_customer(self, service, org_id):
        mock = make_mock_customer(org_id)
        service._customer_repo.create.return_value = mock
        data = CustomerCreate(name="test customer")
        result = await service.create_customer(org_id, data)
        assert result.name == "test customer"
        service._customer_repo.create.assert_awaited_once()

    async def test_get_customer_not_found(self, service, org_id):
        service._customer_repo.get_by_id.return_value = None
        with pytest.raises(ValueError, match="العميل غير موجود"):
            await service.get_customer(uuid4(), org_id)

    async def test_get_customer_found(self, service, org_id):
        mock = make_mock_customer(org_id)
        service._customer_repo.get_by_id.return_value = mock
        result = await service.get_customer(mock.id, org_id)
        assert result.id == mock.id

    async def test_update_customer(self, service, org_id):
        mock = make_mock_customer(org_id)
        service._customer_repo.get_by_id.return_value = mock
        service._customer_repo.update.return_value = make_mock_customer(
            org_id, name="updated"
        )
        data = CustomerUpdate(name="updated")
        result = await service.update_customer(mock.id, org_id, data)
        assert result.name == "updated"

    async def test_delete_customer(self, service, org_id):
        mock = make_mock_customer(org_id)
        service._customer_repo.get_by_id.return_value = mock
        await service.delete_customer(mock.id, org_id)
        service._customer_repo.soft_delete.assert_awaited_once()

    async def test_list_customers(self, service, org_id):
        service._customer_repo.list.return_value = ([], 0)
        items, total = await service.list_customers(org_id)
        assert total == 0
        assert items == []

    async def test_list_customers_with_results(self, service, org_id):
        mock = make_mock_customer(org_id)
        service._customer_repo.list.return_value = ([mock], 1)
        items, total = await service.list_customers(org_id)
        assert total == 1
        assert len(items) == 1


class TestSupplierService:
    async def test_create_supplier(self, service, org_id):
        mock = MagicMock(spec=Supplier)
        mock.id = uuid4()
        mock.organization_id = org_id
        mock.branch_id = None
        mock.name = "test supplier"
        mock.phone = None
        mock.email = None
        mock.tax_number = None
        mock.cr_number = None
        mock.address = None
        mock.contact_person = None
        mock.notes = None
        mock.is_active = True
        mock.created_at = datetime.now(timezone.utc)
        mock.updated_at = datetime.now(timezone.utc)
        service._supplier_repo.create.return_value = mock
        data = SupplierCreate(name="test supplier")
        result = await service.create_supplier(org_id, data)
        assert result.name == "test supplier"

    async def test_get_supplier_not_found(self, service, org_id):
        service._supplier_repo.get_by_id.return_value = None
        with pytest.raises(ValueError, match="المورد غير موجود"):
            await service.get_supplier(uuid4(), org_id)


class TestCategoryService:
    async def test_create_category(self, service, org_id):
        mock = MagicMock(spec=ProductCategory)
        mock.id = uuid4()
        mock.organization_id = org_id
        mock.name = "test category"
        mock.name_ar = None
        mock.description = None
        mock.image = None
        mock.is_active = True
        mock.created_at = datetime.now(timezone.utc)
        service._category_repo.create.return_value = mock
        data = CategoryCreate(name="test category")
        result = await service.create_category(org_id, data)
        assert result.name == "test category"

    async def test_list_categories(self, service, org_id):
        service._category_repo.list.return_value = []
        result = await service.list_categories(org_id)
        assert result == []


class TestProductService:
    async def test_create_product(self, service, org_id):
        service._product_repo.get_by_sku.return_value = None
        service._product_repo.get_by_barcode.return_value = None
        mock = make_mock_product(org_id)
        service._product_repo.create.return_value = mock
        data = ProductCreate(name="test product", price=100)
        result = await service.create_product(org_id, data)
        assert result.name == "test product"
        service._product_repo.create.assert_awaited_once()

    async def test_create_product_duplicate_sku(self, service, org_id):
        mock = make_mock_product(org_id, sku="TEST123")
        service._product_repo.get_by_sku.return_value = mock
        data = ProductCreate(name="test", sku="TEST123", price=50)
        with pytest.raises(ValueError, match="رمز SKU موجود مسبقاً"):
            await service.create_product(org_id, data)

    async def test_get_product_found(self, service, org_id):
        mock = make_mock_product(org_id)
        service._product_repo.get_by_id.return_value = mock
        result = await service.get_product(mock.id, org_id)
        assert result.id == mock.id

    async def test_get_product_not_found(self, service, org_id):
        service._product_repo.get_by_id.return_value = None
        with pytest.raises(ValueError, match="المنتج غير موجود"):
            await service.get_product(uuid4(), org_id)

    async def test_update_product(self, service, org_id):
        mock = make_mock_product(org_id)
        service._product_repo.get_by_id.return_value = mock
        service._product_repo.update.return_value = make_mock_product(
            org_id, name="updated", price=200
        )
        result = await service.update_product(
            mock.id, org_id, ProductCreate(name="updated", price=200)
        )
        assert result is not None

    async def test_delete_product(self, service, org_id):
        mock = make_mock_product(org_id)
        service._product_repo.get_by_id.return_value = mock
        await service.delete_product(mock.id, org_id)
        service._product_repo.soft_delete.assert_awaited_once()

    async def test_list_products(self, service, org_id):
        mock = make_mock_product(org_id)
        service._product_repo.list.return_value = ([mock], 1)
        items, total = await service.list_products(org_id)
        assert total == 1


class TestInventoryService:
    async def test_record_movement(self, service, org_id, user_id):
        product_id = uuid4()
        mock_product = make_mock_product(org_id, id=product_id, stock=10)
        service._product_repo.get_by_id.return_value = mock_product
        mock_movement = make_mock_movement(org_id, user_id, product_id)
        service._inventory_repo.create.return_value = mock_movement

        data = InventoryMovementCreate(
            product_id=product_id,
            movement_type="sale",
            quantity=-5,
            unit_price=100,
        )
        result = await service.record_movement(org_id, user_id, data)
        assert result is not None
        service._inventory_repo.create.assert_awaited_once()
        assert mock_product.stock == 5
        assert result.quantity == -5 and result.total == 500

    async def test_record_movement_insufficient_stock(self, service, org_id, user_id):
        mock_product = make_mock_product(org_id, stock=2)
        service._product_repo.get_by_id.return_value = mock_product
        data = InventoryMovementCreate(
            product_id=mock_product.id,
            movement_type="sale",
            quantity=-10,
            unit_price=100,
        )
        with pytest.raises(ValueError, match="الرصيد غير كافي"):
            await service.record_movement(org_id, user_id, data)
        assert mock_product.stock == 2
        service._inventory_repo.create.assert_not_awaited()
        service._product_repo.update.assert_not_awaited()

    async def test_record_movement_service_product(self, service, org_id, user_id):
        mock_product = make_mock_product(org_id, is_service=True)
        service._product_repo.get_by_id.return_value = mock_product
        data = InventoryMovementCreate(
            product_id=mock_product.id,
            movement_type="sale",
            quantity=-1,
            unit_price=100,
        )
        with pytest.raises(ValueError, match="منتج خدمي"):
            await service.record_movement(org_id, user_id, data)

    async def test_list_movements(self, service, org_id):
        service._inventory_repo.list.return_value = ([], 0)
        items, total = await service.list_movements(org_id)
        assert total == 0
