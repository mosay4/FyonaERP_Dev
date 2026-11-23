"""Business Reports engine (قسم التقارير) — merchant-facing, real numbers.

SOURCE OF TRUTH (no parallel ledgers):
- كم بعت        → sale Invoices (status NOT draft/cancelled) `total`, per the
                  invoice's own strict single currency.
- كم ربحت       → FROZEN per-line FIFO/FEFO profit (`InvoiceItem.profit`,
                  line_total − actual lot cost, frozen at issue time)
                  − returns impact (InvoiceReturn refund vs the original
                  line's frozen cost, proportional to returned qty)
                  − operational Expenses. Stock purchases are NEVER counted
                  as operating expense.
- كم صرفت       → Expense rows only.
- كم باقي عند العملاء → CustomerReceivable open/partial remainders
                  (current state); suppliers likewise on SupplierPayable.
- استلام الديون → Payments in the period on sale invoices; supplier side
                  symmetric (payments on purchase invoices).
- فلوس الحسابات → BankTransaction signed sums per account (day-bucketed for
                  FX); internal transfers reported SEPARATELY and never as
                  company income/expense; reconciliation settlements come
                  from the permanent archive, separate and labelled.
- قيمة المخزون  → InventoryLot remaining_quantity × unit_cost per lot
                  currency — the ACTUAL FIFO/FEFO cost, never a blended
                  average.

FX RULES (mandatory):
- A report currency is chosen; every operation converts with the rate
  matching ITS OWN DATE:
    1. operations dated TODAY may use today's approved engine rate
       (CentralFXEngine: exchangerate-api.com + 2dec.net for YER); the used
       rate is archived into exchange_rate_history so future lookups are
       real — never invented;
    2. older operations use the documented ExchangeRateHistory rate closest
       to (not after) the operation date;
    3. a missing documented rate is NEVER faked or replaced by 1:1 or
       today's rate — the operation becomes an explicit FX GAP with a clear
       count/notice instead.
- YER_OLD and YER_NEW are fully independent currencies end to end.
- Decimal precision is kept until final display rounding.
- Current balances/debts are valued at CURRENT engine rates (basis
  "current"); historical operations use frozen/history rates (basis
  "historical"). The two are never mixed silently.
"""

import json
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from typing import Any, Dict, List, Optional, Tuple
from uuid import UUID

from sqlalchemy import func, literal_column, select, case, and_
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.business_entities import (
    Customer,
    InventoryMovement,
    Product,
    ProductCategory,
    Supplier,
    WarehouseSetting,
)
from app.domain.entities.finance_entities import (
    BankAccount,
    BankTransaction,
    ExchangeRateHistory,
    Expense,
)
from app.domain.entities.invoice_entities import (
    Invoice,
    InvoiceItem,
    Payment,
)
from app.domain.entities.purchase_entities import PurchaseReturn
from app.domain.entities.reconciliation_entities import Reconciliation
from app.domain.entities.sale_entities import (
    Branch,
    CustomerReceivable,
    InventoryLot,
    InvoiceReturn,
    InvoiceReturnItem,
    ProductUnit,
    SupplierPayable,
)

ZERO = Decimal("0")
EPS = Decimal("0.000001")
VALID_STATUSES = ("confirmed", "paid", "partially_paid")
UTC = timezone.utc


def _f(v) -> float:
    if v is None:
        return 0.0
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(str(v))
    except Exception:
        return 0.0


def _d(v) -> Decimal:
    from .report_fx import decimal_value
    return decimal_value(v)


def _num(v) -> float:
    r = _d(v).quantize(Decimal('0.01'), rounding=ROUND_HALF_UP)
    return int(r) if r == r.to_integral_value() else float(r)


def _bounds(since: Optional[date], until: Optional[date]) -> Tuple[datetime, datetime]:
    now = datetime.now(UTC)
    start = datetime.combine(since, time.min, tzinfo=UTC) if since \
        else (now - timedelta(days=30))
    end = datetime.combine(until, time.max, tzinfo=UTC) if until else now
    return start, end


def _prev_window(start: datetime, end: datetime) -> Tuple[datetime, datetime]:
    span = end - start
    return start - span, start


def _at_date(d: date) -> datetime:
    return datetime.combine(d, time.min, tzinfo=UTC)


# ══════════════════════════════════════════════════════════════
#  FX resolver — documented historical rates + today engine rates
# ══════════════════════════════════════════════════════════════


from .report_fx import FxResolver


async def _convert_rows(
    fx: FxResolver,
    rows: List[Tuple[Decimal, str, datetime]],
    report_cur: str,
) -> Tuple[Decimal, Dict[str, int]]:
    """Convert (amount, currency, at) rows → total in report currency +
    explicit FX gaps (never faked)."""
    total = ZERO
    gaps: Dict[str, int] = {}
    for amount, cur, at in rows:
        if (cur or "SAR").upper() == report_cur:
            total += amount
            continue
        out = await fx.convert(amount, cur, report_cur, at)
        if out is None:
            gaps[cur] = gaps.get(cur, 0) + 1
        else:
            total += out
    return total, gaps


async def _convert_series(
    fx: FxResolver,
    buckets: List[Tuple[Decimal, str, datetime]],
    report_cur: str,
) -> Tuple[Decimal, Dict[str, int]]:
    return await _convert_rows(fx, buckets, report_cur)


def _gap_note(gaps: Dict[str, int]) -> List[Dict]:
    return [{"currency": c, "count": n} for c, n in sorted(gaps.items())]


def _merge_gaps(*gap_dicts: Dict[str, int]) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for g in gap_dicts:
        for c, n in g.items():
            out[c] = out.get(c, 0) + n
    return out


def _per_ccy(d: Dict[str, Decimal]) -> List[Dict]:
    return [{"currency": c, "total": _num(v)} for c, v in sorted(d.items())]


def _money(v: Decimal, gaps: Dict[str, int]) -> Dict[str, Any]:
    return {"total": _num(v), "gaps": _gap_note(gaps),
            "complete": not gaps}


def _merge_chart(rows):
    totals = {}
    for row in rows:
        totals[row['date']] = totals.get(row['date'], ZERO) + _d(row['value'])
    return [{'date': day, 'value': _num(value)}
            for day, value in sorted(totals.items()) if value != 0]


def _sum_balances(accounts):
    totals = {}
    for account in accounts:
        cur = account['currency']
        totals[cur] = totals.get(cur, ZERO) + _d(account['balance'])
    return totals


