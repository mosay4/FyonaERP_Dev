from uuid import UUID
from typing import Optional, List, Tuple
from datetime import date, datetime, timezone
from decimal import Decimal
from app.domain.models.accounting_models import (
    AccountCreate,
    AccountResponse,
    JournalEntryCreate,
    JournalEntryResponse,
    JournalEntryLineResponse,
    TrialBalanceResponse,
    TrialBalanceItem,
    ProfitLossResponse,
    ProfitLossItem,
    BalanceSheetResponse,
    BalanceSheetItem,
)
from app.domain.entities.accounting_entities import (
    Account,
    JournalEntry,
    JournalEntryLine,
)
from app.domain.repositories.m4_repository import (
    AccountRepository,
    JournalEntryRepository,
    JournalEntryLineRepository,
)

ZERO = Decimal("0")


class AccountingService:
    DEFAULT_COA = [
        {"code": "1000", "name": "Assets", "name_ar": "الأصول", "type": "asset"},
        {"code": "1100", "name": "Cash", "name_ar": "النقدية", "type": "asset"},
        {
            "code": "1200",
            "name": "Accounts Receivable",
            "name_ar": "حسابات مدينة",
            "type": "asset",
        },
        {"code": "1300", "name": "Inventory", "name_ar": "المخزون", "type": "asset"},
        {
            "code": "1400",
            "name": "Fixed Assets",
            "name_ar": "الأصول الثابتة",
            "type": "asset",
        },
        {
            "code": "2000",
            "name": "Liabilities",
            "name_ar": "الخصوم",
            "type": "liability",
        },
        {
            "code": "2100",
            "name": "Accounts Payable",
            "name_ar": "حسابات دائنة",
            "type": "liability",
        },
        {
            "code": "2200",
            "name": "Tax Payable",
            "name_ar": "ضريبة مستحقة",
            "type": "liability",
        },
        {"code": "3000", "name": "Equity", "name_ar": "حقوق الملكية", "type": "equity"},
        {
            "code": "3100",
            "name": "Retained Earnings",
            "name_ar": "الأرباح المحتجزة",
            "type": "equity",
        },
        {"code": "4000", "name": "Income", "name_ar": "الإيرادات", "type": "income"},
        {
            "code": "4100",
            "name": "Sales Revenue",
            "name_ar": "إيرادات المبيعات",
            "type": "income",
        },
        {"code": "5000", "name": "Expenses", "name_ar": "المصروفات", "type": "expense"},
        {
            "code": "5100",
            "name": "Cost of Goods Sold",
            "name_ar": "تكلفة البضاعة المباعة",
            "type": "expense",
        },
        {
            "code": "5200",
            "name": "Operating Expenses",
            "name_ar": "المصروفات التشغيلية",
            "type": "expense",
        },
    ]

    def __init__(
        self,
        acc_repo: AccountRepository,
        je_repo: JournalEntryRepository,
        jel_repo: JournalEntryLineRepository,
    ):
        self._acc = acc_repo
        self._je = je_repo
        self._jel = jel_repo

    # ═══ Chart of Accounts ═══

    async def init_default_chart(self, org_id: UUID) -> List[AccountResponse]:
        existing = await self._acc.list(org_id)
        if existing:
            return [AccountResponse.model_validate(a) for a in existing]
        accounts = []
        for d in self.DEFAULT_COA:
            a = Account(
                organization_id=org_id,
                code=d["code"],
                name=d["name"],
                name_ar=d["name_ar"],
                type=d["type"],
            )
            accounts.append(await self._acc.create(a))
        return [AccountResponse.model_validate(a) for a in accounts]

    async def create_account(
        self, org_id: UUID, data: AccountCreate, *, account_id=None
    ) -> AccountResponse:
        existing = await self._acc.get_by_code(data.code, org_id)
        if existing:
            raise ValueError(f"كود الحساب {data.code} موجود مسبقاً")
        a = Account(
            **({'id': account_id} if account_id is not None else {}),
            organization_id=org_id,
            code=data.code,
            name=data.name,
            name_ar=data.name_ar,
            type=data.type,
            parent_id=data.parent_id,
            is_active=data.is_active,
        )
        r = await self._acc.create(a)
        from app.core.cache import tenant_cache_invalidate
        await tenant_cache_invalidate(org_id, "accounts")
        return AccountResponse.model_validate(r)

    async def list_accounts(
        self, org_id: UUID, type_filter: Optional[str] = None
    ) -> List[AccountResponse]:
        from app.core.cache import tenant_cache_get, tenant_cache_set

        cached = await tenant_cache_get(org_id, "accounts", type=type_filter)
        if cached:
            return [AccountResponse.model_validate(a) for a in cached]

        items = await self._acc.list(org_id, type_filter)
        result = [AccountResponse.model_validate(a) for a in items]
        await tenant_cache_set(org_id, "accounts", [r.model_dump() for r in result], ttl=300, type=type_filter)
        return result

    # ═══ Journal Entries ═══

    async def create_journal_entry(
        self, org_id: UUID, uid: UUID, data: JournalEntryCreate,
        branch_id=None, *, entry_id=None,
    ) -> JournalEntryResponse:
        if not data.lines:
            raise ValueError("يجب إضافة قيد واحد على الأقل")
        total_dr = sum(l.debit for l in data.lines)
        total_cr = sum(l.credit for l in data.lines)
        if total_dr != total_cr:
            raise ValueError(
                f"مجموع المدين ({total_dr}) لا يساوي مجموع الدائن ({total_cr})"
            )
        num = await self._je.get_next_sequence(
            org_id, f"JE-{date.today().strftime('%Y%m%d')}", date.today()
        )
        entry = JournalEntry(
            **({'id': entry_id} if entry_id is not None else {}),
            organization_id=org_id,
            branch_id=branch_id,
            entry_number=f"JE-{date.today().strftime('%Y%m%d')}-{num:04d}",
            entry_date=data.entry_date or date.today(),
            description=data.description,
            reference_type=data.reference_type,
            reference_id=data.reference_id,
            created_by=uid,
        )
        r = await self._je.create(entry)
        lines = []
        for ld in data.lines:
            line = JournalEntryLine(
                account_id=ld.account_id,
                description=ld.description,
                debit=ld.debit,
                credit=ld.credit,
            )
            lines.append(line)
        await self._jel.bulk_create(r.id, lines)
        r = await self._je.get_by_id(r.id, org_id)
        return self._je_resp(r)

    def _je_resp(self, e):
        return JournalEntryResponse(
            id=e.id,
            organization_id=e.organization_id,
            branch_id=e.branch_id,
            entry_number=e.entry_number,
            entry_date=e.entry_date,
            description=e.description,
            reference_type=e.reference_type,
            reference_id=e.reference_id,
            status=e.status,
            created_at=e.created_at,
            posted_at=e.posted_at,
            lines=[
                JournalEntryLineResponse(
                    id=l.id,
                    journal_entry_id=l.journal_entry_id,
                    account_id=l.account_id,
                    account_name=l.account.name if l.account else None,
                    account_code=l.account.code if l.account else None,
                    description=l.description,
                    debit=l.debit,
                    credit=l.credit,
                )
                for l in (e.lines or [])
            ],
        )

    async def post_journal_entry(
        self, eid: UUID, org_id: UUID, uid: UUID
    ) -> JournalEntryResponse:
        e = await self._je.get_by_id(eid, org_id)
        if not e:
            raise ValueError("القيد غير موجود")
        if e.status != "draft":
            raise ValueError("يمكن ترحيل المسودة فقط")
        # Validate debit = credit
        total_dr = sum(l.debit for l in e.lines)
        total_cr = sum(l.credit for l in e.lines)
        if total_dr != total_cr:
            raise ValueError(f"القيد غير متوازن ({total_dr} != {total_cr})")
        e.status, e.posted_at = "posted", datetime.now(timezone.utc)
        r = await self._je.update(e)
        r = await self._je.get_by_id(r.id, org_id)
        from app.core.cache import tenant_cache_invalidate
        await tenant_cache_invalidate(org_id, "trial_balance")
        await tenant_cache_invalidate(org_id, "profit_loss")
        await tenant_cache_invalidate(org_id, "balance_sheet")
        return self._je_resp(r)

    async def list_journal_entries(
        self, org_id: UUID, page: int = 1, per_page: int = 20,
        branch_id=None,
        branch_ids=None,
    ) -> Tuple[List[JournalEntryResponse], int]:
        items, total = await self._je.list(
            org_id, page, per_page, branch_id, branch_ids)
        return [self._je_resp(i) for i in items], total

    # ═══ Reports ═══

    async def trial_balance(
        self, org_id: UUID, entry_date: Optional[date] = None
    ) -> TrialBalanceResponse:
        from app.core.cache import tenant_cache_get, tenant_cache_set

        cached = await tenant_cache_get(org_id, "trial_balance", entry_date=str(entry_date))
        if cached:
            return TrialBalanceResponse.model_validate(cached)

        accounts = await self._acc.list(org_id)
        ed = entry_date or date.today()
        entries = await self._je.get_entries_in_range(org_id, date(2000, 1, 1), ed)
        acct_totals = {}
        for e in entries:
            for l in e.lines:
                if l.account_id not in acct_totals:
                    acct_totals[l.account_id] = (ZERO, ZERO)
                dr, cr = acct_totals[l.account_id]
                acct_totals[l.account_id] = (dr + l.debit, cr + l.credit)
        items = []
        total_dr = total_cr = ZERO
        for a in accounts:
            debit, credit = acct_totals.get(a.id, (ZERO, ZERO))
            bal = debit - credit if a.type in ("asset", "expense") else credit - debit
            total_dr += debit
            total_cr += credit
            items.append(
                TrialBalanceItem(
                    account_id=a.id,
                    account_code=a.code,
                    account_name=a.name,
                    account_type=a.type,
                    debit=debit,
                    credit=credit,
                    balance=bal,
                )
            )
        result = TrialBalanceResponse(
            items=items, total_debit=total_dr, total_credit=total_cr, entry_date=ed
        )
        await tenant_cache_set(org_id, "trial_balance", result.model_dump(), ttl=120, entry_date=str(entry_date))
        return result

    async def profit_loss(
        self, org_id: UUID, from_date: date, to_date: date
    ) -> ProfitLossResponse:
        from app.core.cache import tenant_cache_get, tenant_cache_set

        cached = await tenant_cache_get(org_id, "profit_loss", from_date=str(from_date), to_date=str(to_date))
        if cached:
            return ProfitLossResponse.model_validate(cached)

        income_accounts = await self._acc.list_by_type(org_id, "income")
        expense_accounts = await self._acc.list_by_type(org_id, "expense")
        entries = await self._je.get_entries_in_range(org_id, from_date, to_date)
        acct_totals = {}
        for e in entries:
            for l in e.lines:
                if l.account_id not in acct_totals:
                    acct_totals[l.account_id] = (ZERO, ZERO)
                dr, cr = acct_totals[l.account_id]
                acct_totals[l.account_id] = (dr + l.debit, cr + l.credit)
        income_items, expense_items = [], []
        total_income = total_expense = ZERO
        for a in income_accounts:
            dr, cr = acct_totals.get(a.id, (ZERO, ZERO))
            amt = cr - dr
            income_items.append(
                ProfitLossItem(
                    account_id=a.id,
                    account_code=a.code,
                    account_name=a.name,
                    amount=amt,
                )
            )
            total_income += amt
        for a in expense_accounts:
            dr, cr = acct_totals.get(a.id, (ZERO, ZERO))
            amt = dr - cr
            expense_items.append(
                ProfitLossItem(
                    account_id=a.id,
                    account_code=a.code,
                    account_name=a.name,
                    amount=amt,
                )
            )
            total_expense += amt
        result = ProfitLossResponse(
            income=income_items,
            expenses=expense_items,
            total_income=total_income,
            total_expenses=total_expense,
            net_profit=total_income - total_expense,
            entry_date=to_date,
        )
        await tenant_cache_set(org_id, "profit_loss", result.model_dump(), ttl=120, from_date=str(from_date), to_date=str(to_date))
        return result

    async def balance_sheet(self, org_id: UUID, as_of: date) -> BalanceSheetResponse:
        from app.core.cache import tenant_cache_get, tenant_cache_set

        cached = await tenant_cache_get(org_id, "balance_sheet", as_of=str(as_of))
        if cached:
            return BalanceSheetResponse.model_validate(cached)

        assets = await self._acc.list_by_type(org_id, "asset")
        liabilities = await self._acc.list_by_type(org_id, "liability")
        equities = await self._acc.list_by_type(org_id, "equity")
        entries = await self._je.get_entries_in_range(org_id, date(2000, 1, 1), as_of)
        acct_totals = {}
        for e in entries:
            for l in e.lines:
                if l.account_id not in acct_totals:
                    acct_totals[l.account_id] = (ZERO, ZERO)
                dr, cr = acct_totals[l.account_id]
                acct_totals[l.account_id] = (dr + l.debit, cr + l.credit)

        def calc_balance(accounts, is_debit_side):
            result = []
            total = ZERO
            for a in accounts:
                dr, cr = acct_totals.get(a.id, (ZERO, ZERO))
                bal = dr - cr
                if not is_debit_side:
                    bal = -bal
                result.append(
                    BalanceSheetItem(
                        account_id=a.id,
                        account_code=a.code,
                        account_name=a.name,
                        account_type=a.type,
                        balance=bal,
                    )
                )
                total += bal
            return result, total

        asset_items, total_as = calc_balance(assets, True)
        liab_items, total_li = calc_balance(liabilities, False)
        eq_items, total_eq = calc_balance(equities, False)
        result = BalanceSheetResponse(
            assets=asset_items,
            liabilities=liab_items,
            equity=eq_items,
            total_assets=total_as,
            total_liabilities=total_li,
            total_equity=total_eq,
            entry_date=as_of,
        )
        await tenant_cache_set(org_id, "balance_sheet", result.model_dump(), ttl=120, as_of=str(as_of))
        return result
