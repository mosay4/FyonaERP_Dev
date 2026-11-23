import pytest
from test_branch_access_transfers_api import _sync_engine, _async_engine, _session_factory, client, _employee_access_scenario, API
from test_business_sara import selected, fake_model

pytestmark = pytest.mark.asyncio


async def product(client, headers):
    response = await client.post(f'{API}/products', headers=headers,
        json={'name': 'منتج اختبار سارة', 'price': 5, 'stock': 10, 'cost_price': 2})
    assert response.status_code == 201, response.text
    return response.json()['data']['id']


async def test_inventory_adjustment_through_sara_uses_the_repository_session(client, _session_factory, monkeypatch):
    scenario = await _employee_access_scenario(_session_factory, full=True)
    headers = await selected(client, scenario)
    pid = await product(client, headers)
    fake_model(monkeypatch, 'prepare_operation', {'method': 'POST', 'path': '/inventory/adjust',
        'body': {'product_id': pid, 'mode': 'add', 'amount': 2, 'reason': 'اختبار ضبط سارة'},
        'summary': 'زيادة المخزون وحدتين'})
    response = await client.post(f'{API}/business-sara/query', headers=headers, json={'query': 'زود المخزون وحدتين'})
    assert response.status_code == 200, response.text
    token = response.json()['data']['pending_tools'][0]['params']['token']
    executed = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': token})
    assert executed.json()['data']['success'], executed.text
    row = await client.get(f'{API}/products/{pid}', headers=headers)
    assert float(row.json()['data']['stock']) == 12


async def test_purchase_of_existing_product_uses_explicit_branch_context(client, _session_factory):
    scenario = await _employee_access_scenario(_session_factory, full=True)
    headers = await selected(client, scenario)
    pid = await product(client, headers)
    supplier = await client.post(f'{API}/suppliers', headers=headers, json={'name': 'مورد اختبار'})
    response = await client.post(f'{API}/invoices/issue-purchase', headers=headers, json={
        'supplier_id': supplier.json()['data']['id'], 'currency': 'USD',
        'items': [{'product_id': pid, 'quantity': 3, 'unit_price': 2}]})
    assert response.status_code == 201, response.text
    other = await selected(client, scenario, branch=1)
    response = await client.post(f'{API}/invoices/issue-purchase', headers=other, json={
        'currency': 'USD', 'items': [{'product_id': pid, 'quantity': 1, 'unit_price': 2}]})
    assert response.status_code in (400, 403, 404), response.text
