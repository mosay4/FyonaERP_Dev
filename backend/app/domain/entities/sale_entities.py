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
    Integer,
    Numeric,
    JSON,
    UniqueConstraint,
    CheckConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class ProductUnit(Base):
    """Sellable unit of a product (قطعة / باكيت / كرتون ...).

    factor = how many BASE units one of this unit equals
    (base unit itself has factor 1). Prices are optional overrides;
    when NULL the caller falls back to the product's own prices.
    Managed inside Inventory → add/edit product, never inside invoices.
    """

    __tablename__ = "product_units"

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
    name = Column(String(50), nullable=False)
    factor = Column(Numeric(12, 4), nullable=False, default=1)
    # Measurement family (count/weight/volume/length/area/time/service). Kept
    # so a product's extra units stay compatible with its base unit even for
    # merchant-defined units that are not in the canonical name table. NULL for
    # legacy rows = unknown (never blocked).
    group = Column(String(20))
    barcode = Column(String(100))
    sale_price = Column(Numeric(12, 2))
    purchase_price = Column(Numeric(12, 2))
    is_base = Column(Boolean, default=False)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)

    product = relationship("Product", lazy="selectin")

    __table_args__ = (
        UniqueConstraint(
            "organization_id", "product_id", "name", name="uq_unit_org_product_name"
        ),
        CheckConstraint("factor > 0", name="ck_unit_factor_positive"),
    )


