import json
from types import SimpleNamespace
from uuid import UUID
from unittest.mock import AsyncMock

import pytest
from sqlalchemy import select, func
from app.main import app
from app.api.v1 import business_sara as sara
from app.domain.entities.business_entities import Customer
from test_branch_access_transfers_api import (
    _sync_engine, _async_engine, _session_factory, client,
    _employee_access_scenario, _h, API,
)

pytestmark = pytest.mark.asyncio


class Call:
    id = 'tool-1'
    def __init__(self, name, args):
        self.function = SimpleNamespace(name=name, arguments=json.dumps(args))
    def model_dump(self):
        return {'id': self.id, 'type': 'function', 'function': vars(self.function)}


def fake_model(monkeypatch, name, args):
    message = SimpleNamespace(content=None, tool_calls=[Call(name, args)])
    create = AsyncMock(return_value=SimpleNamespace(choices=[SimpleNamespace(message=message)]))
    monkeypatch.setattr(sara, 'client', lambda: SimpleNamespace(chat=SimpleNamespace(
        completions=SimpleNamespace(create=create))))
    return create


async def selected(client, scenario, all=False, branch=0, worker=False):
    headers = _h(scenario['worker_token'] if worker else scenario['owner_token'])
    response = await client.post(f'{API}/branches/select', headers=headers, json={
        'organization_id': str(scenario['org'].id),
        **({'all': True} if all else {'branch_id': str(scenario['branches'][branch].id)})})
    assert response.status_code == 200, response.text
    return {**headers, 'X-Branch-Token': response.json()['data']['token']}


async def test_owner_prepares_confirms_once_and_scope_is_bound(client, _session_factory, monkeypatch):
    scenario = await _employee_access_scenario(_session_factory, full=True)
    headers = await selected(client, scenario)
    fake_model(monkeypatch, 'prepare_operation', {'method': 'POST', 'path': '/customers',
        'body': {'name': 'Sara-created customer', 'currency': 'USD'}, 'summary': 'إنشاء عميل بالفرع الحالي'})
    reply = await client.post(f'{API}/business-sara/query', headers=headers, json={'query': 'أضف عميل'})
    assert reply.status_code == 200, reply.text
    plan = reply.json()['data']['pending_tools'][0]['params']['token']
    async with _session_factory() as db:
        assert await db.scalar(select(func.count(Customer.id)).where(Customer.name == 'Sara-created customer')) == 0
    other = await selected(client, scenario, branch=1)
    denied = await client.post(f'{API}/business-sara/execute', headers=other, json={'token': plan})
    assert denied.status_code == 403
    executed = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': plan})
    assert executed.status_code == 200, executed.text
    assert executed.json()['data']['success'], executed.text
    repeated = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': plan})
    assert repeated.json()['data'] == executed.json()['data']
    async with _session_factory() as db:
        rows = (await db.execute(select(Customer).where(Customer.name == 'Sara-created customer'))).scalars().all()
        assert len(rows) == 1
        assert rows[0].branch_id == scenario['branches'][0].id


async def test_employee_denied_and_all_view_has_no_execution_tool(client, _session_factory, monkeypatch):
    scenario = await _employee_access_scenario(_session_factory, full=True)
    worker = await selected(client, scenario, worker=True)
    denied = await client.post(f'{API}/business-sara/query', headers=worker, json={'query': 'مرحبا'})
    assert denied.status_code == 403, denied.text
    headers = await selected(client, scenario, all=True)
    create = fake_model(monkeypatch, 'open_app_screen', {'route': '/customers', 'screen': 'العملاء'})
    reply = await client.post(f'{API}/business-sara/query', headers=headers,
        json={'query': 'افتح العملاء', 'screen_catalog': [{'name': 'العملاء', 'route': '/customers'}]})
    assert reply.status_code == 200, reply.text
    assert all(t['function']['name'] != 'prepare_operation'
               for t in create.call_args.kwargs['tools'])
    denied = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': 'fake'})
    assert denied.status_code in (403, 409)


async def test_real_read_respects_branch_and_failures_are_not_success(client, _session_factory, monkeypatch):
    scenario = await _employee_access_scenario(_session_factory, full=True)
    headers = await selected(client, scenario)
    fake_model(monkeypatch, 'prepare_operation', {'method': 'POST', 'path': '/customers',
        'body': {}, 'summary': 'طلب ناقص'})
    reply = await client.post(f'{API}/business-sara/query', headers=headers, json={'query': 'عميل'})
    token = reply.json()['data']['pending_tools'][0]['params']['token']
    executed = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': token})
    assert executed.status_code == 200, executed.text
    assert not executed.json()['data']['success']
    assert executed.json()['data']['status'] == 422


async def test_catalog_rejects_foreign_personal_or_control_paths():
    for path in ('https://example.org', '/personal/banks', '/auth/me', '/admin/users',
                 '/customers/../auth', '/branches/select', '/customers?branch_id=other'):
        with pytest.raises(Exception):
            sara.resolve(app, 'GET', path)
    assert sara.schema_for(app, 'POST', '/customers')['schemas']


