"""Destructive branch lifecycle: permanent delete and data reset.

Risk-managed rules:
- The MAIN branch can never be deleted (it is the organization anchor).
- Resetting the main branch is allowed, but only touches legacy rows with
  branch_id NULL when it is the ONLY branch (never steals shared legacy data
  from other branches).
- Every dependent row is deleted in FK-safe order; other branches and all
  organization/staff/settings rows are untouched.
"""

import json
from typing import List
from uuid import UUID

from sqlalchemy import delete, func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.accounting_entities import JournalEntry
from app.domain.entities.branch_entities import (
    BranchInvitation, BranchMember, BranchTransfer,
)
from app.domain.entities.business_entities import (
    Customer, InventoryMovement, Product, Supplier,
)
from app.domain.entities.finance_entities import (
    BankAccount, BankTransaction, Expense, FinancialPayment,
)
from app.domain.entities.invoice_entities import Invoice
from app.domain.entities.notification_entities import AppNotification
from app.domain.entities.reconciliation_entities import Reconciliation
from app.domain.entities.sale_entities import (
    Branch, BranchStock, InventoryLot,
)


async def _other_branch_count(db: AsyncSession, org_id: UUID,
                              branch_id: UUID) -> int:
    return int((await db.execute(select(func.count()).select_from(Branch).where(
        Branch.organization_id == org_id, Branch.id != branch_id,
    ))).scalar_one())


async def _purge(
    db: AsyncSession, org_id: UUID, branch: Branch,
    keep_memberships: bool,
    preserve_banks: bool = False,
) -> None:
    bid = branch.id
    only_main = branch.is_default and await _other_branch_count(
        db, org_id, bid) == 0
    include_legacy = only_main

    def legacy(column):
        return or_(column == bid, column.is_(None)) if include_legacy \
            else column == bid

    # ── Transfers first (their rows reference accounts/products) ──
    transfer_ids = list((await db.execute(select(BranchTransfer.id).where(
        BranchTransfer.organization_id == org_id,
        or_(BranchTransfer.from_branch_id == bid,
            BranchTransfer.to_branch_id == bid),
    ))).scalars().all())
    if transfer_ids:
        for tid in transfer_ids:
            await db.execute(delete(AppNotification).where(
                AppNotification.event_id.like(f"branch_transfer:{tid}%")))
        await db.execute(delete(BranchTransfer).where(
            BranchTransfer.id.in_(transfer_ids)))

    # ── Invoices (child items/returns/receivables/payables cascade) ──
    invoice_ids = list((await db.execute(select(Invoice.id).where(
        Invoice.organization_id == org_id, legacy(Invoice.branch_id),
    ))).scalars().all())
    for iid in invoice_ids:
        await db.execute(delete(AppNotification).where(
            AppNotification.event_id.like(f"debt_created:{iid}%")))
    await db.execute(delete(FinancialPayment).where(
        FinancialPayment.organization_id == org_id,
        FinancialPayment.branch_id == bid,
    ))
    await db.execute(delete(Invoice).where(
        Invoice.organization_id == org_id,
        legacy(Invoice.branch_id),
    ))
    await db.execute(delete(Expense).where(
        Expense.organization_id == org_id,
        Expense.branch_id == bid,
    ))
    await db.execute(delete(JournalEntry).where(
        JournalEntry.organization_id == org_id,
        JournalEntry.branch_id == bid,
    ))
    await db.execute(delete(Reconciliation).where(
        Reconciliation.organization_id == org_id,
        Reconciliation.branch_id == bid,
    ))

    # ── Inventory / banks ──
    await db.execute(delete(InventoryMovement).where(
        InventoryMovement.organization_id == org_id,
        InventoryMovement.branch_id == bid,
    ))
    await db.execute(delete(InventoryLot).where(
        InventoryLot.organization_id == org_id,
        InventoryLot.branch_id == bid,
    ))
    if preserve_banks:
        # Reset keeps the branch's cash/bank accounts and their currencies.
        # Only transactions/balances return to zero; the owner may still
        # delete an account manually later.
        bank_ids = list((await db.execute(select(BankAccount.id).where(
            BankAccount.organization_id == org_id,
            BankAccount.branch_id == bid,
        ))).scalars().all())
        if bank_ids:
            await db.execute(delete(BankTransaction).where(
                BankTransaction.organization_id == org_id,
                BankTransaction.bank_account_id.in_(bank_ids),
            ))
            await db.execute(update(BankAccount).where(
                BankAccount.id.in_(bank_ids)).values(balance=0))
    else:
        await db.execute(delete(BankAccount).where(
            BankAccount.organization_id == org_id,
            BankAccount.branch_id == bid,
        ))

    # ── Products (stock/units/barcodes/prices cascade) ──
    await db.execute(delete(BranchStock).where(
        BranchStock.organization_id == org_id,
        BranchStock.branch_id == bid,
    ))
    await db.execute(delete(Product).where(
        Product.organization_id == org_id,
        legacy(Product.branch_id),
    ))

    # ── Parties ──
    await db.execute(delete(Customer).where(
        Customer.organization_id == org_id,
        legacy(Customer.branch_id),
    ))
    await db.execute(delete(Supplier).where(
        Supplier.organization_id == org_id,
        legacy(Supplier.branch_id),
    ))

    # ── Invitations / memberships ──
    invite_ids = list((await db.execute(select(BranchInvitation.id).where(
        BranchInvitation.organization_id == org_id,
        BranchInvitation.branch_id == bid,
    ))).scalars().all())
    for iid in invite_ids:
        await db.execute(delete(AppNotification).where(
            AppNotification.event_id.like(f"branch_invite:{iid}%")))
        await db.execute(delete(AppNotification).where(
            AppNotification.event_id.like(f"branch_invite_response:{iid}%")))
    await db.execute(delete(BranchInvitation).where(
        BranchInvitation.organization_id == org_id,
        BranchInvitation.branch_id == bid,
    ))
    if not keep_memberships:
        members = (await db.execute(select(BranchMember).where(
            BranchMember.organization_id == org_id))).scalars().all()
        for member in members:
            try:
                ids = [UUID(str(x)) for x in json.loads(
                    member.branch_ids or "[]")]
            except Exception:
                ids = []
            if bid in ids:
                ids = [x for x in ids if x != bid]
                member.branch_ids = json.dumps([str(x) for x in ids])
                if not ids and not member.all_branches:
                    await db.execute(delete(BranchMember).where(
                        BranchMember.id == member.id))


