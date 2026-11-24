from fastapi import APIRouter, BackgroundTasks, Depends, Header, HTTPException, status, File, UploadFile, Request
from sqlalchemy.ext.asyncio import AsyncSession
from typing import Optional
from uuid import UUID

from ...core.database import get_db
from ...core.qa_business_ledger import contains_registered_branch
from ...api.deps import (get_branch_context, get_branch_scope, get_current_org_id, get_current_user_uuid,
                         require_permission, has_permission)
from ...api.responses import ok, created, no_content, ok_paginated
from ...domain.models.business_models import (
    CustomerCreate,
    CustomerUpdate,
    CustomerResponse,
    SupplierCreate,
    SupplierUpdate,
    CategoryCreate,
    CategoryUpdate,
    ProductCreate,
    ProductUpdate,
    InventoryMovementCreate,
    InventoryAdjustRequest,
    ProductPricesUpdate,
    InventoryTransferRequest,
    FalconAnalyzeRequest,
    FalconChatRequest,
    WarehouseSettingsUpdate,
)
from ...domain.models.invoice_models import (
    ProductUnitCreate,
    ProductUnitUpdate,
    ProductBarcodeCreate,
    PartyPaymentRequest,
)
from ...domain.services.business_service import (BusinessService, ProductBranchMismatch, ProductCodeConflict)
from ...infrastructure.repositories.sql_alchemy_business_repository import (
    SqlAlchemyCustomerRepository,
    SqlAlchemySupplierRepository,
    SqlAlchemyProductCategoryRepository,
    SqlAlchemyProductRepository,
    SqlAlchemyInventoryMovementRepository,
)

router = APIRouter(tags=["Business"])


def _get_service(db: AsyncSession) -> BusinessService:
    return BusinessService(
        customer_repo=SqlAlchemyCustomerRepository(db),
        supplier_repo=SqlAlchemySupplierRepository(db),
        category_repo=SqlAlchemyProductCategoryRepository(db),
        product_repo=SqlAlchemyProductRepository(db),
        inventory_repo=SqlAlchemyInventoryMovementRepository(db),
    )

async def _row_branch_allowed(db: AsyncSession, row_branch,
                              scope) -> bool:
    """All-mode: any active scoped branch; single-mode: exactly this branch
    (legacy NULL rows count as the MAIN branch only)."""
    if scope.all_mode:
        if row_branch is not None:
            return str(row_branch) in {str(b) for b in scope.branch_ids}
        from sqlalchemy import select
        from ...domain.entities.sale_entities import Branch as _Branch
        return bool((await db.execute(select(_Branch.id).where(
            _Branch.id.in_(scope.branch_ids), _Branch.is_default.is_(True)))).scalar_one_or_none())
    if row_branch is not None:
        return str(row_branch) == str(scope.branch_id)
    from sqlalchemy import select as _sel
    from ...domain.entities.sale_entities import Branch as _Branch
    return bool((await db.execute(_sel(_Branch.is_default).where(
        _Branch.id == scope.branch_id))).scalar_one_or_none())


async def _connected_inventory_scope(db: AsyncSession, scope):
    if scope is None:
        return
    ids = scope.branch_ids if scope.all_mode else [scope.branch_id]
    if await contains_registered_branch(db, ids):
        raise HTTPException(409, detail={
            "code": "inventory_device_scope",
            "message": "اختر فرع الدفتر المحلي لعرض مخزونه وتصنيفاته من الجهاز.",
        })


async def _category_branch_scope(
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    token: Optional[str] = Header(default=None, alias="X-Branch-Token"),
    db: AsyncSession = Depends(get_db),
):
    # The shared category route was read-only and did not provision a main
    # branch. Validate an explicit selection without adding that no-token write.
    if not token:
        return None
    return await get_branch_scope(org_id, user_id, token, db)



# ═══════════════════════════════════════════
# Customers
# ═══════════════════════════════════════════


@router.post(
    "/customers",
    summary="Create a customer",
    response_model=CustomerResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_customer(
    data: CustomerCreate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("customers", "create")),
):
    service = _get_service(db)
    try:
        result = await service.create_customer(
            UUID(org_id), data, branch_id=branch.id)
        return created(result, "تم إنشاء العميل بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.get("/customers", summary="List customers with pagination and search")
async def list_customers(
    search: Optional[str] = None,
    page: int = 1,
    per_page: int = 20,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("customers", "read")),
):
    service = _get_service(db)
    items, total = await service.list_customers(
        UUID(org_id), search, page, per_page,
        branch_id=scope.branch_id,
        branch_ids=scope.branch_ids if scope.all_mode else [scope.branch_id])
    return ok_paginated([i.model_dump() for i in items], total, page, per_page)


@router.get("/customers/{customer_id}", summary="Get a single customer by ID")
async def get_customer(
    customer_id: UUID,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("customers", "read")),
):
    service = _get_service(db)
    try:
        result = await service.get_customer(
            customer_id, UUID(org_id),
            None if scope.all_mode else scope.branch_id)
        if not await _row_branch_allowed(db, result.branch_id, scope):
            raise HTTPException(404, detail='العميل غير موجود')
        return ok(result)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.put("/customers/{customer_id}", summary="Update a customer")
