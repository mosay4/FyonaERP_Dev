"""Business expense-type withdrawals create an Expense row atomically."""

import asyncio
import os
import sys
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from uuid import UUID

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete, select  # noqa: E402

from app.api.v1 import finance as F  # noqa: E402
from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.finance_entities import (  # noqa: E402
    BankAccount,
    BankTransaction,
    Expense,
)
from app.domain.models.finance_models import AmountRequest  # noqa: E402
from app.domain.services import business_reports_service as R  # noqa: E402

ORG = UUID("d6c27bfb-9a8d-4535-8e43-f23787330cbe")
PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    tag = uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        acc = BankAccount(
            organization_id=ORG, bank_name=f"EXPW-{tag}",
            account_name="T", account_number="1", currency="SAR",
            account_type="checking", balance=Decimal("1000"))
        db.add(acc)
        await db.flush()
        aid = acc.id
        await db.commit()

    try:
        # Expense-type withdrawal (what the Business sheet now sends).
        async with async_session_factory() as db:
            await F.withdraw(
                aid,
                AmountRequest(amount=Decimal("250"), description="t",
                              is_expense=True, category="قرطاسية"),
                org_id=str(ORG), db=db, _=None)
            await db.commit()
            rows = (await db.execute(select(Expense).where(
                Expense.organization_id == ORG,
                Expense.category == "قرطاسية"))).scalars().all()
            check("expense-type withdrawal created an Expense row",
                  len(rows) == 1 and float(rows[0].amount) == 250.0
                  and (rows[0].currency or "").upper() == "SAR",
                  f"{[(float(r.amount), r.currency) for r in rows]}")

        # Plain withdrawal (no flag) creates NO Expense row.
        async with async_session_factory() as db:
            before = (await db.execute(select(Expense).where(
                Expense.organization_id == ORG))).scalars().all()
            n0 = len(before)
            await F.withdraw(
                aid, AmountRequest(amount=Decimal("50"), description="t2"),
                org_id=str(ORG), db=db, _=None)
            await db.commit()
            after = (await db.execute(select(Expense).where(
                Expense.organization_id == ORG))).scalars().all()
            check("plain withdrawal creates no Expense row",
                  len(after) == n0, f"{n0} -> {len(after)}")

        # Reports see the categorized expense (period covers today).
        async with async_session_factory() as db:
            now = datetime.now(timezone.utc)
            out = await R.money_report(
                db, ORG,
                datetime(now.year, now.month, now.day, tzinfo=timezone.utc),
                now, "SAR")
            check("reports expenses include the 250",
                  float(out["expenses"]["total"]) >= 250.0,
                  f"expenses={out['expenses']['total']}")

        # Expense SCOPED to this account shows its category only.
        async with async_session_factory() as db:
            now = datetime.now(timezone.utc)
            scoped = await R.money_report(
                db, ORG,
                datetime(now.year, now.month, now.day, tzinfo=timezone.utc),
                now, "SAR", account_id=str(aid))
            cats = (scoped.get("expense_scoped") or {}).get("categories") or []
            check("scoped expenses follow the selected account only",
                  any(c.get("category") == "قرطاسية"
                      and float(c.get("total") or 0) >= 250.0
                      for c in cats),
                  f"{cats}")
            gcats = (scoped["expenses"].get("categories") or [])
            check("global expenses KPI stays company-wide",
                  any(float(c.get("total") or 0) >= 250.0
                      for c in gcats),
                  f"{gcats}")

        # Income (مدخول) counts in reports profit.
        async with async_session_factory() as db:
            await F.deposit(
                aid, AmountRequest(amount=Decimal("400"),
                                   description="t3"),
                org_id=str(ORG), db=db, _=None)
            await db.commit()
            now = datetime.now(timezone.utc)
            h = await R.home_report(
                db, ORG,
                datetime(now.year, now.month, now.day, tzinfo=timezone.utc),
                now, "SAR", None)
            check("typed income enters home income KPI",
                  float(h["kpis"]["income"]["total"]) >= 400.0,
                  f"{h['kpis']['income']}")
            check("profit includes the income",
                  float(h["kpis"]["profit"]["total"])
                  >= float(h["kpis"]["income"]["total"]),
                  f"{h['kpis']['profit']}")
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(BankTransaction).where(
                BankTransaction.bank_account_id == aid))
            await db.execute(delete(Expense).where(
                Expense.organization_id == ORG,
                Expense.category == "قرطاسية"))
            await db.execute(delete(BankAccount).where(
                BankAccount.id == aid))
            await db.commit()

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
