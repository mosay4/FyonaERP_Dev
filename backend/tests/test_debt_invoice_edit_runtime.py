"""Debt invoice edit/delete runtime test (real DB, isolated rows).

Verifies: adjust qty/price recomputes totals, receivable, stock, records the
change; a scoped payment updates the bank; deleting the invoice restores stock,
reverses the bank payment, removes the receivable and soft-deletes the invoice.
"""

import asyncio
import os
import sys
import uuid
from datetime import date
from decimal import Decimal
from uuid import UUID

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete, select  # noqa: E402

from app.api.v1 import reconciliation as _R  # noqa: E402,F401
from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import Organization, User  # noqa: E402
from app.domain.entities.business_entities import (  # noqa: E402
    Customer, InventoryMovement, Product,
)
from app.domain.entities.finance_entities import (  # noqa: E402
    BankAccount, BankTransaction,
)
from app.domain.entities.invoice_entities import (  # noqa: E402
    Invoice, InvoiceItem, InvoiceItemChange, Payment,
)
from app.domain.entities.sale_entities import (  # noqa: E402
    CustomerReceivable,
)
from app.domain.models.invoice_models import PartyPaymentRequest  # noqa: E402
from app.domain.services import debt_invoice_service as dis  # noqa: E402
from app.domain.services import sale_service  # noqa: E402

PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    tag = uuid.uuid4().hex[:6]
    org = user = cust = prod = inv = acct = rec = None
    item1 = item2 = None
    try:
        async with async_session_factory() as db:
            org = Organization(name=f"Edit-{tag}", slug=f"edit-{tag}")
            db.add(org)
            await db.flush()
            user = User(organization_id=org.id, full_name=f"تاجر {tag}",
                        email=f"e{tag}@t.local", role="owner")
            db.add(user)
            await db.flush()
            cust = Customer(organization_id=org.id, name=f"زبون {tag}")
            prod = Product(organization_id=org.id, name=f"منتج {tag}",
                           sku=f"SKU-{tag}", unit="قطعة", stock=17,
                           cost_price=Decimal("4"),
                           cost_currency="SAR", is_service=False)
            db.add_all([cust, prod])
            await db.flush()
            acct = BankAccount(organization_id=org.id, bank_name="بنك",
                               account_name="جاري", account_number="1",
                               balance=Decimal("1000"), currency="SAR")
            db.add(acct)
            await db.flush()
            inv = Invoice(organization_id=org.id,
                          invoice_number=f"EDT-{tag}", invoice_type="sale",
                          customer_id=cust.id, invoice_date=date.today(),
                          status="confirmed", subtotal=Decimal("25"),
                          total=Decimal("25"), paid_amount=Decimal("0"),
                          balance=Decimal("25"), currency="SAR")
            db.add(inv)
            await db.flush()
            item1 = InvoiceItem(invoice_id=inv.id, product_id=prod.id,
                                description="بند 1", quantity=2,
                                unit_price=Decimal("10"),
                                discount=Decimal("0"), total=Decimal("20"),
                                base_quantity=2, factor=Decimal("1"),
                                is_service=False)
            item2 = InvoiceItem(invoice_id=inv.id, product_id=prod.id,
                                description="بند 2", quantity=1,
                                unit_price=Decimal("5"),
                                discount=Decimal("0"), total=Decimal("5"),
                                base_quantity=1, factor=Decimal("1"),
                                is_service=False)
            db.add_all([item1, item2])
            await db.flush()
            rec = CustomerReceivable(organization_id=org.id,
                                     customer_id=cust.id, invoice_id=inv.id,
                                     amount=Decimal("25"), paid=Decimal("0"),
                                     status="open")
            db.add(rec)
            db.add(InventoryMovement(organization_id=org.id,
                                     product_id=prod.id, movement_type="sale",
                                     quantity=-3, unit_price=Decimal("10"),
                                     total=Decimal("-25"),
                                     reference_type="invoice",
                                     reference_id=inv.id))
            await db.commit()

        # ── adjust ──
        async with async_session_factory() as db:
            res = await dis.adjust_debt_invoice(
                db, org.id, user.id, "customer", cust.id, inv.id,
                [{"item_id": str(item1.id), "quantity": 3,
                  "unit_price": 12}])
            await db.commit()
            check("adjust total recomputed", abs(res["total"] - 41) < 0.01,
                  str(res))
            inv2 = (await db.execute(select(Invoice).where(
                Invoice.id == inv.id))).scalar_one()
            rec2 = (await db.execute(select(CustomerReceivable).where(
                CustomerReceivable.invoice_id == inv.id))).scalar_one()
            prod2 = (await db.execute(select(Product).where(
                Product.id == prod.id))).scalar_one()
            chg = (await db.execute(select(InvoiceItemChange).where(
                InvoiceItemChange.invoice_id == inv.id))).scalars().all()
            check("invoice balance 41", abs(float(inv2.balance) - 41) < 0.01,
                  str(inv2.balance))
            check("receivable amount 41", abs(float(rec2.amount) - 41) < 0.01,
                  str(rec2.amount))
            check("stock 16 after +1 sold", abs(float(prod2.stock) - 16) < 0.01,
                  str(prod2.stock))
            check("change row recorded", len(chg) == 1
                  and abs(float(chg[0].new_quantity) - 3) < 1e-6, str(chg))

        # ── scoped payment ──
        async with async_session_factory() as db:
            await sale_service.add_customer_payment(
                db, org.id, user.id, cust.id,
                PartyPaymentRequest(
                    bank_account_id=acct.id, amount=Decimal("10"),
                    currency="SAR", invoice_id=inv.id))
        async with async_session_factory() as db:
            a = (await db.execute(select(BankAccount).where(
                BankAccount.id == acct.id))).scalar_one()
            i2 = (await db.execute(select(Invoice).where(
                Invoice.id == inv.id))).scalar_one()
            check("bank 1010 after collection", abs(float(a.balance) - 1010) < 0.01,
                  str(a.balance))
            check("invoice balance 31 after payment",
                  abs(float(i2.balance) - 31) < 0.01, str(i2.balance))

        # ── delete with full reversal ──
        async with async_session_factory() as db:
            d = await dis.delete_debt_invoice(
                db, org.id, user.id, "customer", cust.id, inv.id)
            await db.commit()
            check("delete returns number", d["number"] == f"EDT-{tag}")
        async with async_session_factory() as db:
            a = (await db.execute(select(BankAccount).where(
                BankAccount.id == acct.id))).scalar_one()
            prod3 = (await db.execute(select(Product).where(
                Product.id == prod.id))).scalar_one()
            inv3 = (await db.execute(select(Invoice).where(
                Invoice.id == inv.id))).scalar_one()
            rec3 = (await db.execute(select(CustomerReceivable).where(
                CustomerReceivable.invoice_id == inv.id))).scalar_one_or_none()
            pays = (await db.execute(select(Payment).where(
                Payment.invoice_id == inv.id))).scalars().all()
            movs = (await db.execute(select(InventoryMovement).where(
                InventoryMovement.reference_id == inv.id))).scalars().all()
            check("bank restored to 1000", abs(float(a.balance) - 1000) < 0.01,
                  str(a.balance))
            check("stock restored to 20", abs(float(prod3.stock) - 20) < 0.01,
                  str(prod3.stock))
            check("invoice soft-deleted", inv3.is_deleted is True
                  and inv3.status == "cancelled", f"{inv3.is_deleted}/{inv3.status}")
            check("receivable removed", rec3 is None)
            check("payments removed", len(pays) == 0)
            check("stock movements removed", len(movs) == 0)
    finally:
        async with async_session_factory() as db:
            if inv is not None:
                await db.execute(delete(InvoiceItemChange).where(
                    InvoiceItemChange.invoice_id == inv.id))
                await db.execute(delete(Payment).where(
                    Payment.invoice_id == inv.id))
                await db.execute(delete(InvoiceItem).where(
                    InvoiceItem.invoice_id == inv.id))
                await db.execute(delete(CustomerReceivable).where(
                    CustomerReceivable.invoice_id == inv.id))
                await db.execute(delete(InventoryMovement).where(
                    InventoryMovement.reference_id == inv.id))
                await db.execute(delete(Invoice).where(Invoice.id == inv.id))
            if acct is not None:
                await db.execute(delete(BankTransaction).where(
                    BankTransaction.bank_account_id == acct.id))
                await db.execute(delete(BankAccount).where(
                    BankAccount.id == acct.id))
            if prod is not None:
                await db.execute(delete(Product).where(Product.id == prod.id))
            if cust is not None:
                await db.execute(delete(Customer).where(Customer.id == cust.id))
            if user is not None:
                await db.execute(delete(User).where(User.id == user.id))
            if org is not None:
                await db.execute(delete(Organization).where(
                    Organization.id == org.id))
            await db.commit()

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