async def update_customer(
    customer_id: UUID,
    data: CustomerUpdate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("customers", "update")),
):
    service = _get_service(db)
    try:
        result = await service.update_customer(
            customer_id, UUID(org_id), data, branch_id=branch.id)
        return ok(result, "تم تحديث العميل بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.delete("/customers/{customer_id}", summary="Soft-delete a customer")
async def delete_customer(
    customer_id: UUID,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("customers", "delete")),
):
    service = _get_service(db)
    try:
        await service.delete_customer(
            customer_id, UUID(org_id), branch_id=branch.id)
        return no_content("تم حذف العميل بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


# ═══════════════════════════════════════════
# Suppliers
# ═══════════════════════════════════════════


@router.post(
    "/suppliers", summary="Create a supplier", status_code=status.HTTP_201_CREATED
)
async def create_supplier(
    data: SupplierCreate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("suppliers", "create")),
):
    service = _get_service(db)
    try:
        result = await service.create_supplier(
            UUID(org_id), data, branch_id=branch.id)
        return created(result, "تم إنشاء المورد بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.get("/suppliers", summary="List suppliers with pagination and search")
async def list_suppliers(
    search: Optional[str] = None,
    page: int = 1,
    per_page: int = 20,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("suppliers", "read")),
):
    service = _get_service(db)
    items, total = await service.list_suppliers(
        UUID(org_id), search, page, per_page,
        branch_id=scope.branch_id,
        branch_ids=scope.branch_ids if scope.all_mode else [scope.branch_id])
    return ok_paginated([i.model_dump() for i in items], total, page, per_page)


@router.get("/suppliers/{supplier_id}", summary="Get a single supplier by ID")
async def get_supplier(
    supplier_id: UUID,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("suppliers", "read")),
):
    service = _get_service(db)
    try:
        result = await service.get_supplier(
            supplier_id, UUID(org_id),
            None if scope.all_mode else scope.branch_id)
        if not await _row_branch_allowed(db, result.branch_id, scope):
            raise HTTPException(404, detail='المورد غير موجود')
        return ok(result)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.put("/suppliers/{supplier_id}", summary="Update a supplier")
async def update_supplier(
    supplier_id: UUID,
    data: SupplierUpdate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("suppliers", "update")),
):
    service = _get_service(db)
    try:
        result = await service.update_supplier(
            supplier_id, UUID(org_id), data, branch_id=branch.id)
        return ok(result, "تم تحديث المورد بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.delete("/suppliers/{supplier_id}", summary="Soft-delete a supplier")
async def delete_supplier(
    supplier_id: UUID,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("suppliers", "delete")),
):
    service = _get_service(db)
    try:
        await service.delete_supplier(
            supplier_id, UUID(org_id), branch_id=branch.id)
        return no_content("تم حذف المورد بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


# ═══════════════════════════════════════════
# Product Categories
# ═══════════════════════════════════════════


@router.post(
    "/categories",
    summary="Create a product category",
    status_code=status.HTTP_201_CREATED,
)
async def create_category(
    data: CategoryCreate,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("categories", "create")),
):
    service = _get_service(db)
    try:
        result = await service.create_category(UUID(org_id), data)
        return created(result, "تم إنشاء التصنيف بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.get("/categories", summary="List all categories (optionally only active)")
async def list_categories(
    only_active: bool = False,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("categories", "read")),
    scope=Depends(_category_branch_scope),
):
    await _connected_inventory_scope(db, scope)
    service = _get_service(db)
    items = await service.list_categories(UUID(org_id), only_active)
    return ok(items)


@router.get("/categories/{category_id}", summary="Get a category by ID")
async def get_category(
    category_id: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("categories", "read")),
    scope=Depends(_category_branch_scope),
):
    await _connected_inventory_scope(db, scope)
    service = _get_service(db)
    try:
        result = await service.get_category(category_id, UUID(org_id))
        return ok(result)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.delete("/categories/{category_id}", summary="Delete a category, keeping its products")
async def delete_category(
    category_id: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("categories", "delete")),
):
    try:
        await _get_service(db).delete_category(category_id, UUID(org_id))
        await db.commit()
        return ok(None, "تم حذف التصنيف بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.put("/categories/{category_id}", summary="Update a category")
async def update_category(
    category_id: UUID,
    data: CategoryUpdate,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("categories", "update")),
):
    service = _get_service(db)
    try:
        result = await service.update_category(category_id, UUID(org_id), data)
        return ok(result, "تم تحديث التصنيف بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


# ═══════════════════════════════════════════
# Products
# ═══════════════════════════════════════════


@router.post(
    "/products", summary="Create a product", status_code=status.HTTP_201_CREATED
)
async def create_product(
    data: ProductCreate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "create")),
):
    service = _get_service(db)
    try:
        result = await service.create_product(
            UUID(org_id), data, branch_id=branch.id)
        return created(result, "تم إنشاء المنتج بنجاح")
    except ProductCodeConflict as e:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "code": "product_code_conflict",
                "field": e.field,
                "message": str(e),
                "product_id": str(e.product.id),
                "product_name": e.product.name,
            },
        )
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.get(
    "/products", summary="List products with pagination, search, and category filter"
)
async def list_products(
    search: Optional[str] = None,
    category_id: Optional[UUID] = None,
    page: int = 1,
    per_page: int = 20,
    stock_status: Optional[str] = None,
    expiry: Optional[str] = None,
    expiry_days: int = 30,
    uncategorized: bool = False,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "read")),
    can_view_cost: bool = Depends(has_permission("inventory_cost", "read")),
):
    await _connected_inventory_scope(db, scope)
    service = _get_service(db)
    items, total = await service.list_products(
        UUID(org_id), search, category_id, page, per_page, stock_status, expiry,
        expiry_days, uncategorized, scope.branch_id,
        scope.branch_ids if scope.all_mode else None,
    )
    out = []
    for i in items:
        d = i.model_dump()
        if not can_view_cost:
            d["cost_price"] = None
            d["cost_currency"] = None
        out.append(d)
    return ok_paginated(out, total, page, per_page)