# ══════════════════════════════════════════════════════════════
#  Shared aggregations (SQL group-bys — no N+1)
# ══════════════════════════════════════════════════════════════


def _invoice_conditions(
    org_id: UUID, itype: str, start: datetime, end: datetime,
    branch_id: Optional[UUID],
) -> List[Any]:
    conds = [
        Invoice.organization_id == org_id,
        ~Invoice.is_deleted,
        Invoice.invoice_type == itype,
        Invoice.status.in_(VALID_STATUSES),
        Invoice.created_at >= start,
        Invoice.created_at <= end,
    ]
    if branch_id:
        conds.append(Invoice.branch_id == branch_id)
    return conds


async def _daily_buckets(
    db: AsyncSession, org_id: UUID, itype: str,
    start: datetime, end: datetime, branch_id: Optional[UUID],
) -> List[Tuple[Decimal, str, datetime]]:
    conds = _invoice_conditions(org_id, itype, start, end, branch_id)
    rows = (
        await db.execute(
            select(
                Invoice.created_at.label("day_bucket"),
                Invoice.currency,
                func.sum(Invoice.total),
            ).where(*conds).group_by(
                literal_column("day_bucket"), Invoice.currency)
        )
    ).all()
    return [
        (_d(t), (c or "SAR").upper(),
         d if isinstance(d, datetime) else _at_date(d))
        for d, c, t in rows
    ]


async def _profit_buckets(
    db: AsyncSession, org_id: UUID,
    start: datetime, end: datetime, branch_id: Optional[UUID],
) -> List[Tuple[Decimal, str, datetime]]:
    """Σ frozen FIFO/FEFO item profit grouped by (day, invoice currency)."""
    conds = _invoice_conditions(org_id, "sale", start, end, branch_id)
    rows = (
        await db.execute(
            select(
                Invoice.created_at.label("day_bucket"),
                Invoice.currency,
                func.coalesce(func.sum(InvoiceItem.profit), 0),
            )
            .join(InvoiceItem, InvoiceItem.invoice_id == Invoice.id)
            .where(*conds).group_by(
                literal_column("day_bucket"), Invoice.currency)
        )
    ).all()
    return [
        (_d(t), (c or "SAR").upper(),
         d if isinstance(d, datetime) else _at_date(d))
        for d, c, t in rows
    ]


async def _paid_buckets(
    db: AsyncSession, org_id: UUID, itype: str,
    start: datetime, end: datetime, branch_id: Optional[UUID],
    use_created: bool = True,
) -> Tuple[List[Tuple[Decimal, str, datetime]],
           List[Tuple[Decimal, str, datetime]]]:
    """Per-invoice paid/balance rows (invoice currency) for totals; the
    collection/paysup conversion uses payment_date when set."""
    conds = _invoice_conditions(org_id, itype, start, end, branch_id)
    rows = (
        await db.execute(
            select(Invoice.paid_amount, Invoice.balance, Invoice.currency,
                   Invoice.created_at, Invoice.invoice_date)
            .where(*conds)
        )
    ).all()
    paid_rows, rem_rows = [], []
    for paid, bal, cur, created, idate in rows:
        cur = (cur or "SAR").upper()
        at = created or _at_date(idate)
        paid_rows.append((_d(paid), cur, at))
        rem_rows.append((_d(bal), cur, at))
    return paid_rows, rem_rows


async def _sale_returns(
    db: AsyncSession, org_id: UUID, start: datetime, end: datetime,
) -> Dict[str, Any]:
    ret_rows = (
        await db.execute(
            select(InvoiceReturn, Invoice.currency)
            .join(Invoice, Invoice.id == InvoiceReturn.invoice_id)
            .where(
                InvoiceReturn.organization_id == org_id,
                InvoiceReturn.status == "confirmed",
                InvoiceReturn.created_at >= start,
                InvoiceReturn.created_at <= end,
            )
        )
    ).all()
    refund_rows: List[Tuple[Decimal, str, datetime]] = []
    count = 0
    for ret, cur in ret_rows:
        cur = (cur or "SAR").upper()
        at = ret.created_at or _at_date(ret.return_date)
        refund_rows.append((_d(ret.total), cur, at))
        count += 1
    item_rows = (
        await db.execute(
            select(InvoiceReturnItem, InvoiceReturn, Invoice.currency)
            .join(InvoiceReturn, InvoiceReturn.id == InvoiceReturnItem.return_id)
            .join(Invoice, Invoice.id == InvoiceReturn.invoice_id)
            .where(
                InvoiceReturn.organization_id == org_id,
                InvoiceReturn.status == "confirmed",
                InvoiceReturn.created_at >= start,
                InvoiceReturn.created_at <= end,
                InvoiceReturnItem.invoice_item_id.isnot(None),
            )
        )
    ).all()
    orig_ids = {str(r[0].invoice_item_id) for r in item_rows}
    orig = {}
    if orig_ids:
        o_rows = (
            await db.execute(
                select(InvoiceItem).where(InvoiceItem.id.in_(list(orig_ids))))
        ).scalars().all()
        orig = {str(o.id): o for o in o_rows}
    cost_rows: List[Tuple[Decimal, str, datetime]] = []
    for rit, ret, cur in item_rows:
        src = orig.get(str(rit.invoice_item_id))
        if not src or not src.quantity:
            continue
        restored = _d(src.cost_total or 0) * (
            Decimal(str(rit.quantity)) / Decimal(str(src.quantity)))
        cur = (cur or "SAR").upper()
        cost_rows.append((restored, cur,
                          ret.created_at or _at_date(ret.return_date)))
    return {"count": count, "refund_rows": refund_rows,
            "cost_restored_rows": cost_rows}


async def _purchase_returns(
    db: AsyncSession, org_id: UUID, start: datetime, end: datetime,
) -> Dict[str, Any]:
    rows = (
        await db.execute(
            select(PurchaseReturn, Invoice.currency)
            .join(Invoice, Invoice.id == PurchaseReturn.invoice_id)
            .where(
                PurchaseReturn.organization_id == org_id,
                PurchaseReturn.status == "confirmed",
                PurchaseReturn.created_at >= start,
                PurchaseReturn.created_at <= end,
            )
        )
    ).all()
    refund_rows: List[Tuple[Decimal, str, datetime]] = []
    count = 0
    for ret, cur in rows:
        cur = (cur or "SAR").upper()
        refund_rows.append((_d(ret.total), cur,
                            ret.created_at or _at_date(ret.return_date)))
        count += 1
    return {"count": count, "refund_rows": refund_rows}


