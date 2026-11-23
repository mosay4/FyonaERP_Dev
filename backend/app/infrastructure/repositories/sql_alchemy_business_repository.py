from uuid import UUID
from typing import Optional, List, Tuple
from sqlalchemy import select, func, or_, update
from sqlalchemy.ext.asyncio import AsyncSession
from app.domain.entities.business_entities import (
    Customer,
    Supplier,
    ProductCategory,
    Product,
    InventoryMovement,
)
from app.domain.repositories.business_repository import (
    CustomerRepository,
    SupplierRepository,
    ProductCategoryRepository,
    ProductRepository,
    InventoryMovementRepository,
)


class SqlAlchemyCustomerRepository(CustomerRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, customer: Customer) -> Customer:
        self._session.add(customer)
        await self._session.flush()
        return customer

    async def get_by_id(self, customer_id: UUID, org_id: UUID) -> Optional[Customer]:
        stmt = select(Customer).where(
            Customer.id == customer_id,
            Customer.organization_id == org_id,
            ~Customer.is_deleted,
        )
        result = await self._session.execute(stmt)
        return result.unique().scalar_one_or_none()

    async def update(self, customer: Customer) -> Customer:
        self._session.add(customer)
        await self._session.flush()
        return customer

    async def soft_delete(self, customer_id: UUID, org_id: UUID) -> None:
        from datetime import datetime, timezone

        stmt = (
            update(Customer)
            .where(Customer.id == customer_id, Customer.organization_id == org_id)
            .values(is_deleted=True, deleted_at=datetime.now(timezone.utc))
        )
        await self._session.execute(stmt)
        await self._session.flush()

    async def list(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
        branch_id: Optional[UUID] = None,
        branch_ids: Optional[list] = None,
    ) -> Tuple[List[Customer], int]:
        query = select(Customer).where(
            Customer.organization_id == org_id, ~Customer.is_deleted
        )
        count_query = select(func.count(Customer.id)).where(
            Customer.organization_id == org_id, ~Customer.is_deleted
        )
        if branch_ids is not None:
            query = query.where(Customer.branch_id.in_(branch_ids))
            count_query = count_query.where(Customer.branch_id.in_(branch_ids))
        elif branch_id is not None:
            query = query.where(Customer.branch_id == branch_id)
            count_query = count_query.where(Customer.branch_id == branch_id)

        if search:
            search_filter = or_(
                Customer.name.ilike(f"%{search}%"),
                Customer.phone.ilike(f"%{search}%"),
                Customer.email.ilike(f"%{search}%"),
            )
            query = query.where(search_filter)
            count_query = count_query.where(search_filter)

        count_result = await self._session.execute(count_query)
        total = count_result.scalar() or 0

        query = (
            query.order_by(Customer.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        result = await self._session.execute(query)
        items = list(result.unique().scalars().all())

        return items, total


class SqlAlchemySupplierRepository(SupplierRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, supplier: Supplier) -> Supplier:
        self._session.add(supplier)
        await self._session.flush()
        return supplier

    async def get_by_id(self, supplier_id: UUID, org_id: UUID) -> Optional[Supplier]:
        stmt = select(Supplier).where(
            Supplier.id == supplier_id,
            Supplier.organization_id == org_id,
            ~Supplier.is_deleted,
        )
        result = await self._session.execute(stmt)
        return result.unique().scalar_one_or_none()

    async def update(self, supplier: Supplier) -> Supplier:
        self._session.add(supplier)
        await self._session.flush()
        return supplier

    async def soft_delete(self, supplier_id: UUID, org_id: UUID) -> None:
        from datetime import datetime, timezone

        stmt = (
            update(Supplier)
            .where(Supplier.id == supplier_id, Supplier.organization_id == org_id)
            .values(is_deleted=True, deleted_at=datetime.now(timezone.utc))
        )
        await self._session.execute(stmt)
        await self._session.flush()

    async def list(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
        branch_id: Optional[UUID] = None,
        branch_ids: Optional[list] = None,
    ) -> Tuple[List[Supplier], int]:
        query = select(Supplier).where(
            Supplier.organization_id == org_id, ~Supplier.is_deleted
        )
        count_query = select(func.count(Supplier.id)).where(
            Supplier.organization_id == org_id, ~Supplier.is_deleted
        )
        if branch_ids is not None:
            query = query.where(Supplier.branch_id.in_(branch_ids))
            count_query = count_query.where(Supplier.branch_id.in_(branch_ids))
        elif branch_id is not None:
            query = query.where(Supplier.branch_id == branch_id)
            count_query = count_query.where(Supplier.branch_id == branch_id)

        if search:
            search_filter = or_(
                Supplier.name.ilike(f"%{search}%"),
                Supplier.phone.ilike(f"%{search}%"),
                Supplier.email.ilike(f"%{search}%"),
            )
            query = query.where(search_filter)
            count_query = count_query.where(search_filter)

        count_result = await self._session.execute(count_query)
        total = count_result.scalar() or 0

        query = (
            query.order_by(Supplier.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        result = await self._session.execute(query)
        items = list(result.unique().scalars().all())

        return items, total


class SqlAlchemyProductCategoryRepository(ProductCategoryRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, category: ProductCategory) -> ProductCategory:
        self._session.add(category)
        await self._session.flush()
        return category

    async def get_by_id(
        self, category_id: UUID, org_id: UUID
    ) -> Optional[ProductCategory]:
        stmt = select(ProductCategory).where(
            ProductCategory.id == category_id,
            ProductCategory.organization_id == org_id,
            ProductCategory.is_deleted.is_(False),
        )
        result = await self._session.execute(stmt)
        return result.unique().scalar_one_or_none()

    async def update(self, category: ProductCategory) -> ProductCategory:
        self._session.add(category)
        await self._session.flush()
        return category

    async def soft_delete(self, category_id: UUID, org_id: UUID) -> bool:
        # Unlink products in the same transaction; never delete their stock,
        # invoices or lots. Both updates are scoped to the current tenant.
        result = await self._session.execute(
            update(ProductCategory).where(
                ProductCategory.id == category_id,
                ProductCategory.organization_id == org_id,
                ProductCategory.is_deleted.is_(False),
            ).values(is_deleted=True, is_active=False).returning(ProductCategory.id)
        )
        if result.scalar_one_or_none() is None:
            return False
        await self._session.execute(
            update(Product).where(
                Product.category_id == category_id,
                Product.organization_id == org_id,
            ).values(category_id=None)
        )
        await self._session.flush()
        return True

    async def list(
        self, org_id: UUID, only_active: bool = False
    ) -> List[ProductCategory]:
        stmt = select(ProductCategory).where(
            ProductCategory.organization_id == org_id,
            ProductCategory.is_deleted.is_(False),
        )
        if only_active:
            stmt = stmt.where(ProductCategory.is_active)
        stmt = stmt.order_by(ProductCategory.name)
        result = await self._session.execute(stmt)
        return list(result.unique().scalars().all())


class SqlAlchemyProductRepository(ProductRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, product: Product) -> Product:
        self._session.add(product)
        await self._session.flush()
        return product

    async def get_by_id(
        self, product_id: UUID, org_id: UUID, lock: bool = False
    ) -> Optional[Product]:
        stmt = select(Product).where(
            Product.id == product_id,
            Product.organization_id == org_id,
            ~Product.is_deleted,
        )
        if lock:
            stmt = stmt.with_for_update()
        result = await self._session.execute(stmt)
        return result.unique().scalar_one_or_none()

    async def get_by_sku(self, sku: str, org_id: UUID,
                         branch_id: Optional[UUID] = None) -> Optional[Product]:
        stmt = select(Product).where(
            Product.sku == sku,
            Product.organization_id == org_id,
            ~Product.is_deleted,
        )
        if branch_id is not None:
            stmt = stmt.where(Product.branch_id == branch_id)
        result = await self._session.execute(stmt)
        return result.unique().scalars().first()

    async def get_by_barcode(self, barcode: str, org_id: UUID,
                             branch_id: Optional[UUID] = None) -> Optional[Product]:
        stmt = select(Product).where(
            Product.barcode == barcode,
            Product.organization_id == org_id,
            ~Product.is_deleted,
        )
        if branch_id is not None:
            stmt = stmt.where(Product.branch_id == branch_id)
        result = await self._session.execute(stmt)
        return result.unique().scalars().first()

    async def update(self, product: Product) -> Product:
        self._session.add(product)
        await self._session.flush()
        return product

    async def soft_delete(self, product_id: UUID, org_id: UUID) -> None:
        from datetime import datetime, timezone

        stmt = (
            update(Product)
            .where(Product.id == product_id, Product.organization_id == org_id)
            .values(is_deleted=True, deleted_at=datetime.now(timezone.utc))
        )
        await self._session.execute(stmt)
        await self._session.flush()

    async def list(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        category_id: Optional[UUID] = None,
        page: int = 1,
        per_page: int = 20,
        stock_status: Optional[str] = None,
        expiry: Optional[str] = None,
        expiry_days: int = 30,
        uncategorized: bool = False,
        branch_id: Optional[UUID] = None,
        branch_ids: Optional[list] = None,
    ) -> Tuple[List[Product], int]:
        query = select(Product).where(
            Product.organization_id == org_id, ~Product.is_deleted
        )
        count_query = select(func.count(Product.id)).where(
            Product.organization_id == org_id, ~Product.is_deleted
        )
        if branch_ids is not None:
            query = query.where(Product.branch_id.in_(branch_ids))
            count_query = count_query.where(Product.branch_id.in_(branch_ids))
        elif branch_id is not None:
            query = query.where(Product.branch_id == branch_id)
            count_query = count_query.where(Product.branch_id == branch_id)

        if search:
            search_filter = or_(
                Product.name.ilike(f"%{search}%"),
                Product.name_ar.ilike(f"%{search}%"),
                Product.sku.ilike(f"%{search}%"),
                Product.barcode.ilike(f"%{search}%"),
            )
            query = query.where(search_filter)
            count_query = count_query.where(search_filter)

        if category_id:
            query = query.where(Product.category_id == category_id)
            count_query = count_query.where(Product.category_id == category_id)

        if uncategorized:
            flt = Product.category_id.is_(None)
            query = query.where(flt)
            count_query = count_query.where(flt)

        # Plain-language inventory filters: «قرب يخلص» (at/below the alert
        # threshold but still positive) and «خلص» (zero or negative).
        quantity = Product.stock
        if branch_ids is not None or branch_id is not None:
            from app.domain.entities.sale_entities import Branch, BranchStock
            if branch_ids is not None:
                quantity = select(func.coalesce(func.sum(BranchStock.quantity), 0)).where(
                    BranchStock.product_id == Product.id,
                    BranchStock.branch_id.in_(branch_ids),
                ).correlate(Product).scalar_subquery()
            else:
                is_main = bool((await self._session.execute(
                    select(Branch.is_default).where(Branch.id == branch_id)
                )).scalar_one_or_none())
                branch_quantity = select(BranchStock.quantity).where(
                    BranchStock.product_id == Product.id,
                    BranchStock.branch_id == branch_id,
                ).correlate(Product).scalar_subquery()
                quantity = func.coalesce(
                    branch_quantity, Product.stock if is_main else 0)
        if stock_status == "low":
            flt = (quantity > 0) & (quantity <= Product.min_stock)
            query = query.where(flt)
            count_query = count_query.where(flt)
        elif stock_status == "out":
            flt = quantity <= 0
            query = query.where(flt)
            count_query = count_query.where(flt)

        # Expiry filters: «قرب تنتهي» (within 30 days) and «منتهي».
        if expiry in ("soon", "expired"):
            from datetime import date, timedelta

            from app.domain.entities.sale_entities import InventoryLot

            today = date.today()
            if expiry == "expired":
                prod_cond = Product.expiry_date < today
                lot_cond = InventoryLot.expiry_date < today
            else:
                hi = today + timedelta(days=expiry_days)
                prod_cond = (Product.expiry_date >= today) & (
                    Product.expiry_date <= hi
                )
                lot_cond = (InventoryLot.expiry_date >= today) & (
                    InventoryLot.expiry_date <= hi
                )
            sub = select(InventoryLot.product_id).where(
                InventoryLot.organization_id == org_id,
                InventoryLot.remaining_quantity > 0,
                InventoryLot.expiry_date.isnot(None),
                lot_cond,
            )
            cond = prod_cond | Product.id.in_(sub)
            query = query.where(cond)
            count_query = count_query.where(cond)

        count_result = await self._session.execute(count_query)
        total = count_result.scalar() or 0

        query = (
            query.order_by(Product.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        result = await self._session.execute(query)
        items = list(result.unique().scalars().all())

        return items, total


class SqlAlchemyInventoryMovementRepository(InventoryMovementRepository):
    def __init__(self, session: AsyncSession):
        self._session = session

    async def create(self, movement: InventoryMovement) -> InventoryMovement:
        self._session.add(movement)
        await self._session.flush()
        return movement

    async def get_by_id(
        self, movement_id: UUID, org_id: UUID
    ) -> Optional[InventoryMovement]:
        stmt = select(InventoryMovement).where(
            InventoryMovement.id == movement_id,
            InventoryMovement.organization_id == org_id,
        )
        result = await self._session.execute(stmt)
        return result.unique().scalar_one_or_none()

    async def list_by_product(
        self, product_id: UUID, org_id: UUID, limit: int = 50
    ) -> List[InventoryMovement]:
        stmt = (
            select(InventoryMovement)
            .where(
                InventoryMovement.product_id == product_id,
                InventoryMovement.organization_id == org_id,
            )
            .order_by(InventoryMovement.created_at.desc())
            .limit(limit)
        )
        result = await self._session.execute(stmt)
        return list(result.unique().scalars().all())

    async def list(
        self,
        org_id: UUID,
        product_id: Optional[UUID] = None,
        movement_type: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
        branch_ids: Optional[list] = None,
    ) -> Tuple[List[InventoryMovement], int]:
        query = select(InventoryMovement).where(
            InventoryMovement.organization_id == org_id
        )
        count_query = select(func.count(InventoryMovement.id)).where(
            InventoryMovement.organization_id == org_id
        )
        # Optional branch scope (all-branches passes every active branch).
        if branch_ids is not None:
            query = query.where(InventoryMovement.branch_id.in_(branch_ids))
            count_query = count_query.where(
                InventoryMovement.branch_id.in_(branch_ids))

        if product_id:
            query = query.where(InventoryMovement.product_id == product_id)
            count_query = count_query.where(InventoryMovement.product_id == product_id)

        if movement_type:
            query = query.where(InventoryMovement.movement_type == movement_type)
            count_query = count_query.where(
                InventoryMovement.movement_type == movement_type
            )

        count_result = await self._session.execute(count_query)
        total = count_result.scalar() or 0

        query = (
            query.order_by(InventoryMovement.created_at.desc())
            .offset((page - 1) * per_page)
            .limit(per_page)
        )
        result = await self._session.execute(query)
        items = list(result.unique().scalars().all())

        return items, total
