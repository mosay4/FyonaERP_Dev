"""Real branch aggregation in isolated in-memory SQLite; never use live data or AI."""
import json
from types import SimpleNamespace
from unittest.mock import AsyncMock
from uuid import uuid4

import pytest
import pytest_asyncio
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import app.main  # noqa: F401 -- register the full relationship graph
from app.core.database import Base
from app.domain.entities.auth_entities import Organization
from app.domain.entities.business_entities import Product
from app.domain.entities.invoice_entities import Invoice, InvoiceItem
from app.domain.entities.sale_entities import Branch, BranchStock
from app.domain.services import falcon_service as fs


@pytest_asyncio.fixture
async def evidence(monkeypatch):
    monkeypatch.setattr(fs, '_call_ai', AsyncMock(return_value=None))
    monkeypatch.setattr(fs.settings, 'OPENAI_API_KEY', '')
    engine = create_async_engine('sqlite+aiosqlite:///:memory:')
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    try:
        async with async_sessionmaker(engine, expire_on_commit=False)() as db:
            org = uuid4()
            db.add(Organization(id=org, name='Test', slug=f'falcon-{org}'))
            branches = [Branch(id=uuid4(), organization_id=org, name=name, is_default=i == 0)
                        for i, name in enumerate(['فرع الرياض', 'فرع جدة', 'فرع ممنوع'])]
            db.add_all(branches)
            product = Product(id=uuid4(), organization_id=org, name='سكر', unit='قطعة',
                              branch_id=branches[0].id, stock=999, price=10,
                              cost_price=2, cost_currency='SAR')
            db.add(product)
            for branch, stock, sales in zip(branches, [7, 13, 999], [40, 90, 9999]):
                db.add(BranchStock(organization_id=org, branch_id=branch.id,
                                   product_id=product.id, quantity=stock, avg_cost=2))
                invoice = Invoice(id=uuid4(), organization_id=org, branch_id=branch.id,
                                  invoice_number=str(branch.id), invoice_type='sale',
                                  status='confirmed', currency='SAR')
                db.add(invoice)
                db.add(InvoiceItem(invoice_id=invoice.id, product_id=product.id,
                                   description='سكر', quantity=2, base_quantity=2,
                                   total=sales, cost_total=4, profit=sales-4))
            await db.flush()
            yield db, org, branches
    finally:
        await engine.dispose()


@pytest.mark.asyncio
async def test_all_permitted_branches_exact_evidence_and_report(evidence):
    db, org, branches = evidence
    ids = [b.id for b in branches[:2]]
    report = await fs.analyze(db, org, 'inventory', None, 'ar', 'SAR', branch_ids=ids)
    summaries = report['stats']['branch_summaries']
    assert [(r['branch_name'], r['stock'], r['total_sales']) for r in summaries] == [
        ('فرع الرياض', 7, 40), ('فرع جدة', 13, 90)]
    assert report['stats']['total_sales'] == 130
    assert report['stats']['branch_ids'] == [str(b.id) for b in branches[:2]]
    assert 'فرع ممنوع' not in json.dumps(report, ensure_ascii=False)
    assert 'فرع الرياض\nالمبيعات: 40.00 SAR، المخزون: 7.00.' in report['status_line']
    assert '\n\nفرع جدة\n' in report['status_line']
    assert report['ai'] is False


@pytest.mark.asyncio
@pytest.mark.parametrize('lang', ['ar', 'en'])
async def test_chat_fallback_spacing_and_named_branch_isolation(evidence, lang):
    db, org, branches = evidence
    ids = [b.id for b in branches[:2]]
    all_answer = (await fs.chat(db, org, 'inventory', None, 'قارن الفروع', [], lang,
                                'SAR', branch_ids=ids))['answer']
    assert 'فرع الرياض' in all_answer and 'فرع جدة' in all_answer
    assert '\n\n' in all_answer and '\n\n\n' not in all_answer
    for mark in ['**', '`', '"', '«', '»', '{', '}', 'فرع ممنوع']:
        assert mark not in all_answer
    named = (await fs.chat(db, org, 'inventory', None, 'ما مخزون فرع جدة؟',
                          [{'role': 'assistant', 'content': 'فرع الرياض 999'}], lang,
                          'SAR', branch_ids=ids))['answer']
    assert 'فرع جدة' in named and '13.00' in named and '90.00' in named
    assert 'فرع الرياض' not in named and 'فرع ممنوع' not in named
    assert '999' not in named


@pytest.mark.asyncio
async def test_ai_report_narratives_are_normalized(evidence, monkeypatch):
    db, org, branches = evidence
    ai = AsyncMock(return_value=json.dumps({
        'status_line': '**واضح**!!!\n\n\nالمبيعات 130.25',
        'attention': ['`المخزون` 20'], 'recommendations': ['«راجع التوريد»'],
        'opportunity': '"فرصة"',
    }, ensure_ascii=False))
    monkeypatch.setattr(fs, '_call_ai', ai)
    report = await fs.analyze(db, org, 'inventory', None, 'ar', 'SAR',
                              branch_ids=[b.id for b in branches[:2]])
    assert 'واضح!\n\nالمبيعات 130.25' in report['status_line']
    assert report['attention'] == ['المخزون 20']
    assert report['recommendations'] == ['راجع التوريد']
    assert report['opportunity'] == 'فرصة'
    assert all(b.name in ai.call_args.args[1] for b in branches[:2])
    assert branches[2].name not in ai.call_args.args[1]


@pytest.mark.asyncio
async def test_named_branch_ai_context_and_answer_are_isolated(evidence, monkeypatch):
    from app.domain.services import ai_router
    db, org, branches = evidence
    monkeypatch.setattr(fs.settings, 'OPENAI_API_KEY', 'test-only')
    create = AsyncMock(return_value=SimpleNamespace(choices=[SimpleNamespace(
        message=SimpleNamespace(content='**فرع جدة**\n\nالمخزون 13.00!!!'))]))
    monkeypatch.setattr(ai_router, 'route', lambda *a, **kw: SimpleNamespace(
        api_key='test-only', model='test', max_tokens=500, effort='low'))
    monkeypatch.setattr(ai_router, 'build_client', lambda r: SimpleNamespace(
        chat=SimpleNamespace(completions=SimpleNamespace(create=create))))
    result = await fs.chat(db, org, 'inventory', None, 'ماذا عن جدة؟',
                           [{'role': 'assistant', 'content': 'فرع الرياض'}], 'ar',
                           'SAR', branch_ids=[b.id for b in branches[:2]])
    assert result['answer'] == 'فرع جدة\n\nالمخزون 13.00!'
    sent = json.dumps(create.call_args.kwargs['messages'], ensure_ascii=False)
    assert 'فرع جدة' in sent and 'فرع الرياض' not in sent and 'فرع ممنوع' not in sent


def test_normalization_preserves_numbers_and_meaningful_newlines():
    raw = '```json\n{"answer": "**المبيعات** 1,234.50!!!\n\n\n`المخزون` 13.25؟؟"}\n```'
    assert fs._as_plain(raw) == 'المبيعات 1,234.50!\n\nالمخزون 13.25؟'
    assert fs._as_plain('"**Sales** 1,234.50!!!\n\n\nStock 13.25??"') == (
        'Sales 1,234.50!\n\nStock 13.25?')