async def _expense_buckets(
    db: AsyncSession, org_id: UUID, start: datetime, end: datetime,
    account_id: Optional[UUID] = None,
) -> Dict[str, Any]:
    scope = [Expense.organization_id == org_id, ~Expense.is_deleted,
             Expense.expense_date >= start, Expense.expense_date <= end]
    if account_id is not None:
        # Per-bank scope: only expenses actually paid FROM this account.
        scope.append(Expense.bank_account_id == account_id)
    rows = (
        await db.execute(
            select(
                Expense.expense_date,
                Expense.currency,
                func.sum(Expense.amount),
            ).where(*scope).group_by(Expense.expense_date, Expense.currency)
        )
    ).all()
    day_rows = [
        (_d(t), (c or "SAR").upper(), _at_date(d)) for d, c, t in rows
    ]
    cat_rows = (
        await db.execute(
            select(
                Expense.category, Expense.currency, Expense.expense_date,
                func.sum(Expense.amount),
            ).where(*scope).group_by(
                Expense.category, Expense.currency, Expense.expense_date)
        )
    ).all()
    cat_buckets = [
        (_d(t), (c or "SAR").upper(), _at_date(d), (cat or "").strip()
         or "متنوعة")
        for cat, c, d, t in cat_rows
    ]
    return {"day_rows": day_rows, "cat_buckets": cat_buckets}


async def _bank_flow(
    db: AsyncSession, org_id: UUID, start: datetime, end: datetime,
) -> Dict[str, Any]:
    day_rows = (
        await db.execute(
            select(
                BankTransaction.date.label("day_bucket"),
                BankTransaction.tx_type,
                BankTransaction.currency,
                func.sum(BankTransaction.amount),
            ).where(
                BankTransaction.organization_id == org_id,
                ~BankTransaction.is_deleted,
                BankTransaction.date >= start,
                BankTransaction.date <= end,
            ).group_by(literal_column("day_bucket"), BankTransaction.tx_type,
                       BankTransaction.currency)
        )
    ).all()
    inflow_rows: List[Tuple[Decimal, str, datetime]] = []
    outflow_rows: List[Tuple[Decimal, str, datetime]] = []
    transfer_rows: List[Tuple[Decimal, str, datetime]] = []
    settlement_rows: List[Tuple[Decimal, str, datetime]] = []
    for d, tx_type, cur, total in day_rows:
        cur = (cur or "SAR").upper()
        at = d if isinstance(d, datetime) else _at_date(d)
        amt = _d(total)
        if tx_type == "deposit":
            inflow_rows.append((amt, cur, at))
        elif tx_type == "withdrawal":
            outflow_rows.append((amt, cur, at))
        elif tx_type == "transfer_out":
            # Company-level moved amount: one out leg per transfer (the
            # matching transfer_in lands in the receiving account).
            transfer_rows.append((amt, cur, at))
        elif tx_type in ("reconciliation_increase",
                         "reconciliation_decrease"):
            # Reconciliation settlements are a SEPARATE bucket — never
            # company income/expense (spec).
            settlement_rows.append((amt, cur, at))

    accounts = (
        await db.execute(
            select(BankAccount).where(
                BankAccount.organization_id == org_id,
                ~BankAccount.is_deleted,
                BankAccount.is_active.is_(True),
            ).order_by(BankAccount.bank_name.asc())
        )
    ).scalars().all()
    acc_sums = (
        await db.execute(
            select(
                BankTransaction.bank_account_id,
                BankTransaction.tx_type,
                func.sum(BankTransaction.amount),
                func.count(BankTransaction.id),
            ).where(
                BankTransaction.organization_id == org_id,
                ~BankTransaction.is_deleted,
                BankTransaction.date >= start,
                BankTransaction.date <= end,
            ).group_by(BankTransaction.bank_account_id, BankTransaction.tx_type)
        )
    ).all()
    per_acc: Dict[str, Dict[str, Decimal]] = {}
    for acc_id, tx_type, total, _cnt in acc_sums:
        key = str(acc_id) if acc_id else "_"
        f = per_acc.setdefault(key, {})
        f[tx_type] = f.get(tx_type, ZERO) + _d(total)
    accounts_out = []
    for a in accounts:
        f = per_acc.get(str(a.id), {})
        inflow = f.get("deposit", ZERO)
        outflow = f.get("withdrawal", ZERO)
        transfers = f.get("transfer_in", ZERO) - f.get("transfer_out", ZERO)
        settlements = f.get("reconciliation_increase", ZERO) \
            - f.get("reconciliation_decrease", ZERO)
        accounts_out.append({
            "id": str(a.id),
            "bank_name": a.bank_name,
            "account_name": a.account_name,
            "account_type": a.account_type or "checking",
            "currency": (a.currency or "SAR").upper(),
            "balance": _num(a.balance),
            "inflow": _num(inflow),
            "outflow": _num(outflow),
            "transfers": _num(transfers),
            "settlements": _num(settlements),
            "net_change": _num(inflow - outflow + transfers + settlements),
        })
    return {
        "accounts": accounts_out,
        "inflow_rows": inflow_rows,
        "outflow_rows": outflow_rows,
        "transfer_rows": transfer_rows,
        "settlement_rows": settlement_rows,
    }


async def _receivables(db: AsyncSession, org_id: UUID, branch_ids: list | None = None) -> Dict[str, Any]:
    rows = (
        await db.execute(
            select(
                CustomerReceivable.customer_id,
                Customer.name.label("party_name"),
                Invoice.currency,
                func.sum(CustomerReceivable.amount - CustomerReceivable.paid),
            ).join(Customer, Customer.id == CustomerReceivable.customer_id)
            .join(Invoice, Invoice.id == CustomerReceivable.invoice_id)
            .where(
                CustomerReceivable.organization_id == org_id,
                CustomerReceivable.status.in_(["open", "partial"]),
                Invoice.status.in_(VALID_STATUSES),
                *([Invoice.branch_id.in_(branch_ids)] if branch_ids is not None else []),
            ).group_by(
                CustomerReceivable.customer_id, Customer.name, Invoice.currency
            )
        )
    ).all()
    parties: Dict[str, Dict[str, Any]] = {}
    totals: Dict[str, Decimal] = {}
    val_rows: List[Tuple[Decimal, str, datetime]] = []
    for _pid, name, cur, remaining in rows:
        rem = _d(remaining)
        if rem <= EPS:
            continue
        cur = (cur or "SAR").upper()
        p = parties.setdefault(str(_pid), {"name": name, "debts": {}})
        p["debts"][cur] = p["debts"].get(cur, ZERO) + rem
        totals[cur] = totals.get(cur, ZERO) + rem
        val_rows.append((rem, cur, datetime.now(UTC)))
    return {"parties": parties, "totals": totals, "rows": val_rows}


