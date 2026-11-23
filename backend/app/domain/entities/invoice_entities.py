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
    UniqueConstraint,
    CheckConstraint,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from app.core.database import Base


def utcnow():
    return datetime.now(timezone.utc)


class Invoice(Base):
    __tablename__ = "invoices"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    invoice_number = Column(String(50), nullable=False, index=True)
    invoice_type = Column(String(20), nullable=False, default="sale")
    customer_id = Column(
        UUID(as_uuid=True), ForeignKey("customers.id", ondelete="SET NULL"), index=True
    )
    supplier_id = Column(
        UUID(as_uuid=True), ForeignKey("suppliers.id", ondelete="SET NULL"), index=True
    )
    invoice_date = Column(Date, nullable=False, default=date.today)
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
    debt_group_id = Column(UUID(as_uuid=True), nullable=True)
    notes = Column(Text)
    terms = Column(Text)
    created_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at = Column(DateTime(timezone=True), default=utcnow)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
    is_deleted = Column(Boolean, default=False)
    deleted_at = Column(DateTime(timezone=True))
    confirmed_at = Column(DateTime(timezone=True))
    cancelled_at = Column(DateTime(timezone=True))
    # Sale-invoice extensions (all nullable/backward-compatible):
    # strict single currency per invoice, owning branch, and the
    # client idempotency key that makes re-issue safe (double-tap/retries).
    currency = Column(String(10), nullable=False, default="SAR")
    branch_id = Column(
        UUID(as_uuid=True), ForeignKey("branches.id", ondelete="SET NULL"), index=True
    )
    idempotency_key = Column(String(100))

    customer = relationship("Customer", lazy="selectin")
    supplier = relationship("Supplier", lazy="selectin")
    items = relationship(
        "InvoiceItem",
        back_populates="invoice",
        lazy="selectin",
        cascade="all, delete-orphan",
    )
    payments = relationship(
        "Payment",
        back_populates="invoice",
        lazy="selectin",
        cascade="all, delete-orphan",
    )

    __table_args__ = (
        UniqueConstraint(
            "organization_id", "invoice_number", name="uq_invoices_org_number"
        ),
        UniqueConstraint(
            "organization_id",
            "idempotency_key",
            name="uq_invoices_org_idempotency",
        ),
        CheckConstraint(
            "invoice_type IN ('sale', 'purchase')", name="ck_invoice_type_valid"
        ),
        CheckConstraint(
            "status IN ('draft', 'confirmed', 'cancelled', 'paid', 'partially_paid')",
            name="ck_invoice_status_valid",
        ),
    )


