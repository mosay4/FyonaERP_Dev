from sqlalchemy import select
from sqlalchemy.orm import with_loader_criteria

from app.domain.entities.business_entities import Product, ProductCategory, InventoryMovement
from app.domain.entities.finance_entities import BankAccount, BankTransaction, Expense
from app.domain.entities.invoice_entities import Invoice, Payment
from app.domain.entities.purchase_entities import PurchaseReturn
from app.domain.entities.reconciliation_entities import Reconciliation
from app.domain.entities.sale_entities import InventoryLot, ProductUnit, InvoiceReturn


class ReportSession:
    """Scope every report query, including nested helper aggregations."""
    def __init__(self, db, branch_ids):
        self.db = db
        self.info = db.info
        ids = tuple(branch_ids)
        account_ids = select(BankAccount.__table__.c.id).where(
            BankAccount.__table__.c.branch_id.in_(ids))
        invoice_ids = select(Invoice.__table__.c.id).where(
            Invoice.__table__.c.branch_id.in_(ids))
        product_ids = select(Product.__table__.c.id).where(
            Product.__table__.c.branch_id.in_(ids))
        categories = select(Product.__table__.c.category_id).where(
            Product.__table__.c.branch_id.in_(ids))
        self.criteria = [
            with_loader_criteria(model, model.branch_id.in_(ids), include_aliases=True)
            for model in [Invoice, BankAccount, Product, Expense, InventoryLot, Reconciliation]
        ] + [
            with_loader_criteria(BankTransaction,
                BankTransaction.bank_account_id.in_(account_ids), include_aliases=True),
            with_loader_criteria(Payment, Payment.invoice_id.in_(invoice_ids), include_aliases=True),
            with_loader_criteria(InvoiceReturn, InvoiceReturn.invoice_id.in_(invoice_ids), include_aliases=True),
            with_loader_criteria(PurchaseReturn, PurchaseReturn.invoice_id.in_(invoice_ids), include_aliases=True),
            with_loader_criteria(InventoryMovement,
                InventoryMovement.product_id.in_(product_ids), include_aliases=True),
            with_loader_criteria(ProductUnit, ProductUnit.product_id.in_(product_ids), include_aliases=True),
            with_loader_criteria(ProductCategory, ProductCategory.id.in_(categories), include_aliases=True),
        ]

    async def execute(self, statement, *args, **kwargs):
        return await self.db.execute(statement.options(*self.criteria), *args, **kwargs)

    def add(self, value):
        self.db.add(value)