async def _payables(db: AsyncSession, org_id: UUID, branch_ids: list | None = None) -> Dict[str, Any]:
    rows = (
        await db.execute(
            select(
                SupplierPayable.supplier_id,
                Supplier.name.label("party_name"),
                Invoice.currency,
                func.sum(SupplierPayable.amount - SupplierPayable.paid),
            ).join(Supplier, Supplier.id == SupplierPayable.supplier_id)
            .join(Invoice, Invoice.id == SupplierPayable.invoice_id)
            .where(
                SupplierPayable.organization_id == org_id,
                SupplierPayable.status.in_(["open", "partial"]),
                Invoice.status.in_(VALID_STATUSES),
                *([Invoice.branch_id.in_(branch_ids)] if branch_ids is not None else []),
            ).group_by(
                SupplierPayable.supplier_id, Supplier.name, Invoice.currency
            )
        )
    ).all()
    parties: Dict[str, Dict[str, Any]] = {}
    totals: Dict[str, Decimal] = {}
    val_rows: List[Tuple[Decimal, str, datetime]] = []
    for _pid, name, cur, remaining in rows:
        rem = _d(remaining)
        if rem <= EPS:
            continue
        cur = (cur or "SAR").upper()
        p = parties.setdefault(str(_pid), {"name": name, "debts": {}})
        p["debts"][cur] = p["debts"].get(cur, ZERO) + rem
        totals[cur] = totals.get(cur, ZERO) + rem
        val_rows.append((rem, cur, datetime.now(UTC)))
    return {"parties": parties, "totals": totals, "rows": val_rows}


async def _payment_buckets(
    db: AsyncSession, org_id: UUID, itype: str,
    start: datetime, end: datetime, branch_ids: list | None = None,
) -> List[Tuple[Decimal, str, datetime]]:
    """Payments in the period on the given invoice kind, bucketed by the
    PAYMENT date (the money actually moved then)."""
    original = and_(Payment.original_amount.isnot(None), Payment.payment_currency.isnot(None))
    payment_currency = case((original, Payment.payment_currency), else_=Invoice.currency)
    payment_amount = case((original, Payment.original_amount), else_=Payment.amount)
    rows = (
        await db.execute(
            select(
                func.date_trunc("day", Payment.payment_date).label("day_bucket"),
                payment_currency,
                func.sum(payment_amount),
            ).join(Invoice, Invoice.id == Payment.invoice_id)
            .where(
                Payment.organization_id == org_id,
                Invoice.invoice_type == itype,
                Invoice.status.in_(VALID_STATUSES),
                Payment.payment_date >= start,
                Payment.payment_date <= end,
                *([Invoice.branch_id.in_(branch_ids)] if branch_ids is not None else []),
            ).group_by(
                literal_column("day_bucket"), payment_currency)
        )
    ).all()
    return [
        (_d(t), (c or "SAR").upper(),
         d if isinstance(d, datetime) else _at_date(d))
        for d, c, t in rows
    ]


async def _overdue(db: AsyncSession, org_id: UUID, branch_ids: list | None = None) -> Dict[str, Any]:
    today = datetime.now(UTC).date()
    rows = (
        await db.execute(
            select(Invoice.currency, func.count(), func.sum(Invoice.balance))
            .where(
                Invoice.organization_id == org_id,
                ~Invoice.is_deleted,
                Invoice.invoice_type == "sale",
                Invoice.status.in_(VALID_STATUSES),
                Invoice.due_date.isnot(None),
                Invoice.due_date < today,
                Invoice.balance > 0,
                *([Invoice.branch_id.in_(branch_ids)] if branch_ids is not None else []),
            ).group_by(Invoice.currency)
        )
    ).all()
    totals: Dict[str, Decimal] = {}
    count = 0
    for cur, cnt, bal in rows:
        cur = (cur or "SAR").upper()
        totals[cur] = totals.get(cur, ZERO) + _d(bal)
        count += int(cnt)
    return {"count": count, "totals": totals}


async def _stock_value(db: AsyncSession, org_id: UUID) -> Dict[str, Decimal]:
    rows = (
        await db.execute(
            select(
                InventoryLot.currency,
                func.sum(InventoryLot.remaining_quantity
                         * InventoryLot.unit_cost),
            ).where(
                InventoryLot.organization_id == org_id,
                InventoryLot.remaining_quantity > 0,
            ).group_by(InventoryLot.currency)
        )
    ).all()
    out: Dict[str, Decimal] = {}
    for cur, val in rows:
        cur = (cur or "SAR").upper()
        out[cur] = out.get(cur, ZERO) + _d(val)
    return out


async def _most_moved(
    db: AsyncSession, org_id: UUID, start: datetime, end: datetime,
) -> List[Dict[str, Any]]:
    rows = (
        await db.execute(
            select(
                Product.name,
                Product.unit,
                func.sum(func.abs(InventoryMovement.quantity)),
                func.sum(InventoryMovement.quantity),
            ).join(Product, Product.id == InventoryMovement.product_id)
            .where(
                InventoryMovement.organization_id == org_id,
                InventoryMovement.created_at >= start,
                InventoryMovement.created_at <= end,
            ).group_by(Product.name, Product.unit)
            .order_by(func.sum(func.abs(InventoryMovement.quantity)).desc())
            .limit(8)
        )
    ).all()
    return [
        {"name": n, "unit": u, "moved": _num(mv), "net": _num(net)}
        for n, u, mv, net in rows
    ]