async def test_insufficient_balance_surfaces_real_failure_without_changing_money(client, _session_factory, monkeypatch):
    from decimal import Decimal
    from app.domain.entities.finance_entities import BankAccount
    scenario = await _employee_access_scenario(_session_factory, full=True)
    headers = await selected(client, scenario)
    bank_id = scenario['banks'][0].id
    fake_model(monkeypatch, 'prepare_operation', {
        'method': 'POST', 'path': f'/banking/accounts/{bank_id}/withdraw',
        'body': {'amount': 999999}, 'summary': 'سحب أكبر من الرصيد'})
    reply = await client.post(f'{API}/business-sara/query', headers=headers, json={'query': 'اسحب'})
    token = reply.json()['data']['pending_tools'][0]['params']['token']
    result = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': token})
    outcome = result.json()['data']
    assert not outcome['success'] and outcome['status'] == 400, outcome
    async with _session_factory() as db:
        assert (await db.get(BankAccount, bank_id)).balance == Decimal('100')


async def test_invoice_is_real_and_timeline_attributes_sara(client, _session_factory, monkeypatch):
    scenario = await _employee_access_scenario(_session_factory, full=True)
    headers = await selected(client, scenario)
    fake_model(monkeypatch, 'prepare_operation', {'method': 'POST', 'path': '/invoices',
        'body': {'invoice_type': 'sale', 'items': [{'description': 'Service', 'unit_price': 5}]},
        'summary': 'فاتورة خدمة بقيمة خمسة'})
    reply = await client.post(f'{API}/business-sara/query', headers=headers, json={'query': 'فاتورة خدمة'})
    plan = reply.json()['data']['pending_tools'][0]['params']['token']
    result = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': plan})
    assert result.json()['data']['success'], result.text
    invoice_id = result.json()['data']['data']['data']['id']
    fake_model(monkeypatch, 'prepare_operation', {'method': 'POST', 'path': f'/invoices/{invoice_id}/status',
        'body': {'action': 'confirm'}, 'summary': 'اعتماد مسودة الفاتورة'})
    reply = await client.post(f'{API}/business-sara/query', headers=headers, json={'query': 'اعتمد الفاتورة'})
    plan = reply.json()['data']['pending_tools'][0]['params']['token']
    confirmed = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': plan})
    assert confirmed.json()['data']['success'], confirmed.text
    response = await client.get(f'{API}/business/transactions', headers=headers)
    assert response.status_code == 200, response.text
    entries = response.json()['data']['items']
    assert any(row.get('by_sara') and row.get('by_name') == 'سارة' for row in entries), entries


@pytest.mark.skipif(__import__('os').environ.get('RUN_LIVE_SARA') != '1', reason='Explicit live-provider test')
async def test_live_deepseek_all_branches_reads_without_foreign_company_data(client, _session_factory):
    scenario = await _employee_access_scenario(_session_factory, full=True)
    async with _session_factory() as db:
        db.add_all([
            Customer(organization_id=scenario['org'].id, branch_id=scenario['branches'][0].id, name='عميل ألف'),
            Customer(organization_id=scenario['org'].id, branch_id=scenario['branches'][1].id, name='عميل باء'),
            Customer(organization_id=scenario['own'].id, name='ForeignSecretCustomer'),
        ])
        await db.commit()
    headers = await selected(client, scenario, all=True)
    response = await client.post(f'{API}/business-sara/query', headers=headers, json={
        'query': 'اعرض أسماء العملاء الحقيقيين لكل فروع شركتي، مع اسم فرع كل عميل. اقرأ البيانات أولًا. لا تنفذ أي تغيير.'})
    assert response.status_code == 200, response.text
    data = response.json()['data']
    assert 'عميل ألف' in data['text'] and 'عميل باء' in data['text'], data['text']
    assert 'ForeignSecretCustomer' not in data['text']
    assert not data.get('pending_tools')


@pytest.mark.skipif(__import__('os').environ.get('RUN_LIVE_SARA') != '1', reason='Explicit live-provider test')
async def test_live_deepseek_prepares_actual_api_operation_in_isolated_database(client, _session_factory):
    scenario = await _employee_access_scenario(_session_factory, full=True)
    headers = await selected(client, scenario)
    response = await client.post(f'{API}/business-sara/query', headers=headers, json={
        'query': 'أضف عميلًا جديدًا اسمه تجربة سارة المباشرة في الفرع الحالي، بالعملة USD. جهز العملية الآن للتأكيد، لا تنفذها قبل تأكيدي.'})
    assert response.status_code == 200, response.text
    data = response.json()['data']
    assert data.get('pending_tools'), data['text']
    token = data['pending_tools'][0]['params']['token']
    result = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': token})
    assert result.status_code == 200, result.text
    assert result.json()['data']['success'], result.text
    async with _session_factory() as db:
        assert await db.scalar(select(func.count(Customer.id)).where(
            Customer.branch_id == scenario['branches'][0].id,
            Customer.name == 'تجربة سارة المباشرة')) == 1
