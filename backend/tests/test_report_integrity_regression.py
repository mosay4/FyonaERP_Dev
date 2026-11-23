from datetime import datetime, timedelta, timezone
from decimal import Decimal
from types import SimpleNamespace
from uuid import uuid4

import pytest
from fastapi import HTTPException
from sqlalchemy import select

from app.api.v1.business_reports import _result, _scoped
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import User
from app.domain.entities.finance_entities import BankAccount, BankTransaction
from app.domain.entities.invoice_entities import Invoice, Payment
from app.domain.entities.sale_entities import Branch
from app.domain.entities.sale_entities import InventoryLot
from app.domain.entities.business_entities import Product
from app.domain.services import business_reports_service as reports
from app.domain.services.currency_service import CentralFXEngine
from app.domain.services.report_fx import FxResolver, decimal_value
from app.domain.services.report_scope import ReportSession

UTC = timezone.utc
D = Decimal
HIST = datetime(2024, 1, 1, tzinfo=UTC)


class HistoryDB:
    def __init__(self, rows):
        self.info = {}
        self.rows = rows
        self.calls = 0

    async def execute(self, statement):
        self.calls += 1
        return SimpleNamespace(all=lambda: self.rows)


@pytest.mark.asyncio
async def test_history_is_loaded_usd_is_identity_and_yer_markets_are_distinct(monkeypatch):
    db = HistoryDB([('SAR', D('3.75'), HIST), ('YER_OLD', D('534'), HIST),
                    ('YER_NEW', D('1600'), HIST)])
    fx = FxResolver(db)
    at = HIST + timedelta(days=1)
    assert await fx.convert(D('534'), 'YER_OLD', 'SAR', at) == D('3.75')
    assert await fx.convert(D('1600'), 'YER_NEW', 'SAR', at) == D('3.75')
    assert await fx.convert(D('1'), 'USD', 'SAR', at) == D('3.75')
    assert await fx.convert(D('-534'), 'YER_OLD', 'SAR', at) == D('-3.75')
    assert db.calls == 1
    assert db.info.get('report_fx_missing', []) == []


@pytest.mark.asyncio
async def test_missing_historical_rate_never_uses_today_or_returns_partial_total(monkeypatch):
    class Engine:
        async def get_all_rates(self):
            raise AssertionError('Historical valuation must not call live rates')
    monkeypatch.setattr(CentralFXEngine, 'get_instance', lambda: Engine())
    db = HistoryDB([('SAR', D('3.75'), HIST)])
    fx = FxResolver(db)
    assert await fx.convert(D('534'), 'YER_OLD', 'SAR', HIST) is None
    with pytest.raises(HTTPException) as error:
        _result(db, {'currency': 'SAR', 'total': 123})
    assert error.value.status_code == 409
    assert error.value.detail['code'] == 'report_fx_missing'
    assert error.value.detail['missing'][0]['original_amount'] == '534'
    assert 'total' not in error.value.detail


@pytest.mark.asyncio
async def test_history_never_uses_future_rate_and_handles_intraday_changes():
    noon = HIST + timedelta(hours=12)
    db = HistoryDB([('SAR', D('3.75'), HIST),
                    ('YER_OLD', D('500'), HIST), ('YER_OLD', D('600'), noon)])
    fx = FxResolver(db)
    assert await fx.convert(D('1000'), 'YER_OLD', 'SAR', HIST + timedelta(hours=10)) == D('7.50')
    assert await fx.convert(D('1200'), 'YER_OLD', 'SAR', noon + timedelta(hours=1)) == D('7.50')
    assert await fx.convert(D('10'), 'YER_OLD', 'SAR', HIST - timedelta(days=1)) is None