async def _recon_archive(
    db: AsyncSession, org_id: UUID, start: datetime, end: datetime,
    rtype: Optional[str] = None,
) -> List[Dict[str, Any]]:
    conds = [
        Reconciliation.organization_id == org_id,
        Reconciliation.status == "approved",
        Reconciliation.approved_at >= start,
        Reconciliation.approved_at <= end,
    ]
    if rtype:
        conds.append(Reconciliation.rtype == rtype)
    rows = (
        await db.execute(
            select(Reconciliation).where(*conds)
            .order_by(Reconciliation.approved_at.desc())
        )
    ).scalars().all()
    # Resolve account metadata (bank/type) for the settlement lines so the
    # money report can scope them to the SELECTED bank + currency + فئة.
    acc_ids = set()
    for r in rows:
        for s in json.loads(r.settlements_json or "[]"):
            if s.get("applied") and s.get("account_id"):
                acc_ids.add(str(s["account_id"]))
    acc_meta: Dict[str, Dict[str, str]] = {}
    if acc_ids:
        from app.domain.entities.finance_entities import BankAccount as _BA
        for a in (await db.execute(
            select(_BA).where(_BA.id.in_(
                [UUID(x) for x in acc_ids if x]))
        )).scalars().all():
            acc_meta[str(a.id)] = {
                "bank_name": a.bank_name or "",
                "account_type": a.account_type or "checking",
            }
    out = []
    for r in rows:
        settlements = json.loads(r.settlements_json or "[]")
        applied = [s for s in settlements if s.get("applied")]
        if not applied:
            continue
        lines = []
        for s in applied:
            meta = acc_meta.get(str(s.get("account_id") or ""), {})
            lines.append({
                "name": s.get("name"),
                "currency": s.get("currency") or s.get("unit"),
                "before": s.get("before"), "after": s.get("after"),
                "diff": s.get("diff"),
                "account_id": str(s.get("account_id") or "") or None,
                "bank_name": meta.get("bank_name"),
                "account_type": meta.get("account_type"),
            })
        out.append({
            "ref_code": r.ref_code,
            "rtype": r.rtype,
            "approved_at": r.approved_at.isoformat() if r.approved_at else None,
            "settlements": lines,
        })
    return out


def _top_parties(parties: Dict[str, Dict[str, Any]], limit: int = 10):
    out = []
    for p in parties.values():
        out.append({"name": p["name"], "debts": _per_ccy(p["debts"])})
    out.sort(key=lambda r: -sum(
        float(d["total"]) for d in r["debts"]))
    return out[:limit]


# ══════════════════════════════════════════════════════════════
#  Reports
# ══════════════════════════════════════════════════════════════


async def _income_rows(
    db: AsyncSession, org_id: UUID, start: datetime, end: datetime,
) -> List[Tuple[Decimal, str, datetime]]:
    """Real CASH INCOME the merchant typed in «المدخول والمصروفات» — deposits
    only (reconciliation corrections and transfers are NEVER income)."""
    rows = (
        await db.execute(
            select(
                BankTransaction.date.label("day_bucket"),
                BankTransaction.currency,
                func.sum(BankTransaction.amount),
            ).where(
                BankTransaction.organization_id == org_id,
                ~BankTransaction.is_deleted,
                BankTransaction.tx_type == "deposit",
                BankTransaction.date >= start,
                BankTransaction.date <= end,
            ).group_by(literal_column("day_bucket"), BankTransaction.currency)
        )
    ).all()
    return [
        (_d(t), (c or "SAR").upper(),
         d if isinstance(d, datetime) else _at_date(d))
        for d, c, t in rows
    ]


async def _core_kpis(
    db: AsyncSession, org_id: UUID, start: datetime, end: datetime,
    report_cur: str, branch_id: Optional[UUID],
    fx: Optional[FxResolver] = None,
) -> Dict[str, Any]:
    fx = fx or FxResolver(db)
    sold_buckets = await _daily_buckets(db, org_id, "sale", start, end,
                                        branch_id)
    sold, g1 = await _convert_rows(fx, sold_buckets, report_cur)

    profit_buckets = await _profit_buckets(db, org_id, start, end, branch_id)
    rets = await _sale_returns(db, org_id, start, end)
    refund, g2 = await _convert_rows(fx, rets["refund_rows"], report_cur)
    restored, _g = await _convert_rows(fx, rets["cost_restored_rows"],
                                       report_cur)
    gross_profit = ZERO
    gp, g3 = await _convert_rows(fx, profit_buckets, report_cur)
    gross_profit = gp - (refund - restored)

    exp = await _expense_buckets(db, org_id, start, end)
    spent, g4 = await _convert_rows(fx, exp["day_rows"], report_cur)
    income, g5 = await _convert_rows(
        fx, await _income_rows(db, org_id, start, end), report_cur)
    # Net profit = sales profit + the merchant's typed INCOME − expenses.
    net = gross_profit + income - spent
    return {
        "sold": {**_money(sold, g1), "rows": sold_buckets},
        "gross_profit": _money(gross_profit, _merge_gaps(g2, g3)),
        "income": _money(income, g5),
        "spent": _money(spent, g4),
        "exp_cat_buckets": exp["cat_buckets"],
        "net_profit": _num(net),
    }


