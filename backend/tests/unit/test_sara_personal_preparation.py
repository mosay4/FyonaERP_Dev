from types import SimpleNamespace
from unittest.mock import AsyncMock
import pytest
from app.domain.services import sara_agent_service as sara


@pytest.mark.asyncio
async def test_transfer_quotes_real_rate_and_never_calls_a_writer(monkeypatch):
    rows = [{'id': 'source', 'name': 'كاش', 'currency': 'USD', 'balance': '100'},
            {'id': 'target', 'name': 'بنك', 'currency': 'SAR', 'balance': '0'}]
    executor = SimpleNamespace(_db=None, _org_id='org', _user_id='u',
                              _exec_get_exchange_rate=AsyncMock(return_value={'rate': 3.75}))
    # The accounts are always the phone's own list.
    assert 'error' in await sara.prepare_personal_banking(executor, {
        'operation': 'transfer', 'from_account_name': 'كاش', 'to_account_name': 'بنك', 'amount': 10})
    result = await sara.prepare_personal_banking(executor, {
        'operation': 'transfer', 'from_account_name': 'كاش', 'to_account_name': 'بنك', 'amount': 10},
        accounts=rows)
    assert result['tool'] == 'create_transfer'
    assert result['params']['destination_amount'] == 37.5
    assert rows[0]['balance'] == '100' and rows[1]['balance'] == '0'
    executor._exec_get_exchange_rate.return_value = {'error': 'لا يوجد سعر موثق'}
    assert 'error' in await sara.prepare_personal_banking(executor, {
        'operation': 'transfer', 'from_account_name': 'كاش', 'to_account_name': 'بنك', 'amount': 10},
        accounts=rows)


@pytest.mark.asyncio
async def test_personal_business_question_never_builds_context():
    db = AsyncMock()
    agent = sara.SaraAgentService(db, __import__('uuid').uuid4(), __import__('uuid').uuid4())
    from app.domain.models.agent_models import AgentContext
    response = await agent.process('اعرض مخزون كل فروع الأعمال', AgentContext(user_id='u', user_name='اختبار', account_type='personal',
        subscription_context={'known': True, 'sections': {'personal': {'active': True}, 'business': {'active': False}}}))
    assert 'القسم الشخصي' in response.text and not response.pending_tools
    db.execute.assert_not_called()
