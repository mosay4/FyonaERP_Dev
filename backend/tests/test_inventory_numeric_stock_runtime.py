"""Real end-to-end: exact NUMERIC stock balance + the invoice line's frozen
conversion-factor snapshot (a later unit-factor change must NOT alter history).
"""

import asyncio
import os
import sys
import uuid
from decimal import Decimal
from uuid import UUID

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete, select  # noqa: E402

from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import User  # noqa: E402
from app.domain.entities.business_entities import (  # noqa: E402
    InventoryMovement,
    Product,
)
from app.domain.entities.finance_entities import (  # noqa: E402
    BankAccount,
    BankTransaction,
)
from app.domain.entities.invoice_entities import Invoice, InvoiceItem  # noqa: E402
from app.domain.entities.sale_entities import ProductUnit  # noqa: E402
from app.domain.models.invoice_models import (  # noqa: E402
    SaleIssueLine,
    SaleIssuePayment,
    SaleIssueRequest,
    SaleReturnLine,
    SaleReturnRequest,
)
from app.domain.services import sale_service  # noqa: E402

ORG = UUID("d6c27bfb-9a8d-4535-8e43-f23787330cbe")
PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


def _inv_id(res):
    if isinstance(res, dict):
        for k in ("id", "invoice_id"):
            if res.get(k):
                return UUID(str(res[k]))
        if isinstance(res.get("data"), dict) and res["data"].get("id"):
            return UUID(str(res["data"]["id"]))
    return None


async def main():
    tag = uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        user_id = (await db.execute(
            select(User.id).where(User.organization_id == ORG).limit(1)
        )).scalar_one()
    async with async_session_factory() as db:
        prod = Product(
            organization_id=ORG, name=f"NUMSTOCK-{tag}", unit="قطعة",
            price=Decimal("10"), cost_price=Decimal("5"), stock=Decimal("100"),
        )
        db.add(prod)
        await db.flush()
        pid = prod.id
        unit = ProductUnit(
            organization_id=ORG, product_id=pid, name="باكيت",
            factor=Decimal("6"), is_base=False, group="count",
        )
        db.add(unit)
        await db.flush()
        uid = unit.id
        acct = BankAccount(
            organization_id=ORG, bank_name=f"NUMCASH-{tag}",
            account_name="TEST", account_number="0000", currency="SAR",
            account_type="checking", balance=Decimal("1000"),
        )
        db.add(acct)
        await db.flush()
        acct_id = acct.id
        await db.commit()

    inv_id = None
    item_id = None
    try:
        # 1) sell 2 باكيت (=12 قطعة) → stock 100 → 88  (paid in full, no debt)
        async with async_session_factory() as db:
            data = SaleIssueRequest(
                items=[SaleIssueLine(
                    product_id=pid, unit_id=uid, description="", quantity=2,
                    unit_price=Decimal("60"))],
                payments=[SaleIssuePayment(
                    bank_account_id=acct_id, amount=Decimal("120"),
                    currency="SAR")],
            )
            res = await sale_service.issue_sale(db, ORG, user_id, data)
            inv_id = _inv_id(res)
            p = (await db.execute(
                select(Product).where(Product.id == pid))).scalar_one()
            check("stock is exact Decimal after sale",
                  isinstance(p.stock, Decimal) and float(p.stock) == 88.0,
                  f"{p.stock} ({type(p.stock).__name__})")
            it = (await db.execute(select(InvoiceItem).where(
                InvoiceItem.invoice_id == inv_id))).scalar_one()
            item_id = it.id
            check("invoice line froze factor=6 + base=12",
                  float(it.factor or 0) == 6.0 and float(it.base_quantity) == 12.0,
                  f"factor={it.factor} base={it.base_quantity}")

        # 2) later edit the unit factor to 10
        async with async_session_factory() as db:
            u = (await db.execute(select(ProductUnit).where(
                ProductUnit.id == uid))).scalar_one()
            u.factor = Decimal("10")
            await db.commit()

        # 3) return 1 باكيت → must use the SNAPSHOT (6), not the new factor (10)
        async with async_session_factory() as db:
            req = SaleReturnRequest(
                lines=[SaleReturnLine(
                    invoice_item_id=item_id, quantity=1, restock=True)],
                refund_account_id=acct_id,
                refund_amount=Decimal("60"),
                refund_currency="SAR",
            )
            await sale_service.confirm_return(db, ORG, user_id, inv_id, req)
            p = (await db.execute(
                select(Product).where(Product.id == pid))).scalar_one()
            check("return used the frozen factor (stock 88 → 94, not 98)",
                  float(p.stock) == 94.0, f"stock={p.stock}")

        # 4) a retried issue with the SAME idempotency_key must NOT double-deduct
        async with async_session_factory() as db:
            key = f"idem-{tag}"
            d = SaleIssueRequest(
                idempotency_key=key,
                items=[SaleIssueLine(
                    product_id=pid, description="", quantity=1,
                    unit_price=Decimal("10"))],  # base unit
                payments=[SaleIssuePayment(
                    bank_account_id=acct_id, amount=Decimal("10"),
                    currency="SAR")],
            )
            r1 = await sale_service.issue_sale(db, ORG, user_id, d)
            r2 = await sale_service.issue_sale(db, ORG, user_id, d)
            check("retried issue returns the SAME invoice",
                  _inv_id(r1) == _inv_id(r2), f"{_inv_id(r1)} vs {_inv_id(r2)}")
            p = (await db.execute(
                select(Product).where(Product.id == pid))).scalar_one()
            check("stock deducted exactly once (94 → 93)",
                  float(p.stock) == 93.0, f"stock={p.stock}")
    finally:
        async with async_session_factory() as db:
            if inv_id:
                await db.execute(delete(InvoiceItem).where(
                    InvoiceItem.invoice_id == inv_id))
                await db.execute(delete(Invoice).where(Invoice.id == inv_id))
            await db.execute(delete(InventoryMovement).where(
                InventoryMovement.product_id == pid))
            await db.execute(delete(ProductUnit).where(
                ProductUnit.product_id == pid))
            await db.execute(delete(Product).where(Product.id == pid))
            await db.execute(delete(BankTransaction).where(
                BankTransaction.bank_account_id == acct_id))
            await db.execute(delete(BankAccount).where(
                BankAccount.id == acct_id))
            await db.commit()

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
