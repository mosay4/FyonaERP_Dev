from uuid import UUID
from typing import Optional, List, Tuple
from decimal import Decimal
from app.domain.models.business_models import (
    CustomerCreate,
    CustomerUpdate,
    CustomerResponse,
    SupplierCreate,
    SupplierUpdate,
    SupplierResponse,
    CategoryCreate,
    CategoryUpdate,
    CategoryResponse,
    ProductCreate,
    ProductUpdate,
    ProductResponse,
    InventoryMovementCreate,
    InventoryMovementResponse,
    InventoryAdjustRequest,
)
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
from app.domain.services import branch_stock_service as bstock


class ProductBranchMismatch(ValueError):
    pass


class ProductCodeConflict(ValueError):
    def __init__(self, message: str, field: str, product):
        super().__init__(message)
        self.field = field
        self.product = product


class BusinessService:
    def __init__(
        self,
        customer_repo: CustomerRepository,
        supplier_repo: SupplierRepository,
        category_repo: ProductCategoryRepository,
        product_repo: ProductRepository,
        inventory_repo: InventoryMovementRepository,
    ):
        self._customer_repo = customer_repo
        self._supplier_repo = supplier_repo
        self._category_repo = category_repo
        self._product_repo = product_repo
        self._inventory_repo = inventory_repo

    # ═══════════════════════════════════════════
    # Customers
    # ═══════════════════════════════════════════

    async def create_customer(
        self, org_id: UUID, data: CustomerCreate,
        branch_id: Optional[UUID] = None,
    ) -> CustomerResponse:
        from sqlalchemy import func, select

        session = self._customer_repo._session
        if data.name:
            dup = (
                await session.execute(
                    select(Customer.id)
                    .where(
                        Customer.organization_id == org_id,
                        ~Customer.is_deleted,
                        Customer.branch_id == branch_id
                        if branch_id is not None else True,
                        func.lower(Customer.name) == data.name.strip().lower(),
                    )
                    .limit(1)
                )
            ).scalar_one_or_none()
            if dup:
                raise ValueError("يوجد عميل بنفس الاسم مسبقًا")
        if data.phone:
            dup = (
                await session.execute(
                    select(Customer.id)
                    .where(
                        Customer.organization_id == org_id,
                        ~Customer.is_deleted,
                        Customer.branch_id == branch_id
                        if branch_id is not None else True,
                        Customer.phone == data.phone.strip(),
                    )
                    .limit(1)
                )
            ).scalar_one_or_none()
            if dup:
                raise ValueError("يوجد عميل بنفس رقم الهاتف مسبقًا")
        customer = Customer(
            organization_id=org_id,
            branch_id=branch_id,
            name=data.name,
            phone=data.phone,
            email=data.email,
            tax_number=data.tax_number,
            cr_number=data.cr_number,
            address=data.address,
            contact_person=data.contact_person,
            notes=data.notes,
            credit_limit=data.credit_limit,
        )
        result = await self._customer_repo.create(customer)
        return CustomerResponse.model_validate(result)

    async def get_customer(self, customer_id: UUID, org_id: UUID,
                           branch_id: Optional[UUID] = None) -> CustomerResponse:
        customer = await self._customer_repo.get_by_id(customer_id, org_id)
        if not customer:
            raise ValueError("العميل غير موجود")
        if branch_id is not None and customer.branch_id != branch_id:
            raise ValueError("هذا العميل تابع لفرع آخر")
        return CustomerResponse.model_validate(customer)

    async def update_customer(
        self, customer_id: UUID, org_id: UUID, data: CustomerUpdate,
        branch_id: Optional[UUID] = None,
    ) -> CustomerResponse:
        customer = await self._customer_repo.get_by_id(customer_id, org_id)
        if not customer:
            raise ValueError("العميل غير موجود")
        if branch_id is not None and customer.branch_id != branch_id:
            raise ValueError("هذا العميل تابع لفرع آخر")

        update_data = data.model_dump(exclude_unset=True)
        for key, value in update_data.items():
            setattr(customer, key, value)

        result = await self._customer_repo.update(customer)
        return CustomerResponse.model_validate(result)

    async def delete_customer(self, customer_id: UUID, org_id: UUID,
                              branch_id: Optional[UUID] = None) -> None:
        customer = await self._customer_repo.get_by_id(customer_id, org_id)
        if not customer:
            raise ValueError("العميل غير موجود")
        if branch_id is not None and customer.branch_id != branch_id:
            raise ValueError("هذا العميل تابع لفرع آخر")
        await self._customer_repo.soft_delete(customer_id, org_id)

    async def list_customers(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
        branch_id: Optional[UUID] = None,
        branch_ids: Optional[list] = None,
    ) -> Tuple[List[CustomerResponse], int]:
        items, total = await self._customer_repo.list(
            org_id, search, page, per_page, branch_id, branch_ids)
        return [CustomerResponse.model_validate(c) for c in items], total

    # ═══════════════════════════════════════════
    # Suppliers
    # ═══════════════════════════════════════════

    async def create_supplier(
        self, org_id: UUID, data: SupplierCreate,
        branch_id: Optional[UUID] = None,
    ) -> SupplierResponse:
        from sqlalchemy import func, select

        session = self._supplier_repo._session
        if data.name:
            dup = (
                await session.execute(
                    select(Supplier.id)
                    .where(
                        Supplier.organization_id == org_id,
                        ~Supplier.is_deleted,
                        Supplier.branch_id == branch_id
                        if branch_id is not None else True,
                        func.lower(Supplier.name) == data.name.strip().lower(),
                    )
                    .limit(1)
                )
            ).scalar_one_or_none()
            if dup:
                raise ValueError("يوجد مورد بنفس الاسم مسبقًا")
        if data.phone:
            dup = (
                await session.execute(
                    select(Supplier.id)
                    .where(
                        Supplier.organization_id == org_id,
                        ~Supplier.is_deleted,
                        Supplier.branch_id == branch_id
                        if branch_id is not None else True,
                        Supplier.phone == data.phone.strip(),
                    )
                    .limit(1)
                )
            ).scalar_one_or_none()
            if dup:
                raise ValueError("يوجد مورد بنفس رقم الهاتف مسبقًا")
        supplier = Supplier(
            organization_id=org_id,
            branch_id=branch_id,
            name=data.name,
            phone=data.phone,
            email=data.email,
            tax_number=data.tax_number,
            cr_number=data.cr_number,
            address=data.address,
            contact_person=data.contact_person,
            notes=data.notes,
        )
        result = await self._supplier_repo.create(supplier)
        return SupplierResponse.model_validate(result)

    async def get_supplier(self, supplier_id: UUID, org_id: UUID,
                           branch_id: Optional[UUID] = None) -> SupplierResponse:
        supplier = await self._supplier_repo.get_by_id(supplier_id, org_id)
        if not supplier:
            raise ValueError("المورد غير موجود")
        if branch_id is not None and supplier.branch_id != branch_id:
            raise ValueError("هذا المورد تابع لفرع آخر")
        return SupplierResponse.model_validate(supplier)

    async def update_supplier(
        self, supplier_id: UUID, org_id: UUID, data: SupplierUpdate,
        branch_id: Optional[UUID] = None,
    ) -> SupplierResponse:
        supplier = await self._supplier_repo.get_by_id(supplier_id, org_id)
        if not supplier:
            raise ValueError("المورد غير موجود")
        if branch_id is not None and supplier.branch_id != branch_id:
            raise ValueError("هذا المورد تابع لفرع آخر")

        update_data = data.model_dump(exclude_unset=True)
        for key, value in update_data.items():
            setattr(supplier, key, value)

        result = await self._supplier_repo.update(supplier)
        return SupplierResponse.model_validate(result)

    async def delete_supplier(self, supplier_id: UUID, org_id: UUID,
                              branch_id: Optional[UUID] = None) -> None:
        supplier = await self._supplier_repo.get_by_id(supplier_id, org_id)
        if not supplier:
            raise ValueError("المورد غير موجود")
        if branch_id is not None and supplier.branch_id != branch_id:
            raise ValueError("هذا المورد تابع لفرع آخر")
        await self._supplier_repo.soft_delete(supplier_id, org_id)

    async def list_suppliers(
        self,
        org_id: UUID,
        search: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
        branch_id: Optional[UUID] = None,
        branch_ids: Optional[list] = None,
    ) -> Tuple[List[SupplierResponse], int]:
        items, total = await self._supplier_repo.list(
            org_id, search, page, per_page, branch_id, branch_ids)
        return [SupplierResponse.model_validate(s) for s in items], total

    # ═══════════════════════════════════════════
    # Categories
    # ═══════════════════════════════════════════

    async def create_category(
        self, org_id: UUID, data: CategoryCreate
    ) -> CategoryResponse:
        category = ProductCategory(
            organization_id=org_id,
            name=data.name,
            name_ar=data.name_ar,
            description=data.description,
        )
        result = await self._category_repo.create(category)
        return CategoryResponse.model_validate(result)

    async def get_category(self, category_id: UUID, org_id: UUID) -> CategoryResponse:
        category = await self._category_repo.get_by_id(category_id, org_id)
        if not category:
            raise ValueError("التصنيف غير موجود")
        return CategoryResponse.model_validate(category)

    async def update_category(
        self, category_id: UUID, org_id: UUID, data: CategoryUpdate
    ) -> CategoryResponse:
        category = await self._category_repo.get_by_id(category_id, org_id)
        if not category:
            raise ValueError("التصنيف غير موجود")

        update_data = data.model_dump(exclude_unset=True)
        for key, value in update_data.items():
            setattr(category, key, value)

        result = await self._category_repo.update(category)
        return CategoryResponse.model_validate(result)

    async def delete_category(self, category_id: UUID, org_id: UUID) -> None:
        if not await self._category_repo.soft_delete(category_id, org_id):
            raise ValueError("التصنيف غير موجود")

    async def list_categories(
        self, org_id: UUID, only_active: bool = False
    ) -> List[CategoryResponse]:
        items = await self._category_repo.list(org_id, only_active)
        return [CategoryResponse.model_validate(c) for c in items]

    async def set_category_image(
        self, category_id: UUID, org_id: UUID, image: Optional[str]
    ) -> CategoryResponse:
        category = await self._category_repo.get_by_id(category_id, org_id)
        if not category:
            raise ValueError("التصنيف غير موجود")
        category.image = image
        result = await self._category_repo.update(category)
        return CategoryResponse.model_validate(result)

    # ═══════════════════════════════════════════
    # Products
    # ═══════════════════════════════════════════

    async def create_product(
        self, org_id: UUID, data: ProductCreate,
        branch_id: Optional[UUID] = None,
    ) -> ProductResponse:
        if data.sku:
            existing = await self._product_repo.get_by_sku(data.sku, org_id, branch_id)
            if existing:
                raise ProductCodeConflict(
                    "رمز SKU موجود مسبقاً", "sku", existing)

        if data.barcode:
            existing = await self._product_repo.get_by_barcode(data.barcode, org_id, branch_id)
            if existing:
                raise ProductCodeConflict(
                    "الباركود موجود مسبقاً", "barcode", existing)

        product = Product(
            organization_id=org_id,
            branch_id=branch_id,
            name=data.name,
            name_ar=data.name_ar,
            category_id=data.category_id,
            sku=data.sku,
            barcode=data.barcode,
            description=data.description,
            unit=data.unit,
            price=data.price,
            cost_price=data.cost_price,
            stock=data.stock,
            min_stock=data.min_stock,
            is_service=data.is_service,
            image=data.image,
            notes=data.notes,
            expiry_date=data.expiry_date,
        )
        result = await self._product_repo.create(product)
        # A freshly-created Product has no loaded relation; accessing
        # `product.category` would trigger a lazy IO (MissingGreenlet). Load
        # it explicitly before serializing.
        try:
            await self._product_repo._session.refresh(
                result, attribute_names=["category"]
            )
        except Exception:
            pass
        return self._product_to_response(result)

    async def get_product(self, product_id: UUID, org_id: UUID,
                          branch_id: Optional[UUID] = None) -> ProductResponse:
        product = await self._product_repo.get_by_id(product_id, org_id)
        if not product:
            raise ValueError("المنتج غير موجود")
        if branch_id is not None and product.branch_id not in (None, branch_id):
            raise ProductBranchMismatch("هذا المنتج تابع لفرع آخر — بدّل إلى فرعه أولاً")
        resp = self._product_to_response(product)
        await self._attach_prices([product], [resp])
        if branch_id is not None:
            resp = (await self._attach_branch_quantities(
                [product], [resp], branch_id))[0]
        return resp

    async def _attach_branch_quantities(self, products, responses,
                                         branch_id: UUID):
        """Product.stock is a legacy MAIN-branch mirror, not the receiving
        warehouse balance. Read the same BranchStock ledger that transfers
        update, without rewriting products or replaying any movement."""
        if not products:
            return responses
        from sqlalchemy import select as _select
        from app.domain.entities.sale_entities import Branch, BranchStock

        session = self._product_repo._session
        quantities = dict((await session.execute(
            _select(BranchStock.product_id, BranchStock.quantity).where(
                BranchStock.branch_id == branch_id,
                BranchStock.product_id.in_([p.id for p in products]),
            ))).all())
        is_main = bool((await session.execute(_select(Branch.is_default).where(
            Branch.id == branch_id))).scalar_one_or_none())
        return [resp.model_copy(update={
            "stock": float(quantities.get(
                product.id, product.stock if is_main else 0) or 0),
        }) for product, resp in zip(products, responses)]

    async def _attach_prices(self, products, responses) -> None:
        """Attach independent per-currency sell prices to product responses."""
        if not products:
            return
        from sqlalchemy import select as _select

        from app.domain.entities.sale_entities import ProductPrice

        ids = [p.id for p in products]
        rows = (
            await self._product_repo._session.execute(
                _select(ProductPrice).where(ProductPrice.product_id.in_(ids))
            )
        ).scalars().all()
        by: dict = {}
        for r in rows:
            by.setdefault(r.product_id, []).append(
                {
                    "currency": r.currency,
                    "price": float(r.price or 0),
                    "buy_price": float(r.buy_price) if r.buy_price is not None else None,
                }
            )
        for resp, p in zip(responses, products):
            resp.prices = by.get(p.id, [])

    async def update_product(
        self, product_id: UUID, org_id: UUID, data: ProductUpdate,
        branch_id: Optional[UUID] = None,
    ) -> ProductResponse:
        product = await self._product_repo.get_by_id(product_id, org_id)
        if not product:
            raise ValueError("المنتج غير موجود")
        if branch_id is not None and product.branch_id not in (None, branch_id):
            raise ProductBranchMismatch("هذا المنتج تابع لفرع آخر — بدّل إلى فرعه أولاً")

        if data.sku is not None and data.sku != product.sku:
            existing = await self._product_repo.get_by_sku(data.sku, org_id, branch_id)
            if existing:
                raise ProductCodeConflict(
                    "رمز SKU موجود مسبقاً", "sku", existing)

        if data.barcode is not None and data.barcode != product.barcode:
            existing = await self._product_repo.get_by_barcode(data.barcode, org_id, branch_id)
            if existing:
                raise ProductCodeConflict(
                    "الباركود موجود مسبقاً", "barcode", existing)

        update_data = data.model_dump(exclude_unset=True)
        for key, value in update_data.items():
            setattr(product, key, value)

        result = await self._product_repo.update(product)
        return self._product_to_response(result)

    async def delete_product(self, product_id: UUID, org_id: UUID,
                              branch_id: Optional[UUID] = None) -> None:
        product = await self._product_repo.get_by_id(product_id, org_id)
        if not product:
            raise ValueError("المنتج غير موجود")
        if branch_id is not None and product.branch_id not in (None, branch_id):
            raise ValueError("هذا المنتج تابع لفرع آخر")
        await self._product_repo.soft_delete(product_id, org_id)

    async def set_product_image(
        self, product_id: UUID, org_id: UUID, image: Optional[str]
    ) -> ProductResponse:
        product = await self._product_repo.get_by_id(product_id, org_id)
        if not product:
            raise ValueError("المنتج غير موجود")
        product.image = image
        result = await self._product_repo.update(product)
        return self._product_to_response(result)

    async def list_products(
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
    ) -> Tuple[List[ProductResponse], int]:
        items, total = await self._product_repo.list(
            org_id, search, category_id, page, per_page, stock_status, expiry,
            expiry_days, uncategorized, branch_id, branch_ids,
        )
        responses = [self._product_to_response(p) for p in items]
        await self._attach_prices(items, responses)
        if branch_id is not None and branch_ids is None:
            responses = await self._attach_branch_quantities(
                items, responses, branch_id)
        if branch_ids:
            # All-branches view: quantities/costs come from branch_stock ONLY.
            # Product.stock is the main-branch mirror and must never be added
            # again (that would double count).
            from decimal import Decimal as _D
            from sqlalchemy import func as _f, select as _s
            from app.domain.entities.sale_entities import BranchStock as _BS
            ids = [p.id for p in items]
            if ids:
                rows = (await self._product_repo._session.execute(
                    _s(_BS.product_id,
                       _f.coalesce(_f.sum(_BS.quantity), 0),
                       _f.coalesce(_f.sum(_BS.quantity * _BS.avg_cost), 0))
                    .where(_BS.branch_id.in_(branch_ids),
                           _BS.product_id.in_(ids))
                    .group_by(_BS.product_id))).all()
                agg = {str(r[0]): (r[1], r[2]) for r in rows}
                merged = []
                for resp in responses:
                    qty, value = agg.get(str(resp.id), (0, 0))
                    q = float(qty or 0)
                    avg = (Decimal(str(value)) / Decimal(str(q))) if q else resp.cost_price
                    merged.append(resp.model_copy(update={
                        'stock': q,
                        'cost_price': avg,
                    }))
                responses = merged
        return responses, total

    def _product_to_response(self, product: Product) -> ProductResponse:
        return ProductResponse(
            id=product.id,
            organization_id=product.organization_id,
            branch_id=product.branch_id,
            category_id=product.category_id,
            category_name=product.category.name if product.category else None,
            name=product.name,
            name_ar=product.name_ar,
            sku=product.sku,
            barcode=product.barcode,
            description=product.description,
            unit=product.unit,
            price=product.price,
            cost_price=product.cost_price,
            cost_currency=product.cost_currency,
            stock=product.stock,
            min_stock=product.min_stock,
            is_service=product.is_service,
            is_active=product.is_active,
            image=product.image,
            notes=product.notes,
            expiry_date=product.expiry_date,
            created_at=product.created_at,
            updated_at=product.updated_at,
        )

    # ═══════════════════════════════════════════
    # Inventory
    # ═══════════════════════════════════════════

    async def record_movement(
        self, org_id: UUID, user_id: UUID, data: InventoryMovementCreate
    ) -> InventoryMovementResponse:
        db = self._product_repo._session
        product = await self._product_repo.get_by_id(data.product_id, org_id, lock=True)
        if not product:
            raise ValueError("المنتج غير موجود")

        if product.is_service:
            raise ValueError("لا يمكن تسجيل حركة مخزنية لمنتج خدمي")

        current = float(await bstock.available(
            db, org_id, getattr(data, "branch_id", None), product))
        new_stock = current + float(data.quantity)
        if new_stock < 0:
            raise ValueError("الرصيد غير كافي")

        qty = Decimal(str(data.quantity))
        movement = InventoryMovement(
            organization_id=org_id,
            product_id=data.product_id,
            movement_type=data.movement_type,
            quantity=data.quantity,
            unit_price=data.unit_price,
            total=qty * data.unit_price,
            notes=data.notes,
            reference_type=data.reference_type,
            reference_id=data.reference_id,
            branch_id=getattr(data, "branch_id", None),
            created_by=user_id,
        )
        result = await self._inventory_repo.create(movement)
        await bstock.apply_delta(db, org_id, getattr(data, "branch_id", None),
                                 product, float(data.quantity))
        await self._product_repo.update(product)

        return InventoryMovementResponse.model_validate(result)

    async def adjust_stock(
        self, org_id: UUID, user_id: UUID, data: InventoryAdjustRequest
    ) -> InventoryMovementResponse:
        """«زود / نقص / عدّل الكمية» with a human reason; audited in the
        background (old/new/difference/reason/user/branch)."""
        db = self._product_repo._session
        product = await self._product_repo.get_by_id(
            data.product_id, org_id, lock=True
        )
        if not product:
            raise ValueError("المنتج غير موجود")
        if product.is_service:
            raise ValueError("لا يمكن تعديل كمية منتج خدمي")

        old = float(await bstock.available(
            db, org_id, getattr(data, "branch_id", None), product))
        if data.mode == "add":
            new = old + float(data.amount)
        elif data.mode == "remove":
            new = old - float(data.amount)
        else:  # set
            new = float(data.amount)
        if new < 0:
            raise ValueError("الكمية الجديدة لا يمكن أن تكون سالبة")

        diff = new - old
        movement_type = {
            "add": "adjust_add",
            "remove": "adjust_remove",
            "set": "adjust_set",
        }[data.mode]
        movement = InventoryMovement(
            organization_id=org_id,
            product_id=data.product_id,
            movement_type=movement_type,
            quantity=diff,
            unit_price=Decimal("0"),
            total=Decimal("0"),
            reason=data.reason,
            old_quantity=old,
            new_quantity=new,
            difference=diff,
            branch_id=data.branch_id,
            notes=data.notes,
            reference_type="adjustment",
            created_by=user_id,
        )
        result = await self._inventory_repo.create(movement)
        await bstock.set_quantity(db, org_id, getattr(data, "branch_id", None),
                                  product, new)
        await self._product_repo.update(product)
        # Move the matching lot quantities too (FIFO/FEFO for reductions).
        from app.domain.services import inventory_lots as lots

        await lots.adjust_lots(
            self._product_repo._session, org_id, product, diff,
            product.cost_currency or "",
        )
        return InventoryMovementResponse.model_validate(result)

    async def transfer_stock(
        self, org_id: UUID, user_id: UUID, data
    ) -> InventoryMovementResponse:
        """Move stock between branches as a stock move (never a sale/purchase)."""
        db = self._product_repo._session
        from .branch_transfer_service import _validate_transfer_access
        from app.domain.entities.auth_entities import User

        # Resolve the implicit main branch *before* looking up lots; a null
        # source in the old lot helper would consume across the company.
        sender = await bstock.resolve_branch_id(db, org_id, data.from_branch_id)
        receiver = await bstock.resolve_branch_id(db, org_id, data.to_branch_id)
        await _validate_transfer_access(db, org_id, await db.get(User, user_id), sender, receiver)
        product = await self._product_repo.get_by_id(
            data.product_id, org_id, lock=True
        )
        if not product:
            raise ValueError("المنتج غير موجود")
        if product.is_service:
            raise ValueError("لا يمكن تحويل منتج خدمي")
        from .branch_transfer_service import require_connected_transfer_scope
        await require_connected_transfer_scope(db, (product.branch_id,))
        from app.domain.services import inventory_lots as lots

        await lots.transfer_lots(
            db=self._product_repo._session,
            org_id=org_id,
            product=product,
            qty=data.quantity,
            from_branch_id=sender,
            to_branch_id=receiver,
            user_id=user_id,
        )
        # Keep the per-branch quantities authoritative (main mirrored).
        await bstock.apply_delta(db, org_id, sender, product, -data.quantity)
        await bstock.apply_delta(db, org_id, receiver, product,
                                 data.quantity,
                                 unit_cost=getattr(product, "cost_price", 0))
        movement = InventoryMovement(
            organization_id=org_id,
            product_id=product.id,
            movement_type="transfer",
            quantity=0,
            unit_price=Decimal("0"),
            total=Decimal("0"),
            branch_id=receiver,
            reference_type="transfer",
            notes="تحويل بين الفروع",
            created_by=user_id,
        )
        result = await self._inventory_repo.create(movement)
        return InventoryMovementResponse.model_validate(result)

    async def get_product_movements(
        self, product_id: UUID, org_id: UUID, limit: int = 50
    ) -> List[InventoryMovementResponse]:
        items = await self._inventory_repo.list_by_product(product_id, org_id, limit)
        return [InventoryMovementResponse.model_validate(m) for m in items]

    async def list_movements(
        self,
        org_id: UUID,
        product_id: Optional[UUID] = None,
        movement_type: Optional[str] = None,
        page: int = 1,
        per_page: int = 20,
        branch_ids: Optional[list] = None,
    ) -> Tuple[List[InventoryMovementResponse], int]:
        items, total = await self._inventory_repo.list(
            org_id, product_id, movement_type, page, per_page,
            branch_ids=branch_ids,
        )
        return [InventoryMovementResponse.model_validate(m) for m in items], total
