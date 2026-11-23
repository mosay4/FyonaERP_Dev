"""Over-payment runtime test: a little extra over the remaining debt must
still execute — the debt is cleared with its exact remainder and the extra
still moves through the bank (customer advance / rounded supplier payment)."""

import asyncio
import os
import sys
import uuid
from datetime import date
from decimal import Decimal

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete, select  # noqa: E402
from app.api.v1 import reconciliation as _R  # noqa: E402,F401
from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import Organization, User  # noqa: E402
from app.domain.entities.business_entities import Customer, Supplier  # noqa: E402
from app.domain.entities.finance_entities import BankAccount, BankTransaction  # noqa: E402
from app.domain.entities.invoice_entities import Invoice, Payment  # noqa: E402
from app.domain.entities.merchant_entities import SharedAuditLog  # noqa: E402
from app.domain.entities.sale_entities import (  # noqa: E402
    CustomerReceivable, SupplierPayable,
)
from app.domain.models.invoice_models import PartyPaymentRequest  # noqa: E402
from app.domain.services import sale_service  # noqa: E402

PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    tag = uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org = Organization(name=f"O-{tag}", slug=f"o-{tag}")
        db.add(org)
        await db.flush()
        user = User(organization_id=org.id, full_name="t",
                    email=f"t{tag}@t.local", phone=f"+96774{tag}", role="owner")
        c = Customer(organization_id=org.id, name=f"c-{tag}")
        s = Supplier(organization_id=org.id, name=f"s-{tag}")
        acct = BankAccount(organization_id=org.id, bank_name=f"B-{tag}",
                           account_name="T", account_number="1", currency="SAR",
                           account_type="checking", balance=Decimal("1000"))
        db.add_all([user, c, s, acct])
        await db.flush()
        si = Invoice(organization_id=org.id, invoice_number=f"S-{tag}",
                     invoice_type="sale", customer_id=c.id, invoice_date=date.today(),
                     status="confirmed", total=Decimal("100"),
                     paid_amount=Decimal("0"), balance=Decimal("100"), currency="SAR")
        pi = Invoice(organization_id=org.id, invoice_number=f"P-{tag}",
                     invoice_type="purchase", supplier_id=s.id, invoice_date=date.today(),
                     status="confirmed", total=Decimal("100"),
                     paid_amount=Decimal("0"), balance=Decimal("100"), currency="SAR")
        db.add_all([si, pi])
        await db.flush()
        db.add(CustomerReceivable(organization_id=org.id, customer_id=c.id,
                                  invoice_id=si.id, amount=Decimal("100"),
                                  paid=Decimal("0"), status="open"))
        db.add(SupplierPayable(organization_id=org.id, supplier_id=s.id,
                               invoice_id=pi.id, amount=Decimal("100"),
                               paid=Decimal("0"), status="open"))
        await db.commit()
    try:
        async with async_session_factory() as db:
            # collect 110 from a 100 debt
            res = await sale_service.add_customer_payment(
                db, org.id, user.id, c.id,
                PartyPaymentRequest(bank_account_id=acct.id, amount=Decimal("110"),
                                    currency="SAR", invoice_id=si.id))
            await db.commit()
            check("customer over-payment accepted", res["applied"] == 100.0)
            check("surplus reported", abs(res["surplus"] - 10.0) < 0.01,
                  str(res["surplus"]))
        async with async_session_factory() as db:
            inv = (await db.execute(select(Invoice).where(
                Invoice.id == si.id))).scalar_one()
            bank = (await db.execute(select(BankAccount).where(
                BankAccount.id == acct.id))).scalar_one()
            check("invoice cleared exactly to 0", float(inv.balance) == 0.0)
            check("bank received the FULL 110",
                  abs(float(bank.balance) - 1110.0) < 0.01, str(bank.balance))
        async with async_session_factory() as db:
            # pay supplier 120 against 100
            res = await sale_service.add_supplier_payment(
                db, org.id, user.id, s.id,
                PartyPaymentRequest(bank_account_id=acct.id, amount=Decimal("120"),
                                    currency="SAR", invoice_id=pi.id))
            await db.commit()
            check("supplier over-payment accepted", res["applied"] == 100.0)
        async with async_session_factory() as db:
            bank = (await db.execute(select(BankAccount).where(
                BankAccount.id == acct.id))).scalar_one()
            inv = (await db.execute(select(Invoice).where(
                Invoice.id == pi.id))).scalar_one()
            check("supplier debt cleared", float(inv.balance) == 0.0)
            check("bank paid the FULL 120", abs(float(bank.balance) - 990.0) < 0.01,
                  str(bank.balance))
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(BankTransaction).where(
                BankTransaction.bank_account_id == acct.id))
            await db.execute(delete(Payment).where(
                Payment.invoice_id.in_([si.id, pi.id])))
            await db.execute(delete(CustomerReceivable).where(
                CustomerReceivable.customer_id == c.id))
            await db.execute(delete(SupplierPayable).where(
                SupplierPayable.supplier_id == s.id))
            await db.execute(delete(Invoice).where(Invoice.id.in_([si.id, pi.id])))
            await db.execute(delete(BankAccount).where(BankAccount.id == acct.id))
            await db.execute(delete(Customer).where(Customer.id == c.id))
            await db.execute(delete(Supplier).where(Supplier.id == s.id))
            await db.execute(delete(User).where(User.id == user.id))
            await db.execute(delete(Organization).where(Organization.id == org.id))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
