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


class SalesOrder(Base):
    __tablename__ = "sales_orders"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    customer_id = Column(
        UUID(as_uuid=True), ForeignKey("customers.id", ondelete="SET NULL"), index=True
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
    delivered_at = Column(DateTime(timezone=True))
    cancelled_at = Column(DateTime(timezone=True))

    customer = relationship("Customer", lazy="selectin")
    items = relationship(
        "SalesOrderItem",
        back_populates="order",
        lazy="selectin",
        cascade="all, delete-orphan",
    )

    __table_args__ = (
        UniqueConstraint(
            "organization_id", "order_number", name="uq_sales_orders_org_number"
        ),
        CheckConstraint(
            "status IN ('draft','confirmed','delivered','cancelled','returned')",
            name="ck_sales_order_status",
        ),
    )


class SalesOrderItem(Base):
    __tablename__ = "sales_order_items"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    sales_order_id = Column(
        UUID(as_uuid=True),
        ForeignKey("sales_orders.id", ondelete="CASCADE"),
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
    tax_rate = Column(Numeric(5, 2), default=0)
    total = Column(Numeric(12, 2), default=0)

    order = relationship("SalesOrder", back_populates="items")
    product = relationship("Product", lazy="selectin")

    __table_args__ = (CheckConstraint("quantity > 0", name="ck_so_item_qty"),)


class SalesReturn(Base):
    __tablename__ = "sales_returns"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    customer_id = Column(
        UUID(as_uuid=True), ForeignKey("customers.id", ondelete="SET NULL"), index=True
    )
    sales_order_id = Column(
        UUID(as_uuid=True),
        ForeignKey("sales_orders.id", ondelete="SET NULL"),
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

    customer = relationship("Customer", lazy="selectin")
    items = relationship(
        "SalesReturnItem",
        back_populates="return_",
        lazy="selectin",
        cascade="all, delete-orphan",
    )

    __table_args__ = (
        UniqueConstraint("organization_id", "return_number", name="uq_sr_org_number"),
        CheckConstraint(
            "status IN ('draft','confirmed','cancelled')", name="ck_sales_return_status"
        ),
    )


class SalesReturnItem(Base):
    __tablename__ = "sales_return_items"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    sales_return_id = Column(
        UUID(as_uuid=True),
        ForeignKey("sales_returns.id", ondelete="CASCADE"),
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

    return_ = relationship("SalesReturn", back_populates="items")
    product = relationship("Product", lazy="selectin")

    __table_args__ = (CheckConstraint("quantity > 0", name="ck_sr_item_qty"),)


class SalesQuote(Base):
    __tablename__ = "sales_quotes"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    customer_id = Column(
        UUID(as_uuid=True), ForeignKey("customers.id", ondelete="SET NULL"), index=True
    )
    quote_number = Column(String(50), nullable=False, index=True)
    quote_date = Column(Date, nullable=False, default=date.today)
    expiry_date = Column(Date)
    status = Column(String(20), nullable=False, default="draft")
    subtotal = Column(Numeric(12, 2), default=0)
    discount_type = Column(String(20))
    discount_value = Column(Numeric(12, 2), default=0)
    discount_amount = Column(Numeric(12, 2), default=0)
    tax_type = Column(String(20))
    tax_rate = Column(Numeric(5, 2), default=0)
    tax_amount = Column(Numeric(12, 2), default=0)
    total = Column(Numeric(12, 2), default=0)
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

    customer = relationship("Customer", lazy="selectin")
    items = relationship(
        "QuoteItem",
        back_populates="quote",
        lazy="selectin",
        cascade="all, delete-orphan",
    )

    __table_args__ = (
        UniqueConstraint("organization_id", "quote_number", name="uq_sq_org_number"),
        CheckConstraint(
            "status IN ('draft','sent','accepted','rejected','expired')",
            name="ck_quote_status",
        ),
    )


class QuoteItem(Base):
    __tablename__ = "quote_items"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    quote_id = Column(
        UUID(as_uuid=True),
        ForeignKey("sales_quotes.id", ondelete="CASCADE"),
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

    quote = relationship("SalesQuote", back_populates="items")
    product = relationship("Product", lazy="selectin")

    __table_args__ = (CheckConstraint("quantity > 0", name="ck_qi_qty"),)


class DeliveryNote(Base):
    __tablename__ = "delivery_notes"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    customer_id = Column(
        UUID(as_uuid=True), ForeignKey("customers.id", ondelete="SET NULL"), index=True
    )
    sales_order_id = Column(
        UUID(as_uuid=True),
        ForeignKey("sales_orders.id", ondelete="SET NULL"),
        index=True,
    )
    delivery_number = Column(String(50), nullable=False, index=True)
    delivery_date = Column(Date, nullable=False, default=date.today)
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

    customer = relationship("Customer", lazy="selectin")
    items = relationship(
        "DeliveryNoteItem",
        back_populates="note",
        lazy="selectin",
        cascade="all, delete-orphan",
    )

    __table_args__ = (
        UniqueConstraint("organization_id", "delivery_number", name="uq_dn_org_number"),
        CheckConstraint(
            "status IN ('draft','confirmed','cancelled')", name="ck_dn_status"
        ),
    )


class DeliveryNoteItem(Base):
    __tablename__ = "delivery_note_items"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    delivery_note_id = Column(
        UUID(as_uuid=True),
        ForeignKey("delivery_notes.id", ondelete="CASCADE"),
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

    note = relationship("DeliveryNote", back_populates="items")
    product = relationship("Product", lazy="selectin")

    __table_args__ = (CheckConstraint("quantity > 0", name="ck_dni_qty"),)
