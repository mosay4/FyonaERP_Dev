import json
import pytest
from app.core.employee_response_guard import EmployeeBankResponseGuard, redact_balances
from app.domain.services.employee_access_policy import GROUPS


def permissions():
    return {key: True for parent, children in GROUPS.items()
            for key in [parent, *(f'{parent}.{child}' for child in children)]}


def test_nested_bank_balance_fields_and_aggregates_are_removed():
    result = redact_balances({'data': {'accounts': [{'id': 'allowed', 'balance': 900,
        'balance_after': 950, 'opening_balance': 300, 'currencies': {'USD': 900}}],
        'total_balance': 900, 'totals': {'USD': 900}}})
    encoded = json.dumps(result)
    assert '900' not in encoded and '950' not in encoded and '300' not in encoded
    assert result['data']['accounts'][0]['id'] == 'allowed'
    assert result['data']['accounts'][0]['balance_visible'] is False


@pytest.mark.asyncio
@pytest.mark.parametrize('path,denial', [
    ('/api/v1/business-reports/money', 'banks.balances'),
    ('/api/v1/business-reports/overview', 'reports.view'),
    ('/api/v1/business-reports/export', 'reports.export'),
    ('/api/v1/banking/accounts/a/statement', 'reports.export'),
])
async def test_response_boundary_blocks_nested_and_streamed_report_leaks(path, denial):
    policy = permissions(); policy[denial] = False
    messages = []
    async def upstream(scope, receive, send):
        scope['state']['employee_policy'] = policy
        await send({'type': 'http.response.start', 'status': 200, 'headers': []})
        await send({'type': 'http.response.body', 'body': b'{"nested":{"total":', 'more_body': True})
        await send({'type': 'http.response.body', 'body': b'999123}}'})
    async def receive(): return {'type': 'http.request'}
    async def send(message): messages.append(message)
    await EmployeeBankResponseGuard(upstream)({'type': 'http', 'path': path, 'state': {}}, receive, send)
    assert messages[0]['status'] == 403
    assert b'999123' not in b''.join(m.get('body', b'') for m in messages)


@pytest.mark.asyncio
@pytest.mark.parametrize('path', ['/api/v1/business/transactions', '/api/v1/business/payment-options', '/api/v1/banking/accounts'])
async def test_balance_redaction_covers_transaction_and_payment_option_responses(path):
    messages = []
    async def upstream(scope, receive, send):
        scope['state']['employee_policy'] = {**permissions(), 'banks.balances': False}
        await send({'type': 'http.response.start', 'status': 200, 'headers': []})
        await send({'type': 'http.response.body', 'body': b'{"data":[{"amount":12,"balance":999123,"running_balance":999123}]}', 'more_body': False})
    async def receive(): return {'type': 'http.request'}
    async def send(message): messages.append(message)
    await EmployeeBankResponseGuard(upstream)({'type': 'http', 'path': path, 'state': {}}, receive, send)
    assert messages[0]['status'] == 200
    encoded = b''.join(m.get('body', b'') for m in messages)
    assert b'999123' not in encoded and b'12' in encoded
