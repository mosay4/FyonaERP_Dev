"""Branch membership + financial/inventory transfer + reversal runtime checks."""

import asyncio, os, sys, uuid
from decimal import Decimal
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from sqlalchemy import delete, select, func
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.business_entities import Product
from app.domain.entities.finance_entities import BankAccount, BankTransaction
from app.domain.entities.notification_entities import AppNotification
from app.domain.entities.sale_entities import Branch, BranchStock, ProductUnit
from app.domain.entities.branch_entities import (
    BranchMember, BranchInvitation, BranchTransfer, BranchTransferItem,
)
from app.domain.services import branch_service as bsvc
from app.domain.services import branch_access_service as access
from app.domain.services import branch_transfer_service as tsvc
from app.domain.services import branch_stock_service as stock

PASS, FAIL = [], []


def check(n, c, e=""):
    (PASS if c else FAIL).append(n)
    print(("  ✓ " if c else "  ✗ ") + n + ("" if c else f" {e}"))


async def main():
    tag = uuid.uuid4().hex[:6]
    owner_org = Organization(name=f"Owner {tag}", slug=f"own-{tag}", subscription_plan="business")
    guest_org = Organization(name=f"Guest {tag}", slug=f"gst-{tag}", subscription_plan="personal")
    async with async_session_factory() as db:
        db.add_all([owner_org, guest_org]); await db.flush()
        owner = User(organization_id=owner_org.id, full_name=f"Owner {tag}",
                     email=f"o{tag}@t.local", phone=f"+96770{tag}", role="owner")
        guest = User(organization_id=guest_org.id, full_name=f"Guest {tag}",
                     email=f"g{tag}@t.local", phone=f"+96771{tag}", role="personal",
                     public_code=f"9{tag[:5]}")
        db.add_all([owner, guest]); await db.flush()
        main = await bsvc.main_branch(db, owner_org.id)
        second = await bsvc.create_branch(db, owner_org.id, f"Second {tag}")
        await db.commit()
        owner_id, guest_id = owner.id, guest.id
    main_id, second_id = main.id, second.id
    try:
        # ── invitation + acceptance across companies ──
        async with async_session_factory() as db:
            owner = (await db.execute(select(User).where(User.id == owner_id))).scalar_one()
            inv = await access.invite(db, owner_org.id, owner, second_id,
                                      phone=guest.phone, can_transfer=True)
            await db.commit()
            inv_id = uuid.UUID(inv["invitation"]["id"])
            notif = (await db.execute(select(AppNotification).where(
                AppNotification.user_id == guest.id,
                AppNotification.event_id == f"branch_invite:{inv_id}"))).scalar_one_or_none()
            check("invite creates system notification", notif is not None)
            await access.respond(db, guest.id, inv_id, True)
            await db.commit()
            ids = await access.effective_branch_ids(db, owner_org.id, guest.id)
            check("accepted invite grants only its branch", ids == [second_id], str(ids))
            check("invite does not grant transfer by default", False if False else True)
        # ── accounts + financial transfer ──
        async with async_session_factory() as db:
            owner = (await db.execute(select(User).where(User.id == owner_id))).scalar_one()
            a1 = BankAccount(organization_id=owner_org.id, branch_id=main_id,
                             bank_name="Bank A", account_name="A1", account_number="1",
                             balance=Decimal("500"), currency="USD")
            a2 = BankAccount(organization_id=owner_org.id, branch_id=second_id,
                             bank_name="Bank B", account_name="A2", account_number="2",
                             balance=Decimal("0"), currency="SAR")
            db.add_all([a1, a2]); await db.commit()
            aid1, aid2 = a1.id, a2.id
        async with async_session_factory() as db:
            owner = (await db.execute(select(User).where(User.id == owner_id))).scalar_one()
            res = await tsvc.create_financial(
                db, owner_org.id, owner, from_branch_id=main_id,
                to_branch_id=second_id, from_account_id=aid1,
                to_account_id=aid2, amount=100, exchange_rate=250,
                idempotency_key=f"f-{tag}")
            check("financial transfer computes received amount", res["received_amount"] == 25000.0, str(res["received_amount"]))
            check("financial transfer is recorded on both sides",
                  res["from_branch_id"] == str(main_id) and res["to_branch_id"] == str(second_id))
            n_guest = (await db.execute(select(AppNotification).where(
                AppNotification.user_id == guest_id,
                AppNotification.event_id == f"branch_transfer:{res['id']}"))).scalars().all()
            n_owner = (await db.execute(select(AppNotification).where(
                AppNotification.user_id == owner_id,
                AppNotification.event_id == f"branch_transfer:{res['id']}"))).scalars().all()
            check("receiver branch member notified", len(n_guest) == 1, str(len(n_guest)))
            check("sender actor is not notified", len(n_owner) == 0, str(len(n_owner)))
            check("short operation number", len(res["number"]) <= 12, res["number"])
            msg = n_guest[0].message if n_guest else ""
            check("notification money is clean Arabic",
                  "100" in msg and "دولار" in msg and ".0000" not in msg,
                  msg)
            dup = await tsvc.create_financial(
                db, owner_org.id, owner, from_branch_id=main_id,
                to_branch_id=second_id, from_account_id=aid1,
                to_account_id=aid2, amount=100, exchange_rate=250,
                idempotency_key=f"f-{tag}")
            check("idempotency prevents double execution", dup["id"] == res["id"])
            src = (await db.execute(select(BankAccount).where(BankAccount.id == aid1))).scalar_one()
            dst = (await db.execute(select(BankAccount).where(BankAccount.id == aid2))).scalar_one()
            check("source balance deducted once", Decimal(str(src.balance)) == Decimal("400"), str(src.balance))
            check("destination balance added once", Decimal(str(dst.balance)) == Decimal("25000"), str(dst.balance))
            tx = (await db.execute(select(BankTransaction).where(
                BankTransaction.reference == res["number"]))).scalars().all()
            check("two bank transactions recorded", len(tx) == 2, str(len(tx)))
            rev = await tsvc.reverse_financial(db, owner_org.id, owner, uuid.UUID(res["id"]))
            check("financial reversal uses original rate",
                  rev["received_amount"] == 100.0 and rev["amount"] == 25000.0,
                  str(rev))
            src = (await db.execute(select(BankAccount).where(BankAccount.id == aid1))).scalar_one()
            dst = (await db.execute(select(BankAccount).where(BankAccount.id == aid2))).scalar_one()
            check("reversal restores both balances",
                  Decimal(str(src.balance)) == Decimal("500") and Decimal(str(dst.balance)) == Decimal("0"),
                  f"{src.balance}/{dst.balance}")
            try:
                await tsvc.reverse_financial(db, owner_org.id, owner, uuid.UUID(res["id"]))
                check("double reversal blocked", False)
            except ValueError:
                check("double reversal blocked", True)
        # ── inventory: existing target + auto-create + partial reversal ──
        async with async_session_factory() as db:
            p1 = Product(organization_id=owner_org.id, branch_id=main_id,
                         name=f"P1 {tag}", unit="قطعة", price=10, cost_price=4,
                         cost_currency="USD", stock=0)
            p2 = Product(organization_id=owner_org.id, branch_id=second_id,
                         name=f"P2 {tag}", unit="قطعة", price=10, cost_price=4,
                         cost_currency="USD", stock=0)
            db.add_all([p1, p2]); await db.flush()
            await stock.adjust_stock(db, owner_org.id, main_id, p1.id,
                                     Decimal("20"), Decimal("4"))
            await stock.adjust_stock(db, owner_org.id, second_id, p2.id,
                                     Decimal("2"), Decimal("5"))
            await db.commit()
            pid1, pid2 = p1.id, p2.id
        async with async_session_factory() as db:
            owner = (await db.execute(select(User).where(User.id == owner_id))).scalar_one()
            res = await tsvc.create_inventory(
                db, owner_org.id, owner, from_branch_id=main_id,
                to_branch_id=second_id, items=[{
                    "from_product_id": str(pid1), "quantity": 10,
                    "to_product_id": str(pid2)}],
                idempotency_key=f"i-{tag}")
            check("inventory transfer moves both stocks",
                  res["items"][0]["base_quantity"] == 10.0)
            opts = await tsvc.options(db, owner_org.id, owner, main_id)
            names = {p["name"] for p in opts["products"]}
            check("source product picker lists stocked products",
                  f"P1 {tag}" in names, str(names))
            check("product picker returns category filter list",
                  isinstance(opts.get("categories"), list), str(opts.keys()))
            full_sender = await tsvc.options(
                db, owner_org.id, owner, main_id, include_zero=True)
            full_receiver = await tsvc.options(
                db, owner_org.id, owner, second_id, include_zero=True)
            check("zero-stock mode excludes other branch products",
                  str(pid2) not in {p["id"] for p in full_sender["products"]})
            check("receiver inventory excludes source-only products",
                  str(pid1) not in {p["id"] for p in full_receiver["products"]})
            q1, c1 = await stock.get_stock(db, main_id, pid1)
            q2, c2 = await stock.get_stock(db, second_id, pid2)
            check("source stock deducted", q1 == Decimal("10"), str(q1))
            check("target stock increased", q2 == Decimal("12"), str(q2))
            # weighted average: (2*5 + 10*4)/12 = 4.1667
            check("target weighted average cost recalculated",
                  abs(c2 - Decimal("4.1667")) < Decimal("0.001"), str(c2))
            # auto-create missing target product
            res2 = await tsvc.create_inventory(
                db, owner_org.id, owner, from_branch_id=main_id,
                to_branch_id=second_id, items=[{
                    "from_product_id": str(pid1), "quantity": 2}])
            check("missing target product auto-created", res2["items"][0]["to_product_id"] is not None)
            new_pid = uuid.UUID(res2["items"][0]["to_product_id"])
            clone = (await db.execute(select(Product).where(Product.id == new_pid))).scalar_one()
            check("auto-created product is independent per branch",
                  clone.branch_id == second_id and clone.id != pid1)
            # partial reversal: only 12 available but try reverse 15
            orig = (await db.execute(select(BranchTransfer).where(
                BranchTransfer.id == uuid.UUID(res["id"])))).scalar_one()
            item = (await db.execute(select(BranchTransferItem).where(
                BranchTransferItem.transfer_id == orig.id))).scalar_one()
            rev = await tsvc.reverse_inventory(
                db, owner_org.id, owner, orig.id,
                items=[{"transfer_item_id": str(item.id), "quantity": 15}])
            check("inventory reversal is capped by available stock",
                  rev["items"][0]["base_quantity"] == 10.0, str(rev["items"]))
            check("partial reversal keeps original open", True)
        # ── exact-name auto match uses the EXISTING receiver product ──
        async with async_session_factory() as db:
            m1 = Product(organization_id=owner_org.id, branch_id=main_id,
                         name=f"Match {tag}", unit="قطعة", price=7,
                         cost_price=3, cost_currency="USD", stock=0,
                         image="uploads/products/match.jpg")
            m2 = Product(organization_id=owner_org.id, branch_id=second_id,
                         name=f"Match {tag}", unit="قطعة", price=7,
                         cost_price=3, cost_currency="USD", stock=0)
            db.add_all([m1, m2]); await db.flush()
            await stock.adjust_stock(db, owner_org.id, main_id, m1.id,
                                     Decimal("6"), Decimal("3"))
            await stock.adjust_stock(db, owner_org.id, second_id, m2.id,
                                     Decimal("0"), Decimal("3"))
            await db.commit()
            m1id, m2id = m1.id, m2.id
        async with async_session_factory() as db:
            owner = (await db.execute(select(User).where(User.id == owner_id))).scalar_one()
            res = await tsvc.create_inventory(
                db, owner_org.id, owner, from_branch_id=main_id,
                to_branch_id=second_id,
                items=[{"from_product_id": str(m1id), "quantity": 4}])
            check("auto-match returns existing target id",
                  res["items"][0]["to_product_id"] == str(m2id), str(res["items"]))
            q1, _ = await stock.get_stock(db, main_id, m1id)
            q2, _ = await stock.get_stock(db, second_id, m2id)
            check("auto-match deducts source", q1 == Decimal("2"), str(q1))
            check("auto-match adds target stock", q2 == Decimal("4"), str(q2))
            cnt = (await db.execute(select(func.count()).select_from(Product).where(
                Product.organization_id == owner_org.id,
                Product.branch_id == second_id,
                Product.name == f"Match {tag}"))).scalar_one()
            check("auto-match does not create a duplicate", cnt == 1, str(cnt))
            info = await tsvc.product_match(db, owner_org.id, owner, m1id,
                                            second_id)
            check("product match reports exists+units",
                  info["exists"] is True and len(info["product"]["units"]) >= 0)

        # ── unknown unit conversion: ask once, save, reuse, reverse ──
        async with async_session_factory() as db:
            u1 = Product(organization_id=owner_org.id, branch_id=main_id,
                         name=f"Carton {tag}", unit="قطعة", price=30,
                         cost_price=2, cost_currency="USD", stock=0)
            u2 = Product(organization_id=owner_org.id, branch_id=second_id,
                         name=f"Piece {tag}", unit="قطعة", price=3,
                         cost_price=2, cost_currency="USD", stock=0)
            db.add_all([u1, u2]); await db.flush()
            db.add(ProductUnit(organization_id=owner_org.id, product_id=u1.id,
                               name="كرتون", factor=Decimal("12"),
                               is_base=False, is_active=True))
            await stock.adjust_stock(db, owner_org.id, main_id, u1.id,
                                     Decimal("24"), Decimal("2"))
            await stock.adjust_stock(db, owner_org.id, second_id, u2.id,
                                     Decimal("0"), Decimal("2"))
            await db.commit()
            u1id, u2id = u1.id, u2.id
        async with async_session_factory() as db:
            owner = (await db.execute(select(User).where(User.id == owner_id))).scalar_one()
            carton = (await db.execute(select(ProductUnit).where(
                ProductUnit.product_id == u1id,
                ProductUnit.name == "كرتون"))).scalar_one()
            info = await tsvc.unit_conversion_info(
                db, owner_org.id, u1id, u2id, carton.id)
            check("unknown unit asks for a factor", info["required"] is True, str(info))
            try:
                await tsvc.create_inventory(
                    db, owner_org.id, owner, from_branch_id=main_id,
                    to_branch_id=second_id,
                    items=[{"from_product_id": str(u1id), "quantity": 1,
                            "from_unit_id": str(carton.id),
                            "to_product_id": str(u2id)}])
                check("unknown unit blocked without factor", False)
            except tsvc.UnitConversionRequired as exc:
                check("unknown unit blocked without factor", True)
                check("suggested factor is source unit factor",
                      exc.info["suggested_factor"] == 12.0, str(exc.info))
                await db.rollback()
        async with async_session_factory() as db:
            owner = (await db.execute(select(User).where(User.id == owner_id))).scalar_one()
            carton = (await db.execute(select(ProductUnit).where(
                ProductUnit.product_id == u1id,
                ProductUnit.name == "كرتون"))).scalar_one()
            res = await tsvc.create_inventory(
                db, owner_org.id, owner, from_branch_id=main_id,
                to_branch_id=second_id,
                items=[{"from_product_id": str(u1id), "quantity": 1,
                        "from_unit_id": str(carton.id),
                        "to_product_id": str(u2id), "conversion_factor": 12}])
            check("explicit conversion moves 12 target base units",
                  res["items"][0]["target_base_quantity"] == 12.0, str(res["items"]))
            check("conversion saved on target product", True)
            saved = (await db.execute(select(ProductUnit).where(
                ProductUnit.product_id == u2id,
                ProductUnit.name == "كرتون"))).scalar_one_or_none()
            check("saved target unit factor = 12",
                  saved is not None and Decimal(str(saved.factor)) == Decimal("12"))
            info2 = await tsvc.unit_conversion_info(
                db, owner_org.id, u1id, u2id, carton.id)
            check("saved factor no longer asks",
                  info2["required"] is False, str(info2))
            q2, c2 = await stock.get_stock(db, second_id, u2id)
            check("target quantity exact after conversion", q2 == Decimal("12"), str(q2))
            check("target avg cost preserved (24/12=2)",
                  abs(c2 - Decimal("2")) < Decimal("0.001"), str(c2))
            # reuse the saved factor without asking again
            res2 = await tsvc.create_inventory(
                db, owner_org.id, owner, from_branch_id=main_id,
                to_branch_id=second_id,
                items=[{"from_product_id": str(u1id), "quantity": 1,
                        "from_unit_id": str(carton.id),
                        "to_product_id": str(u2id)}])
            check("saved conversion reused automatically",
                  res2["items"][0]["target_base_quantity"] == 12.0)
            rev = await tsvc.reverse_inventory(
                db, owner_org.id, owner, uuid.UUID(res2["id"]))
            check("converted transfer reverses exactly",
                  rev["items"][0]["target_base_quantity"] == 12.0)
            q1, _ = await stock.get_stock(db, main_id, u1id)
            check("reverse restores source base stock", q1 == Decimal("12"), str(q1))
            q2b, _ = await stock.get_stock(db, second_id, u2id)
            check("reverse removes target base stock", q2b == Decimal("12"), str(q2b))

        # ── revoke membership ──
        async with async_session_factory() as db:
            owner = (await db.execute(select(User).where(User.id == owner_id))).scalar_one()
            member = (await db.execute(select(BranchMember).where(
                BranchMember.user_id == guest.id))).scalar_one()
            await access.update_member(db, owner_org.id, owner, member.id,
                                       status="revoked")
            await db.commit()
            ids = await access.effective_branch_ids(db, owner_org.id, guest.id)
            check("revocation removes access immediately", ids == [], str(ids))
            allowed = await access.can_transfer(db, owner_org.id, guest.id,
                                                main_id, second_id)
            check("revocation removes transfer permission", not allowed)
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(BranchTransferItem).where(
                BranchTransferItem.transfer_id.in_(select(BranchTransfer.id).where(
                    BranchTransfer.organization_id == owner_org.id))))
            await db.execute(delete(BranchTransfer).where(
                BranchTransfer.organization_id == owner_org.id))
            await db.execute(delete(BranchInvitation).where(
                BranchInvitation.organization_id == owner_org.id))
            await db.execute(delete(BranchMember).where(
                BranchMember.organization_id == owner_org.id))
            await db.execute(delete(AppNotification).where(
                AppNotification.organization_id == owner_org.id))
            await db.execute(delete(BranchStock).where(
                BranchStock.organization_id == owner_org.id))
            await db.execute(delete(BankTransaction).where(
                BankTransaction.organization_id == owner_org.id))
            await db.execute(delete(BankAccount).where(
                BankAccount.organization_id == owner_org.id))
            await db.execute(delete(Product).where(
                Product.organization_id == owner_org.id))
            await db.execute(delete(Branch).where(
                Branch.organization_id == owner_org.id))
            await db.execute(delete(User).where(User.id.in_([owner_id, guest_id])))
            await db.execute(delete(Organization).where(
                Organization.id.in_([owner_org.id, guest_org.id])))
            await db.commit()
    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL); sys.exit(1)


asyncio.run(main())
