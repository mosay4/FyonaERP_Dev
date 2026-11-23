"""Merchant ↔ Personal end-to-end runtime test.

Covers: unique codes (existing + new), invite/accept/reject + no duplicates,
one user linked to multiple merchants, partner debts/invoices, settlement-proof
idempotency (approve applies EXACTLY once), reject-with-reason, and debt groups.
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
from app.domain.entities.business_entities import Customer  # noqa: E402
from app.domain.entities.finance_entities import (  # noqa: E402
    BankAccount, BankTransaction,
)
from app.domain.entities.invoice_entities import Invoice, Payment  # noqa: E402
from app.domain.entities.notification_entities import AppNotification  # noqa: E402
from app.domain.entities.merchant_entities import (  # noqa: E402
    DebtGroup, MerchantLink, SettlementRequest, SharedAuditLog,
)
from app.domain.entities.sale_entities import CustomerReceivable  # noqa: E402
from app.domain.services import merchant_link_service as svc  # noqa: E402

ORG = UUID("d6c27bfb-9a8d-4535-8e43-f23787330cbe")
PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    tag = uuid.uuid4().hex[:6]
    p_org = p_user = cust = inv = rec = acct = None
    org2 = cust2 = None
    link1 = link2 = None
    reqs = []

    async with async_session_factory() as db:
        actor = (await db.execute(
            select(User.id).where(User.organization_id == ORG).limit(1)
        )).scalar_one()

        codes = {await svc.allocate_public_code(db) for _ in range(3)}
        check("new codes are 6-digit and unique",
              len(codes) == 3 and all(len(c) == 6 for c in codes), str(codes))

        p_org = Organization(name=f"P-{tag}", slug=f"p-{tag}",
                             subscription_plan="personal")
        db.add(p_org)
        await db.flush()
        p_user = User(organization_id=p_org.id, full_name=f"عميل {tag}",
                      email=f"p{tag}@t.local", phone=f"+96777{tag}", role="owner")
        db.add(p_user)
        await db.flush()
        code = await svc.ensure_user_code(db, p_user)
        check("personal user got a public code", bool(code) and len(code) == 6)

        cust = Customer(organization_id=ORG, name=f"زبون {tag}", phone=p_user.phone)
        db.add(cust)
        await db.flush()
        inv = Invoice(organization_id=ORG, invoice_number=f"INV-{tag}",
                      invoice_type="sale", customer_id=cust.id,
                      invoice_date=date.today(), status="partially_paid",
                      total=Decimal("737.36"), paid_amount=Decimal("0"),
                      balance=Decimal("737.36"), currency="SAR")
        db.add(inv)
        await db.flush()
        rec = CustomerReceivable(organization_id=ORG, customer_id=cust.id,
                                 invoice_id=inv.id, amount=Decimal("737.36"),
                                 paid=Decimal("0"), status="open")
        db.add(rec)
        await db.flush()
        acct = BankAccount(organization_id=ORG, bank_name=f"BANK-{tag}",
                           account_name="T", account_number="1", currency="SAR",
                           account_type="checking", balance=Decimal("5000"))
        db.add(acct)
        await db.flush()
        await db.commit()

    try:
        # ── invite / accept ──
        async with async_session_factory() as db:
            res = await svc.invite(db, ORG, actor, "customer", cust.id,
                                   phone=p_user.phone)
            link1 = UUID(res["id"])
            check("invite created pending", res["status"] == "pending")
            check("lookup by phone", (
                await svc.lookup_user(db, p_user.phone, None)).id == p_user.id)
            check("lookup by code", (
                await svc.lookup_user(db, None, code)).id == p_user.id)
            check("user sees the invite", len(await svc.user_invites(db, p_user.id)) == 1)
            check("nothing shared before accept",
                  await svc.user_links(db, p_user.id) == [])
            try:
                await svc.invite(db, ORG, actor, "customer", cust.id,
                                 phone=p_user.phone)
                check("duplicate invite blocked", False)
            except ValueError:
                check("duplicate invite blocked", True)
            out = await svc.respond(db, p_user.id, link1, True)
            check("accept flips status", out["status"] == "accepted")
            check("user sees the merchant",
                  len(await svc.user_links(db, p_user.id)) == 1)
            det = await svc.partner_detail(db, p_user.id, link1)
            debts = det["debts"]
            # shape: [{'currency': 'SAR', 'debt': 737.36}, ...]
            ok_debt = (isinstance(debts, list) and any(
                d.get("currency") == "SAR"
                and float(d.get("debt", 0)) == 737.36 for d in debts))
            check("partner sees real debt 737.36 SAR", ok_debt, str(debts))
            ivs = await svc.partner_invoices(db, p_user.id, link1)
            check("partner sees the invoice",
                  len(ivs) == 1 and ivs[0]["number"] == f"INV-{tag}", str(ivs))
            await db.commit()

        # ── second merchant → multi-merchant for the same user ──
        async with async_session_factory() as db:
            org2 = Organization(name=f"M2-{tag}", slug=f"m2-{tag}")
            db.add(org2)
            await db.flush()
            cust2 = Customer(organization_id=org2.id, name=f"زبون2 {tag}")
            db.add(cust2)
            await db.flush()
            r2 = await svc.invite(db, org2.id, None, "customer", cust2.id,
                                  phone=p_user.phone)
            link2 = UUID(r2["id"])
            await svc.respond(db, p_user.id, link2, True)
            links = await svc.user_links(db, p_user.id)
            check("one user linked to TWO merchants", len(links) == 2, str(len(links)))
            await db.commit()

        # ── settlement proof idempotency + approve-once ──
        async with async_session_factory() as db:
            key = f"idem-{tag}"
            a = await svc.create_settlement_request(
                db, p_user.id, link1, Decimal("200"), "SAR", "cash", "TRF-1",
                None, "دفعة", key)
            b = await svc.create_settlement_request(
                db, p_user.id, link1, Decimal("200"), "SAR", "cash", "TRF-1",
                None, "دفعة", key)
            check("same idempotency key → one request", a["id"] == b["id"])
            reqs.append(UUID(a["id"]))
            await db.commit()

        async with async_session_factory() as db:
            out = await svc.decide_settlement_request(
                db, ORG, actor, reqs[0], True, acct.id)
            check("approve succeeds", out["status"] == "approved")
            await db.commit()
        async with async_session_factory() as db:
            r = (await db.execute(select(CustomerReceivable).where(
                CustomerReceivable.id == rec.id))).scalar_one()
            check("debt reduced by exactly 200 (once)",
                  float(r.paid) == 200.0, f"paid={r.paid}")
            # re-approve → idempotent, no second movement
            out2 = await svc.decide_settlement_request(
                db, ORG, actor, reqs[0], True, acct.id)
            await db.flush()
            r2 = (await db.execute(select(CustomerReceivable).where(
                CustomerReceivable.id == rec.id))).scalar_one()
            check("re-approve is idempotent (still 200)",
                  out2["status"] == "approved" and float(r2.paid) == 200.0,
                  f"{out2} paid={r2.paid}")
            await db.commit()

        # ── reject with reason (balance unchanged) ──
        async with async_session_factory() as db:
            rr = await svc.create_settlement_request(
                db, p_user.id, link1, Decimal("50"), "SAR", "cash", None, None,
                None, f"rej-{tag}")
            reqs.append(UUID(rr["id"]))
            await db.commit()
        async with async_session_factory() as db:
            try:
                await svc.decide_settlement_request(db, ORG, actor, reqs[1], False)
                check("reject requires a reason", False)
            except ValueError:
                check("reject requires a reason", True)
            await db.rollback()
        async with async_session_factory() as db:
            out = await svc.decide_settlement_request(
                db, ORG, actor, reqs[1], False, None, "المبلغ غير مطابق")
            r = (await db.execute(select(CustomerReceivable).where(
                CustomerReceivable.id == rec.id))).scalar_one()
            check("reject with reason leaves the balance unchanged",
                  out["status"] == "rejected" and float(r.paid) == 200.0,
                  f"paid={r.paid}")
            await db.commit()

        # ── debt groups (organisation only) ──
        async with async_session_factory() as db:
            g = await svc.create_debt_group(db, ORG, actor, "customer",
                                            cust.id, f"دين {tag}", "manual")
            gl = await svc.list_debt_groups(db, ORG, "customer", cust.id)
            check("debt group created & listed",
                  any(x["id"] == g["id"] for x in gl), str(gl))
            await db.commit()
    finally:
        async with async_session_factory() as db:
            from app.api.v1 import reconciliation as _RR  # noqa: F401
            await db.execute(delete(AppNotification).where(
                AppNotification.user_id == p_user.id))
            await db.execute(delete(SharedAuditLog).where(
                SharedAuditLog.entity_id.in_([str(x) for x in reqs])))
            await db.execute(delete(SettlementRequest).where(
                SettlementRequest.external_user_id == p_user.id))
            await db.execute(delete(DebtGroup).where(
                DebtGroup.organization_id.in_(
                    [ORG, org2.id if org2 else ORG])))
            await db.execute(delete(MerchantLink).where(
                MerchantLink.external_user_id == p_user.id))
            if rec:
                await db.execute(delete(Payment).where(Payment.invoice_id == inv.id))
                await db.execute(delete(CustomerReceivable).where(
                    CustomerReceivable.id == rec.id))
            if inv:
                await db.execute(delete(Invoice).where(Invoice.id == inv.id))
            if cust:
                await db.execute(delete(Customer).where(Customer.id == cust.id))
            if cust2:
                await db.execute(delete(Customer).where(Customer.id == cust2.id))
            if acct:
                await db.execute(delete(BankTransaction).where(
                    BankTransaction.bank_account_id == acct.id))
                await db.execute(delete(BankAccount).where(BankAccount.id == acct.id))
            if p_user:
                await db.execute(delete(User).where(User.id == p_user.id))
            for o in (p_org, org2):
                if o:
                    await db.execute(delete(Organization).where(Organization.id == o.id))
            await db.commit()

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
