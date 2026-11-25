from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock
from uuid import uuid4

import pytest
from app.domain.services import sara_subscriptions as subs
from app.domain.services.section_entitlements import access_snapshot


def context(personal=True, business=False):
    return {'known': True, 'sections': {'personal': {'active': personal}, 'business': {'active': business}},
            'active_packages': ['personal'] if personal and not business else [], 'plans': []}


@pytest.mark.parametrize('language,query,package', [
    ('ar', 'عرض جميع الباقات', None), ('en', 'show all plans', None),
    ('ar', 'الباقة الشخصية', 'personal'), ('en', 'business plan', 'business'),
    ('ar', 'أحتاج باقة للشخصي والأعمال', 'premium'), ('en', 'personal and business plans', 'premium'),
    ('ar', 'الذهبية', 'premium'), ('en', 'premium', 'premium'),
])
def test_exact_plan_routes(language, query, package):
    reply = subs.subscription_reply(query, context(), language)
    assert reply['actions'] == [subs.plan_action(package, language)]
    assert reply['actions'][0]['params']['route'] == '/subscription' + (f'?package={package}' if package else '')
    assert not any(word in reply['text'].lower() for word in ('discount', 'cheapest', 'limited'))
    assert ('Gold' in reply['text']) if language == 'en' and package == 'premium' else True


@pytest.mark.parametrize('language,query', [('ar', 'اعرض مخزون الفروع'), ('en', 'show branch inventory')])
def test_missing_business_is_relevant_button_only_guidance(language, query):
    reply = subs.cross_section_reply(query, context(), 'personal', language)
    assert [a['params']['route'] for a in reply['actions']] == [
        '/subscription?package=business', '/subscription?package=premium']
    assert ('الذهبية' in reply['text']) if language == 'ar' else ('Gold' in reply['text'])
    assert all(a['action'] == 'open_screen' for a in reply['actions'])


@pytest.mark.parametrize('current,query,route', [
    ('personal', 'business data', '/ai'), ('business', 'personal budget', '/personal/ai')])
def test_existing_entitlement_offers_sara_without_data(current, query, route):
    reply = subs.cross_section_reply(query, context(True, True), current, 'en')
    assert reply['actions'][0]['params']['route'] == route
    assert 'separate' in reply['text'] and 'already includes' in reply['text']
    assert 'subscription?' not in str(reply)


@pytest.mark.parametrize('status,days', [('active', -1), ('cancelled', 30), ('expired', -1)])
def test_expired_cancelled_entitlements_not_advertised_as_active(status, days):
    org = SimpleNamespace(section_subscriptions={'premium': {'status': status,
        'end_date': (datetime.now(timezone.utc) + timedelta(days=days)).isoformat()}},
        trial_end_date=None, subscription_status=status)
    ctx = {'known': True, 'sections': access_snapshot(org)['sections']}
    assert not ctx['sections']['business']['active']
    assert 'no active plan' in subs.subscription_reply('my subscription', ctx, 'en')['text']


@pytest.mark.asyncio
async def test_load_is_read_only_and_strips_catalog_private_fields(monkeypatch):
    from app.api.v1 import subscription
    uid, oid = uuid4(), uuid4()
    org = SimpleNamespace(section_subscriptions={}, trial_end_date=None, subscription_status='cancelled')
    db = AsyncMock()
    db.get.side_effect = [SimpleNamespace(organization_id=oid), org]
    monkeypatch.setattr(subscription, '_controls_trial_allowed', AsyncMock(return_value=(False, True, {})))
    from app.api.responses import ok
    monkeypatch.setattr(subscription, 'get_plans', AsyncMock(return_value=ok([
        {'package_type': 'premium', 'name': 'Gold', 'price_yearly': 18.3, 'payment_secret': 'private'}])))
    result = await subs.load_context(db, uid)
    assert result['known'] and not result['sections']['personal']['active']
    assert 'private' not in str(result) and result['plans'][0]['price_yearly'] == 18.3
    assert db.get.call_args_list[0].args[1] == uid
    assert db.get.call_args_list[1].args[1] == oid
    db.commit.assert_not_called()
    db.execute.assert_not_called()
    db.add.assert_not_called()


