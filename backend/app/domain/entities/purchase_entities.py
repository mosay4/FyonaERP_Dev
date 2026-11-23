import uuid
from datetime import datetime, timezone, date
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
    UniqueConstraint,
    CheckConstraint,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from app.core.database import Base


class PurchaseOrder(Base):
    __tablename__ = "purchase_orders"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    supplier_id = Column(
        UUID(as_uuid=True), ForeignKey("suppliers.id", ondelete="SET NULL"), index=True
    )
    order_number = Column(String(50), nullable=False, index=True)
    order_date = Column(Date, nullable=False, default=date.today)
    status = Column(String(20), nullable=False, default="draft")
    subtotal = Column(Numeric(12, 2), default=0)
    discount_type = Column(String(20))
    discount_value = Column(Numeric(12, 2), default=0)
    discount_amount = Column(Numeric(12, 2), default=0)
    tax_type = Column(String(20))
    tax_rate = Column(Numeric(5, 2), default=0)
    tax_amount = Column(Numeric(12, 2), default=0)
    total = Column(Numeric(12, 2), default=0)
    paid_amount = Column(Numeric(12, 2), default=0)
    balance = Column(Numeric(12, 2), default=0)
    notes = Column(Text)
    terms = Column(Text)
    created_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
    updated_at = Column(
        DateTime(timezone=True),
        default=datetime.now(timezone.utc),
        onupdate=datetime.now(timezone.utc),
    )
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))
    confirmed_at = Column(DateTime(timezone=True))
    received_at = Column(DateTime(timezone=True))
    cancelled_at = Column(DateTime(timezone=True))

    supplier = relationship("Supplier", lazy="selectin")
    items = relationship(
        "PurchaseOrderItem",
        back_populates="order",
        lazy="selectin",
        cascade="all, delete-orphan",
    )

    __table_args__ = (
        UniqueConstraint("organization_id", "order_number", name="uq_po_org_number"),
        CheckConstraint(
            "status IN ('draft','confirmed','received','cancelled')",
            name="ck_po_status",
        ),
    )


