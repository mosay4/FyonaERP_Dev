import uuid
from datetime import datetime, timezone
from sqlalchemy import (
    Column,
    String,
    Boolean,
    DateTime,
    Date,
    ForeignKey,
    Text,
    Float,
    Numeric,
    Integer,
    UniqueConstraint,
    CheckConstraint,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class Customer(Base):
    __tablename__ = "customers"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    branch_id = Column(
        UUID(as_uuid=True),
        ForeignKey("branches.id", ondelete="SET NULL"),
        index=True,
    )
    name = Column(String(200), nullable=False, index=True)
    phone = Column(String(50))
    email = Column(String(100))
    tax_number = Column(String(100))
    cr_number = Column(String(100))
    address = Column(Text)
    contact_person = Column(String(200))
    notes = Column(Text)
    credit_limit = Column(Numeric(12, 2), default=0)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))


class Supplier(Base):
    __tablename__ = "suppliers"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    branch_id = Column(
        UUID(as_uuid=True),
        ForeignKey("branches.id", ondelete="SET NULL"),
        index=True,
    )
    name = Column(String(200), nullable=False, index=True)
    phone = Column(String(50))
    email = Column(String(100))
    tax_number = Column(String(100))
    cr_number = Column(String(100))
    address = Column(Text)
    contact_person = Column(String(200))
    notes = Column(Text)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))


class ProductCategory(Base):
    __tablename__ = "product_categories"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    name = Column(String(200), nullable=False)
    name_ar = Column(String(200))
    description = Column(Text)
    image = Column(String(500))
    is_active = Column(Boolean, default=True)
    is_deleted = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), default=utcnow)

    products = relationship("Product", back_populates="category")


class Product(Base):
    __tablename__ = "products"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    category_id = Column(
        UUID(as_uuid=True),
        ForeignKey("product_categories.id", ondelete="SET NULL"),
        index=True,
    )
    branch_id = Column(
        UUID(as_uuid=True),
        ForeignKey("branches.id", ondelete="SET NULL"),
        index=True,
    )
    name = Column(String(200), nullable=False, index=True)
    name_ar = Column(String(200))
    sku = Column(String(100), index=True)
    barcode = Column(String(100))
    description = Column(Text)
    unit = Column(String(50), default="قطعة")
    price = Column(Numeric(12, 2), nullable=False, default=0)
    cost_price = Column(Numeric(12, 2), default=0)
    # Currency of `cost_price` as last purchased (never auto-converted, so a
    # historical purchase cost keeps its original currency).
    cost_currency = Column(String(10))
    stock = Column(Numeric(18, 4), default=0)
    min_stock = Column(Numeric(18, 4), default=0)
    is_service = Column(Boolean, default=False)
    is_active = Column(Boolean, default=True)
    expiry_date = Column(Date)
    image = Column(String(500))
    notes = Column(Text)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))

    category = relationship(
        "ProductCategory", back_populates="products", lazy="selectin"
    )

    __table_args__ = (
        CheckConstraint("price >= 0", name="ck_product_price_non_negative"),
    )


class InventoryMovement(Base):
    __tablename__ = "inventory_movements"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    product_id = Column(
        UUID(as_uuid=True),
        ForeignKey("products.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    movement_type = Column(String(50), nullable=False)
    quantity = Column(Float, nullable=False)
    unit_price = Column(Numeric(12, 2), default=0)
    total = Column(Numeric(12, 2), default=0)
    # Currency of unit_price/total for this movement (original purchase
    # currency), so historical costs are never silently re-converted.
    currency = Column(String(10))
    # Stock-adjustment audit (plain-language reasons: خطأ/تالف/مفقود/زيادة…).
    reason = Column(String(40))
    old_quantity = Column(Float)
    new_quantity = Column(Float)
    difference = Column(Float)
    branch_id = Column(
        UUID(as_uuid=True), ForeignKey("branches.id", ondelete="SET NULL")
    )
    reference_type = Column(String(50))
    reference_id = Column(UUID(as_uuid=True))
    notes = Column(Text)
    created_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at = Column(DateTime(timezone=True), default=utcnow)


class WarehouseSetting(Base):
    """Per-organization warehouse feature flags that the SERVER needs (for the
    scheduled expiry-notification job). The UI flags stay client-side; this
    mirrors only what the background job must know."""

    __tablename__ = "warehouse_settings"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        unique=True,
    )
    expiry_enabled = Column(Boolean, nullable=False, default=False)
    expiry_warn_days = Column(Integer, nullable=False, default=60)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class ExpiryNotification(Base):
    """Dedup marker: one row per (organization, product, day) so the expiry
    job never sends the same product alert twice in a day."""

    __tablename__ = "expiry_notifications"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
    )
    product_id = Column(
        UUID(as_uuid=True),
        ForeignKey("products.id", ondelete="CASCADE"),
        nullable=False,
    )
    notified_on = Column(Date, nullable=False)
    created_at = Column(DateTime(timezone=True), default=utcnow)

    __table_args__ = (
        UniqueConstraint(
            "organization_id", "product_id", "notified_on",
            name="uq_expiry_notif_org_product_day",
        ),
    )