@router.get("/branches", summary="List organization branches")
async def list_branches(
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "read")),
):
    from ...domain.entities.sale_entities import Branch
    from sqlalchemy import select as _select

    rows = (
        await db.execute(
            _select(Branch)
            .where(Branch.organization_id == UUID(org_id), Branch.id.in_(scope.branch_ids))
            .order_by(Branch.name.asc())
        )
    ).scalars().all()
    return ok([{"id": str(b.id), "name": b.name} for b in rows])


@router.get("/products/resolve-barcode", summary="Resolve a barcode to product + unit + price")
async def resolve_barcode(
    code: str,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "read")),
):
    from ...domain.services import sale_service

    await _connected_inventory_scope(db, scope)
    try:
        return ok(await sale_service.resolve_barcode(
            db, UUID(org_id), code,
            branch_ids=scope.branch_ids,
        ))
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.get("/products/{product_id}", summary="Get a single product by ID")
async def get_product(
    product_id: UUID,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "read")),
    can_view_cost: bool = Depends(has_permission("inventory_cost", "read")),
):
    await _connected_inventory_scope(db, scope)
    service = _get_service(db)
    try:
        result = await service.get_product(
            product_id, UUID(org_id),
            branch_id=None if scope.all_mode else scope.branch_id)
        if not await _row_branch_allowed(db, result.branch_id, scope):
            raise HTTPException(404, detail='المنتج غير موجود')
        d = result.model_dump()
        if not can_view_cost:
            d["cost_price"] = None
            d["cost_currency"] = None
        return ok(d)
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.put("/products/{product_id}", summary="Update a product")
async def update_product(
    product_id: UUID,
    data: ProductUpdate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "update")),
):
    service = _get_service(db)
    try:
        result = await service.update_product(
            product_id, UUID(org_id), data, branch_id=branch.id)
        return ok(result, "تم تحديث المنتج بنجاح")
    except ProductBranchMismatch as e:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"code": "product_branch_mismatch", "message": str(e)},
        )
    except ProductCodeConflict as e:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "code": "product_code_conflict",
                "field": e.field,
                "message": str(e),
                "product_id": str(e.product.id),
                "product_name": e.product.name,
            },
        )
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                            detail=str(e))


@router.delete("/products/{product_id}", summary="Soft-delete a product")
async def delete_product(
    product_id: UUID,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "delete")),
):
    service = _get_service(db)
    try:
        await service.delete_product(
            product_id, UUID(org_id), branch_id=branch.id)
        return no_content("تم حذف المنتج بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.post("/products/{product_id}/image", summary="Upload / replace a product image")
async def upload_product_image(
    product_id: UUID,
    file: UploadFile = File(...),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "update")),
):
    """Optional product picture. Compressed server-side (max ~1000px, JPEG)
    and stored via the same unified storage backend as avatars."""
    import io

    from PIL import Image

    raw = await file.read()
    if not raw or len(raw) > 8 * 1024 * 1024:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="الصورة غير صالحة أو تتجاوز 8 ميجابايت",
        )
    try:
        img = Image.open(io.BytesIO(raw))
        img.verify()
        img = Image.open(io.BytesIO(raw))
        if img.mode in ("RGBA", "LA", "P"):
            bg = Image.new("RGB", img.size, (255, 255, 255))
            bg.paste(
                img, mask=img.split()[-1] if img.mode in ("RGBA", "LA") else None
            )
            img = bg
        else:
            img = img.convert("RGB")
        # Keep it light: cap the longest edge and re-encode as JPEG.
        img.thumbnail((1000, 1000))
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="ملف الصورة غير صالح"
        )
    out = io.BytesIO()
    img.save(out, format="JPEG", quality=82)

    from datetime import datetime as _dt, timezone as _tz

    version = int(_dt.now(_tz.utc).timestamp())
    rel_path = f"products/{product_id}.jpg"
    try:
        from ...core.storage import unified_upload

        rel = await unified_upload(
            "products", f"{product_id}.jpg", out.getvalue(), "image/jpeg"
        )
    except Exception:
        from ...core.paths import UPLOAD_ROOT
        from ...core.storage import LocalStorage

        rel = await LocalStorage(UPLOAD_ROOT).upload(
            rel_path, io.BytesIO(out.getvalue()), "image/jpeg"
        )
    service = _get_service(db)
    try:
        result = await service.set_product_image(
            product_id, UUID(org_id), f"/uploads/{rel}?v={version}"
        )
        await db.commit()
        return ok(result, "تم تحديث صورة المنتج")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.delete("/products/{product_id}/image", summary="Remove a product image")