async def home_report(
    db: AsyncSession, org_id: UUID, start: datetime, end: datetime,
    report_cur: str, branch_id: Optional[UUID] = None,
) -> Dict[str, Any]:
    fx = FxResolver(db)
    cur = await _core_kpis(db, org_id, start, end, report_cur, branch_id, fx)
    p_start, p_end = _prev_window(start, end)
    prev = await _core_kpis(db, org_id, p_start, p_end, report_cur,
                            branch_id, fx)

    debts = await _receivables(db, org_id)
    debt_val, debt_gaps = await _convert_rows(fx, debts["rows"], report_cur)

    sale_count = (
        await db.execute(
            select(func.count()).select_from(Invoice).where(
                *_invoice_conditions(org_id, "sale", start, end, branch_id))
        )
    ).scalar_one()

    chart: List[Dict[str, Any]] = []
    for amount, c, at in cur["sold"]["rows"]:
        val, _ = await _convert_rows(fx, [(amount, c, at)], report_cur)
        chart.append({"date": at.date().isoformat(), "value": val})
    chart = _merge_chart(chart)

    net_profit = _d(cur.get("net_profit") or 0)
    if net_profit == 0:
        net_profit = (_d(cur["gross_profit"]["total"])
                      + _d((cur.get("income") or {}).get("total") or 0)
                      - _d(cur["spent"]["total"]))
    sold_gaps = {g["currency"]: g["count"] for g in cur["sold"]["gaps"]}
    profit_gaps = {g["currency"]: g["count"]
                   for g in cur["gross_profit"]["gaps"]}
    gaps = _merge_gaps(sold_gaps, profit_gaps,
                       {g["currency"]: g["count"]
                        for g in cur["spent"]["gaps"]},
                       {g["currency"]: g["count"]
                        for g in (cur.get("income") or {}).get("gaps", []) or []})
    # REAL currencies of this business (accounts + invoices + expenses) —
    # the reports currency picker lists the app's own currencies, not a
    # hardcoded four.
    cur_rows = (
        await db.execute(
            select(BankAccount.currency).where(
                BankAccount.organization_id == org_id,
                ~BankAccount.is_deleted)
        )
    ).all()
    inv_cur_rows = (
        await db.execute(
            select(Invoice.currency).where(
                Invoice.organization_id == org_id,
                ~Invoice.is_deleted)
        )
    ).all()
    exp_cur_rows = (
        await db.execute(
            select(Expense.currency).where(
                Expense.organization_id == org_id,
                ~Expense.is_deleted)
        )
    ).all()
    currencies = sorted({
        ((c or "").strip().upper())
        for (c,) in list(cur_rows) + list(inv_cur_rows) + list(exp_cur_rows)
        if (c or "").strip()
    })
    return {
        "report": "home",
        "currency": report_cur,
        "currencies": currencies,
        "fx_basis": {"operations": "historical", "balances": "current"},
        "kpis": {
            "sold": {**_money(_d(cur["sold"]["total"]), sold_gaps),
                     "count": int(sale_count)},
            "profit": _money(net_profit, gaps),
            "income": cur.get("income") or {"total": 0, "gaps": []},
            "spent": cur["spent"],
            "customer_debt": {**_money(debt_val, debt_gaps),
                              "count": len(debts["parties"])},
        },
        "comparison": {
            "sold_delta": _num(_d(cur["sold"]["total"])
                               - _d(prev["sold"]["total"])),
            "spent_delta": _num(_d(cur["spent"]["total"])
                                - _d(prev["spent"]["total"])),
            "prev_sold": prev["sold"]["total"],
            "prev_spent": prev["spent"]["total"],
            "prev_profit": _num(_d(prev.get("net_profit") or 0)
                                if prev.get("net_profit") is not None else
                                (_d(prev["gross_profit"]["total"])
                                 + _d((prev.get("income") or {}).get("total") or 0)
                                 - _d(prev["spent"]["total"]))),
            "profit_delta": _num(net_profit - (
                _d(prev.get("net_profit") or 0)
                if prev.get("net_profit") is not None else
                (_d(prev["gross_profit"]["total"])
                 + _d((prev.get("income") or {}).get("total") or 0)
                 - _d(prev["spent"]["total"])))),
        },
        "chart": chart,
    }


async def sales_purchases_report(
    db: AsyncSession, org_id: UUID, start: datetime, end: datetime,
    report_cur: str, branch_id: Optional[UUID] = None,
) -> Dict[str, Any]:
    fx = FxResolver(db)

    sold_buckets = await _daily_buckets(db, org_id, "sale", start, end,
                                        branch_id)
    sold, g1 = await _convert_rows(fx, sold_buckets, report_cur)
    paid_s, rem_s = await _paid_buckets(db, org_id, "sale", start, end,
                                        branch_id)
    paid_s_v, g2 = await _convert_rows(fx, paid_s, report_cur)
    rem_s_v, _ = await _convert_rows(fx, rem_s, report_cur)
    s_rets = await _sale_returns(db, org_id, start, end)
    ret_s, g3 = await _convert_rows(fx, s_rets["refund_rows"], report_cur)

    bought_buckets = await _daily_buckets(db, org_id, "purchase", start, end,
                                          branch_id)
    bought, g4 = await _convert_rows(fx, bought_buckets, report_cur)
    paid_p, rem_p = await _paid_buckets(db, org_id, "purchase", start, end,
                                        branch_id)
    paid_p_v, g5 = await _convert_rows(fx, paid_p, report_cur)
    rem_p_v, _ = await _convert_rows(fx, rem_p, report_cur)
    p_rets = await _purchase_returns(db, org_id, start, end)
    ret_p, g6 = await _convert_rows(fx, p_rets["refund_rows"], report_cur)

    counts = {}
    for itype, key in (("sale", "sale"), ("purchase", "purchase")):
        conds = _invoice_conditions(org_id, itype, start, end, branch_id)
        counts[key] = (
            await db.execute(
                select(func.count()).select_from(Invoice).where(*conds))
        ).scalar_one()

    # Top products by converted sold value (per line's own invoice currency).
    item_rows = (
        await db.execute(
            select(InvoiceItem.description, InvoiceItem.quantity,
                   InvoiceItem.total, Invoice.currency, Invoice.created_at,
                   Product.image, Product.unit,
                   InvoiceItem.product_id)
            .join(Invoice, Invoice.id == InvoiceItem.invoice_id)
            .outerjoin(Product, Product.id == InvoiceItem.product_id)
            .where(*_invoice_conditions(org_id, "sale", start, end,
                                        branch_id))
            .limit(2000)
        )
    ).all()
    prod_map: Dict[str, Dict[str, Any]] = {}
    for desc, qty, total, cur, at, img, unit, prod_id in item_rows:
        key = f"{desc}"
        p = prod_map.setdefault(
            key, {"name": desc, "qty": 0.0, "rows": [], "image": img,
                  "unit": unit, "product_id": prod_id})
        p["qty"] += _f(qty)
        p["rows"].append((_d(total), (cur or "SAR").upper(),
                          at or datetime.now(UTC)))
    top = []
    for p in prod_map.values():
        rows = p.pop("rows")
        val, _ = await _convert_rows(fx, rows, report_cur)
        top.append({"name": p["name"], "qty": _num(p["qty"]),
                    "total": _num(val), "image": p.get("image"),
                    "unit": p.get("unit"),
                    "product_id": (str(p["product_id"])
                                   if p.get("product_id") else None)})
    top.sort(key=lambda r: -r["total"])
    top = top[:8]

    chart_s, chart_p = [], []
    for amount, c, at in sold_buckets:
        val, _ = await _convert_rows(fx, [(amount, c, at)], report_cur)
        chart_s.append({"date": at.date().isoformat(), "value": val})
    for amount, c, at in bought_buckets:
        val, _ = await _convert_rows(fx, [(amount, c, at)], report_cur)
        chart_p.append({"date": at.date().isoformat(), "value": val})
    chart_s = _merge_chart(chart_s)
    chart_p = _merge_chart(chart_p)

    # Details preview (both kinds, recent first).
    inv_rows = (
        await db.execute(
            select(Invoice)
            .where(
                Invoice.organization_id == org_id,
                ~Invoice.is_deleted,
                Invoice.status.in_(VALID_STATUSES),
                Invoice.created_at >= start,
                Invoice.created_at <= end,
            ).order_by(Invoice.created_at.desc()).limit(40)
        )
    ).scalars().all()
    return {
        "report": "sales_purchases",
        "currency": report_cur,
        "sales": {
            "total": _num(sold), "count": int(counts["sale"]),
            "paid": _num(paid_s_v), "remaining": _num(rem_s_v),
            "returns": {"total": _num(ret_s),
                        "count": s_rets["count"]},
            "chart": chart_s,
            "gaps": _gap_note(_merge_gaps(g1, g2, g3)),
        },
        "purchases": {
            "total": _num(bought), "count": int(counts["purchase"]),
            "paid": _num(paid_p_v), "remaining": _num(rem_p_v),
            "returns": {"total": _num(ret_p),
                        "count": p_rets["count"]},
            "chart": chart_p,
            "gaps": _gap_note(_merge_gaps(g4, g5, g6)),
        },
        "top_products": top,
        "invoices": [
            {"id": str(i.id), "number": i.invoice_number,
             "kind": i.invoice_type,
             "party": (i.customer.name if i.customer_id and i.customer
                       else (i.supplier.name if i.supplier_id and i.supplier
                             else None)),
             "currency": (i.currency or "SAR").upper(),
             "total": _num(i.total), "paid": _num(i.paid_amount),
             "balance": _num(i.balance), "status": i.status,
             "date": (i.created_at or _at_date(i.invoice_date)).isoformat()}
            for i in inv_rows
        ],
    }


