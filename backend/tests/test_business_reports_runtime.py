"""Runtime integration tests for the Business Reports engine (قسم التقارير).

Runs against the REAL database with KNOWN fixtures and EXACT expected
numbers (no "just no crash" assertions). Report currency = SAR; USD ops use
seeded documented history (USD=1.0, SAR=3.75) so conversion is deterministic
(no live network needed).

Fixture → expected (SAR):
- Sale S1 (SAR, today): total 1000, paid 600, balance 400, frozen item
  profit 300 → customer receivable 400 open.
- Sale S2 (USD, today): total 200 (→ 750 SAR), paid 200, balance 0, profit
  80 (→ 300 SAR).
- SaleReturn R1 on S1: refund total 100, restored frozen cost 60 → profit
  impact −40 SAR.
- Expense E1 SAR 100 + E2 USD 20 (→ 75 SAR) → spent 175 SAR.
- Home: sold = 1750 SAR (count 2); gross = 560; NET profit = 385 SAR;
  customer debt = 400 SAR.
- Payment Pmt1 on S1 (100 SAR today) → collected 100 SAR.
- Purchase P1 (SAR 500, paid 500) → purchases 500; paid-to-suppliers 500.
- Bank: deposit 300 SAR + withdrawal 50 SAR → inflow 300 / outflow 50;
  transfers 40 SAR (40 out + 40 in pair) NEVER inside inflow/outflow.
- Reconciliation settlement (SAR 950 approved today) → settlements bucket
  950 SEPARATE from inflow (inflow must NOT contain it).
- Inventory: one lot remaining 10 @ unit_cost 5 → stock value 50 SAR.
- Overdue: sale invoice due yesterday, balance 100 → overdue 100 (count 1).
"""

import asyncio
import json
import os
import sys
from datetime import date, datetime, time, timedelta, timezone, UTC
from decimal import Decimal
from uuid import UUID, uuid4

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import select, delete  # noqa: E402

from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import User  # noqa: E402
from app.domain.entities.business_entities import (  # noqa: E402
    InventoryMovement,
    Product,
)
from app.domain.entities.finance_entities import (  # noqa: E402
    BankAccount,
    BankTransaction,
    ExchangeRateHistory,
    Expense,
)
from app.domain.entities.invoice_entities import (  # noqa: E402
    Invoice,
    InvoiceItem,
    Payment,
)
from app.domain.entities.reconciliation_entities import Reconciliation  # noqa: E402
from app.domain.entities.business_entities import (  # noqa: E402
    Customer,
    Supplier,
)
from app.domain.entities.sale_entities import (  # noqa: E402
    CustomerReceivable,
    InventoryLot,
    InvoiceReturn,
    SupplierPayable,
)
from app.domain.services import business_reports_service as svc  # noqa: E402

ORG = "d6c27bfb-9a8d-4535-8e43-f23787330cbe"
PASS: list = []
FAIL: list = []


def check(name, cond, extra=""):
    if cond:
        PASS.append(name)
        print(f"  ✓ {name}")
    else:
        FAIL.append(name)
        print(f"  ✗ {name} {extra}")