class PurchaseOrderItem(Base):
    __tablename__ = "purchase_order_items"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    purchase_order_id = Column(
        UUID(as_uuid=True),
        ForeignKey("purchase_orders.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    product_id = Column(
        UUID(as_uuid=True), ForeignKey("products.id", ondelete="SET NULL"), index=True
    )
    description = Column(String(500), nullable=False)
    quantity = Column(Float, nullable=False, default=1)
    unit_price = Column(Numeric(12, 2), nullable=False, default=0)
    discount = Column(Numeric(12, 2), default=0)
    total = Column(Numeric(12, 2), default=0)

    order = relationship("PurchaseOrder", back_populates="items")
    product = relationship("Product", lazy="selectin")

    __table_args__ = (CheckConstraint("quantity > 0", name="ck_poi_qty"),)


class PurchaseReceipt(Base):
    __tablename__ = "purchase_receipts"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    supplier_id = Column(
        UUID(as_uuid=True), ForeignKey("suppliers.id", ondelete="SET NULL"), index=True
    )
    purchase_order_id = Column(
        UUID(as_uuid=True),
        ForeignKey("purchase_orders.id", ondelete="SET NULL"),
        index=True,
    )
    receipt_number = Column(String(50), nullable=False, index=True)
    receipt_date = Column(Date, nullable=False, default=date.today)
    status = Column(String(20), nullable=False, default="draft")
    notes = Column(Text)
    created_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
    updated_at = Column(
        DateTime(timezone=True),
        default=datetime.now(timezone.utc),
        onupdate=datetime.now(timezone.utc),
    )

    supplier = relationship("Supplier", lazy="selectin")
    items = relationship(
        "PurchaseReceiptItem",
        back_populates="receipt",
        lazy="selectin",
        cascade="all, delete-orphan",
    )

    __table_args__ = (
        UniqueConstraint("organization_id", "receipt_number", name="uq_pr_org_number"),
        CheckConstraint(
            "status IN ('draft','confirmed','cancelled')", name="ck_pr_status"
        ),
    )


class PurchaseReceiptItem(Base):
    __tablename__ = "purchase_receipt_items"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    purchase_receipt_id = Column(
        UUID(as_uuid=True),
        ForeignKey("purchase_receipts.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    product_id = Column(
        UUID(as_uuid=True), ForeignKey("products.id", ondelete="SET NULL"), index=True
    )
    description = Column(String(500), nullable=False)
    quantity = Column(Float, nullable=False, default=1)
    unit_price = Column(Numeric(12, 2), default=0)
    total = Column(Numeric(12, 2), default=0)

    receipt = relationship("PurchaseReceipt", back_populates="items")
    product = relationship("Product", lazy="selectin")

    __table_args__ = (CheckConstraint("quantity > 0", name="ck_pri_qty"),)


class PurchaseReturn(Base):
    __tablename__ = "purchase_returns"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    supplier_id = Column(
        UUID(as_uuid=True), ForeignKey("suppliers.id", ondelete="SET NULL"), index=True
    )
    purchase_order_id = Column(
        UUID(as_uuid=True),
        ForeignKey("purchase_orders.id", ondelete="SET NULL"),
        index=True,
    )
    invoice_id = Column(
        UUID(as_uuid=True),
        ForeignKey("invoices.id", ondelete="CASCADE"),
        index=True,
    )
    return_number = Column(String(50), nullable=False, index=True)
    return_date = Column(Date, nullable=False, default=date.today)
    status = Column(String(20), nullable=False, default="draft")
    reason = Column(Text)
    total = Column(Numeric(12, 2), default=0)
    notes = Column(Text)
    created_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
    updated_at = Column(
        DateTime(timezone=True),
        default=datetime.now(timezone.utc),
        onupdate=datetime.now(timezone.utc),
    )

    supplier = relationship("Supplier", lazy="selectin")
    items = relationship(
        "PurchaseReturnItem",
        back_populates="return_",
        lazy="selectin",
        cascade="all, delete-orphan",
    )

    __table_args__ = (
        UniqueConstraint("organization_id", "return_number", name="uq_pur_org_number"),
        CheckConstraint(
            "status IN ('draft','confirmed','cancelled')", name="ck_pur_status"
        ),
    )


class PurchaseReturnItem(Base):
    __tablename__ = "purchase_return_items"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    purchase_return_id = Column(
        UUID(as_uuid=True),
        ForeignKey("purchase_returns.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    product_id = Column(
        UUID(as_uuid=True), ForeignKey("products.id", ondelete="SET NULL"), index=True
    )
    invoice_item_id = Column(
        UUID(as_uuid=True),
        ForeignKey("invoice_items.id", ondelete="SET NULL"),
        index=True,
    )
    description = Column(String(500), nullable=False)
    quantity = Column(Float, nullable=False, default=1)
    unit_price = Column(Numeric(12, 2), default=0)
    total = Column(Numeric(12, 2), default=0)

    return_ = relationship("PurchaseReturn", back_populates="items")
    product = relationship("Product", lazy="selectin")

    __table_args__ = (CheckConstraint("quantity > 0", name="ck_puri_qty"),)


class SupplierBill(Base):
    __tablename__ = "supplier_bills"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    supplier_id = Column(
        UUID(as_uuid=True), ForeignKey("suppliers.id", ondelete="SET NULL"), index=True
    )
    purchase_order_id = Column(
        UUID(as_uuid=True),
        ForeignKey("purchase_orders.id", ondelete="SET NULL"),
        index=True,
    )
    bill_number = Column(String(50), nullable=False, index=True)
    bill_date = Column(Date, nullable=False, default=date.today)
    due_date = Column(Date)
    status = Column(String(20), nullable=False, default="draft")
    subtotal = Column(Numeric(12, 2), default=0)
    discount_type = Column(String(20))
    discount_value = Column(Numeric(12, 2), default=0)
    discount_amount = Column(Numeric(12, 2), default=0)
    tax_type = Column(String(20))
    tax_rate = Column(Numeric(5, 2), default=0)
    tax_amount = Column(Numeric(12, 2), default=0)
    total = Column(Numeric(12, 2), default=0)
    paid_amount = Column(Numeric(12, 2), default=0)
    balance = Column(Numeric(12, 2), default=0)
    notes = Column(Text)
    created_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at = Column(DateTime(timezone=True), default=datetime.now(timezone.utc))
    updated_at = Column(
        DateTime(timezone=True),
        default=datetime.now(timezone.utc),
        onupdate=datetime.now(timezone.utc),
    )

    supplier = relationship("Supplier", lazy="selectin")

    __table_args__ = (
        UniqueConstraint("organization_id", "bill_number", name="uq_sb_org_number"),
        CheckConstraint(
            "status IN ('draft','confirmed','paid','partially_paid','cancelled')",
            name="ck_sb_status",
        ),
    )
