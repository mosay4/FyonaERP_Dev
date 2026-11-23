"""ROOT-CAUSE regression: creating a bank account with an OPENING BALANCE must
persist that balance and document it as ONE opening movement.

The old route hardcoded balance=0 and the request model dropped the field →
the balance always stayed zero. This test drives the REAL endpoint function.
"""

import asyncio
import json
import os
import sys
from datetime import datetime, timezone
from decimal import Decimal
from uuid import UUID


def _uuid(x):
    return x if isinstance(x, UUID) else UUID(str(x))

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import select  # noqa: E402

from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.finance_entities import (  # noqa: E402
    BankAccount,
    BankTransaction,
)
from app.domain.models.finance_models import BankAccountCreate  # noqa: E402
from app.api.v1.finance import create_bank_account  # noqa: E402
from app.domain.services.business_transactions_service import (  # noqa: E402
    list_transactions,
)

ORG = "d6c27bfb-9a8d-4535-8e43-f23787330cbe"
TAG = "OB-TEST"
PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    async with async_session_factory() as db:
        # cleanup previous run
        old = (
            await db.execute(
                select(BankAccount).where(
                    BankAccount.organization_id == UUID(ORG),
                    BankAccount.bank_name.like(f"{TAG}%"))
            )
        ).scalars().all()
        for a in old:
            await db.delete(a)
        await db.flush()

        # ── 1) Opening balance 1500 → persisted + one documented movement ──
        resp = await create_bank_account(
            data=BankAccountCreate(
                bank_name=f"{TAG}-بنك",
                account_name=f"{TAG}-حساب",
                account_number="OB-1",
                currency="SAR",
                balance=1500,
            ),
            org_id=ORG, db=db, _=None,
        )
        check("endpoint returns the opening balance (not 0)",
              float(resp["balance"]) == 1500, f"got {resp['balance']}")
        acc_id = resp["id"]

        acc = (
            await db.execute(select(BankAccount).where(BankAccount.id == _uuid(acc_id)))
        ).scalar_one()
        check("stored account balance = 1500", float(acc.balance) == 1500,
              f"got {acc.balance}")

        txs = (
            await db.execute(
                select(BankTransaction).where(
                    BankTransaction.bank_account_id == _uuid(acc_id))
            )
        ).scalars().all()
        check("exactly ONE opening movement", len(txs) == 1, f"got {len(txs)}")
        check("movement type = opening_balance", txs[0].tx_type == "opening_balance",
              txs[0].tx_type)
        check("movement amount + running balance = 1500",
              float(txs[0].amount) == 1500 and float(txs[0].running_balance) == 1500)

        # ── 2) Timeline: own kind, never income ──
        feed = await list_transactions(db, ORG, per_page=500,
                                       date_from=(datetime.now(timezone.utc)
                                                  .date().isoformat()))
        ours = [i for i in feed["items"]
                if i.get("source_id") and str(i["source_id"]) == str(txs[0].id)]
        check("opening movement visible in المعاملات with kind=opening",
              len(ours) == 1 and ours[0]["kind"] == "opening",
              f"got {[ (i.get('kind'), i.get('source_id')) for i in ours ]}")
        income_feed = await list_transactions(db, ORG, per_page=500, kind="income",
                                              date_from=(datetime.now(timezone.utc)
                                                         .date().isoformat()))
        check("opening movement NEVER counted as income",
              all(str(i.get("source_id")) != str(txs[0].id)
                  for i in income_feed["items"]))
        await db.commit()

        # ── 3) Zero opening balance → no movement ──
        resp0 = await create_bank_account(
            data=BankAccountCreate(
                bank_name=f"{TAG}-بنك0", account_name="x",
                account_number="OB-2", currency="SAR", balance=0),
            org_id=ORG, db=db, _=None,
        )
        txs0 = (
            await db.execute(
                select(BankTransaction).where(
                    BankTransaction.bank_account_id == _uuid(resp0["id"]))
            )
        ).scalars().all()
        check("zero opening → balance 0 and NO movement",
              float(resp0["balance"]) == 0 and len(txs0) == 0)

        # ── 4) Negative opening → refused ──
        refused = False
        try:
            await create_bank_account(
                data=BankAccountCreate(
                    bank_name=f"{TAG}-neg", account_name="x",
                    account_number="OB-3", currency="SAR", balance=-5),
                org_id=ORG, db=db, _=None,
            )
        except Exception:
            refused = True
        check("negative opening refused", refused)
        await db.rollback()

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", json.dumps(FAIL, ensure_ascii=False))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