@pytest.mark.asyncio
async def test_current_snapshot_is_frozen_once_and_rejects_hardcoded_fallback(monkeypatch):
    class Engine:
        calls = 0
        async def get_all_rates(self):
            self.calls += 1
            return {'global': {'USD': 1, 'SAR': 3.75},
                    'meta': {'global_source': 'provider'},
                    'yemen': {'source': 'store', 'sanaa': {'USD': {'average': 534}},
                              'aden': {'USD': {'average': 1600}}}}
    engine = Engine()
    monkeypatch.setattr(CentralFXEngine, 'get_instance', lambda: engine)
    db = HistoryDB([])
    a, b = FxResolver(db), FxResolver(db)
    now = datetime.now(UTC)
    assert await a.convert(D('-534'), 'YER_OLD', 'SAR', now) == D('-3.75')
    assert await b.convert(D('1600'), 'YER_NEW', 'SAR', now) == D('3.75')
    assert engine.calls == 1
    db2 = HistoryDB([])
    class Fallback:
        async def get_all_rates(self):
            return {'global': {'SAR': 3.75}, 'meta': {'global_source': 'fallback'}}
    monkeypatch.setattr(CentralFXEngine, 'get_instance', lambda: Fallback())
    assert await FxResolver(db2).convert(D(1), 'USD', 'SAR', now) is None


def test_decimal_precision_and_balance_currency_sum_are_not_lost():
    value = '12345678901234567890.123456789'
    assert decimal_value(value) == D(value)
    assert reports._sum_balances([
        {'currency': 'SAR', 'balance': '100.10'},
        {'currency': 'SAR', 'balance': '200.20'},
    ]) == {'SAR': D('300.30')}
    assert reports._merge_chart([
        {'date': '2025-01-01', 'value': D('.004')},
        {'date': '2025-01-01', 'value': D('.004')},
    ]) == [{'date': '2025-01-01', 'value': .01}]


@pytest.mark.asyncio
async def test_yemen_direct_pair_preserves_the_approved_market_rate(monkeypatch):
    db = HistoryDB([('SAR', D('3.75'), HIST, 'USD'),
                    ('YER_OLD', D('534'), HIST, 'USD'),
                    ('YER_OLD', D('140'), HIST, 'SAR')])
    fx = FxResolver(db)
    assert await fx.convert(D(280), 'YER_OLD', 'SAR', HIST+timedelta(days=1)) == 2
    class Engine:
        async def get_all_rates(self):
            return {'global': {'SAR': 3.75, 'USD': 1},
                'meta': {'global_source': 'provider'},
                'yemen': {'source': '2dec.net', 'sanaa': {
                    'USD': {'average': 534}, 'SAR': {'average': 140}}}}
    monkeypatch.setattr(CentralFXEngine, 'get_instance', lambda: Engine())
    current = FxResolver(HistoryDB([]))
    assert await current.convert(D(280), 'YER_OLD', 'SAR', datetime.now(UTC)) == 2
    assert await current.convert(D(2), 'SAR', 'YER_OLD', datetime.now(UTC)) == 280


@pytest.mark.asyncio
async def test_manual_rate_base_currency_is_not_misread_as_usd(monkeypatch):
    class Engine:
        async def get_all_rates(self):
            return {'global': {'SAR': 3.75, 'USD': 1},
                'meta': {'global_source': 'provider'},
                'yemen': {'source': 'provider', 'sanaa': {
                    'USD': {'average': 534}, 'SAR': {'average': 140}}},
                'admin_rates': [
                    {'currency_code':'YER_OLD','base_currency':'SAR','average_rate':142},
                    {'currency_code':'SAR','base_currency':'USD','average_rate':3.8},
                ]}
    monkeypatch.setattr(CentralFXEngine, 'get_instance', lambda: Engine())
    fx = FxResolver(HistoryDB([]))
    assert await fx.convert(D(284), 'YER_OLD', 'SAR', datetime.now(UTC)) == 2
    assert await fx.convert(D(1), 'USD', 'SAR', datetime.now(UTC)) == D('3.8')