async def delete_product_image(
    product_id: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "update")),
):
    service = _get_service(db)
    try:
        result = await service.set_product_image(product_id, UUID(org_id), None)
        await db.commit()
        return ok(result, "تم حذف صورة المنتج")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.post("/categories/{category_id}/image", summary="Upload / replace a category image")
async def upload_category_image(
    category_id: UUID,
    file: UploadFile = File(...),
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("categories", "update")),
):
    """Optional category picture (shown in the in-place browser). Compressed
    server-side exactly like product pictures."""
    import io

    from PIL import Image

    raw = await file.read()
    if not raw or len(raw) > 8 * 1024 * 1024:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="الصورة غير صالحة أو تتجاوز 8 ميجابايت",
        )
    try:
        img = Image.open(io.BytesIO(raw))
        img.verify()
        img = Image.open(io.BytesIO(raw))
        if img.mode in ("RGBA", "LA", "P"):
            bg = Image.new("RGB", img.size, (255, 255, 255))
            bg.paste(
                img, mask=img.split()[-1] if img.mode in ("RGBA", "LA") else None
            )
            img = bg
        else:
            img = img.convert("RGB")
        img.thumbnail((1000, 1000))
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="ملف الصورة غير صالح"
        )
    out = io.BytesIO()
    img.save(out, format="JPEG", quality=82)

    from datetime import datetime as _dt, timezone as _tz

    version = int(_dt.now(_tz.utc).timestamp())
    rel_path = f"categories/{category_id}.jpg"
    try:
        from ...core.storage import unified_upload

        rel = await unified_upload(
            "categories", f"{category_id}.jpg", out.getvalue(), "image/jpeg"
        )
    except Exception:
        from ...core.paths import UPLOAD_ROOT
        from ...core.storage import LocalStorage

        rel = await LocalStorage(UPLOAD_ROOT).upload(
            rel_path, io.BytesIO(out.getvalue()), "image/jpeg"
        )
    service = _get_service(db)
    try:
        result = await service.set_category_image(
            category_id, UUID(org_id), f"/uploads/{rel}?v={version}"
        )
        await db.commit()
        return ok(result, "تم تحديث صورة التصنيف")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.delete("/categories/{category_id}/image", summary="Remove a category image")
async def delete_category_image(
    category_id: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("categories", "update")),
):
    service = _get_service(db)
    try:
        result = await service.set_category_image(category_id, UUID(org_id), None)
        await db.commit()
        return ok(result, "تم حذف صورة التصنيف")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.get("/products/{product_id}/prices", summary="Per-currency sell prices")
async def list_product_prices(
    product_id: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "read")),
):
    from ...domain.entities.sale_entities import ProductPrice
    from sqlalchemy import select as _select

    rows = (
        await db.execute(
            _select(ProductPrice)
            .where(
                ProductPrice.organization_id == UUID(org_id),
                ProductPrice.product_id == product_id,
            )
            .order_by(ProductPrice.currency.asc())
        )
    ).scalars().all()
    return ok([
        {"currency": r.currency, "price": float(r.price or 0)} for r in rows
    ])


@router.put("/products/{product_id}/prices", summary="Replace per-currency sell prices")
async def set_product_prices(
    product_id: UUID,
    data: ProductPricesUpdate,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "update")),
):
    """Each currency's price is stored exactly as entered and is NEVER
    auto-converted when exchange rates change."""
    from ...domain.entities.sale_entities import ProductPrice
    from ...domain.entities.business_entities import Product
    from sqlalchemy import select as _select, delete as _delete

    org = UUID(org_id)
    product = (
        await db.execute(
            _select(Product).where(
                Product.id == product_id,
                Product.organization_id == org,
                Product.is_deleted.is_(False),
            )
        )
    ).scalar_one_or_none()
    if not product:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="المنتج غير موجود")

    await db.execute(
        _delete(ProductPrice).where(
            ProductPrice.organization_id == org,
            ProductPrice.product_id == product_id,
        )
    )
    seen = set()
    for item in data.prices:
        cur = item.currency.strip().upper()
        if cur in seen:
            continue
        seen.add(cur)
        db.add(
            ProductPrice(
                organization_id=org,
                product_id=product_id,
                currency=cur,
                price=item.price,
                buy_price=item.buy_price,
            )
        )
    await db.commit()
    rows = (
        await db.execute(
            _select(ProductPrice)
            .where(
                ProductPrice.organization_id == org,
                ProductPrice.product_id == product_id,
            )
            .order_by(ProductPrice.currency.asc())
        )
    ).scalars().all()
    return ok(
        [
            {
                "currency": r.currency,
                "price": float(r.price or 0),
                "buy_price": float(r.buy_price) if r.buy_price is not None else None,
            }
            for r in rows
        ],
        "تم حفظ الأسعار",
    )


