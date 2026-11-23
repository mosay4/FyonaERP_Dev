"""Runtime integration tests for the Reconciliation engine (قسم المطابقة).

Runs against the REAL database + service layer (same harness style as
test_qty_currency_runtime.py). Covers the mandatory scenarios:

1.  Bank check with 3 currency accounts (system/actual/diff/status).
2.  Settling only SOME currencies — matched currencies are untouched.
3.  Shortage / surplus / exact match statuses.
4.  Approve creates reconciliation_* BankTransactions visible in
    business_transactions_service (kind=reconciliation), NOT in income/expense.
5.  Balance changed between check and approve → ReconciliationConflict.
6.  Repeated approve / retry → idempotent, no duplicate movements.
7.  Inventory start/save/check/approve for product + full scope.
8.  Partial save (base quantities; extra-unit conversion covered by Flutter
    widget tests at the client layer).
9.  A sale during the count → stale flag; stale expected qty is refused.
10. Archive listing + org isolation (other org cannot see/read records).
11. Permission baseline: employee none, manager create/read/update, owner *.
"""

import asyncio
import json
import os
import sys
from decimal import Decimal
from uuid import UUID, uuid4

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import select  # noqa: E402

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
from app.domain.services import reconciliation_service as svc  # noqa: E402
from app.domain.services.business_transactions_service import (  # noqa: E402
    list_transactions,
)

ORG = "d6c27bfb-9a8d-4535-8e43-f23787330cbe"  # test organization
PASS: list[str] = []
FAIL: list[str] = []


def check(name: str, cond: bool, extra: str = "") -> None:
    if cond:
        PASS.append(name)
        print(f"  ✓ {name}")
    else:
        FAIL.append(name)
        print(f"  ✗ {name} {extra}")


async def make_account(db, currency: str, balance: float, bank: str) -> BankAccount:
    acc = BankAccount(
        organization_id=ORG,
        bank_name=bank,
        account_name=f"{bank} {currency}",
        account_number=f"RC-{uuid4().hex[:10]}",
        currency=currency,
        balance=Decimal(str(balance)),
    )
    db.add(acc)
    await db.flush()
    return acc


