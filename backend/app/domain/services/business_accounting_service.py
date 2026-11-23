"""Shared original Online/sync GL mutations. Caller owns authorization/transaction.

The original GL owns draft creation and posting only: no FX, fiscal-period,
void or reversal API exists here. Do not infer those from route/help constants.
Posting does not mutate Account.balance or manufacture bank/invoice effects.
"""
from decimal import Decimal

import sqlalchemy as sa

from ..entities.accounting_entities import Account, JournalEntry
from ..entities.auth_entities import User
from ..entities.sale_entities import Branch
from ...infrastructure.repositories.sql_alchemy_m4_repository import (
    SqlAlchemyAccountRepository, SqlAlchemyJournalEntryRepository,
    SqlAlchemyJournalEntryLineRepository,
)
from .accounting_service import AccountingService


class BusinessAccountingService(AccountingService):
    def __init__(self, db):
        super().__init__(SqlAlchemyAccountRepository(db),
                         SqlAlchemyJournalEntryRepository(db),
                         SqlAlchemyJournalEntryLineRepository(db))
        self.db = db

    async def _lock(self, company):
        # Serialize chart/number allocation on PostgreSQL.
        if self.db.bind.dialect.name == 'postgresql':
            await self.db.execute(sa.text('SELECT pg_advisory_xact_lock(hashtextextended(:key,0))'),
                                  {'key': 'business-accounting:' + str(company)})

    async def _branch_actor(self, company, branch, actor):
        if not await self.db.scalar(sa.select(Branch.id).where(
                Branch.id == branch, Branch.organization_id == company,
                Branch.is_active, ~Branch.is_archived)):
            raise ValueError('Invalid accounting branch')
        if not await self.db.scalar(sa.select(User.id).where(User.id == actor, User.status == 'active')):
            raise ValueError('Invalid accounting actor')

    async def _accounts(self, company, lines):
        for line in lines:
            if line.description is not None and len(line.description) > 500:
                raise ValueError('Invalid journal line description')
            if not await self.db.scalar(sa.select(Account.id).where(
                    Account.id == line.account_id, Account.organization_id == company, Account.is_active)):
                raise ValueError('Journal account is unavailable in this company')
            for value in (line.debit, line.credit):
                if (not isinstance(value, Decimal) or not value.is_finite() or value < 0 or value >= Decimal('10000000000') or
                        value != value.quantize(Decimal('.01'))):
                    raise ValueError('Journal amounts require exact nonnegative cents')
        if not lines or sum(l.debit for l in lines) != sum(l.credit for l in lines):
            raise ValueError('Journal entry must be balanced and nonempty')

    async def init_default_chart(self, org_id):
        await self._lock(org_id)
        return await super().init_default_chart(org_id)

    async def create_account(self, org_id, data, *, account_id=None):
        await self._lock(org_id)
        if not data.code.strip() or len(data.code) > 20 or not data.name.strip() or len(data.name) > 200:
            raise ValueError('Invalid account code/name')
        if data.name_ar is not None and len(data.name_ar) > 200:
            raise ValueError('Invalid account Arabic name')
        if data.parent_id is not None and not await self.db.scalar(sa.select(Account.id).where(
                Account.id == data.parent_id, Account.organization_id == org_id)):
            raise ValueError('Parent account is unavailable in this company')
        return await super().create_account(org_id, data, account_id=account_id)

    async def create_journal_entry(self, org_id, uid, data, branch_id=None, *, entry_id=None):
        await self._lock(org_id)
        await self._branch_actor(org_id, branch_id, uid)
        if data.reference_type is not None and len(data.reference_type) > 50:
            raise ValueError('Invalid journal reference type')
        await self._accounts(org_id, data.lines)
        return await super().create_journal_entry(org_id, uid, data, branch_id, entry_id=entry_id)

    async def post_journal_entry(self, eid, org_id, uid, *, branch_id):
        await self._lock(org_id)
        await self._branch_actor(org_id, branch_id, uid)
        row = (await self.db.execute(sa.select(JournalEntry).where(
            JournalEntry.id == eid, JournalEntry.organization_id == org_id,
            sa.or_(JournalEntry.branch_id == branch_id,
                   sa.and_(JournalEntry.branch_id.is_(None), sa.exists(sa.select(Branch.id).where(
                       Branch.id == branch_id, Branch.organization_id == org_id, Branch.is_default)))))
            .with_for_update().execution_options(populate_existing=True))).scalar_one_or_none()
        if row is None:
            raise ValueError('Journal entry is unavailable in this branch')
        await self._accounts(org_id, row.lines)
        return await super().post_journal_entry(eid, org_id, uid)

    async def list_journal_entries(self, org_id, page=1, per_page=20, branch_id=None, branch_ids=None):
        if page < 1 or not 1 <= per_page <= 200:
            raise ValueError('Invalid journal pagination')
        conditions = [JournalEntry.organization_id == org_id]
        selected = branch_ids if branch_ids is not None else ([branch_id] if branch_id is not None else None)
        if selected is not None:
            conditions.append(sa.or_(JournalEntry.branch_id.in_(selected), sa.and_(
                JournalEntry.branch_id.is_(None), sa.exists(sa.select(Branch.id).where(
                    Branch.organization_id == org_id, Branch.id.in_(selected), Branch.is_default)))))
        total = await self.db.scalar(sa.select(sa.func.count()).select_from(JournalEntry).where(*conditions))
        rows = (await self.db.scalars(sa.select(JournalEntry).where(*conditions)
            .order_by(JournalEntry.entry_date.desc(), JournalEntry.id)
            .offset((page - 1) * per_page).limit(per_page))).all()
        return [self._je_resp(row) for row in rows], total