# ═══════════════════════════════════════════
# Inventory
# ═══════════════════════════════════════════


@router.post(
    "/inventory/movements",
    summary="Record an inventory movement",
    status_code=status.HTTP_201_CREATED,
)
async def record_movement(
    data: InventoryMovementCreate,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("inventory", "create")),
):
    service = _get_service(db)
    try:
        result = await service.record_movement(UUID(org_id), user_id, data)
        return created(result, "تم تسجيل الحركة بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post(
    "/inventory/adjust",
    summary="Adjust stock (زود / نقص / عدّل الكمية) with a plain reason",
    status_code=status.HTTP_201_CREATED,
)
async def adjust_stock(
    data: InventoryAdjustRequest,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("inventory", "update")),
):
    service = _get_service(db)
    try:
        result = await service.adjust_stock(UUID(org_id), user_id, data)
        await db.commit()
        return created(result, "تم تعديل الكمية")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.put("/inventory/warehouse-settings", summary="Persist server-side warehouse settings")
async def set_warehouse_settings(
    data: WarehouseSettingsUpdate,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "read")),
):
    from ...domain.entities.business_entities import WarehouseSetting
    from sqlalchemy import select as _select

    org = UUID(org_id)
    row = (
        await db.execute(
            _select(WarehouseSetting).where(WarehouseSetting.organization_id == org)
        )
    ).scalar_one_or_none()
    if row is None:
        row = WarehouseSetting(
            organization_id=org,
            expiry_enabled=data.expiry_enabled,
            expiry_warn_days=data.expiry_warn_days,
        )
        db.add(row)
    else:
        row.expiry_enabled = data.expiry_enabled
        row.expiry_warn_days = data.expiry_warn_days
    await db.commit()
    return ok(
        {
            "expiry_enabled": data.expiry_enabled,
            "expiry_warn_days": data.expiry_warn_days,
        },
        "تم حفظ إعدادات المخزن",
    )


@router.post("/inventory/falcon/analyze", summary="Falcon inventory analysis")
async def falcon_analyze(
    data: FalconAnalyzeRequest,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    branch_context=Depends(get_branch_scope),
    _: bool = Depends(require_permission("falcon", "read")),
):
    from ...domain.services import falcon_service

    try:
        ref = str(data.ref_id) if data.ref_id else None
        device = (falcon_service.device_dataset(data.device_items, data.report_currency,
                                                data.scope, ref, data.device_category)
                  if data.device_items is not None else None)
        return ok(await falcon_service.analyze(
            db, UUID(org_id), data.scope, ref, data.lang,
            data.report_currency,
            branch_ids=branch_context.branch_ids if branch_context.all_mode else [branch_context.branch_id],
            device=device,
        ))
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post("/inventory/falcon/chat", summary="Falcon follow-up chat")
async def falcon_chat(
    data: FalconChatRequest,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    branch_context=Depends(get_branch_scope),
    _: bool = Depends(require_permission("falcon", "read")),
):
    from ...domain.services import falcon_service

    ref = str(data.ref_id) if data.ref_id else None
    device = (falcon_service.device_dataset(data.device_items, data.report_currency,
                                            data.scope, ref, data.device_category)
              if data.device_items is not None else None)

    def device_rebuild(ids):
        # «جميع الفروع» on the phone: a question about named branches only.
        return falcon_service.device_dataset(
            [i for i in data.device_items or [] if isinstance(i, dict) and i.get('branch_id') in ids],
            data.report_currency, data.scope, ref, data.device_category)

    return ok(await falcon_service.chat(
        db, UUID(org_id), data.scope, ref,
        data.question, data.history, data.lang, data.report_currency,
        branch_ids=branch_context.branch_ids if branch_context.all_mode else [branch_context.branch_id],
        device=device,
        device_rebuild=device_rebuild if data.device_items is not None else None,
    ))


@router.post(
    "/inventory/transfer",
    summary="Transfer stock between branches (a stock move, not a sale)",
    status_code=status.HTTP_201_CREATED,
)
async def transfer_stock(
    data: InventoryTransferRequest,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("inventory", "update")),
):
    from ...domain.services.branch_transfer_service import (
        TransferNeedsArbitration,
    )

    service = _get_service(db)
    try:
        result = await service.transfer_stock(UUID(org_id), user_id, data)
        await db.commit()
        return created(result, "تم تحويل الكمية بين الفروع")
    except TransferNeedsArbitration as e:
        raise HTTPException(409, detail={"code": "transfer_device_scope", "message": str(e)}) from e
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.get("/products/{product_id}/stats", summary="Product statistics (real COGS/profit)")
async def product_stats(
    product_id: UUID,
    date_from: Optional[str] = None,
    date_to: Optional[str] = None,
    display_currency: Optional[str] = None,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("inventory", "read")),
    can_view_cost: bool = Depends(has_permission("inventory_cost", "read")),
    can_view_profit: bool = Depends(has_permission("inventory_profit", "read")),
):
    from datetime import date as _date

    from ...domain.services import inventory_stats
    from ...domain.entities.business_entities import Product as _P
    from sqlalchemy import select as _sel
    b = (await db.execute(_sel(_P.branch_id).where(
        _P.id == product_id, _P.organization_id == UUID(org_id)))).scalar_one_or_none()
    if not await _row_branch_allowed(db, b, scope):
        raise HTTPException(status_code=404, detail="المنتج غير موجود")

    def _d(s):
        try:
            return _date.fromisoformat(s) if s else None
        except Exception:
            return None

    data = await inventory_stats.product_stats(
        db, UUID(org_id), product_id, _d(date_from), _d(date_to),
        display_currency=display_currency,
    )
    # Permission Engine: hide cost/profit data for users without the right.
    if not can_view_cost:
        data["cogs"] = None
    if not can_view_profit:
        data["profit"] = None
    return ok(data)