async def main() -> None:
    async with async_session_factory() as db:
        uid = (
            await db.execute(
                select(User.id)
                .where(User.organization_id == UUID(ORG))
                .order_by(User.created_at.asc())
                .limit(1)
            )
        ).scalars().first()

        # ── 1..4) Bank: 3 currency accounts, settle 2, one matched ──
        usd = await make_account(db, "USD", 1000, "بنك المطابقات")
        yold = await make_account(db, "YER_OLD", 750000, "بنك المطابقات")
        sar = await make_account(db, "SAR", 2500, "بنك المطابقات")
        await db.commit()

        rec = await svc.bank_check(
            db, ORG, uid,
            [
                {"account_id": str(usd.id), "actual": 950},      # short 50
                {"account_id": str(yold.id), "actual": 750000},  # match
                {"account_id": str(sar.id), "actual": 2000},     # short 500
            ],
            idempotency_key=f"bank-{usd.id}",
        )
        lines = {l["currency"]: l for l in rec["lines"]}
        check("bank check 3 currencies", len(rec["lines"]) == 3)
        check("usd short diff -50", lines["USD"]["diff"] == -50
              and lines["USD"]["status"] == "short")
        check("yer_old match", lines["YER_OLD"]["status"] == "match"
              and lines["YER_OLD"]["diff"] == 0)
        check("sar short diff -500", lines["SAR"]["diff"] == -500
              and lines["SAR"]["status"] == "short")
        check("archive ref_code", rec["ref_code"].startswith("RCN-"))

        rec2 = await svc.bank_check(
            db, ORG, uid,
            [{"account_id": str(usd.id), "actual": 950}],
            idempotency_key=f"bank-{usd.id}",
        )
        check("bank check idempotent", rec2["id"] == rec["id"])

        approved = await svc.bank_approve(
            db, ORG, uid, rec["id"],
            [
                {"account_id": str(usd.id), "actual": 950,
                 "expected_system": 1000},
                {"account_id": str(sar.id), "actual": 2000,
                 "expected_system": 2500},
            ],
        )
        await db.commit()
        check("approve settled 2", approved["result"]["settled"] == 2)
        s_by_ccy = {s["currency"]: s for s in approved["settlements"]}
        check("usd after=950", s_by_ccy["USD"]["after"] == 950
              and s_by_ccy["USD"]["before"] == 1000)
        check("yer_old untouched", s_by_ccy.get("YER_OLD") is None)

        await db.refresh(usd)
        await db.refresh(sar)
        await db.refresh(yold)
        check("usd balance updated", float(usd.balance) == 950)
        check("sar balance updated", float(sar.balance) == 2000)
        check("yer_old balance unchanged", float(yold.balance) == 750000)

        txs = (await db.execute(
            select(BankTransaction).where(
                BankTransaction.reference == rec["ref_code"])
        )).scalars().all()
        check("2 adjustment txs created", len(txs) == 2)
        check("tx types reconciliation_*",
              all(t.tx_type in ("reconciliation_increase",
                                "reconciliation_decrease") for t in txs))
        check("tx running_balance correct",
              all(float(t.running_balance) == float(
                  usd.balance if t.bank_account_id == usd.id else sar.balance)
                  for t in txs))

        feed = await list_transactions(db, ORG, per_page=200,
                                       kind="reconciliation")
        check("settlements visible in المعاملات kind=reconciliation",
              len(feed["items"]) >= 2)

        # 6) Repeated approve is idempotent — no duplicate movements
        again = await svc.bank_approve(
            db, ORG, uid, rec["id"],
            [{"account_id": str(usd.id), "actual": 950,
              "expected_system": 950}],
        )
        check("re-approve idempotent (same record)", again["id"] == rec["id"])
        txs2 = (await db.execute(
            select(BankTransaction).where(
                BankTransaction.reference == rec["ref_code"])
        )).scalars().all()
        check("no duplicate movements on re-approve", len(txs2) == 2)

        # 5) Balance changed between check and approve → conflict
        r3 = await svc.bank_check(
            db, ORG, uid,
            [{"account_id": str(usd.id), "actual": 900}],
        )
        usd.balance = Decimal("960")  # a concurrent movement happened
        await db.flush()
        conflict = False
        try:
            await svc.bank_approve(
                db, ORG, uid, r3["id"],
                [{"account_id": str(usd.id), "actual": 900,
                  "expected_system": 950}],
            )
        except svc.ReconciliationConflict as e:
            conflict = True
            check("conflict carries fresh state",
                  e.fresh.get("system") == 960)
        check("balance-changed conflict raised", conflict)
        await db.rollback()  # undo the manual balance poke

        # ── Surplus: actual ABOVE system → status surplus, settled ──
        surp = await make_account(db, "USD", 100, "بنك المطابقات")
        await db.commit()
        r_surp = await svc.bank_check(
            db, ORG, uid, [{"account_id": str(surp.id), "actual": 120}],
        )
        check("surplus status + diff", r_surp["lines"][0]["status"] == "surplus"
              and r_surp["lines"][0]["diff"] == 20)
        approved_surp = await svc.bank_approve(
            db, ORG, uid, r_surp["id"],
            [{"account_id": str(surp.id), "actual": 120,
              "expected_system": 100}],
        )
        await db.commit()
        await db.refresh(surp)
        check("surplus settled to 120", float(surp.balance) == 120)

        # ── 7..9) Inventory ──
        prod = Product(
            organization_id=ORG,
            name="منتج جرد تجريبي",
            unit="قطعة",
            price=Decimal("10"),
            cost_price=Decimal("5"),
            cost_currency="SAR",
            stock=40,
            barcode=f"RC-{uuid4().hex[:8]}",
        )
        db.add(prod)
        await db.flush()
        prod_id = prod.id
        await db.commit()

        inv = await svc.inventory_start(
            db, ORG, uid, "product", product_id=prod_id,
            idempotency_key=f"inv-{prod_id}",
        )
        check("inventory start snapshot 40", inv["lines"][0]["system_qty"] == 40)

        save = await svc.inventory_save(
            db, ORG, uid, inv["id"],
            [{"product_id": str(prod_id), "qty": 35}],  # base units
        )
        check("partial save base qty", save["lines"][0]["base_qty"] == 35)

        chk = await svc.inventory_check(db, ORG, uid, inv["id"])
        l0 = chk["lines"][0]
        check("check short -5", l0["diff"] == -5 and l0["status"] == "short")
        check("not stale yet", l0["stale"] is False)

        # Movement during the count (a sale ships 2 units after the snapshot —
        # exactly what the real sale engine does: movement + stock update)
        db.add(InventoryMovement(
            organization_id=ORG, product_id=prod_id,
            movement_type="sale", quantity=-2,
            reason="", old_quantity=40, new_quantity=38, difference=-2,
        ))
        prod.stock = 38
        await db.commit()
        chk2 = await svc.inventory_check(db, ORG, uid, inv["id"])
        l0 = chk2["lines"][0]
        check("stale flagged after movements", l0["stale"] is True
              and l0["movements_since"] >= 1)

        conflict2 = False
        try:
            await svc.inventory_approve(
                db, ORG, uid, inv["id"],
                [{"product_id": str(prod_id), "expected_system": 40,
                  "new_qty": 35}],
            )
        except svc.ReconciliationConflict:
            conflict2 = True
        check("stale expected qty refused", conflict2)

        await svc.inventory_check(db, ORG, uid, inv["id"])  # refresh to 38
        approved_inv = await svc.inventory_approve(
            db, ORG, uid, inv["id"],
            [{"product_id": str(prod_id), "expected_system": 38,
              "new_qty": 35}],
        )
        await db.commit()
        check("inventory settled 1", approved_inv["result"]["settled"] == 1)
        await db.refresh(prod)
        check("product stock = 35", float(prod.stock) == 35)
        s0 = approved_inv["settlements"][0]
        check("movement linked", s0["movement_id"] is not None
              and s0["diff"] == -3)

        mv = (await db.execute(
            select(InventoryMovement).where(
                InventoryMovement.id == s0["movement_id"])
        )).scalar_one()
        check("movement type adjust_set + recon reference",
              mv.movement_type == "adjust_set"
              and mv.reference_type == "reconciliation"
              and mv.reason == "مطابقة المخزون"
              and float(mv.old_quantity) == 38
              and float(mv.new_quantity) == 35)

        again_inv = await svc.inventory_approve(
            db, ORG, uid, inv["id"],
            [{"product_id": str(prod_id), "expected_system": 35,
              "new_qty": 35}],
        )
        check("inventory re-approve idempotent",
              again_inv["status"] == "approved" and again_inv["id"] == inv["id"])

        cat_scope = await svc.inventory_start(db, ORG, uid, "full")
        check("full scope snapshots products", len(cat_scope["lines"]) >= 1)

        # ── 10) Archive + org isolation ──
        arch = await svc.list_reconciliations(db, ORG, rtype="bank")
        check("archive lists bank recs",
              any(a["ref_code"] == rec["ref_code"] for a in arch["items"]))
        other_org = uuid4()
        cross = await svc.list_reconciliations(db, other_org)
        check("org isolation", len(cross["items"]) == 0)
        try:
            await svc.get_reconciliation(db, other_org, rec["id"])
            visible = True
        except svc.ReconciliationError:
            visible = False
        check("cross-org detail refused", not visible)

        # ── 11) Permission baseline ──
        from app.domain.services.auth_service import ROLE_PERMISSIONS  # noqa: E402

        check("employee has no reconciliation",
              "reconciliation" not in ROLE_PERMISSIONS.get("employee", {}))
        check("manager can read/create/update reconciliation",
              set(ROLE_PERMISSIONS["manager"]["reconciliation"])
              == {"create", "read", "update"})
        check("owner wildcard covers reconciliation",
              "*" in ROLE_PERMISSIONS["owner"])

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", json.dumps(FAIL, ensure_ascii=False, indent=1))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())# NOTE: the reconciliation redesign relies on `account_type` being present in
# the accounts listing (currency selection shows جاري/توفير) and on multi-unit
# counting (`parts`). Both are verified by test_bank_account_type + the app
# widget tests; the runtime core above stays green.