class InvoiceItem(Base):
    __tablename__ = "invoice_items"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    invoice_id = Column(
        UUID(as_uuid=True),
        ForeignKey("invoices.id", ondelete="CASCADE"),
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
    # Line snapshot extensions: the sold unit (name + id for traceability),
    # the quantity converted to BASE units (what stock actually lost), and
    # whether this line is a non-stock service/manual entry.
    unit_id = Column(
        UUID(as_uuid=True),
        ForeignKey("product_units.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    unit_name = Column(String(50))
    base_quantity = Column(Float, default=0)
    # Conversion-factor snapshot at issue time: base units per sold unit. Kept
    # so a later edit of the unit's factor can NEVER change how a historical
    # sale/purchase (or its returns) converts quantities.
    factor = Column(Numeric(12, 4), nullable=True)
    is_service = Column(Boolean, default=False)
    # Frozen product-image snapshot at issue time so an old invoice never
    # changes when the merchant later replaces the product picture.
    image = Column(String(500))
    # Real FIFO/FEFO cost of the lots this sale line consumed, and the profit
    # (line_total - cost_total) frozen at issue time.
    cost_total = Column(Numeric(12, 2))
    profit = Column(Numeric(12, 2))
    # Sell-price snapshot: the original price + its currency + the FX rate used
    # to convert it to the invoice currency at issue time.
    original_unit_price = Column(Numeric(12, 2))
    price_currency = Column(String(10))
    exchange_rate_used = Column(Numeric(18, 8))

    invoice = relationship("Invoice", back_populates="items")
    product = relationship("Product", lazy="selectin")

    __table_args__ = (
        CheckConstraint("quantity > 0", name="ck_invoice_item_qty_positive"),
    )


class Payment(Base):
    __tablename__ = "payments"

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
    invoice_id = Column(
        UUID(as_uuid=True),
        ForeignKey("invoices.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    amount = Column(Numeric(12, 2), nullable=False)
    payment_date = Column(Date, nullable=False, default=date.today)
    payment_method = Column(String(50), default="cash")
    reference = Column(String(200))
    notes = Column(Text)
    # Which bank/cash account actually received the money (sale split
    # payments). NULL only for legacy rows created before accounts existed.
    bank_account_id = Column(
        UUID(as_uuid=True),
        ForeignKey("bank_accounts.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    # Multi-currency split-payment snapshot. `amount` above stays the value in
    # the invoice currency (backward compatible); these preserve the money as
    # it was actually received and the frozen conversion at issue time.
    payment_currency = Column(String(10))
    invoice_currency = Column(String(10))
    original_amount = Column(Numeric(12, 2))
    exchange_rate = Column(Numeric(18, 8))
    equivalent_amount = Column(Numeric(12, 2))
    exchange_rate_source = Column(String(20))
    exchange_rate_timestamp = Column(DateTime(timezone=True))
    created_by = Column(
        UUID(as_uuid=True), ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    created_at = Column(DateTime(timezone=True), default=utcnow)

    invoice = relationship("Invoice", back_populates="payments")
    bank_account = relationship("BankAccount", lazy="selectin")

    __table_args__ = (
        CheckConstraint("amount > 0", name="ck_payment_amount_positive"),
        CheckConstraint(
            "payment_method IN ('cash', 'bank', 'card', 'transfer', 'cheque')",
            name="ck_payment_method_valid",
        ),
    )


class InvoiceSequence(Base):
    __tablename__ = "invoice_sequences"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    prefix = Column(String(20), nullable=False)
    last_sequence = Column(Integer, default=0)
    date = Column(Date, nullable=False)

    __table_args__ = (
        UniqueConstraint(
            "organization_id", "prefix", "date", name="uq_inv_seq_org_prefix_date"
        ),
    )


class OrgInvoiceDesign(Base):
    """The merchant's customized A4/paper invoice design, stored server-side so
    the LINKED customer/supplier can see the EXACT same invoice (logo, colours,
    signature, stamp, footer). Images are base64 inside `payload`."""

    __tablename__ = "org_invoice_designs"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    organization_id = Column(
        UUID(as_uuid=True),
        ForeignKey("organizations.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    branch_id = Column(
        UUID(as_uuid=True), ForeignKey("branches.id", ondelete="CASCADE"),
        nullable=True, index=True,
    )
    template_id = Column(String(30), nullable=False, default="paper")
    payload = Column(Text, nullable=False)
    updated_at = Column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)

    __table_args__ = (
        UniqueConstraint("organization_id", "branch_id", "template_id",
                         name="uq_org_invoice_design_branch"),
    )


class InvoiceItemChange(Base):
    """A single quantity/price change the merchant made to an invoice line,
    shown to the linked party as «before → after» so every edit is traceable."""

    __tablename__ = "invoice_item_changes"

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
    item_id = Column(UUID(as_uuid=True), nullable=True)
    description = Column(String(500))
    old_quantity = Column(Float, nullable=True)
    new_quantity = Column(Float, nullable=True)
    old_unit_price = Column(Numeric(12, 2), nullable=True)
    new_unit_price = Column(Numeric(12, 2), nullable=True)
    changed_by = Column(UUID(as_uuid=True), nullable=True)
    changed_at = Column(DateTime(timezone=True), default=utcnow)
