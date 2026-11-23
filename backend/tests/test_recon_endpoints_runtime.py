"""ROUTER-level regression: every reconciliation endpoint must run through the
REAL route functions (the service-level tests missed a missing `await` that
returned a coroutine → HTTP 500 for check/approve/list/detail).
"""

import asyncio
import json
import os
import sys
from decimal import Decimal
from uuid import UUID, uuid4

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import select  # noqa: E402

from app.api.v1 import reconciliation as R  # noqa: E402
from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import User  # noqa: E402
from app.domain.entities.finance_entities import BankAccount  # noqa: E402

ORG = "d6c27bfb-9a8d-4535-8e43-f23787330cbe"
TAG = "REP-EP"
PASS, FAIL = [], []


def _body(resp):
    b = resp.body
    return json.loads(b.decode() if isinstance(b, (bytes, bytearray)) else b)


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    async with async_session_factory() as db:
        uid = (await db.execute(
            select(User.id).where(User.organization_id == UUID(ORG))
            .order_by(User.created_at.asc()).limit(1))).scalars().first()
        # fixtures
        old = (await db.execute(
            select(BankAccount).where(
                BankAccount.organization_id == UUID(ORG),
                BankAccount.bank_name.like(f"{TAG}%")))).scalars().all()
        for a in old:
            await db.delete(a)
        await db.flush()
        acc = BankAccount(organization_id=UUID(ORG), bank_name=f"{TAG}-بنك",
                          account_name="حساب", account_number="EP1",
                          currency="USD", balance=Decimal("1000"))
        db.add(acc)
        await db.flush()
        acc_id = str(acc.id)
        await db.commit()

        # 1) accounts
        out = _body(await R.recon_accounts(org_id=ORG, db=db, _=None))
        check("GET /accounts returns the account",
              len(out.get("data") or []) >= 1)

        # 2) bank check (the previously-500 path)
        rec = await R.bank_check(
            R.BankCheckRequest(entries=[R.ReconEntry(account_id=acc_id,
                                                     actual=950.0)]),
            org_id=ORG, user_id=uid, db=db, _=None, branch=None)
        rec = _body(rec)["data"]
        check("POST /bank/check returns lines with real numbers",
              rec["lines"][0]["system"] == 1000
              and rec["lines"][0]["actual"] == 950
              and rec["lines"][0]["diff"] == -50,
              json.dumps(rec["lines"][0], ensure_ascii=False))

        # 3) bank approve
        appr = await R.bank_approve(
            UUID(rec["id"]),
            R.BankApproveRequest(entries=[R.ReconEntry(
                account_id=acc_id, actual=950.0, expected_system=1000.0)]),
            org_id=ORG, user_id=uid, db=db, _=None)
        check("POST /bank/{id}/approve equalizes",
              _body(appr)["data"]["status"] == "approved")
        await db.refresh(acc)
        check("account balance updated to 950", float(acc.balance) == 950)

        # 3b) idempotent re-approve — status stays approved, no 2nd movement,
        #     balance unchanged (the "success but not saved / retry fails" bug)
        appr2 = await R.bank_approve(
            UUID(rec["id"]),
            R.BankApproveRequest(entries=[R.ReconEntry(
                account_id=acc_id, actual=950.0, expected_system=1000.0)]),
            org_id=ORG, user_id=uid, db=db, _=None)
        await db.refresh(acc)
        check("re-approve is idempotent (status + balance unchanged)",
              _body(appr2)["data"]["status"] == "approved"
              and float(acc.balance) == 950)

        # 3c) reopening the SAME record reads the persisted approved state
        det2 = _body(await R.get_reconciliation(
            UUID(rec["id"]), org_id=ORG, db=db, _=None))
        check("reopened record is approved with settlements",
              det2["data"]["status"] == "approved"
              and len(det2["data"]["settlements"]) >= 1,
              json.dumps(det2["data"].get("settlements"),
                         ensure_ascii=False)[:120])

        # 3d) the SAME operation id dedupes a repeated CHECK (no twin record)
        k = f"idem-{uuid4()}"
        c1 = _body(await R.bank_check(
            R.BankCheckRequest(
                entries=[R.ReconEntry(account_id=acc_id, actual=900.0)],
                idempotency_key=k),
            org_id=ORG, user_id=uid, db=db, _=None, branch=None))["data"]
        c2 = _body(await R.bank_check(
            R.BankCheckRequest(
                entries=[R.ReconEntry(account_id=acc_id, actual=900.0)],
                idempotency_key=k),
            org_id=ORG, user_id=uid, db=db, _=None, branch=None))["data"]
        check("idempotency_key dedupes repeated checks", c1["id"] == c2["id"])

        # 4) inventory start → save(parts) → check → approve
        inv = _body(await R.inventory_start(
            R.InventoryStartRequest(scope="full"),
            org_id=ORG, user_id=uid, db=db, _=None, branch=None))["data"]
        check("POST /inventory/start returns lines", len(inv["lines"]) >= 1)
        pid = inv["lines"][0]["product_id"]
        await R.inventory_save(
            UUID(inv["id"]),
            R.InventorySaveRequest(counts=[R.CountEntry(
                product_id=pid,
                parts=[R.CountPart(qty=7, unit_name="قطعة")])]),
            org_id=ORG, user_id=uid, db=db, _=None)
        chk = _body(await R.inventory_check(
            UUID(inv["id"]), org_id=ORG, user_id=uid, db=db, _=None))["data"]
        line = [l for l in chk["lines"] if l["product_id"] == pid][0]
        check("parts → base_qty 7 + real diff", line["base_qty"] == 7
              and line["diff"] == 7 - line["system_qty"],
              json.dumps({k: line[k] for k in ('system_qty','base_qty','diff')}))

        # 5) list (the previously-500 archive) + detail
        listed = _body(await R.list_reconciliations(
            rtype="bank", status=None, date_from=None, date_to=None,
            search=None, page=1, per_page=20, org_id=ORG, db=db, _=None))
        check("GET /reconciliation (archive) returns items",
              listed.get("data") is not None)
        det = _body(await R.get_reconciliation(
            UUID(rec["id"]), org_id=ORG, db=db, _=None))
        check("GET /reconciliation/{id} returns the record",
              det["data"]["ref_code"] == rec["ref_code"])

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", json.dumps(FAIL, ensure_ascii=False))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