class ProductBarcode(Base):
    """Extra barcodes of a product: aliases of the base unit or barcodes of
    a specific unit. Lookup order is always unit barcode first, then the
    product's own `barcode` column (kept for backward compatibility)."""

    __tablename__ = "product_barcodes"

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
    unit_id = Column(
        UUID(as_uuid=True),
        ForeignKey("product_units.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    barcode = Column(String(100), nullable=False)

    __table_args__ = (
        UniqueConstraint("organization_id", "barcode", name="uq_barcode_org_code"),
    )


class ProductPrice(Base):
    """Per-currency SELL price for a product.

    A merchant can price a product in several currencies (SAR / USD / YER…).
    Each row is independent and NEVER re-derived from today's exchange rate,
    so a price the merchant set stays exactly as set.
    """

    __tablename__ = "product_prices"

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
    currency = Column(String(10), nullable=False)
    price = Column(Numeric(12, 2), nullable=False, default=0)
    buy_price = Column(Numeric(12, 2))
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)

    __table_args__ = (
        UniqueConstraint(
            "organization_id",
            "product_id",
            "currency",
            name="uq_price_org_product_currency",
        ),
        CheckConstraint("price >= 0", name="ck_product_price_non_negative"),
    )


class Branch(Base):
    """Minimal branch registry. Sale invoices always carry a branch_id
    (the org default is auto-created on first use). Per-branch stock split
    is intentionally NOT modeled yet — stock stays on Product.stock."""

    __tablename__ = "branches"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    name = Column(String(200), nullable=False)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
    # Per-branch business identity picture (server-relative upload path).
    image = Column(String(500))
    # Per-branch preferences that must survive reinstall (currencies, etc.).
    settings = Column(JSON, nullable=True)
    is_default = Column(Boolean, default=False)
    is_active = Column(Boolean, default=True)
    is_archived = Column(Boolean, default=False, nullable=False,
                       server_default=text("false"))
    archived_at = Column(DateTime(timezone=True))
    updated_at = Column(DateTime(timezone=True), default=utcnow,
                        onupdate=utcnow)
    created_at = Column(DateTime(timezone=True), default=utcnow)

    __table_args__ = (
        UniqueConstraint("organization_id", "name", name="uq_branch_org_name"),
    )


class CustomerReceivable(Base):
    """Explicit debt row: the unpaid remainder of a sale invoice, linked to
    both the customer and the invoice. Paid down by later collections (and
    reduced by confirmed returns). The invoice `balance` stays the
    invoice-level mirror; this row is the customer-level one."""

    __tablename__ = "customer_receivables"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    customer_id = Column(
        UUID(as_uuid=True),
        ForeignKey("customers.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    invoice_id = Column(
        UUID(as_uuid=True),
        ForeignKey("invoices.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    amount = Column(Numeric(12, 2), nullable=False, default=0)
    paid = Column(Numeric(12, 2), nullable=False, default=0)
    status = Column(String(20), nullable=False, default="open")
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)

    __table_args__ = (
        UniqueConstraint("invoice_id", name="uq_receivable_invoice"),
        CheckConstraint("amount >= 0", name="ck_receivable_amount_non_negative"),
        CheckConstraint("paid >= 0", name="ck_receivable_paid_non_negative"),
        CheckConstraint(
            "status IN ('open', 'partial', 'paid', 'cancelled')",
            name="ck_receivable_status_valid",
        ),
    )


class SupplierPayable(Base):
    """Explicit debt row mirroring CustomerReceivable, but for the money the
    business still owes a supplier on an unpaid purchase invoice. Paid down by
    later supplier payments; the invoice `balance` stays the invoice-level
    mirror, this row is the supplier-level one."""

    __tablename__ = "supplier_payables"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    supplier_id = Column(
        UUID(as_uuid=True),
        ForeignKey("suppliers.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    invoice_id = Column(
        UUID(as_uuid=True),
        ForeignKey("invoices.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    amount = Column(Numeric(12, 2), nullable=False, default=0)
    paid = Column(Numeric(12, 2), nullable=False, default=0)
    status = Column(String(20), nullable=False, default="open")
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)

    __table_args__ = (
        UniqueConstraint("invoice_id", name="uq_payable_invoice"),
        CheckConstraint("amount >= 0", name="ck_payable_amount_non_negative"),
        CheckConstraint("paid >= 0", name="ck_payable_paid_non_negative"),
        CheckConstraint(
            "status IN ('open', 'partial', 'paid', 'cancelled')",
            name="ck_payable_status_valid",
        ),
    )


class InvoiceReturn(Base):
    """Return linked ALWAYS to its original invoice. Confirming restocks,
    shrinks the invoice balance/receivable first, then refunds the rest
    through a chosen account. No accounting complexity beyond that."""

    __tablename__ = "invoice_returns"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    invoice_id = Column(
        UUID(as_uuid=True),
        ForeignKey("invoices.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    return_number = Column(String(50), nullable=False, index=True)
    return_date = Column(Date, nullable=False, default=date.today)
    status = Column(String(20), nullable=False, default="confirmed")
    reason = Column(Text)
    total = Column(Numeric(12, 2), nullable=False, default=0)
    created_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at = Column(DateTime(timezone=True), default=utcnow)

    items = relationship(
        "InvoiceReturnItem",
        back_populates="invoice_return",
        lazy="selectin",
        cascade="all, delete-orphan",
    )

    __table_args__ = (
        UniqueConstraint(
            "organization_id", "return_number", name="uq_returns_org_number"
        ),
        CheckConstraint(
            "status IN ('confirmed', 'cancelled')",
            name="ck_return_status_valid",
        ),
    )


class InvoiceReturnItem(Base):
    __tablename__ = "invoice_return_items"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    return_id = Column(
        UUID(as_uuid=True),
        ForeignKey("invoice_returns.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    invoice_item_id = Column(
        UUID(as_uuid=True),
        ForeignKey("invoice_items.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    product_id = Column(
        UUID(as_uuid=True), ForeignKey("products.id", ondelete="SET NULL"), index=True
    )
    description = Column(String(500), nullable=False)
    quantity = Column(Float, nullable=False)
    unit_price = Column(Numeric(12, 2), nullable=False, default=0)
    total = Column(Numeric(12, 2), nullable=False, default=0)

    invoice_return = relationship("InvoiceReturn", back_populates="items")

    __table_args__ = (
        CheckConstraint("quantity > 0", name="ck_return_item_qty_positive"),
    )


class BranchStock(Base):
    """Authoritative per-branch stock and weighted-average cost.

    Option A migration: every product's existing stock lives on the MAIN
    branch only; new branches start at zero. `Product.stock` is kept as the
    legacy mirror for the main branch until all operations are rewired.
    """

    __tablename__ = "branch_stock"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    branch_id = Column(
        UUID(as_uuid=True),
        ForeignKey("branches.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    product_id = Column(
        UUID(as_uuid=True),
        ForeignKey("products.id", ondelete="CASCADE"),
        nullable=False, index=True,
    )
    quantity = Column(Numeric(14, 3), nullable=False, default=0)
    avg_cost = Column(Numeric(14, 4), nullable=False, default=0)
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow,
                        onupdate=utcnow)

    __table_args__ = (
        UniqueConstraint("branch_id", "product_id",
                         name="uq_branch_stock_branch_product"),
    )


class InventoryLot(Base):
    """One purchase batch/lot, kept INDEPENDENT for exact costing.

    Stock leaving the warehouse is matched FIFO (oldest first) or FEFO
    (nearest expiry first) against these rows, so COGS/profit come from the
    real batches consumed — never from a blended average cost.
    """

    __tablename__ = "inventory_lots"

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
    branch_id = Column(
        UUID(as_uuid=True), ForeignKey("branches.id", ondelete="SET NULL")
    )
    supplier_id = Column(
        UUID(as_uuid=True), ForeignKey("suppliers.id", ondelete="SET NULL")
    )
    purchase_invoice_id = Column(
        UUID(as_uuid=True), ForeignKey("invoices.id", ondelete="SET NULL")
    )
    invoice_item_id = Column(
        UUID(as_uuid=True), ForeignKey("invoice_items.id", ondelete="SET NULL")
    )
    unit_id = Column(
        UUID(as_uuid=True), ForeignKey("product_units.id", ondelete="SET NULL")
    )
    received_quantity = Column(Float, nullable=False, default=0)
    remaining_quantity = Column(Float, nullable=False, default=0)
    # Cost per BASE unit, in `currency`; frozen at receipt.
    unit_cost = Column(Numeric(12, 4), nullable=False, default=0)
    currency = Column(String(10))
    # 1 `currency` = exchange_rate * organization base currency (snapshot).
    exchange_rate = Column(Numeric(18, 8), default=1)
    purchase_date = Column(Date)
    expiry_date = Column(Date)
    lot_number = Column(String(100))
    source = Column(String(30))  # purchase | opening | adjustment | return
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)


class InventoryLotConsumption(Base):
    """Links a sold invoice line to the exact lot(s) it consumed."""

    __tablename__ = "inventory_lot_consumptions"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    lot_id = Column(
        UUID(as_uuid=True),
        ForeignKey("inventory_lots.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    invoice_item_id = Column(
        UUID(as_uuid=True), ForeignKey("invoice_items.id", ondelete="CASCADE")
    )
    quantity = Column(Float, nullable=False, default=0)
    unit_cost = Column(Numeric(12, 4), nullable=False, default=0)
    currency = Column(String(10))
    created_at = Column(DateTime(timezone=True), default=utcnow)