@router.get("/products/{product_id}/lots", summary="Inventory lots (batches) of a product")
async def list_product_lots(
    product_id: UUID,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("inventory", "read")),
):
    from ...domain.entities.sale_entities import InventoryLot
    from ...domain.entities.business_entities import Product as _P
    from sqlalchemy import select as _select

    b = (await db.execute(_select(_P.branch_id).where(
        _P.id == product_id, _P.organization_id == UUID(org_id)))).scalar_one_or_none()
    if not await _row_branch_allowed(db, b, scope):
        raise HTTPException(status_code=404, detail="المنتج غير موجود")
    rows = (
        await db.execute(
            _select(InventoryLot)
            .where(
                InventoryLot.organization_id == UUID(org_id),
                InventoryLot.product_id == product_id,
            )
            .order_by(InventoryLot.purchase_date.asc(), InventoryLot.created_at.asc())
        )
    ).scalars().all()
    return ok([
        {
            "id": str(r.id),
            "remaining": float(r.remaining_quantity or 0),
            "received": float(r.received_quantity or 0),
            "unit_cost": float(r.unit_cost or 0),
            "currency": r.currency,
            "expiry_date": r.expiry_date.isoformat() if r.expiry_date else None,
            "lot_number": r.lot_number,
            "purchase_date": r.purchase_date.isoformat() if r.purchase_date else None,
            "source": r.source,
        }
        for r in rows
    ])


@router.get("/inventory/movements", summary="List inventory movements with filters")
async def list_movements(
    product_id: Optional[UUID] = None,
    movement_type: Optional[str] = None,
    page: int = 1,
    per_page: int = 20,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("inventory", "read")),
):
    service = _get_service(db)
    items, total = await service.list_movements(
        UUID(org_id), product_id, movement_type, page, per_page,
        branch_ids=scope.branch_ids if scope.all_mode else [scope.branch_id],
    )
    return ok_paginated([i.model_dump() for i in items], total, page, per_page)


@router.get(
    "/inventory/movements/product/{product_id}",
    summary="Get movements for a specific product",
)
async def get_product_movements(
    product_id: UUID,
    limit: int = 50,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("inventory", "read")),
):
    service = _get_service(db)
    items = await service.get_product_movements(product_id, UUID(org_id), limit)
    return ok(items)


# ═══════════════════════════════════════════
# Product units & barcodes (Inventory-owned;
# the sale screen only READS them + resolves barcodes)
# ═══════════════════════════════════════════


@router.get("/products/{product_id}/units", summary="List units + extra barcodes of a product")
async def list_product_units(
    product_id: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "read")),
):
    from ...domain.services import sale_service

    try:
        return ok(await sale_service.list_units(db, UUID(org_id), product_id))
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.post(
    "/products/{product_id}/units",
    summary="Add a unit to a product",
    status_code=status.HTTP_201_CREATED,
)
async def create_product_unit(
    product_id: UUID,
    data: ProductUnitCreate,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "update")),
):
    from ...domain.services import sale_service

    try:
        result = await sale_service.create_unit(db, UUID(org_id), product_id, data)
        return created(result, "تمت إضافة الوحدة بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.put("/products/units/{unit_id}", summary="Update a product unit")
async def update_product_unit(
    unit_id: UUID,
    data: ProductUnitUpdate,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "update")),
):
    from ...domain.services import sale_service

    try:
        result = await sale_service.update_unit(db, UUID(org_id), unit_id, data)
        return ok(result, "تم تحديث الوحدة بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.delete("/products/units/{unit_id}", summary="Delete a non-base product unit")
async def delete_product_unit(
    unit_id: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "update")),
):
    from ...domain.services import sale_service

    try:
        await sale_service.delete_unit(db, UUID(org_id), unit_id)
        return no_content("تم حذف الوحدة بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.post(
    "/products/{product_id}/barcodes",
    summary="Add an extra barcode to a product",
    status_code=status.HTTP_201_CREATED,
)
async def add_product_barcode(
    product_id: UUID,
    data: ProductBarcodeCreate,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "update")),
):
    from ...domain.services import sale_service

    try:
        result = await sale_service.add_barcode(db, UUID(org_id), product_id, data)
        return created(result, "تمت إضافة الباركود بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.delete("/products/barcodes/{barcode_id}", summary="Delete an extra barcode")
async def delete_product_barcode(
    barcode_id: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("products", "update")),
):
    from ...domain.services import sale_service

    try:
        await sale_service.delete_barcode(db, UUID(org_id), barcode_id)
        return no_content("تم حذف الباركود بنجاح")
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.get("/customers/{customer_id}/operations", summary="Customer invoice operations with per-op outstanding")
async def customer_operations(
    customer_id: UUID,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("customers", "read")),
):
    from ...domain.services import sale_service
    from ...domain.entities.business_entities import Customer as _C
    from sqlalchemy import select as _sel
    b = (await db.execute(_sel(_C.branch_id).where(
        _C.id == customer_id, _C.organization_id == UUID(org_id)))).scalar_one_or_none()
    if not await _row_branch_allowed(db, b, scope):
        raise HTTPException(status_code=404, detail="العميل غير موجود")
    return ok(await sale_service.party_operations(
        db, UUID(org_id), customer_id, False
    ))


