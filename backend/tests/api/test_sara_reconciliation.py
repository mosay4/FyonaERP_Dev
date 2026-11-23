from types import SimpleNamespace
from uuid import uuid4
from unittest.mock import AsyncMock
from decimal import Decimal
import pytest
from app.api.v1 import business_sara as sara
from app.domain.entities.finance_entities import BankAccount
from test_branch_access_transfers_api import _sync_engine, _async_engine, _session_factory, client, _employee_access_scenario, API
from test_business_sara import selected, fake_model, Call

pytestmark = pytest.mark.asyncio


async def balances(client, factory):
    scenario = await _employee_access_scenario(factory, full=True)
    async with factory() as db:
        rows = [BankAccount(organization_id=scenario['org'].id, branch_id=scenario['branches'][0].id,
            bank_name='كاش', account_name='كاش', account_number=uuid4().hex, currency=c, balance=a)
            for c, a in [('EGP', Decimal('303.37')), ('CNY', Decimal('80'))]]
        db.add_all(rows)
        await db.commit()
    headers = await selected(client, scenario)
    await client.put(f'{API}/business/project-settings', headers=headers, json={'enabled_currencies': ['EGP', 'CNY', 'USD']})
    return scenario, rows, headers


async def test_actuals_only_use_real_system_balances_and_do_not_change_money(client, _session_factory, monkeypatch):
    scenario, rows, headers = await balances(client, _session_factory)
    fake_model(monkeypatch, 'prepare_reconciliation', {'actuals': [
        {'account_name': 'الكاش', 'currency': 'EGP', 'actual': 50, 'system_balance': 99999},
        {'account_name': 'الكاش', 'currency': 'CNY', 'actual': 30}]})
    response = await client.post(f'{API}/business-sara/query', headers=headers, json={
        'query': 'الفعلي خمسون جنيهًا وثلاثون يوانًا',
        'history': [{'role': 'user', 'content': 'أريد مطابقة حسابات الكاش'},
                    {'role': 'assistant', 'content': 'كم الرصيد الفعلي لكل عملة؟'}]})
    assert response.status_code == 200, response.text
    pending = response.json()['data']['pending_tools'][0]['params']
    assert {'label': 'رصيد النظام', 'value': '303.37'} in pending['fields']
    assert {'label': 'رصيد النظام', 'value': '80'} in pending['fields']
    assert '99999' not in str(pending)
    result = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': pending['token']})
    assert result.json()['data']['success'], result.text
    async with _session_factory() as db:
        assert (await db.get(BankAccount, rows[0].id)).balance == Decimal('303.37')
        assert (await db.get(BankAccount, rows[1].id)).balance == Decimal('80')


async def test_changed_system_balance_requires_new_review_not_user_entered_system_number(client, _session_factory, monkeypatch):
    _, rows, headers = await balances(client, _session_factory)
    fake_model(monkeypatch, 'prepare_reconciliation', {'actuals': [{'account_id': str(rows[0].id), 'actual': 50}]})
    response = await client.post(f'{API}/business-sara/query', headers=headers, json={'query': 'جهز المطابقة'})
    token = response.json()['data']['pending_tools'][0]['params']['token']
    async with _session_factory() as db:
        row = await db.get(BankAccount, rows[0].id)
        row.balance = Decimal('304')
        await db.commit()
    response = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': token})
    assert response.status_code == 409, response.text


async def test_model_asking_for_system_balance_is_redirected_to_actual_read(client, _session_factory, monkeypatch):
    _, _, headers = await balances(client, _session_factory)
    messages = [
        SimpleNamespace(content='أحتاج الرصيد المسجل حتى أقارن؛ لا يمكنني افتراضه.', tool_calls=None),
        SimpleNamespace(content=None, tool_calls=[Call('get_reconciliation_accounts', {})]),
        SimpleNamespace(content='رصيد النظام للكاش 303.37 جنيه مصري و80 يوان صيني.', tool_calls=None),
    ]
    create = AsyncMock(side_effect=[SimpleNamespace(choices=[SimpleNamespace(message=m)]) for m in messages])
    monkeypatch.setattr(sara, 'client', lambda: SimpleNamespace(chat=SimpleNamespace(completions=SimpleNamespace(create=create))))
    response = await client.post(f'{API}/business-sara/query', headers=headers,
        json={'query': 'الفعلي 50 جنيه و30 يوان', 'history': [{'role': 'user', 'content': 'طابق الحسابات'}]})
    assert response.status_code == 200, response.text
    assert 'أحتاج' not in response.json()['data']['text']
    assert create.call_args_list[1].kwargs['tool_choice']['function']['name'] == 'get_reconciliation_accounts'
    tool_results = [m['content'] for m in create.call_args_list[-1].kwargs['messages'] if m['role'] == 'tool']
    assert any('303.37' in x for x in tool_results)
