from unittest.mock import AsyncMock

import pytest

from app.api.v1 import ai, business_sara
from app.domain.models.agent_models import AgentResponse
from test_branch_access_transfers_api import (
    _sync_engine, _async_engine, _session_factory, client,
    _employee_access_scenario, _h, API,
)
from test_business_sara import selected


@pytest.mark.asyncio
@pytest.mark.parametrize('multipart', [False, True])
async def test_personal_context_is_server_owned_even_when_client_claims_premium(
        client, _session_factory, monkeypatch, multipart):
    scenario = await _employee_access_scenario(_session_factory, full=True)
    server = {'known': True, 'sections': {'personal': {'active': True}, 'business': {'active': False}}, 'plans': []}
    loader = AsyncMock(return_value=server)
    monkeypatch.setattr(ai, 'load_context', loader)
    monkeypatch.setattr(ai.settings, 'SARA_API_KEY', 'test-not-used')
    process = AsyncMock(return_value=AgentResponse(text='server-owned guidance'))
    monkeypatch.setattr(ai.SaraAgentService, 'process', process)
    payload = {'query': 'business plan', 'language': 'en', 'subscription_plan': 'premium',
               'subscription_status': 'active'}
    headers = _h(scenario['worker_token'])
    if multipart:
        result = await client.post(f'{API}/ai/query-attachment', headers=headers, data=payload)
    else:
        payload['subscription_context'] = {'known': True, 'sections': {'business': {'active': True}}}
        result = await client.post(f'{API}/ai/query', headers=headers, json=payload)
    assert result.status_code == 200, result.text
    ctx = process.call_args.kwargs['ctx']
    assert ctx.subscription_context == server
    assert not ctx.subscription_plan
    assert str(loader.call_args.args[1]) == str(scenario['worker'].id)


@pytest.mark.asyncio
@pytest.mark.parametrize('language,query,package', [
    ('ar', 'أريد باقة للشخصي والأعمال', 'premium'),
    ('en', 'activate business plan now', 'business'),
])
async def test_business_plan_requests_offer_review_only_without_model_or_plan(
        client, _session_factory, monkeypatch, language, query, package):
    scenario = await _employee_access_scenario(_session_factory, full=True)
    headers = await selected(client, scenario)
    model = AsyncMock(side_effect=AssertionError('subscription guidance must not call model'))
    call_api = AsyncMock(side_effect=AssertionError('subscription guidance must not mutate or read business data'))
    monkeypatch.setattr(business_sara, 'client', model)
    monkeypatch.setattr(business_sara, 'call_api', call_api)
    result = await client.post(f'{API}/business-sara/query', headers=headers,
                               json={'query': query, 'language': language})
    assert result.status_code == 200, result.text
    response = result.json()['data']
    assert response['actions'][0]['params']['route'] == f'/subscription?package={package}'
    assert not response['pending_tools']
    assert all(action['action'] == 'open_screen' for action in response['actions'])
    model.assert_not_called()
    call_api.assert_not_called()