@router.get("/suppliers/{supplier_id}/operations", summary="Supplier invoice operations with per-op outstanding")
async def supplier_operations(
    supplier_id: UUID,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("suppliers", "read")),
):
    from ...domain.services import sale_service
    from ...domain.entities.business_entities import Supplier as _S
    from sqlalchemy import select as _sel
    b = (await db.execute(_sel(_S.branch_id).where(
        _S.id == supplier_id, _S.organization_id == UUID(org_id)))).scalar_one_or_none()
    if not await _row_branch_allowed(db, b, scope):
        raise HTTPException(status_code=404, detail="المورد غير موجود")
    return ok(await sale_service.party_operations(
        db, UUID(org_id), supplier_id, True
    ))


@router.get("/customers/{customer_id}/balance", summary="Customer open debt snapshot")
async def customer_balance(
    customer_id: UUID,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("customers", "read")),
):
    from ...domain.services import sale_service
    from ...domain.entities.business_entities import Customer as _C
    from sqlalchemy import select as _sel
    b = (await db.execute(_sel(_C.branch_id).where(
        _C.id == customer_id, _C.organization_id == UUID(org_id)))).scalar_one_or_none()
    if not await _row_branch_allowed(db, b, scope):
        raise HTTPException(status_code=404, detail="العميل غير موجود")
    try:
        return ok(await sale_service.customer_balance(db, UUID(org_id), customer_id))
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.post(
    "/customers/{customer_id}/payments",
    summary="Collect a payment from a customer against open invoices",
    status_code=status.HTTP_201_CREATED,
)
async def collect_customer_payment(
    customer_id: UUID,
    data: PartyPaymentRequest,
    tasks: BackgroundTasks,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "update")),
):
    from ...domain.services import sale_service

    try:
        result = await sale_service.add_customer_payment(
            db, UUID(org_id), user_id, customer_id, data, branch_id=branch.id
        )
        service_pushes = result.pop('_notification_pushes', [])
        remaining = None
        try:
            from sqlalchemy import func as _func, select as _sel
            from ...domain.entities.invoice_entities import Invoice as _Inv
            if getattr(data, "invoice_id", None):
                inv = (await db.execute(_sel(_Inv).where(
                    _Inv.id == data.invoice_id))).scalar_one_or_none()
                if inv is not None:
                    remaining = float(inv.balance or 0)
            else:
                remaining = float((await db.execute(
                    _sel(_func.coalesce(_func.sum(_Inv.balance), 0)).where(
                        _Inv.organization_id == UUID(org_id),
                        _Inv.customer_id == customer_id,
                        _Inv.invoice_type == 'sale',
                        ((_Inv.branch_id == branch.id) |
                         (_Inv.branch_id.is_(None) if branch.is_default else False)),
                        *([_Inv.debt_group_id == data.debt_group_id] if data.debt_group_id else []),
                        _Inv.is_deleted.is_(False),
                        _func.upper(_Inv.currency) ==
                        (data.currency or "").upper(),
                    ))).scalar() or 0)
        except Exception:  # noqa: BLE001
            remaining = None
        if remaining is not None and remaining <= 0.004:
            _title = "تم سداد الدين بالكامل"
            _msg = f"تم سداد الدين بالكامل — دفعة {data.amount} {data.currency}"
        else:
            _title = "تحديث السداد"
            _msg = f"سداد جزئي: {data.amount} {data.currency}" + (
                f" — المتبقي {remaining:.2f}" if remaining is not None else "")
        try:
            from ...domain.services import merchant_link_service as mls
            pushes = service_pushes
            if pushes:
                tasks.add_task(mls.deliver_pushes, pushes, UUID(org_id))
        except Exception:  # noqa: BLE001
            pass
        return created(result, "تم تسجيل التحصيل بنجاح")
    except ValueError as e:
        await db.rollback()
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.get("/suppliers/{supplier_id}/balance", summary="Supplier open payable snapshot")
async def supplier_balance(
    supplier_id: UUID,
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("suppliers", "read")),
):
    from ...domain.services import sale_service
    from ...domain.entities.business_entities import Supplier as _S
    from sqlalchemy import select as _sel
    b = (await db.execute(_sel(_S.branch_id).where(
        _S.id == supplier_id, _S.organization_id == UUID(org_id)))).scalar_one_or_none()
    if not await _row_branch_allowed(db, b, scope):
        raise HTTPException(status_code=404, detail="المورد غير موجود")
    try:
        return ok(await sale_service.supplier_balance(db, UUID(org_id), supplier_id))
    except ValueError as e:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))