async def reset_branch_data(db: AsyncSession, org_id: UUID,
                            branch: Branch) -> None:
    await _purge(db, org_id, branch, keep_memberships=True,
                 preserve_banks=True)
    await db.flush()


async def delete_branch_permanently(db: AsyncSession, org_id: UUID,
                                    branch: Branch) -> None:
    if branch.is_default:
        raise ValueError("الفرع الرئيسي لا يمكن حذفه نهائيًا")
    await _purge(db, org_id, branch, keep_memberships=False)
    await db.execute(delete(Branch).where(Branch.id == branch.id))
    await db.flush()


async def reset_whole_business(db: AsyncSession, org_id: UUID,
                               org_name: str) -> Branch:
    """Factory-reset all Business data: every branch, its operations and all
    branch staff links. The organization, owner, subscription and settings
    remain, and one fresh MAIN branch is recreated."""
    from app.domain.entities.invoice_entities import OrgInvoiceDesign
    from app.domain.services.branch_service import clean_branch_name

    branches = list((await db.execute(select(Branch).where(
        Branch.organization_id == org_id).order_by(
            Branch.is_default.asc()))).scalars().all())
    for branch in branches:
        await _purge(db, org_id, branch, keep_memberships=False)
        await db.execute(delete(Branch).where(Branch.id == branch.id))
    await db.execute(delete(BranchMember).where(
        BranchMember.organization_id == org_id))
    await db.execute(delete(BranchInvitation).where(
        BranchInvitation.organization_id == org_id))
    await db.execute(delete(OrgInvoiceDesign).where(
        OrgInvoiceDesign.organization_id == org_id))
    name = clean_branch_name(org_name) or "الفرع الرئيسي"
    fresh = Branch(organization_id=org_id, name=name, is_default=True,
                   is_active=True, is_archived=False)
    db.add(fresh)
    await db.flush()
    return fresh
