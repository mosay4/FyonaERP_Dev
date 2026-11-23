"""Single-base inventory reconciliation: one real entry per product, consistent
equivalents for EVERY unit, one equalization (the زبادي scenario).
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
from app.api.v1 import reconciliation as _recon_router  # noqa: E402,F401
from app.domain.entities.auth_entities import User  # noqa: E402
from app.domain.entities.business_entities import (  # noqa: E402
    InventoryMovement,
    Product,
)
from app.domain.entities.invoice_entities import (  # noqa: E402,F401
    Invoice,
    InvoiceItem,
)
from app.domain.entities.reconciliation_entities import Reconciliation  # noqa: E402
from app.domain.entities.sale_entities import ProductUnit  # noqa: E402
from app.domain.services import reconciliation_service as svc  # noqa: E402

ORG = UUID("d6c27bfb-9a8d-4535-8e43-f23787330cbe")
PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


def _urow(rows, name):
    for r in rows or []:
        if r.get("unit_name") == name:
            return r
    return {}


async def main():
    tag = uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        user_id = (await db.execute(
            select(User.id).where(User.organization_id == ORG).limit(1)
        )).scalar_one()
        prod = Product(
            organization_id=ORG, name=f"ZABADI-{tag}", unit="قطعة",
            price=Decimal("10"), cost_price=Decimal("5"), stock=Decimal("832"),
        )
        db.add(prod)
        await db.flush()
        pid = prod.id
        db.add(ProductUnit(
            organization_id=ORG, product_id=pid, name="باكيت",
            factor=Decimal("8"), is_base=False, group="count"))
        # The base unit row (created by ensure_base_unit in the real flow).
        db.add(ProductUnit(
            organization_id=ORG, product_id=pid, name="قطعة",
            factor=Decimal("1"), is_base=True, group="count"))
        await db.commit()

    rec_id = None
    try:
        # start → save a SINGLE entry (50 قطعة) → check → approve → reopen,
        # all in one session (services flush; the router commits per call).
        async with async_session_factory() as db:
            rec = await svc.inventory_start(
                db, ORG, user_id, "product", product_id=pid)
            rec_id = rec["id"]
            await svc.inventory_save(db, ORG, user_id, UUID(str(rec_id)), [
                {"product_id": str(pid),
                 "parts": [{"unit_name": "قطعة", "qty": 50}]},
            ])
            chk = await svc.inventory_check(db, ORG, user_id, UUID(str(rec_id)))
            line = [l for l in chk["lines"]
                    if str(l["product_id"]) == str(pid)][0]
            check("single base total = 50 (not 50+48)",
                  float(line["base_qty"]) == 50.0
                  and float(line["system_qty"]) == 832.0
                  and float(line["diff"]) == -782.0,
                  f"base={line.get('base_qty')} sys={line.get('system_qty')}")
            urs = line.get("unit_rows") or []
            pc = _urow(urs, "قطعة")
            pk = _urow(urs, "باكيت")
            check("قطعة row 832 → 50",
                  float(pc.get("system", -1)) == 832.0
                  and float(pc.get("actual", -1)) == 50.0,
                  str(pc))
            check("باكيت row 104 → 6.25 (equivalent, not extra)",
                  float(pk.get("system", -1)) == 104.0
                  and abs(float(pk.get("actual", -1)) - 6.25) < 1e-9,
                  str(pk))

        # approve ONCE: 832 → 50 deducts 782 exactly once
            out = await svc.inventory_approve(
                db, ORG, user_id, UUID(str(rec_id)),
                [{"product_id": str(pid), "expected_system": 832.0,
                  "new_qty": 50.0}])
            check("approved with one settlement", out["status"] == "approved"
                  and len(out.get("settlements") or []) == 1)
            st = (out.get("settlements") or [])[0]
            check("settlement 832 → 50 (single)",
                  float(st.get("before", -1)) == 832.0
                  and float(st.get("after", -1)) == 50.0, str(st)[:200])
            p = (await db.execute(
                select(Product).where(Product.id == pid))).scalar_one()
            check("stock is exactly 50 (782 deducted once)",
                  float(p.stock) == 50.0, f"stock={p.stock}")

        # reopen → approved, consistent unit rows
            det = await svc.get_reconciliation(db, ORG, UUID(str(rec_id)))
            check("reopened record is approved", det["status"] == "approved")
            dline = [l for l in det["lines"]
                     if str(l["product_id"]) == str(pid)][0]
            durs = dline.get("unit_rows") or []
            dpc = _urow(durs, "قطعة")
            dpk = _urow(durs, "باكيت")
            check("reopened rows stay consistent (no double count)",
                  float(dpc.get("actual", -1)) == 50.0
                  and abs(float(dpk.get("actual", -1)) - 6.25) < 1e-9,
                  f"{dpc} {dpk}")
    finally:
        async with async_session_factory() as db:
            if rec_id:
                await db.execute(delete(Reconciliation).where(
                    Reconciliation.id == UUID(str(rec_id))))
            await db.execute(delete(InventoryMovement).where(
                InventoryMovement.product_id == pid))
            await db.execute(delete(ProductUnit).where(
                ProductUnit.product_id == pid))
            await db.execute(delete(Product).where(Product.id == pid))
            await db.commit()

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
