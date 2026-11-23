"""Debt-rebuild runtime test (isolated rows, real DB, no mocks).

Covers the rebuilt paths:
- overview per-currency totals, individual vs groups, newest-first ordering
- converted display total OR honest fx_missing gap (never a fake number)
- group assign / rename / delete-unassign (financial rows survive)
- business_overview identity/contact shape (phone XOR code, no email)
- personal settlement-request tracking + duplicate-key safety
- unauthorized link access blocked; supplier side works
- debt-domain notification emit is exactly-once per event
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

from app.api.v1 import reconciliation as _R  # noqa: E402,F401 (entity graph)
from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import Organization, User  # noqa: E402
from app.domain.entities.business_entities import Customer, Supplier  # noqa: E402
from app.domain.entities.invoice_entities import (
    Invoice, OrgInvoiceDesign,
)  # noqa: E402
from app.domain.entities.notification_entities import AppNotification  # noqa: E402
from app.domain.entities.merchant_entities import (  # noqa: E402
    DebtGroup, MerchantLink, SettlementRequest,
)
from app.domain.entities.sale_entities import (  # noqa: E402
    Branch, CustomerReceivable, SupplierPayable,
)
from app.domain.services import merchant_link_service as svc  # noqa: E402
from app.domain.services import debt_notification_service as dn  # noqa: E402

ORG = UUID("d6c27bfb-9a8d-4535-8e43-f23787330cbe")
PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    tag = uuid.uuid4().hex[:6]
    p_org = p_user = p_user2 = cust = sup = None
    inv_sar = inv_usd = inv_sup = None
    design_branches = []
    design_ids = []
    rec_sar = rec_usd = pay_sup = None
    link_c = link_s = None
    stranger = None
    group_id = None

    async with async_session_factory() as db:
        actor = (await db.execute(
            select(User.id).where(User.organization_id == ORG).limit(1)
        )).scalar_one()
        p_org = Organization(name=f"DR-{tag}", slug=f"dr-{tag}",
                             subscription_plan="personal")
        db.add(p_org)
        await db.flush()
        p_user = User(organization_id=p_org.id, full_name=f"عميل {tag}",
                      email=f"dr{tag}@t.local", phone=f"+96770{tag}", role="owner")
        db.add(p_user)
        await db.flush()
        await svc.ensure_user_code(db, p_user)
        p_user2 = User(organization_id=p_org.id, full_name=f"مورد-عميل {tag}",
                       email=f"dr2{tag}@t.local", phone=f"+96772{tag}", role="owner")
        db.add(p_user2)
        await db.flush()
        await svc.ensure_user_code(db, p_user2)
        stranger = User(organization_id=p_org.id, full_name=f"غريب {tag}",
                        email=f"st{tag}@t.local", phone=f"+96771{tag}", role="owner")
        db.add(stranger)
        await db.flush()
        cust = Customer(organization_id=ORG, name=f"زبون {tag}", phone=p_user.phone)
        db.add(cust)
        await db.flush()
        sup = Supplier(organization_id=ORG, name=f"مورد {tag}")
        db.add(sup)
        await db.flush()

        inv_sar = Invoice(organization_id=ORG, invoice_number=f"DRS-{tag}",
                          invoice_type="sale", customer_id=cust.id,
                          invoice_date=date.today(), status="confirmed",
                          total=Decimal("1000"), paid_amount=Decimal("0"),
                          balance=Decimal("1000"), currency="SAR")
        inv_usd = Invoice(organization_id=ORG, invoice_number=f"DRU-{tag}",
                          invoice_type="sale", customer_id=cust.id,
                          invoice_date=date.today(), status="confirmed",
                          total=Decimal("500"), paid_amount=Decimal("0"),
                          balance=Decimal("500"), currency="USD")
        inv_sup = Invoice(organization_id=ORG, invoice_number=f"DRP-{tag}",
                          invoice_type="purchase", supplier_id=sup.id,
                          invoice_date=date.today(), status="confirmed",
                          total=Decimal("300"), paid_amount=Decimal("0"),
                          balance=Decimal("300"), currency="SAR")
        db.add_all([inv_sar, inv_usd, inv_sup])
        await db.flush()
        # Two real branch designs reproduce the former MultipleResultsFound
        # when the personal partner opened an invoice (branch_id NULL legacy).
        for suffix in ("A", "B"):
            branch = Branch(organization_id=ORG, name=f"DR-{tag}-{suffix}")
            db.add(branch)
            await db.flush()
            design = OrgInvoiceDesign(
                organization_id=ORG, branch_id=branch.id,
                template_id="paper", payload="{}")
            db.add(design)
            design_branches.append(branch)
            design_ids.append(design.id)
        await db.flush()
        rec_sar = CustomerReceivable(organization_id=ORG, customer_id=cust.id,
                                     invoice_id=inv_sar.id, amount=Decimal("1000"),
                                     paid=Decimal("0"), status="open")
        rec_usd = CustomerReceivable(organization_id=ORG, customer_id=cust.id,
                                     invoice_id=inv_usd.id, amount=Decimal("500"),
                                     paid=Decimal("0"), status="open")
        pay_sup = SupplierPayable(organization_id=ORG, supplier_id=sup.id,
                                  invoice_id=inv_sup.id, amount=Decimal("300"),
                                  paid=Decimal("0"), status="open")
        db.add_all([rec_sar, rec_usd, pay_sup])
        await db.flush()
        await db.commit()

    try:
        # ── link validation ──
        async with async_session_factory() as db:
            try:
                await svc.lookup_user(db, p_user.phone, p_user.public_code)
                check("phone+code together rejected", False)
            except ValueError:
                check("phone+code together rejected", True)
            try:
                await svc.invite(db, ORG, actor, " stranger ".strip() or "x",
                                 cust.id, phone=p_user.phone)
                check("bad party kind rejected", False)
            except ValueError:
                check("bad party kind rejected", True)
            r = await svc.invite(db, ORG, actor, "customer", cust.id,
                                 phone=p_user.phone)
            link_c = UUID(r["id"])
            check("customer invite pending", r["status"] == "pending")
            await svc.respond(db, p_user.id, link_c, True)
            r2 = await svc.invite(db, ORG, actor, "supplier", sup.id,
                                  code=p_user2.public_code)
            link_s = UUID(r2["id"])
            await svc.respond(db, p_user2.id, link_s, True)
            st = await svc.merchant_link_status(db, ORG, "customer", cust.id)
            check("status carries phone contact only",
                  st["contact"]["via"] == "phone"
                  and st["contact"]["value"] == p_user.phone
                  and "email" not in str(st).lower(), str(st.get("contact")))
            st2 = await svc.merchant_link_status(db, ORG, "supplier", sup.id)
            check("code-linked contact shows code",
                  st2["contact"]["via"] == "code"
                  and st2["contact"]["value"] == p_user2.public_code,
                  str(st2.get("contact")))
            await db.commit()

        # ── stranger isolation ──
        async with async_session_factory() as db:
            try:
                await svc.partner_debt_overview(db, stranger.id, link_c, "SAR")
                check("stranger blocked from debts", False)
            except ValueError:
                check("stranger blocked from debts", True)
            await db.rollback()

        # ── overview: two currencies, no fake sums ──
        async with async_session_factory() as db:
            ov = await svc.partner_debt_overview(db, p_user.id, link_c, "SAR")
            ccys = {c["currency"]: c["total"] for c in ov["per_currency"]}
            check("per-currency kept separate (SAR+USD)",
                  set(ccys) == {"SAR", "USD"}, str(ccys))
            check("individual holds both ops pre-grouping",
                  len(ov["individual"]) == 2, str(len(ov["individual"])))
            dates = [o["date"] for o in ov["operations"]]
            check("operations newest-first",
                  dates == sorted(dates, reverse=True), str(dates))
            if ov["display_total"] is None:
                check("unconvertible total is an honest gap",
                      len(ov.get("fx_missing") or []) > 0,
                      str(ov.get("fx_missing")))
            else:
                check("converted total is a number",
                      float(ov["display_total"]) > 0, str(ov["display_total"]))
            await db.rollback()

        # ── supplier overview ──
        async with async_session_factory() as db:
            ovs = await svc.partner_debt_overview(db, p_user2.id, link_s, "SAR")
            check("supplier debt visible",
                  any(c["currency"] == "SAR" for c in ovs["per_currency"]),
                  str(ovs["per_currency"]))
            await db.rollback()

        # ── business overview identity ──
        async with async_session_factory() as db:
            bo = await svc.business_overview(db, ORG, "customer", cust.id)
            check("business overview has party+contact+requests",
                  bo["party"]["name"] == cust.name
                  and bo["contact"]["via"] == "phone"
                  and isinstance(bo["requests"], list), str(bo.keys()))
            await db.rollback()

        # ── group lifecycle ──
        async with async_session_factory() as db:
            g = await svc.create_debt_group(db, ORG, actor, "customer",
                                            cust.id, f"قسم {tag}", "manual")
            group_id = UUID(g["id"])
            await svc.assign_group(db, ORG, actor, "customer", cust.id,
                                   inv_sar.id, group_id)
            ov = await svc.partner_debt_overview(db, p_user.id, link_c, "SAR")
            check("grouped op leaves individual list",
                  all(o["id"] != str(inv_sar.id) for o in ov["individual"]),
                  str([o["id"] for o in ov["individual"]]))
            check("group count is exactly 1",
                  any(x["id"] == str(group_id) and x["count"] == 1
                      for x in ov["groups"]), str(ov["groups"]))
            ov_g = await svc.partner_debt_overview(
                db, p_user.id, link_c, "SAR", group_id)
            check("group-scoped ops contain the invoice",
                  any(o["id"] == str(inv_sar.id) for o in ov_g["operations"]),
                  str([o["id"] for o in ov_g["operations"]]))
            await svc.manage_group(db, ORG, actor, group_id, f"قسم معدل {tag}")
            gl = await svc.list_debt_groups(db, ORG, "customer", cust.id)
            check("rename works",
                  any(x["id"] == str(group_id) and "معدل" in x["name"]
                      for x in gl), str(gl))
            await db.commit()
        async with async_session_factory() as db:
            await svc.manage_group(db, ORG, actor, group_id, remove=True)
            ov = await svc.partner_debt_overview(db, p_user.id, link_c, "SAR")
            check("delete unassigns (invoice survives, back to individual)",
                  any(o["id"] == str(inv_sar.id) for o in ov["individual"]),
                  str([o["id"] for o in ov["individual"]]))
            await db.commit()
            group_id = None

        # ── personal request tracking ──
        async with async_session_factory() as db:
            rr = await svc.create_settlement_request(
                db, p_user.id, link_c, Decimal("100"), "SAR", "cash",
                None, None, None, f"track-{tag}")
            mine = await svc.user_settlement_requests(db, p_user.id, link_c)
            check("user tracks own request",
                  any(x["id"] == rr["id"] and x["status"] == "pending"
                      for x in mine), str(mine))
            await db.commit()
        async with async_session_factory() as db:
            try:
                await svc.user_settlement_requests(db, stranger.id, link_c)
                check("stranger cannot list requests", False)
            except ValueError:
                check("stranger cannot list requests", True)
            await db.rollback()

        # ── operation detail + notification dedup ──
        async with async_session_factory() as db:
            det = await svc.partner_operation_detail(
                db, p_user.id, link_c, inv_usd.id)
            check("operation detail has items/totals/currency",
                  det["currency"] == "USD"
                  and float(det["total"]) == 500.0
                  and isinstance(det["items"], list), str(det))
            e1 = await dn.emit(db, ORG, f"dedup-{tag}", [p_user.id],
                               title="T", message="M", route="/personal")
            e2 = await dn.emit(db, ORG, f"dedup-{tag}", [p_user.id],
                               title="T", message="M", route="/personal")
            check("duplicate event emits once", bool(e1) and not e2,
                  f"{e1}/{e2}")
            await db.commit()
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(AppNotification).where(
                AppNotification.user_id.in_(
                    [u.id for u in (p_user, p_user2, stranger) if u is not None])))
            # Scoped cleanup only: rows created by this run (tagged names).
            await db.execute(delete(SettlementRequest).where(
                SettlementRequest.external_user_id.in_(
                    [u.id for u in (p_user, p_user2, stranger) if u is not None])))
            await db.execute(delete(DebtGroup).where(
                DebtGroup.organization_id == ORG,
                DebtGroup.name.like(f"%{tag}%")))
            await db.execute(delete(MerchantLink).where(
                MerchantLink.merchant_org_id == ORG,
                MerchantLink.external_user_id.in_(
                    [u.id for u in (p_user, p_user2, stranger) if u is not None])))
            for rid, model in ((rec_sar, CustomerReceivable),
                               (rec_usd, CustomerReceivable)):
                if rid is not None:
                    await db.execute(delete(model).where(
                        model.id == rid.id))
            if pay_sup is not None:
                await db.execute(delete(SupplierPayable).where(
                    SupplierPayable.id == pay_sup.id))
            for did in design_ids:
                await db.execute(delete(OrgInvoiceDesign).where(
                    OrgInvoiceDesign.id == did))
            for branch in design_branches:
                await db.execute(delete(Branch).where(
                    Branch.id == branch.id))
            for inv in (inv_sar, inv_usd, inv_sup):
                if inv is not None:
                    await db.execute(delete(Invoice).where(
                        Invoice.id == inv.id))
            if cust is not None:
                await db.execute(delete(Customer).where(
                    Customer.id == cust.id))
            if sup is not None:
                await db.execute(delete(Supplier).where(
                    Supplier.id == sup.id))
            for u in (p_user, stranger):
                if u is not None:
                    await db.execute(delete(User).where(User.id == u.id))
            if p_org is not None:
                await db.execute(delete(Organization).where(
                    Organization.id == p_org.id))
            await db.commit()

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