async def money_report(
    db: AsyncSession, org_id: UUID, start: datetime, end: datetime,
    report_cur: str, account_id: Optional[str] = None,
) -> Dict[str, Any]:
    fx = FxResolver(db)
    flow = await _bank_flow(db, org_id, start, end)
    inflow, g1 = await _convert_rows(fx, flow["inflow_rows"], report_cur)
    outflow, g2 = await _convert_rows(fx, flow["outflow_rows"], report_cur)
    transfers, _ = await _convert_rows(fx, flow["transfer_rows"], report_cur)
    settled_money, gs = await _convert_rows(fx, flow.get("settlement_rows", []),
                                            report_cur)

    exp = await _expense_buckets(db, org_id, start, end)
    # Scoped view for the SELECTED bank account (categories + settlements).
    # The top KPIs stay company-wide; the sections follow the selection.
    scoped_exp = None
    settlements = await _recon_archive(db, org_id, start, end, "bank")
    if account_id:
        try:
            aid = UUID(str(account_id))
        except Exception:
            aid = None
        if aid is not None:
            scoped_exp = await _expense_buckets(db, org_id, start, end,
                                                account_id=aid)
            settlements = [
                it for it in settlements
                if any((l.get("account_id") or "") == str(aid)
                       for l in it.get("settlements", []))
            ]
    spent, g3 = await _convert_rows(fx, exp["day_rows"], report_cur)
    cat_map: Dict[str, List[Tuple[Decimal, str, datetime]]] = {}
    for amount, c, at, name in exp["cat_buckets"]:
        cat_map.setdefault(name, []).append((amount, c, at))
    cats = []
    for name, rows in cat_map.items():
        val, _ = await _convert_rows(fx, rows, report_cur)
        cats.append({"category": name, "total": _num(val)})
    cats.sort(key=lambda r: -r["total"])
    cats = cats[:6]

    # Scoped expenses for the SELECTED account (same shape as `expenses`).
    scoped_section = None
    if scoped_exp is not None:
        s_spent, _sg = await _convert_rows(fx, scoped_exp["day_rows"],
                                           report_cur)
        s_map: Dict[str, List[Tuple[Decimal, str, datetime]]] = {}
        for amount, c, at, name in scoped_exp["cat_buckets"]:
            s_map.setdefault(name, []).append((amount, c, at))
        s_cats = []
        for name, rows2 in s_map.items():
            val, _ = await _convert_rows(fx, rows2, report_cur)
            s_cats.append({"category": name, "total": _num(val)})
        s_cats.sort(key=lambda r: -r["total"])
        scoped_section = {"total": _num(s_spent), "categories": s_cats[:6]}

    accounts = flow["accounts"]
    bal_rows = [(_d(a["balance"]), a["currency"], datetime.now(UTC))
                for a in accounts]
    bal_total, g4 = await _convert_rows(fx, bal_rows, report_cur)

    return {
        "report": "money",
        "currency": report_cur,
        "inflow": _money(inflow, g1),
        "outflow": _money(outflow, g2),
        "transfers": {"total": _num(transfers),
                      "note": "تحويلات بين حساباتك — ليست مدخولًا أو مصروفًا"},
        "expenses": {**_money(spent, g3), "categories": cats},
        "balances": {
            "total": _num(bal_total), "basis": "current",
            "per_currency": _per_ccy(_sum_balances(accounts)),
            "gaps": _gap_note(g4),
        },
        "accounts": accounts,
        "expense_scoped": scoped_section,
        "settlements": {
            "count": len(settlements), "items": settlements,
            "total": _num(settled_money),
            "gaps": _gap_note(gs),
            "note": "تسويات المطابقة — منفصلة عن المدخول والمصروف",
        },
    }


async def inventory_report_data(
    db: AsyncSession, org_id: UUID, start: datetime, end: datetime,
    report_cur: str, can_view_cost: bool,
) -> Dict[str, Any]:
    fx = FxResolver(db)
    products = (
        await db.execute(
            select(Product).where(
                Product.organization_id == org_id,
                ~Product.is_deleted,
                Product.is_active.is_(True),
                ~Product.is_service,
            )
        )
    ).scalars().all()
    warn_days = (
        (
            await db.execute(
                select(WarehouseSetting.expiry_warn_days).where(
                    WarehouseSetting.organization_id == org_id))
        ).scalar_one_or_none()
    ) or 60
    today = datetime.now(UTC).date()
    low, out, expiring = [], [], []
    for p in products:
        stock = _f(p.stock)
        row = {"id": str(p.id), "name": p.name, "unit": p.unit,
               "stock": _num(stock), "min_stock": _num(_f(p.min_stock))}
        if stock <= 0:
            out.append(row)
        elif p.min_stock and stock <= _f(p.min_stock):
            low.append(row)
        if p.expiry_date:
            days = (p.expiry_date - today).days
            if 0 <= days <= warn_days:
                expiring.append({**row,
                                 "expiry_date": p.expiry_date.isoformat(),
                                 "days": days})
    value_map = await _stock_value(db, org_id)
    val_rows = [(v, c, datetime.now(UTC)) for c, v in value_map.items()]
    val_total, gaps = await _convert_rows(fx, val_rows, report_cur)
    cats = (
        await db.execute(
            select(func.count()).select_from(ProductCategory).where(
                ProductCategory.organization_id == org_id,
                ProductCategory.is_deleted.is_(False))
        )
    ).scalar_one()
    units = (
        await db.execute(
            select(func.count()).select_from(ProductUnit).where(
                ProductUnit.organization_id == org_id,
                ProductUnit.is_active.is_(True))
        )
    ).scalar_one()
    moved = await _most_moved(db, org_id, start, end)
    counting = await _recon_archive(db, org_id, start, end, "inventory")
    return {
        "report": "inventory",
        "currency": report_cur,
        "products": len(products),
        "categories": int(cats),
        "units": int(units),
        "stock_value": _num(val_total) if can_view_cost else None,
        "stock_value_per_currency": _per_ccy(value_map) if can_view_cost
        else None,
        "stock_value_basis": "actual_lot_cost",
        "low_stock": low[:30], "low_count": len(low),
        "out_of_stock": out[:30], "out_count": len(out),
        "expiring_soon": sorted(expiring, key=lambda r: r["days"])[:30],
        "expiring_count": len(expiring),
        "warn_days": warn_days,
        "most_moved": moved,
        "counting": {"count": len(counting), "items": counting},
        "gaps": _gap_note(gaps),
    }