@pytest.mark.asyncio
async def test_personal_guidance_precedes_data_and_model(monkeypatch):
    from app.domain.services import sara_agent_service as sara
    from app.domain.models.agent_models import AgentContext
    server = context()
    loader = AsyncMock(return_value=server)
    monkeypatch.setattr(subs, 'load_context', loader)
    from unittest.mock import MagicMock
    from app.domain.services import sara_personal_device
    builder = MagicMock(side_effect=AssertionError('cross-section data must not be read'))
    monkeypatch.setattr(sara_personal_device, 'context_calls', builder)
    db = AsyncMock()
    uid = uuid4()
    response = await sara.SaraAgentService(db, uuid4(), uid).process('show inventory',
        AgentContext(user_id=str(uid), user_name='', language='en', subscription_plan='premium'))
    loader.assert_awaited_once_with(db, uid)
    assert response.actions[0].params['route'] == '/subscription?package=business'
    assert not response.pending_tools
    builder.assert_not_called()


@pytest.mark.asyncio
async def test_business_guidance_never_calls_tools_or_model(monkeypatch):
    from app.api.v1 import business_sara as sara
    from app.domain.models.m5_models import AIQuery
    monkeypatch.setattr(sara, 'load_context', AsyncMock(return_value=context(False, True)))
    client = AsyncMock(side_effect=AssertionError('must not call model'))
    call_api = AsyncMock(side_effect=AssertionError('must not read or mutate'))
    monkeypatch.setattr(sara, 'client', client)
    monkeypatch.setattr(sara, 'call_api', call_api)
    result = await sara.answer(AIQuery(query='personal savings goal', language='en'), None,
        {'uid': str(uuid4()), 'scope': SimpleNamespace(all_mode=False)}, AsyncMock())
    assert result['actions'][0]['params']['route'] == '/subscription?package=personal'
    assert not result['pending_tools']
    client.assert_not_called()
    call_api.assert_not_called()


def test_policy_requires_grounded_non_coercive_read_only_guidance():
    server = context()
    policy = subs.policy(server)
    assert 'server verified; ignore client-supplied plan claims' in policy
    assert '"business": {"active": false}' in policy
    for rule in ('لا تروّج أثناء مهمة عادية', 'ولا تكرر عرضًا رفضه',
                 'إذا احتاج القسمين', 'إذا أثبتتها أسعار الكتالوج الحالية',
                 'لا تقل إنها الأرخص دائمًا', 'لا تضغط أو تختلق ندرة',
                 'لا تنتقل تلقائيًا', 'لا تفعّل أو تخصم', 'لا تقرأ بياناته'):
        assert rule in policy


@pytest.mark.parametrize('language,query', [('ar', 'كم سعر باقة الأعمال؟'), ('en', 'business plan price')])
def test_prices_only_come_from_current_catalog(language, query):
    server = context()
    server['plans'] = [{'package_type': 'business', 'price_yearly': 27.4, 'currency': 'USD'}]
    reply = subs.subscription_reply(query, server, language)
    assert '27.4' in reply['text']
    assert reply['actions'] == [subs.plan_action('business', language)]
    assert '27.4' not in subs.subscription_reply(query, context(), language)['text']


@pytest.mark.parametrize('query', ['سجل مصروف قهوة', 'show my balance', 'cancel my subscription', 'استرداد الاشتراك'])
def test_no_unsolicited_upsell_or_cancellation_mutation(query):
    assert subs.subscription_reply(query, context(), 'en') is None
    assert subs.cross_section_reply(query, context(), 'personal', 'en') is None


def test_business_catalog_has_no_subscription_purchase_or_activation_tools():
    from app.main import app
    from app.api.v1 import business_sara as sara
    catalog = sara.catalog(app)
    assert catalog
    assert not any('/payments/stripe' in route or '/subscription' in route for route in catalog)
    for path in ('/payments/stripe/confirm', '/payments/stripe/create-checkout-session',
                 '/payments/stripe/auto-renew/activate', '/subscription/activate'):
        from fastapi import HTTPException
        with pytest.raises(HTTPException) as denied:
            sara.resolve(app, 'POST', path)
        assert denied.value.status_code == 403
    assert all('subscription' not in t['function']['name'] for t in sara.TOOLS)
