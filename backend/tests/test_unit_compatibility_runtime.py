"""Unit measurement-group enforcement (Business only).

Verifies both the pure classifier AND the real service path `create_unit`,
which is what the API endpoint calls.
"""

import asyncio
import os
import sys
import uuid
from decimal import Decimal

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete, select  # noqa: E402

from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.business_entities import Product  # noqa: E402
from app.domain.entities.sale_entities import ProductUnit  # noqa: E402
from app.domain.models.invoice_models import ProductUnitCreate  # noqa: E402
from app.domain.services import sale_service  # noqa: E402

ORG = uuid.UUID("d6c27bfb-9a8d-4535-8e43-f23787330cbe")
PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    # ── pure classifier ──
    check("قطعة → count", sale_service.unit_group_for("قطعة") == "count")
    check("درزن → count", sale_service.unit_group_for("درزن") == "count")
    check("كيلو → weight", sale_service.unit_group_for("كيلو") == "weight")
    check("طن → weight", sale_service.unit_group_for("طن") == "weight")
    check("لتر → volume", sale_service.unit_group_for("لتر") == "volume")
    check("متر → length", sale_service.unit_group_for("متر") == "length")
    check("متر مربع → area", sale_service.unit_group_for("متر مربع") == "area")
    check("ساعة → time", sale_service.unit_group_for("ساعة") == "time")
    check("خدمة → service", sale_service.unit_group_for("خدمة") == "service")
    check("unknown name has no group",
          sale_service.unit_group_for("غير معروف") is None)
    check("custom uses provided group",
          sale_service.unit_group_for("كيس", "weight") == "weight")

    # ── pure compatibility ──
    def blocked(base, extra, group=None):
        try:
            sale_service.assert_unit_compatible(base, extra, group)
            return False
        except ValueError as e:
            assert str(e) == sale_service.UNIT_INCOMPATIBLE_MSG, str(e)
            return True

    check("قطعة+باكيت allowed", not blocked("قطعة", "باكيت"))
    check("قطعة+لتر BLOCKED", blocked("قطعة", "لتر"))
    check("قطعة+كيلو BLOCKED", blocked("قطعة", "كيلو"))
    check("قطعة+متر BLOCKED", blocked("قطعة", "متر"))
    check("كيلو+طن allowed", not blocked("كيلو", "طن"))
    check("لتر+متر BLOCKED", blocked("لتر", "متر"))
    check("unknown extra allowed", not blocked("قطعة", "غير معروف"))
    check("custom weight vs قطعة BLOCKED", blocked("قطعة", "كيس", "weight"))

    # ── real service path (create_unit) ──
    tag = uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        prod = Product(organization_id=ORG, name=f"UNITC-{tag}", unit="قطعة",
                       price=Decimal("0"), cost_price=Decimal("0"), stock=0)
        db.add(prod)
        await db.flush()
        pid = prod.id
        await db.commit()

    async with async_session_factory() as db:
        try:
            await sale_service.create_unit(
                db, ORG, pid, ProductUnitCreate(name="باكيت",
                                                factor=Decimal("6")))
            check("service: compatible unit created", True)
        except Exception as e:  # noqa: BLE001
            check("service: compatible unit created", False, repr(e))

    async with async_session_factory() as db:
        try:
            await sale_service.create_unit(
                db, ORG, pid, ProductUnitCreate(name="لتر",
                                                factor=Decimal("1")))
            check("service: incompatible unit REJECTED", False)
        except ValueError as e:
            check("service: incompatible unit REJECTED",
                  str(e) == sale_service.UNIT_INCOMPATIBLE_MSG, str(e))

    async with async_session_factory() as db:
        try:
            await sale_service.create_unit(
                db, ORG, pid,
                ProductUnitCreate(name="كيس", factor=Decimal("2"),
                                  group="count"))
            check("service: custom unit with matching group created", True)
        except Exception as e:  # noqa: BLE001
            check("service: custom unit with matching group created",
                  False, repr(e))

    # ── cleanup ──
    async with async_session_factory() as db:
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