async def debts_report_data(
    db: AsyncSession, org_id: UUID, start: datetime, end: datetime,
    report_cur: str, branch_ids: list | None = None,
) -> Dict[str, Any]:
    fx = FxResolver(db)
    rec = await _receivables(db, org_id, branch_ids)
    pay = await _payables(db, org_id, branch_ids)
    cust_total, g1 = await _convert_rows(fx, rec["rows"], report_cur)
    supp_total, g2 = await _convert_rows(fx, pay["rows"], report_cur)

    collected_buckets = await _payment_buckets(db, org_id, "sale", start, end,
                                               branch_ids)
    collected, g3 = await _convert_rows(fx, collected_buckets, report_cur)
    paid_sup_buckets = await _payment_buckets(db, org_id, "purchase", start,
                                              end, branch_ids)
    paid_sup, g4 = await _convert_rows(fx, paid_sup_buckets, report_cur)

    overdue = await _overdue(db, org_id, branch_ids)
    overdue_total, g5 = await _convert_rows(
        fx, [(_d(v), c, datetime.now(UTC))
             for c, v in overdue["totals"].items()], report_cur)

    # Recent debt movements (payments) — newest first, for the «آخر حركات
    # الديون» block. Positive = money IN (customer paid us), negative =
    # money OUT (we paid a supplier). Converted once to the report currency.
    pay_rows = (
        await db.execute(
            select(Payment, Invoice, Customer.name, Supplier.name)
            .join(Invoice, Invoice.id == Payment.invoice_id)
            .outerjoin(Customer, Customer.id == Invoice.customer_id)
            .outerjoin(Supplier, Supplier.id == Invoice.supplier_id)
            .where(
                Payment.organization_id == org_id,
                Invoice.organization_id == org_id,
                ~Invoice.is_deleted,
                Invoice.status.in_(VALID_STATUSES),
                *([Invoice.branch_id.in_(branch_ids)] if branch_ids is not None else []),
            )
            .order_by(Payment.payment_date.desc(),
                      Payment.created_at.desc() if hasattr(Payment, "created_at")
                      else Payment.payment_date.desc())
            .limit(8)
        )
    ).all()
    movements = []
    for pmt, inv, cname, sname in pay_rows:
        is_sale = inv.invoice_type == "sale"
        original = pmt.original_amount is not None and pmt.payment_currency
        val, _ = await _convert_rows(
            fx, [(_d(pmt.original_amount if original else pmt.amount),
                   (pmt.payment_currency if original else inv.currency or "SAR").upper(),
                  datetime.combine(pmt.payment_date, time.min, tzinfo=UTC))],
            report_cur)
        movements.append({
            "party": (cname if is_sale else sname) or "—",
            "kind": "customer" if is_sale else "supplier",
            "date": pmt.payment_date.isoformat(),
            "amount": _num(val if is_sale else -val),
        })
    return {
        "report": "debts",
        "currency": report_cur,
        "customers": {"total": _num(cust_total),
                      "count": len(rec["parties"]),
                      "top": _top_parties(rec["parties"]),
                      # RAW per-currency totals (no conversion) so the debts
                      # section shows each currency exactly as stored.
                      "per_currency": _per_ccy(rec["totals"]),
                      "gaps": _gap_note(g1)},
        "suppliers": {"total": _num(supp_total),
                      "count": len(pay["parties"]),
                      "top": _top_parties(pay["parties"]),
                      "per_currency": _per_ccy(pay["totals"]),
                      "gaps": _gap_note(g2)},
        "collected": _money(collected, g3),
        "paid_to_suppliers": _money(paid_sup, g4),
        "overdue": {"count": overdue["count"],
                    "total": _num(overdue_total),
                    "gaps": _gap_note(g5)},
        "recent_movements": movements,
    }


async def overview_report(
    db: AsyncSession, org_id: UUID, start: datetime, end: datetime,
    report_cur: str, branch_id: Optional[UUID] = None,
) -> Dict[str, Any]:
    fx = FxResolver(db)
    home = await home_report(db, org_id, start, end, report_cur, branch_id)
    money = await money_report(db, org_id, start, end, report_cur)
    inv = await inventory_report_data(db, org_id, start, end, report_cur,
                                      can_view_cost=True)
    debts = await debts_report_data(db, org_id, start, end, report_cur)

    bought_buckets = await _daily_buckets(db, org_id, "purchase", start, end,
                                          branch_id)
    bought, _g = await _convert_rows(fx, bought_buckets, report_cur)
    return {
        "report": "overview",
        "currency": report_cur,
        "sales": home["kpis"]["sold"],
        "income": home["kpis"].get("income") or {"total": 0, "gaps": []},
        "purchases": {"total": _num(bought)},
        "profit": home["kpis"]["profit"],
        "expenses": home["kpis"]["spent"],
        "customer_debt": {"total": debts["customers"]["total"],
                          "count": debts["customers"]["count"]},
        "supplier_debt": {"total": debts["suppliers"]["total"],
                          "count": debts["suppliers"]["count"]},
        "inventory": {"stock_value": inv["stock_value"],
                      "products": inv["products"],
                      "low_count": inv["low_count"],
                      "out_count": inv["out_count"]},
        "comparison": home["comparison"],
        "chart": home["chart"],
    }