@router.post(
    "/suppliers/{supplier_id}/payments",
    summary="Pay a supplier against open purchase invoices",
    status_code=status.HTTP_201_CREATED,
)
async def pay_supplier(
    supplier_id: UUID,
    data: PartyPaymentRequest,
    tasks: BackgroundTasks,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    branch=Depends(get_branch_context),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("invoices", "update")),
):
    from ...domain.services import sale_service

    try:
        result = await sale_service.add_supplier_payment(
            db, UUID(org_id), user_id, supplier_id, data, branch_id=branch.id
        )
        service_pushes = result.pop('_notification_pushes', [])
        remaining = None
        try:
            from sqlalchemy import func as _func, select as _sel
            from ...domain.entities.invoice_entities import Invoice as _Inv
            if getattr(data, "invoice_id", None):
                inv = (await db.execute(_sel(_Inv).where(
                    _Inv.id == data.invoice_id))).scalar_one_or_none()
                if inv is not None:
                    remaining = float(inv.balance or 0)
            else:
                remaining = float((await db.execute(
                    _sel(_func.coalesce(_func.sum(_Inv.balance), 0)).where(
                        _Inv.organization_id == UUID(org_id),
                        _Inv.supplier_id == supplier_id,
                        _Inv.invoice_type == 'purchase',
                        ((_Inv.branch_id == branch.id) |
                         (_Inv.branch_id.is_(None) if branch.is_default else False)),
                        *([_Inv.debt_group_id == data.debt_group_id] if data.debt_group_id else []),
                        _Inv.is_deleted.is_(False),
                        _func.upper(_Inv.currency) ==
                        (data.currency or "").upper(),
                    ))).scalar() or 0)
        except Exception:  # noqa: BLE001
            remaining = None
        if remaining is not None and remaining <= 0.004:
            _title = "تم سداد المستحق بالكامل"
            _msg = f"تم سداد المستحق بالكامل — دفعة {data.amount} {data.currency}"
        else:
            _title = "تحديث السداد"
            _msg = f"سداد جزئي: {data.amount} {data.currency}" + (
                f" — المتبقي {remaining:.2f}" if remaining is not None else "")
        try:
            from ...domain.services import merchant_link_service as mls
            pushes = service_pushes
            if pushes:
                tasks.add_task(mls.deliver_pushes, pushes, UUID(org_id))
        except Exception:  # noqa: BLE001
            pass
        return created(result, "تم تسجيل الدفع للمورد بنجاح")
    except ValueError as e:
        await db.rollback()
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))


@router.get("/business/transactions", summary="Unified business transactions timeline")
async def business_transactions(
    request: Request,
    page: int = 1,
    per_page: int = 50,
    kind: Optional[str] = None,
    period: Optional[str] = None,
    search: Optional[str] = None,
    date_from: Optional[str] = None,
    date_to: Optional[str] = None,
    include_doc_legs: bool = False,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
    _: bool = Depends(require_permission("payments", "read")),
):
    """Read-only unified timeline over the movements that already exist in
    the system (sale/purchase invoices, returns, collections/supplier
    payments, expenses, bank movements). Every row keeps its real source
    id so the app can open the original document."""
    from ...domain.services import business_transactions_service as svc
    from ...domain.services.employee_access_policy import member_policy, visible_kinds
    policy = await member_policy(db, request, user_id)

    return ok(await svc.list_transactions(
        db, UUID(org_id), page=page, per_page=per_page,
        kind=kind, period=period, search=search,
        date_from=date_from, date_to=date_to,
        include_doc_legs=include_doc_legs,
        branch_ids=scope.branch_ids if scope.all_mode else [scope.branch_id],
        allowed_kinds=visible_kinds(policy) if policy is not None else None,
    ))


@router.get("/business/transactions/{source_type}/{source_id}",
            summary="One business transaction by its real source")
async def business_transaction_details(
    request: Request,
    source_type: str,
    source_id: UUID,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    scope=Depends(get_branch_scope),
    _: bool = Depends(require_permission("payments", "read")),
):
    from ...domain.services import business_transactions_service as svc

    row = await svc.get_transaction(db, UUID(org_id), source_type, source_id)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                             detail="المعاملة غير موجودة")
    from ...domain.services.employee_access_policy import member_policy, visible_kinds
    policy = await member_policy(db, request, user_id)
    if policy is not None and row.get('kind') not in visible_kinds(policy):
        raise HTTPException(404, detail='المعاملة غير موجودة')
    permitted = {str(b) for b in scope.branch_ids} if scope.all_mode else {str(scope.branch_id)}
    if row.get('branch_id') and str(row['branch_id']) not in permitted:
        raise HTTPException(404, detail='المعاملة غير موجودة')
    return ok(row)