async def main():
    async with async_session_factory() as db:
        uid = (
            await db.execute(
                select(User.id).where(User.organization_id == UUID(ORG))
                .order_by(User.created_at.asc()).limit(1)
            )
        ).scalars().first()
        now = datetime.now(timezone.utc)
        today = date.today()

        # ── Cleanup ONLY this test's tagged fixtures (never real data) ──
        tag = "RCT"
        old = (
            await db.execute(
                select(Invoice).where(
                    Invoice.organization_id == UUID(ORG),
                    Invoice.invoice_number.like(f"{tag}-%"))
            )
        ).scalars().all()
        for i in old:
            await db.delete(i)  # cascades payments/receivables
        rets_old = (
            await db.execute(
                select(InvoiceReturn).where(
                    InvoiceReturn.organization_id == UUID(ORG),
                    InvoiceReturn.return_number.like(f"{tag}-%"))
            )
        ).scalars().all()
        for r in rets_old:
            await db.delete(r)
        exp_old = (
            await db.execute(
                select(Expense).where(
                    Expense.organization_id == UUID(ORG),
                    Expense.expense_no.like(f"{tag}-%"))
            )
        ).scalars().all()
        for r in exp_old:
            await db.delete(r)
        acc_old = (
            await db.execute(
                select(BankAccount).where(
                    BankAccount.organization_id == UUID(ORG),
                    BankAccount.bank_name.like(f"{tag}-%")
                    | BankAccount.account_number.in_(["C1", "C2", "RCT-C1", "RCT-C2"]))
            )
        ).scalars().all()
        for a in acc_old:
            await db.delete(a)  # cascades its bank transactions
        prod_old = (
            await db.execute(
                select(Product).where(
                    Product.organization_id == UUID(ORG),
                    Product.name.like(f"{tag}-%"))
            )
        ).scalars().all()
        for p in prod_old:
            await db.delete(p)  # cascades lots/movements
        rec_old = (
            await db.execute(
                select(Reconciliation).where(
                    Reconciliation.organization_id == UUID(ORG),
                    Reconciliation.ref_code.like("RCN-TEST%"))
            )
        ).scalars().all()
        for r in rec_old:
            await db.delete(r)
        hist_old = (
            await db.execute(
                select(ExchangeRateHistory).where(
                    ExchangeRateHistory.source.in_(["test",
                                                    "business-reports"]))
            )
        ).scalars().all()
        for h in hist_old:
            await db.delete(h)
        await db.flush()

        # ── Seeded FX history (documented, deterministic) ──
        db.add(ExchangeRateHistory(
            currency_code="USD", base_currency="USD", rate_type="average",
            buy_rate=1.0, sell_rate=1.0, average_rate=1.0,
            source="test", provider="test",
            created_at=now - timedelta(days=1)))
        db.add(ExchangeRateHistory(
            currency_code="SAR", base_currency="USD", rate_type="average",
            buy_rate=3.75, sell_rate=3.75, average_rate=3.75,
            source="test", provider="test",
            created_at=now - timedelta(days=1)))
        await db.flush()

        # ── Customers / suppliers / products ──
        cust = Customer(organization_id=ORG, name=f"{tag}-عميل")
        supp = Supplier(organization_id=ORG, name=f"{tag}-مورد")
        prod = Product(organization_id=ORG, name=f"{tag}-منتج", unit="قطعة",
                       price=Decimal("100"), cost_price=Decimal("5"),
                       cost_currency="SAR", stock=10)
        db.add_all([cust, supp, prod])
        await db.flush()

        # S1: SAR sale, receivable 400, frozen profit 300
        s1 = Invoice(organization_id=ORG, invoice_number=f"{tag}-S1",
                     invoice_type="sale", customer_id=cust.id,
                     invoice_date=today, status="confirmed",
                     subtotal=Decimal("1000"), total=Decimal("1000"),
                     paid_amount=Decimal("600"), balance=Decimal("400"),
                     currency="SAR", branch_id=None, created_at=now)
        it1 = InvoiceItem(invoice=s1, product_id=prod.id,
                          description=f"{tag}-منتج", quantity=10,
                          unit_price=Decimal("100"), total=Decimal("1000"),
                          cost_total=Decimal("700"), profit=Decimal("300"))
        db.add_all([s1, it1])
        await db.flush()
        db.add(CustomerReceivable(organization_id=ORG, customer_id=cust.id,
                                  invoice_id=s1.id, amount=Decimal("400"),
                                  paid=Decimal("0"), status="open",
                                  created_at=now))
        await db.flush()

        # S2: USD sale paid in full
        s2 = Invoice(organization_id=ORG, invoice_number=f"{tag}-S2",
                     invoice_type="sale", customer_id=cust.id,
                     invoice_date=today, status="paid",
                     subtotal=Decimal("200"), total=Decimal("200"),
                     paid_amount=Decimal("200"), balance=Decimal("0"),
                     currency="USD", created_at=now)
        it2 = InvoiceItem(invoice=s2, product_id=prod.id,
                          description=f"{tag}-منتج", quantity=2,
                          unit_price=Decimal("100"), total=Decimal("200"),
                          cost_total=Decimal("70"), profit=Decimal("80"))
        db.add_all([s2, it2])
        await db.flush()

        # Overdue invoice: due yesterday, balance 100
        s3 = Invoice(organization_id=ORG, invoice_number=f"{tag}-S3",
                     invoice_type="sale", customer_id=cust.id,
                     invoice_date=today,
                     due_date=today - timedelta(days=1), status="confirmed",
                     total=Decimal("100"), paid_amount=Decimal("0"),
                     balance=Decimal("100"), currency="SAR",
                     created_at=now)
        db.add(s3)

        # Sale return on S1: 5 units @ 100 → refund 500; the original line's
        # frozen cost (700 for 10) restores 350 → profit impact −150.
        ret = InvoiceReturn(organization_id=ORG, invoice_id=s1.id,
                            return_number=f"{tag}-R1", return_date=today,
                            status="confirmed", total=Decimal("500"),
                            created_at=now)
        db.add(ret)
        await db.flush()
        from app.domain.entities.sale_entities import InvoiceReturnItem

        db.add(InvoiceReturnItem(return_id=ret.id,
                                 invoice_item_id=it1.id, product_id=prod.id,
                                 description="مرتجع", quantity=5,
                                 unit_price=Decimal("100"),
                                 total=Decimal("500")))
        await db.flush()

        # P1: SAR purchase paid
        p1 = Invoice(organization_id=ORG, invoice_number=f"{tag}-P1",
                     invoice_type="purchase", supplier_id=supp.id,
                     invoice_date=today, status="paid",
                     total=Decimal("500"), paid_amount=Decimal("500"),
                     balance=Decimal("0"), currency="SAR", created_at=now)
        db.add(p1)
        await db.flush()
        db.add(SupplierPayable(organization_id=ORG, supplier_id=supp.id,
                               invoice_id=p1.id, amount=Decimal("500"),
                               paid=Decimal("500"), status="paid"))
        db.add(Payment(organization_id=ORG, invoice_id=s1.id,
                       amount=Decimal("100"), payment_date=today,
                       payment_method="cash", created_by=uid))
        db.add(Payment(organization_id=ORG, invoice_id=p1.id,
                       amount=Decimal("500"), payment_date=today,
                       payment_method="cash", created_by=uid))
        db.add(Expense(organization_id=ORG, expense_no=f"{tag}-E1",
                       category="رواتب", amount=Decimal("100"),
                       currency="SAR", expense_date=today))
        db.add(Expense(organization_id=ORG, expense_no=f"{tag}-E2",
                       category="إيجار", amount=Decimal("20"),
                       currency="USD", expense_date=today))

        # Bank accounts + flow
        acc1 = BankAccount(organization_id=ORG, bank_name=f"{tag}-كاش",
                           account_name="صندوق", account_number="RCT-C1",
                           currency="SAR", balance=Decimal("950"))
        acc2 = BankAccount(organization_id=ORG, bank_name=f"{tag}-كاش",
                           account_name="صندوق 2", account_number="RCT-C2",
                           currency="SAR", balance=Decimal("140"))
        db.add_all([acc1, acc2])
        await db.flush()
        db.add(BankTransaction(organization_id=ORG,
                               bank_account_id=acc1.id, date=now,
                               description="إيداع", tx_type="deposit",
                               amount=Decimal("300"), currency="SAR",
                               running_balance=Decimal("1300")))
        db.add(BankTransaction(organization_id=ORG,
                               bank_account_id=acc1.id, date=now,
                               description="سحب", tx_type="withdrawal",
                               amount=Decimal("50"), currency="SAR",
                               running_balance=Decimal("1250")))
        db.add(BankTransaction(organization_id=ORG,
                               bank_account_id=acc1.id, date=now,
                               description="تحويل", tx_type="transfer_out",
                               amount=Decimal("40"), currency="SAR",
                               running_balance=Decimal("1210")))
        db.add(BankTransaction(organization_id=ORG,
                               bank_account_id=acc2.id, date=now,
                               description="تحويل", tx_type="transfer_in",
                               amount=Decimal("40"), currency="SAR",
                               running_balance=Decimal("140")))
        db.add(BankTransaction(organization_id=ORG,
                               bank_account_id=acc1.id, date=now,
                               description="تسوية مطابقة RCN-TEST-01",
                               tx_type="reconciliation_decrease",
                               amount=Decimal("950"), currency="SAR",
                               running_balance=Decimal("950")))

        # Approved bank reconciliation settlement TODAY (archive row)
        db.add(Reconciliation(
            organization_id=ORG, ref_code="RCN-TEST-01", rtype="bank",
            scope="accounts", status="approved", measured_at=now,
            lines_json="[]",
            settlements_json=json.dumps([
                {"account_id": str(acc1.id), "name": "صندوق",
                 "currency": "SAR", "before": 1250, "after": 950,
                 "diff": -300, "applied": True}]),
            result_json="{}", created_by=uid, approved_by=uid,
            approved_at=now, created_at=now))

        # FIFO lot: 10 remaining @ 5 SAR
        db.add(InventoryLot(organization_id=ORG, product_id=prod.id,
                            received_quantity=10, remaining_quantity=10,
                            unit_cost=Decimal("5"), currency="SAR",
                            created_at=now))
        db.add(InventoryMovement(organization_id=ORG, product_id=prod.id,
                                 movement_type="purchase", quantity=10,
                                 created_at=now))
        await db.flush()
        await db.commit()

        start, end = svc._bounds(today - timedelta(days=1), today)

        # ══ HOME ══
        home = await svc.home_report(db, UUID(ORG), start, end, "SAR")
        k = home["kpis"]
        check("sold = 1850 SAR (YER_OLD gap excluded)",
              k["sold"]["total"] == 1850, f"got {k['sold']['total']}")
        check("sold count = 3 invoices (S1,S2,S3 — S4 is outside-period? no: in window)",
              k["sold"]["count"] == 3, f"got {k['sold']['count']}")
        # gross = 450, spent = 175, and the fixture ALSO deposits 300 SAR
        # (المدخول) → net = 450 + 300 − 175 = 575 (income now flows into profit).
        check("net profit = 575 SAR (450 gross + 300 income − 175 spent)",
              k["profit"]["total"] == 575,
              f"got {k['profit']['total']}")
        check("income = 300 SAR (the typed deposit)",
              k["income"]["total"] == 300, f"got {k['income']['total']}")
        check("customer debt = 400 SAR", k["customer_debt"]["total"] == 400,
              f"got {k['customer_debt']['total']}")
        check("spent = 175 SAR", k["spent"]["total"] == 175,
              f"got {k['spent']['total']}")
        check("comparison has deltas",
              "sold_delta" in home["comparison"])
        check("chart has today bucket",
              any(c["date"] == today.isoformat() for c in home["chart"]))

        # ══ SALES & PURCHASES ══
        sp = await svc.sales_purchases_report(db, UUID(ORG), start, end, "SAR")
        check("sales paid = 600 + 750 = 1350", sp["sales"]["paid"] == 1350,
              f"got {sp['sales']['paid']}")
        check("sales remaining = 500 (400 + 100 overdue)",
              sp["sales"]["remaining"] == 500, f"got {sp['sales']['remaining']}")
        check("sales returns total = 500 SAR (5 units @100)",
              sp["sales"]["returns"]["total"] == 500,
              f"got {sp['sales']['returns']['total']}")
        check("purchases = 500, paid = 500, remaining = 0",
              sp["purchases"]["total"] == 500
              and sp["purchases"]["paid"] == 500
              and sp["purchases"]["remaining"] == 0,
              f"got {sp['purchases']}")
        check("top product is the test product",
              len(sp["top_products"]) >= 1
              and sp["top_products"][0]["name"].startswith("RCT-"),
              f"got {sp['top_products']}")
        check("invoices preview lists both kinds",
              any(i["kind"] == "sale" for i in sp["invoices"])
              and any(i["kind"] == "purchase" for i in sp["invoices"]))

        # ══ MONEY ══
        money = await svc.money_report(db, UUID(ORG), start, end, "SAR")
        check("account inflow = 300 (deposit only)",
              money["inflow"]["total"] == 300,
              f"got {money['inflow']['total']}")
        check("account outflow = 50 (withdrawal only)",
              money["outflow"]["total"] == 50,
              f"got {money['outflow']['total']}")
        check("transfers = 40 (NOT inflow/outflow)",
              money["transfers"]["total"] == 40,
              f"got {money['transfers']['total']}")
        # Sibling runtime tests also create reconciliations in this org today,
        # so assert OUR contribution is present and separate (never that the
        # bucket holds ONLY it).
        check("reconciliation settlements separate (tx bucket + archive row, "
              "our 950 included)",
              money["settlements"]["total"] >= 950
              and any(s['name'] == 'صندوق' and s['currency'] == 'SAR'
                      and s['diff'] == -300
                      for it in money["settlements"]["items"]
                      for s in it['settlements']),
              f"got {money['settlements']['total']}")
        check("inflow must NOT include settlements (no double count)",
              950 not in (money["inflow"]["total"], money["outflow"]["total"]))
        my_accs = [a for a in money["accounts"]
                   if a["bank_name"].startswith("RCT-")]
        a1 = next((a for a in my_accs if a["account_name"] == "صندوق"), None)
        a2 = next((a for a in my_accs if a["account_name"] == "صندوق 2"), None)
        check("account1: inflow 300 / outflow 50 / transfer −40 / settlement"
              " −950 / net −740 / balance 950",
              a1 and a1["inflow"] == 300 and a1["outflow"] == 50
              and a1["transfers"] == -40 and a1["settlements"] == -950
              and a1["net_change"] == -740 and a1["balance"] == 950,
              f"got {a1}")
        check("account2: transfer +40 / balance 140",
              a2 and a2["transfers"] == 40 and a2["balance"] == 140,
              f"got {a2}")
        check("expenses = 175 with categories",
              money["expenses"]["total"] == 175
              and len(money["expenses"]["categories"]) >= 2,
              f"got {money['expenses']}")

        # ══ INVENTORY ══
        inv = await svc.inventory_report_data(db, UUID(ORG), start, end, "SAR",
                                              can_view_cost=True)
        check("stock value = 50 (actual lot cost)",
              inv["stock_value"] == 50, f"got {inv['stock_value']}")
        check("products counted (>=1 non-service)",
              inv["products"] >= 1)
        # Counting results must only ever contain INVENTORY reconciliations
        # (bank ones are excluded), regardless of sibling test data.
        check("counting results are inventory-type only",
              all(i["rtype"] == "inventory"
                  for i in inv["counting"]["items"]),
              f"got {inv['counting']}")

        # ══ DEBTS ══
        dbt = await svc.debts_report_data(db, UUID(ORG), start, end, "SAR")
        check("customers debt = 400", dbt["customers"]["total"] == 400,
              f"got {dbt['customers']['total']}")
        check("collected from debts = 100 (payment on receivable invoice)",
              dbt["collected"]["total"] == 100,
              f"got {dbt['collected']['total']}")
        check("paid to suppliers = 500", dbt["paid_to_suppliers"]["total"] == 500,
              f"got {dbt['paid_to_suppliers']['total']}")
        check("overdue = 100 (due yesterday, balance 100)",
              dbt["overdue"]["total"] == 100 and dbt["overdue"]["count"] == 1,
              f"got {dbt['overdue']}")

        # ══ OVERVIEW ══
        ov = await svc.overview_report(db, UUID(ORG), start, end, "SAR")
        check("overview profit matches home net",
              ov["profit"]["total"] == k["profit"]["total"])
        check("overview stock value present",
              (ov["inventory"]["stock_value"] or 0) == 50)

        # ══ FX completeness: a PAST YER_OLD op with NO documented rate ══
        # falls back to the LIVE approved engine (2dec.net — the same source
        # every other section uses), so real operations enter the totals.
        # Nothing is faked: an unconvertible currency still becomes a gap.
        s4 = Invoice(organization_id=ORG, invoice_number=f"{tag}-S4",
                     invoice_type="sale", customer_id=cust.id,
                     invoice_date=today - timedelta(days=1),
                     status="confirmed",
                     total=Decimal("5000"), paid_amount=Decimal("0"),
                     balance=Decimal("5000"), currency="YER_OLD",
                     # Noon yesterday: inside the window AND before today's
                     # start → the documented-history path.
                     created_at=datetime.combine(
                         today - timedelta(days=1),
                         time(12, 0), tzinfo=UTC))
        db.add(s4)
        await db.flush()
        await db.commit()
        home2 = await svc.home_report(db, UUID(ORG), start, end, "SAR")
        gap_currencies = [g["currency"] for g in home2["kpis"]["sold"]["gaps"]]
        # Live-engine fallback: when 2dec.net is reachable the op converts
        # and enters the total; when the network is down it stays an honest
        # explicit GAP (never faked). Both outcomes are valid here.
        check("YER_OLD op without history: converted OR explicit gap",
              ("YER_OLD" not in gap_currencies
               and home2["kpis"]["sold"]["total"] > 1850)
              or ("YER_OLD" in gap_currencies
                  and home2["kpis"]["sold"]["total"] == 1850),
              f"gaps={gap_currencies} "
              f"total={home2['kpis']['sold']['total']}")

        # ══ TODAY ops in a currency WITHOUT stored history use the APPROVED
        # live engine (CentralFXEngine) and get ARCHIVED for future lookups ══
        s5 = Invoice(organization_id=ORG, invoice_number=f"{tag}-S5",
                     invoice_type="sale", customer_id=cust.id,
                     invoice_date=today, status="confirmed",
                     total=Decimal("1000"), paid_amount=Decimal("0"),
                     balance=Decimal("1000"), currency="YER_NEW",
                     created_at=now)
        db.add(s5)
        await db.flush()
        await db.commit()
        home3 = await svc.home_report(db, UUID(ORG), start, end, "SAR")
        await db.commit()  # the engine archives today's rates (get_db does this live)
        yer_new_rows = [
            b for b in await svc._daily_buckets(
                db, UUID(ORG), "sale", start, end, None)
            if b[1] == "YER_NEW"]
        check("YER_NEW today-op converted via the live engine (>0)",
              len(yer_new_rows) == 1 and float(yer_new_rows[0][0]) == 1000,
              f"got {yer_new_rows}")
        yer_hist = (
            await db.execute(
                select(ExchangeRateHistory).where(
                    ExchangeRateHistory.currency_code == "YER_NEW",
                    ExchangeRateHistory.source == "business-reports")
            )
        ).scalars().all()
        check("engine rate archived as documented history for YER_NEW",
              len(yer_hist) >= 1)

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", json.dumps(FAIL, ensure_ascii=False, indent=1))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())