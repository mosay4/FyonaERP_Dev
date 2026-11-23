"""Unified Business transactions timeline.

NOT new data and never a duplicate: a read-only UNION over the movements
that ALREADY exist in the system (sale/purchase invoices, sale/purchase
returns, incoming/outgoing payments, expenses, bank transactions).
Every row keeps its real source id/type so the app can open the original
document (عرض الفاتورة). Business isolation by organization_id.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.auth_entities import User
from app.domain.entities.business_entities import Customer, Supplier
from app.domain.entities.finance_entities import (
    BankAccount,
    BankTransaction,
    Expense,
    FinancialPayment,
)
from app.domain.entities.invoice_entities import Invoice
from app.domain.entities.purchase_entities import PurchaseReturn
from app.domain.entities.sale_entities import InvoiceReturn

# Safety cap per source query — the merge sorts and paginates in memory.
_SOURCE_CAP = 2000

_KIND_GROUPS = {
    "sale": {"sale"},
    "purchase": {"purchase"},
    "sale_return": {"sale_return"},
    "purchase_return": {"purchase_return"},
    "return": {"sale_return", "purchase_return"},
    "collection": {"collection"},
    "supplier_payment": {"supplier_payment"},
    "payment": {"collection", "supplier_payment"},
    "income": {"income", "collection"},
    "expense": {"expense", "bank_withdrawal"},
    "transfer": {"transfer"},
    "reconciliation": {"reconciliation"},
    "opening": {"opening"},
    "bank_deposit": {"income"},
    "bank_withdrawal": {"bank_withdrawal"},
    # The المصروف/المدخول page: everything money-in / money-out.
    "inout": {"income", "collection", "expense", "bank_withdrawal"},
}


def _period_start(period: str | None) -> datetime | None:
    now = datetime.now(timezone.utc)
    if period == "today":
        return now.replace(hour=0, minute=0, second=0, microsecond=0)
    if period == "week":
        return now - timedelta(days=7)
    if period == "month":
        return now - timedelta(days=30)
    return None


def _parse_day(value: str | None, end: bool = False) -> datetime | None:
    """ISO date (YYYY-MM-DD) or datetime → aware datetime; [end] snaps to
    the end of that day so 'إلى تاريخ' includes the whole day."""
    if not value:
        return None
    try:
        raw = value.strip()
        if len(raw) == 10:
            d = datetime.fromisoformat(raw)
            d = d.replace(tzinfo=timezone.utc)
        else:
            d = datetime.fromisoformat(raw)
            if d.tzinfo is None:
                d = d.replace(tzinfo=timezone.utc)
        if end and len(raw) == 10:
            d = d + timedelta(days=1) - timedelta(microseconds=1)
        return d
    except Exception:
        return None


def _f(v) -> float:
    return float(v or 0)


def _iso(v) -> str | None:
    return v.isoformat() if v is not None else None


def _money(amount: Decimal | float | None, currency: str | None) -> dict:
    return {"amount": _f(amount), "currency": (currency or "").upper() or None}


def _row(
    *,
    source_type: str,
    source_id,
    kind: str,
    direction: str,
    amount,  # Numeric column instance at runtime → converted below
    currency,  # str column instance → converted below
    ts,  # datetime/date column instance → converted below
    account=None,
    party=None,
    reference=None,
    notes=None,
    status=None,
    invoice_id=None,
    by_id=None,
    branch_id=None,
) -> dict:
    return {
        "id": str(source_id),
        "source_type": source_type,
        "source_id": str(source_id),
        "kind": kind,
        "direction": direction,  # in | out | neutral
        **_money(amount, currency),
        "date": _iso(ts),
        "account": account or None,
        "party": party or None,
        "reference": reference or None,
        "notes": notes or None,
        "status": status,
        "invoice_id": str(invoice_id) if invoice_id else None,
        # Resolved later to the executor's display name (the org manager is
        # labelled «المدير» by the app).
        "by_id": str(by_id) if by_id else None,
        "branch_id": str(branch_id) if branch_id else None,
    }


async def _enrich_executors(db: AsyncSession, org: UUID, rows: list) -> None:
    """Resolve each row's executor: its display name + whether that user is
    the org manager (the first account created — labelled «المدير» in-app).
    Rows without an executor keep nulls (the app hides the field)."""
    ids = set()
    for r in rows:
        raw = r.get("by_id")
        if raw:
            try:
                ids.add(UUID(raw))
            except Exception:
                pass

    names: dict = {}
    employee_names: dict = {}
    if ids:
        res = await db.execute(
            select(User.id, User.full_name).where(User.id.in_(ids))
        )
        names = {row[0]: row[1] for row in res.all()}
        try:
            from ..entities.employee_workspace_entities import EmployeeWorkspace
            from ..entities.hr_entities import Employee
            emp_rows = (await db.execute(
                select(EmployeeWorkspace.linked_user_id, Employee.full_name)
                .join(Employee, Employee.id == EmployeeWorkspace.employee_id)
                .where(EmployeeWorkspace.organization_id == org,
                       EmployeeWorkspace.linked_user_id.in_(ids))
            )).all()
            employee_names = {row[0]: row[1] for row in emp_rows}
        except Exception:
            employee_names = {}

    # The manager = the earliest-created user of the organization (the one
    # who created the account first).
    mgr = (await db.execute(
        select(User.id, User.full_name)
        .where(User.organization_id == org)
        .order_by(User.created_at.asc())
        .limit(1)
    )).first()
    mgr_id = mgr[0] if mgr else None

    from ..entities.merchant_entities import SharedAuditLog
    operation_ids = {str(r.get('source_id')) for r in rows} | {str(r.get('invoice_id')) for r in rows}
    sara_ids = set((await db.execute(select(SharedAuditLog.entity_id).where(
        SharedAuditLog.organization_id == org,
        SharedAuditLog.entity_type == 'sara_operation',
        SharedAuditLog.action == 'sara_executed',
        SharedAuditLog.entity_id.in_(operation_ids),
    ))).scalars().all()) if operation_ids else set()

    for r in rows:
        raw = r.pop("by_id", None)
        uid = UUID(raw) if raw else None
        r["by_name"] = names.get(uid) if uid else None
        r["by_employee_name"] = employee_names.get(uid) if uid else None
        try:
            r["by_is_manager"] = bool(mgr_id and raw and UUID(raw) == mgr_id)
        except Exception:
            r["by_is_manager"] = False
        if str(r.get('source_id')) in sara_ids or str(r.get('invoice_id')) in sara_ids:
            r['by_name'] = 'سارة'
            r['by_is_manager'] = False
            r['by_sara'] = True


async def list_transactions(
    db: AsyncSession,
    org_id: UUID,
    page: int = 1,
    per_page: int = 50,
    kind: str | None = None,
    period: str | None = None,
    search: str | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
    include_doc_legs: bool = False,
    branch_ids: list | None = None,
    allowed_kinds: set | None = None,
) -> dict:
    org = UUID(str(org_id))
    # Explicit custom range wins over the named period.
    since = _parse_day(date_from) or _period_start(period)
    until = _parse_day(date_to, end=True)
    rows: list[dict] = []

    # ── 1) Sale / purchase invoices (the real documents) ──
    q = (
        select(Invoice)
        .where(
            Invoice.organization_id == org,
            ~Invoice.is_deleted,
            Invoice.invoice_type.in_(["sale", "purchase"]),
            Invoice.status.notin_(["draft", "cancelled"]),
        )
        .order_by(Invoice.created_at.desc())
        .limit(_SOURCE_CAP)
    )
    if since is not None:
        q = q.where(Invoice.created_at >= since)
    if until is not None:
        q = q.where(Invoice.created_at <= until)
    if branch_ids is not None:
        q = q.where(Invoice.branch_id.in_(branch_ids))
    for inv in (await db.execute(q)).scalars().all():
        is_sale = inv.invoice_type == "sale"
        party = None
        if is_sale and inv.customer is not None:
            party = inv.customer.name
        elif (not is_sale) and inv.supplier is not None:
            party = inv.supplier.name
        rows.append(
            _row(
                source_type="invoice",
                source_id=inv.id,
                kind="sale" if is_sale else "purchase",
                direction="in" if is_sale else "out",
                amount=inv.total,
                currency=inv.currency,
                ts=inv.created_at or inv.invoice_date,
                party=party,
                reference=inv.invoice_number,
                notes=inv.notes,
                status=inv.status,
                by_id=inv.created_by,
                branch_id=inv.branch_id,
            )
        )

    # ── 2) Sale returns (confirmed) — money goes back OUT ──
    q = (
        select(InvoiceReturn)
        .where(
            InvoiceReturn.organization_id == org,
            InvoiceReturn.status == "confirmed",
        )
        .order_by(InvoiceReturn.created_at.desc())
        .limit(_SOURCE_CAP)
    )
    if since is not None:
        q = q.where(InvoiceReturn.created_at >= since)
    if until is not None:
        q = q.where(InvoiceReturn.created_at <= until)
    if branch_ids is not None:
        q = q.where(InvoiceReturn.invoice_id.in_(
            select(Invoice.id).where(Invoice.branch_id.in_(branch_ids))))
    rets = (await db.execute(q)).scalars().all()
    parent_ids = {r.invoice_id for r in rets if r.invoice_id}
    parents: dict = {}
    if parent_ids:
        res = await db.execute(select(Invoice).where(Invoice.id.in_(parent_ids)))
        parents = {i.id: i for i in res.scalars().all()}
    for r in rets:
        parent = parents.get(r.invoice_id)
        rows.append(
            _row(
                source_type="sale_return",
                source_id=r.id,
                kind="sale_return",
                direction="out",
                amount=r.total,
                currency=parent.currency if parent else None,
                ts=r.created_at or r.return_date,
                party=(parent.customer.name if parent and parent.customer else None),
                reference=r.return_number,
                notes=r.reason,
                status=r.status,
                invoice_id=r.invoice_id,
                by_id=r.created_by,
                branch_id=(parent.branch_id if parent else None),
            )
        )

    # ── 3) Purchase returns (confirmed) — money comes back IN ──
    q = (
        select(PurchaseReturn)
        .where(
            PurchaseReturn.organization_id == org,
            PurchaseReturn.status == "confirmed",
        )
        .order_by(PurchaseReturn.created_at.desc())
        .limit(_SOURCE_CAP)
    )
    if since is not None:
        q = q.where(PurchaseReturn.created_at >= since)
    if until is not None:
        q = q.where(PurchaseReturn.created_at <= until)
    if branch_ids is not None:
        q = q.where(PurchaseReturn.invoice_id.in_(
            select(Invoice.id).where(Invoice.branch_id.in_(branch_ids))))
    pret = (await db.execute(q)).scalars().all()
    sup_ids = {p.supplier_id for p in pret if p.supplier_id}
    sups: dict = {}
    if sup_ids:
        res = await db.execute(select(Supplier).where(Supplier.id.in_(sup_ids)))
        sups = {s.id: s for s in res.scalars().all()}
    # Resolve each purchase return's REAL currency from its linked invoice.
    pr_parent_ids = {p.invoice_id for p in pret if p.invoice_id}
    pr_parents: dict = {}
    if pr_parent_ids:
        res = await db.execute(select(Invoice).where(Invoice.id.in_(pr_parent_ids)))
        pr_parents = {i.id: i for i in res.scalars().all()}
    for p in pret:
        parent = pr_parents.get(p.invoice_id)
        rows.append(
            _row(
                source_type="purchase_return",
                source_id=p.id,
                kind="purchase_return",
                direction="in",
                amount=p.total,
                currency=parent.currency if parent else None,
                ts=p.created_at or p.return_date,
                party=(sups[p.supplier_id].name if p.supplier_id in sups else None),
                reference=p.return_number,
                notes=p.notes,
                status=p.status,
                by_id=p.created_by,
                branch_id=(parent.branch_id if parent else None),
            )
        )

    # ── 4) Payments: incoming = customer collection, outgoing = supplier pay ──
    q = (
        select(FinancialPayment)
        .where(
            FinancialPayment.organization_id == org,
            ~FinancialPayment.is_deleted,
            *([FinancialPayment.branch_id.in_(branch_ids)] if branch_ids is not None else []),
        )
        .order_by(FinancialPayment.created_at.desc())
        .limit(_SOURCE_CAP)
    )
    if since is not None:
        q = q.where(FinancialPayment.created_at >= since)
    if until is not None:
        q = q.where(FinancialPayment.created_at <= until)
    for pay in (await db.execute(q)).scalars().all():
        incoming = (pay.payment_type or "incoming") == "incoming"
        rows.append(
            _row(
                source_type="payment",
                source_id=pay.id,
                kind="collection" if incoming else "supplier_payment",
                direction="in" if incoming else "out",
                amount=pay.amount,
                currency=pay.currency,
                ts=pay.payment_date or pay.created_at,
                reference=pay.payment_no,
                notes=pay.notes,
                branch_id=pay.branch_id,
            )
        )

    # ── 5) Expenses ──
    q = (
        select(Expense)
        .where(Expense.organization_id == org, ~Expense.is_deleted,
               *([Expense.branch_id.in_(branch_ids)] if branch_ids is not None else []))
        .order_by(Expense.created_at.desc())
        .limit(_SOURCE_CAP)
    )
    if since is not None:
        q = q.where(Expense.created_at >= since)
    if until is not None:
        q = q.where(Expense.created_at <= until)
    for e in (await db.execute(q)).scalars().all():
        rows.append(
            _row(
                source_type="expense",
                source_id=e.id,
                kind="expense",
                direction="out",
                amount=e.amount,
                currency=e.currency,
                ts=e.expense_date or e.created_at,
                party=e.category or None,
                reference=e.expense_no,
                notes=e.description,
                branch_id=e.branch_id,
            )
        )

    # ── 6) Bank movements (income / withdrawal / transfers) ──
    q = (
        select(BankTransaction)
        .where(BankTransaction.organization_id == org)
        .order_by(BankTransaction.date.desc())
        .limit(_SOURCE_CAP)
    )
    if since is not None:
        q = q.where(BankTransaction.date >= since)
    if until is not None:
        q = q.where(BankTransaction.date <= until)
    if branch_ids is not None:
        q = q.where(BankTransaction.bank_account_id.in_(
            select(BankAccount.id).where(
                BankAccount.organization_id == org,
                BankAccount.branch_id.in_(branch_ids),
            )))
    bts = (await db.execute(q)).scalars().all()
    acc_ids = {b.bank_account_id for b in bts if b.bank_account_id}
    accs: dict = {}
    if acc_ids:
        res = await db.execute(select(BankAccount).where(BankAccount.id.in_(acc_ids)))
        accs = {a.id: a for a in res.scalars().all()}
    _bank_kind = {
        "deposit": "income",
        "withdrawal": "bank_withdrawal",
        "transfer_in": "transfer",
        "transfer_out": "transfer",
        "transfer_reversal_in": "transfer_reversal",
        "transfer_reversal_out": "transfer_reversal",
        # Reconciliation settlements: a documented balance adjustment — shown
        # in المعاملات under its own kind, deliberately OUTSIDE the
        # income/expense groups so it is never double-counted.
        "reconciliation_increase": "reconciliation",
        "reconciliation_decrease": "reconciliation",
        # The documented opening balance: shown in المعاملات under its own
        # kind — excluded from income/expense groups (never operation money).
        "opening_balance": "opening",
    }
    _bank_dir = {"deposit": "in", "withdrawal": "out",
                 "transfer_in": "in", "transfer_out": "out",
                 "transfer_reversal_in": "in",
                 "transfer_reversal_out": "out",
                 "reconciliation_increase": "in",
                 "reconciliation_decrease": "out",
                 "opening_balance": "in"}
    for b in bts:
        rows.append(
            _row(
                source_type="bank_tx",
                source_id=b.id,
                kind=_bank_kind.get(b.tx_type or "", "bank_withdrawal"),
                direction=_bank_dir.get(b.tx_type or "", "out"),
                amount=b.amount,
                currency=b.currency,
                ts=b.date,
                account=(accs[b.bank_account_id].bank_name
                         if b.bank_account_id in accs else None),
                # Keep the real reference so the money leg of an invoice/
                # return can be de-duplicated against its document row.
                reference=b.reference,
                notes=b.description,
                branch_id=(accs[b.bank_account_id].branch_id
                           if b.bank_account_id in accs else None),
            )
        )

    # ── De-duplicate money legs: the sale/purchase/return flows write the
    # bank movement with the SAME reference as the document (e.g.
    # "تحصيل فاتورة INV-…" ↔ reference=INV-…). That bank row is the money
    # side of the document row — show ONE operation, not two.
    doc_refs = {
        r["reference"]
        for r in rows
        if r["source_type"] in ("invoice", "sale_return", "purchase_return")
        and r.get("reference")
    }
    if doc_refs and not include_doc_legs:
        rows = [
            r for r in rows
            if not (r["source_type"] == "bank_tx" and r.get("reference")
                    and r["reference"] in doc_refs)
        ]

    # ── Executor names (manager → «المدير») ──
    await _enrich_executors(db, org, rows)

    # ── Filters (in-memory over the merged timeline) ──
    if allowed_kinds is not None:
        rows = [r for r in rows if r['kind'] in allowed_kinds]
    if kind:
        allowed = _KIND_GROUPS.get(kind, set())
        rows = [r for r in rows if r["kind"] in allowed]
    if search:
        term = search.strip().lower()
        if term:
            def _hit(r: dict) -> bool:
                hay = " ".join(
                    str(r.get(k) or "")
                    for k in ("reference", "party", "notes", "account",
                              "status", "amount", "currency")
                ).lower()
                return term in hay
            rows = [r for r in rows if _hit(r)]

    rows.sort(key=lambda r: r["date"] or "", reverse=True)

    total = len(rows)
    page = max(1, page)
    per_page = max(1, min(per_page, 100))
    start = (page - 1) * per_page
    if rows:
        from app.domain.entities.sale_entities import Branch
        branch_map = {str(k): v for k, v in (await db.execute(
            select(Branch.id, Branch.name).where(
                Branch.organization_id == org))).all()}
        for r in rows:
            bid = r.get("branch_id")
            r["branch_name"] = branch_map.get(bid) if bid else None
    return {
        "items": rows[start:start + per_page],
        "total": total,
        "page": page,
        "per_page": per_page,
    }


async def get_transaction(
    db: AsyncSession, org_id: UUID, source_type: str, source_id
) -> dict | None:
    row = await _get_transaction_row(db, org_id, source_type, source_id)
    if row is None:
        return None
    await _enrich_executors(db, UUID(str(org_id)), [row])
    return row


async def _get_transaction_row(
    db: AsyncSession, org_id: UUID, source_type: str, source_id
) -> dict | None:
    """One normalized row by its REAL source (un-enriched)."""
    org = UUID(str(org_id))
    sid = UUID(str(source_id))

    if source_type == "invoice":
        inv = (await db.execute(
            select(Invoice).where(Invoice.id == sid,
                                  Invoice.organization_id == org)
        )).scalar_one_or_none()
        if inv is None or inv.is_deleted or inv.invoice_type not in ("sale", "purchase"):
            return None
        is_sale = inv.invoice_type == "sale"
        party = (inv.customer.name if is_sale and inv.customer
                 else (inv.supplier.name if inv.supplier else None))
        return _row(
            source_type="invoice", source_id=inv.id,
            kind="sale" if is_sale else "purchase",
            direction="in" if is_sale else "out",
            amount=inv.total, currency=inv.currency,
            ts=inv.created_at or inv.invoice_date,
            party=party, reference=inv.invoice_number,
            notes=inv.notes, status=inv.status, by_id=inv.created_by,
            invoice_id=inv.id)

    if source_type == "sale_return":
        r = (await db.execute(
            select(InvoiceReturn).where(InvoiceReturn.id == sid,
                                        InvoiceReturn.organization_id == org)
        )).scalar_one_or_none()
        if r is None:
            return None
        parent = None
        if r.invoice_id:
            parent = (await db.execute(
                select(Invoice).where(Invoice.id == r.invoice_id)
            )).scalar_one_or_none()
        return _row(
            source_type="sale_return", source_id=r.id, kind="sale_return",
            direction="out", amount=r.total,
            currency=parent.currency if parent else None,
            ts=r.created_at or r.return_date,
            party=(parent.customer.name if parent and parent.customer else None),
            reference=r.return_number, notes=r.reason, status=r.status,
            invoice_id=r.invoice_id, by_id=r.created_by)

    if source_type == "purchase_return":
        p = (await db.execute(
            select(PurchaseReturn).where(PurchaseReturn.id == sid,
                                         PurchaseReturn.organization_id == org)
        )).scalar_one_or_none()
        if p is None:
            return None
        sup = None
        if p.supplier_id:
            sup = (await db.execute(
                select(Supplier).where(Supplier.id == p.supplier_id)
            )).scalar_one_or_none()
        # The purchase-return module stores no currency of its own: take the
        # REAL currency from the linked purchase invoice so the details view
        # never falls back to a default (was showing SAR for every return).
        parent = None
        if p.invoice_id:
            parent = (await db.execute(
                select(Invoice).where(Invoice.id == p.invoice_id)
            )).scalar_one_or_none()
        return _row(
            source_type="purchase_return", source_id=p.id,
            kind="purchase_return", direction="in", amount=p.total,
            currency=parent.currency if parent else None,
            ts=p.created_at or p.return_date,
            party=(sup.name if sup else None),
            reference=p.return_number, notes=p.notes, status=p.status,
            invoice_id=p.invoice_id, by_id=p.created_by)

    if source_type == "payment":
        pay = (await db.execute(
            select(FinancialPayment).where(FinancialPayment.id == sid,
                                           FinancialPayment.organization_id == org)
        )).scalar_one_or_none()
        if pay is None or pay.is_deleted:
            return None
        incoming = (pay.payment_type or "incoming") == "incoming"
        return _row(
            source_type="payment", source_id=pay.id,
            kind="collection" if incoming else "supplier_payment",
            direction="in" if incoming else "out",
            amount=pay.amount, currency=pay.currency,
            ts=pay.payment_date or pay.created_at,
            reference=pay.payment_no, notes=pay.notes)

    if source_type == "expense":
        e = (await db.execute(
            select(Expense).where(Expense.id == sid,
                                  Expense.organization_id == org)
        )).scalar_one_or_none()
        if e is None or e.is_deleted:
            return None
        return _row(
            source_type="expense", source_id=e.id, kind="expense",
            direction="out", amount=e.amount, currency=e.currency,
            ts=e.expense_date or e.created_at, party=e.category or None,
            reference=e.expense_no, notes=e.description)

    if source_type == "bank_tx":
        b = (await db.execute(
            select(BankTransaction).where(BankTransaction.id == sid,
                                          BankTransaction.organization_id == org)
        )).scalar_one_or_none()
        if b is None:
            return None
        acc = None
        if b.bank_account_id:
            acc = (await db.execute(
                select(BankAccount).where(BankAccount.id == b.bank_account_id)
            )).scalar_one_or_none()
        _bank_kind = {"deposit": "income", "withdrawal": "bank_withdrawal",
                      "transfer_in": "transfer", "transfer_out": "transfer",
                      "transfer_reversal_in": "transfer_reversal",
                      "transfer_reversal_out": "transfer_reversal"}
        _bank_dir = {"deposit": "in", "withdrawal": "out",
                     "transfer_in": "in", "transfer_out": "out",
                     "transfer_reversal_in": "in",
                     "transfer_reversal_out": "out"}
        row = _row(
            source_type="bank_tx", source_id=b.id,
            kind=_bank_kind.get(b.tx_type or "", "bank_withdrawal"),
            direction=_bank_dir.get(b.tx_type or "", "out"),
            amount=b.amount, currency=b.currency, ts=b.date,
            account=(acc.bank_name if acc else None),
            reference=None, notes=b.description or b.reference)

        # Money transfer (مصارفة): attach BOTH legs so the details view can show
        # the source account/currency/amount AND the destination account/
        # currency/received amount. The two BankTransaction rows are written in
        # the same request with the SAME date, opposite types.
        if (b.tx_type or "") in ("transfer_in", "transfer_out"):
            sib_type = ("transfer_in" if b.tx_type == "transfer_out"
                        else "transfer_out")
            sib = (await db.execute(
                select(BankTransaction).where(
                    BankTransaction.organization_id == org,
                    BankTransaction.tx_type == sib_type,
                    BankTransaction.date == b.date,
                    BankTransaction.id != b.id,
                    BankTransaction.is_deleted.isnot(True),
                ).order_by(BankTransaction.created_at.asc()).limit(1)
            )).scalar_one_or_none()
            if sib is not None:
                sib_acc = None
                if sib.bank_account_id:
                    sib_acc = (await db.execute(
                        select(BankAccount).where(
                            BankAccount.id == sib.bank_account_id)
                    )).scalar_one_or_none()
                out_leg = b if b.tx_type == "transfer_out" else sib
                in_leg = b if b.tx_type == "transfer_in" else sib
                out_acc = acc if b.tx_type == "transfer_out" else sib_acc
                in_acc = acc if b.tx_type == "transfer_in" else sib_acc
                from_amt = _f(out_leg.amount)
                to_amt = _f(in_leg.amount)
                transfer = {
                    "from_account": out_acc.bank_name if out_acc else None,
                    "from_account_id": (str(out_leg.bank_account_id)
                                        if out_leg.bank_account_id else None),
                    "from_currency": (out_leg.currency or "").upper() or None,
                    "from_amount": from_amt,
                    "to_account": in_acc.bank_name if in_acc else None,
                    "to_account_id": (str(in_leg.bank_account_id)
                                      if in_leg.bank_account_id else None),
                    "to_currency": (in_leg.currency or "").upper() or None,
                    "to_amount": to_amt,
                }
                if (transfer["from_currency"] != transfer["to_currency"]
                        and from_amt):
                    transfer["rate"] = to_amt / from_amt
                row["transfer"] = transfer
        return row

    return None