@pytest.mark.asyncio(loop_scope='module')
async def test_real_database_branch_all_branches_and_original_totals():
    async with async_session_factory() as db:
        try:
            user = (await db.execute(select(User).limit(1))).scalars().first()
            if user is None:
                pytest.skip('An existing tenant is required; fixtures roll back')
            org = user.organization_id
            tag = uuid4().hex
            a, b = [Branch(id=uuid4(), organization_id=org, name=f'FX-{tag}-{i}')
                    for i in range(2)]
            db.add_all([a, b])
            await db.flush()
            at = datetime.now(UTC) - timedelta(days=2)
            accounts = []
            invoices = []
            for branch, amount, currency in [(a, '100', 'SAR'), (b, '534', 'YER_OLD')]:
                account = BankAccount(id=uuid4(), organization_id=org, branch_id=branch.id,
                    bank_name=tag, account_name=tag, account_number=uuid4().hex,
                    balance=D(amount), currency=currency)
                db.add(account)
                accounts.append(account)
                invoice = Invoice(id=uuid4(), organization_id=org, branch_id=branch.id,
                    invoice_number=f'{tag}-{currency}', invoice_type='sale',
                    status='confirmed', total=D(amount), paid_amount=0,
                    balance=D(amount), currency=currency, created_at=at)
                db.add(invoice)
                invoices.append(invoice)
                product = Product(id=uuid4(), organization_id=org, branch_id=branch.id,
                    name=f'FX-{tag}-{currency}', unit='piece', stock=2,
                    price=D(amount), is_service=False)
                db.add(product)
                await db.flush()
                db.add(InventoryLot(id=uuid4(), organization_id=org,
                    product_id=product.id, branch_id=branch.id,
                    received_quantity=2, remaining_quantity=2,
                    unit_cost=D(amount)/2, currency=currency))
            await db.flush()
            db.add(Payment(id=uuid4(), organization_id=org, branch_id=b.id,
                invoice_id=invoices[1].id, amount=D('534'),
                payment_date=at.date(), payment_currency='SAR',
                original_amount=D('1'), invoice_currency='YER_OLD',
                equivalent_amount=D('534'), exchange_rate=D('534')))
            for account in accounts:
                db.add(BankTransaction(id=uuid4(), organization_id=org,
                    bank_account_id=account.id, tx_type='deposit', amount=10,
                    currency=account.currency, date=at))
            await db.flush()
            db.info['report_fx_history'] = {
                'SAR': [(HIST, D('3.75'))], 'YER_OLD': [(HIST, D('534'))]}
            db.info['report_fx_current'] = {'USD': D(1), 'SAR': D('3.75'), 'YER_OLD': D(534)}
            start, end = at - timedelta(days=1), datetime.now(UTC)
            actual = []
            for ids in [[a.id], [b.id], [a.id, b.id], [b.id], [a.id]]:
                session = ReportSession(db, ids)
                sales = await reports.sales_purchases_report(session, org, start, end, 'SAR')
                actual.append(sales['sales']['total'])
                assert sales['sales']['count'] == len(ids)
                money = await reports.money_report(session, org, start, end, 'SAR')
                assert len(money['accounts']) == len(ids)
                assert money['balances']['total'] == sales['sales']['total']
                inventory = await reports.inventory_report_data(session, org, start, end, 'SAR', True)
                assert inventory['products'] == len(ids)
                assert inventory['stock_value'] == sales['sales']['total']
            assert actual == [100, 3.75, 103.75, 3.75, 100]
            assert actual[0] + actual[1] == actual[2]
            debt = await reports.debts_report_data(ReportSession(db, [a.id,b.id]),
                                                  org, start, end, 'SAR')
            assert debt['collected']['total'] == 1
            with pytest.raises(HTTPException) as denied:
                await _scoped(db, SimpleNamespace(all_mode=False, branch_id=a.id),
                              org, str(b.id))
            assert denied.value.status_code == 403
        finally:
            await db.rollback()


@pytest.mark.asyncio(loop_scope='module')
async def test_documented_backfill_keeps_effective_and_recorded_dates_separate():
    from app.api.v1.admin_exchange_rates import HistoricalRateCreate, document_historical_rate
    from app.domain.entities.finance_entities import ExchangeRateHistory
    async with async_session_factory() as db:
        try:
            user = (await db.execute(select(User).limit(1))).scalars().first()
            if not user:
                pytest.skip('Existing user required; fixtures roll back')
            row = await document_historical_rate(HistoricalRateCreate(
                currency_code='TSTAAA', average_rate='9', effective_at=HIST,
                evidence_reference='approved-document-123', reason='Documented historical valuation'),
                _user_id=str(user.id), _perm=True, db=db)
            import json
            payload = json.loads(row.body)
            stored = (await db.execute(select(ExchangeRateHistory).where(
                ExchangeRateHistory.id == payload['data']['id']))).scalar_one()
            assert stored.effective_at == HIST
            assert stored.created_at > HIST
            fx = FxResolver(db)
            assert await fx.convert(D(9), 'TSTAAA', 'USD', HIST+timedelta(hours=1)) == 1
            assert await fx.convert(D(9), 'TSTAAA', 'USD', HIST-timedelta(days=1)) is None
        finally:
            await db.rollback()
