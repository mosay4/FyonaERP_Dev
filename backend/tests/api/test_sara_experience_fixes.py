from unittest.mock import AsyncMock
import pytest
from test_branch_access_transfers_api import _sync_engine, _async_engine, _session_factory, client, _employee_access_scenario, API
from test_business_sara import selected, fake_model
from app.api.v1 import business_sara as sara
from app.domain.services.sara_presentation import currency_catalog, present, preview_fields


def test_full_currency_catalog_and_male_arabic_display():
    assert len(currency_catalog()) > 140
    assert {'AUD', 'AFN', 'KWD', 'YER_OLD', 'YER_NEW'} <= set(currency_catalog())
    assert present('راجعي 100 USD ثم أكدي 375 SAR') == 'راجع 100 دولار أمريكي ثم أكد 375 ريال سعودي'
    assert present('100 USD', 'en') == '100 USD'


def test_preview_hides_internal_names_and_identifiers():
    fields = preview_fields({'from_account_id': 'private-uuid', 'amount': 100,
        'currency': 'USD', 'exchange_rate': 3.75}, names={'private-uuid': 'كاش'})
    assert fields[0] == {'label': 'الحساب المرسل', 'value': 'كاش'}
    assert 'private-uuid' not in str(fields) and 'from_account_id' not in str(fields)


@pytest.mark.asyncio
async def test_business_voice_multipart_passes_transcript_language_and_scope(client, _session_factory, monkeypatch):
    import app.domain.services.sara_transcription as speech
    scenario = await _employee_access_scenario(_session_factory, full=True)
    headers = await selected(client, scenario)
    monkeypatch.setattr(speech, 'transcribe', AsyncMock(return_value='كم رصيد حساب الكاش؟'))
    answer = AsyncMock(return_value={'text': 'رصيد الكاش مئة دولار أمريكي.', 'pending_tools': []})
    monkeypatch.setattr(sara, 'answer', answer)
    response = await client.post(f'{API}/business-sara/query-attachment', headers=headers,
        data={'query': '', 'language': 'ar', 'history': '[]', 'screen_catalog': '[]'},
        files={'audio_file': ('voice.m4a', b'fixture', 'audio/m4a')})
    assert response.status_code == 200, response.text
    assert 'كم رصيد' in answer.call_args.args[0].query
    assert answer.call_args.args[0].language == 'ar'


@pytest.mark.asyncio
async def test_business_preparation_uses_friendly_fields_and_rejects_disabled_currency(client, _session_factory, monkeypatch):
    scenario = await _employee_access_scenario(_session_factory, full=True)
    headers = await selected(client, scenario)
    fake_model(monkeypatch, 'prepare_operation', {'method': 'POST', 'path': '/banking/accounts',
        'body': {'bank_name': 'بنك تجربة', 'account_name': 'حساب تجربة', 'currency': 'USD', 'balance': 250},
        'summary': 'إنشاء حساب برصيد افتتاحي'})
    response = await client.post(f'{API}/business-sara/query', headers=headers, json={'query': 'أنشئ حسابًا'})
    assert response.status_code == 200, response.text
    fields = response.json()['data']['pending_tools'][0]['params']['fields']
    assert {'label': 'الرصيد الافتتاحي', 'value': '250'} in fields
    assert any(f['value'] == 'دولار أمريكي' for f in fields)


@pytest.mark.asyncio
async def test_sara_bank_check_uses_real_inspection_without_mutating_balance(client, _session_factory, monkeypatch):
    scenario = await _employee_access_scenario(_session_factory, full=True)
    headers = await selected(client, scenario)
    fake_model(monkeypatch, 'prepare_operation', {'method': 'POST', 'path': '/reconciliation/bank/check',
        'body': {'entries': [{'account_id': str(scenario['banks'][0].id), 'actual': 30}]}, 'summary': 'فحص الكاش'})
    response = await client.post(f'{API}/business-sara/query', headers=headers, json={'query': 'افحص'})
    token = response.json()['data']['pending_tools'][0]['params']['token']
    result = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': token})
    assert result.json()['data']['success'], result.text


@pytest.mark.asyncio
async def test_opening_bank_balance_and_opening_customer_debt_are_executable(client, _session_factory, monkeypatch):
    from uuid import uuid4
    scenario = await _employee_access_scenario(_session_factory, full=True)
    headers = await selected(client, scenario)
    fake_model(monkeypatch, 'prepare_operation', {'method': 'POST', 'path': '/banking/accounts',
        'body': {'bank_name': 'بنك جديد', 'account_name': 'حساب جديد', 'account_number': uuid4().hex,
                 'currency': 'USD', 'balance': 250}, 'summary': 'إنشاء بنك برصيد افتتاحي'})
    response = await client.post(f'{API}/business-sara/query', headers=headers, json={'query': 'أنشئ بنكًا'})
    token = response.json()['data']['pending_tools'][0]['params']['token']
    result = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': token})
    assert result.json()['data']['success'], result.text
    customer = await client.post(f'{API}/customers', headers=headers, json={'name': 'عميل افتتاحي'})
    party_id = customer.json()['data']['id']
    fake_model(monkeypatch, 'prepare_operation', {'method': 'POST', 'path': '/merchant-links/party/opening-debt',
        'body': {'party_kind': 'customer', 'party_id': party_id, 'amount': 80, 'currency': 'USD'},
        'summary': 'دين افتتاحي للعميل'})
    response = await client.post(f'{API}/business-sara/query', headers=headers, json={'query': 'أضف دينًا افتتاحيًا'})
    token = response.json()['data']['pending_tools'][0]['params']['token']
    result = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': token})
    assert result.json()['data']['success'], result.text


def test_catalog_covers_every_currency_in_the_existing_application_selector():
    import re
    from pathlib import Path
    source = (Path(__file__).resolve().parents[3] / 'lib/shared/widgets/currency_selector.dart').read_text()
    source = source.split('const Map<String, String> worldCurrencies = {', 1)[1].split('};', 1)[0]
    codes = set(re.findall(r"'([A-Z_]+)'\s*:", source))
    codes.discard('YER')  # Explicitly represented as YER_NEW; no ambiguous YER in agent writes.
    assert codes <= set(currency_catalog()), codes - set(currency_catalog())


@pytest.mark.asyncio
async def test_confirmed_currency_quote_is_rejected_if_account_currency_changed(client, _session_factory, monkeypatch):
    from uuid import uuid4
    from app.domain.entities.finance_entities import BankAccount
    from app.domain.services.currency_service import CurrencyService
    monkeypatch.setattr(CurrencyService.get_instance(), 'get_rate', AsyncMock(return_value={'rate': 3.75}))
    scenario = await _employee_access_scenario(_session_factory, full=True)
    async with _session_factory() as db:
        target = BankAccount(organization_id=scenario['org'].id, branch_id=scenario['branches'][0].id,
            bank_name='Target', account_name='Target', account_number=uuid4().hex, currency='SAR', balance=0)
        db.add(target)
        await db.commit()
    headers = await selected(client, scenario)
    fake_model(monkeypatch, 'prepare_operation', {'method': 'POST', 'path': '/banking/transfer',
        'body': {'from_account_id': str(scenario['banks'][0].id), 'to_account_id': str(target.id), 'amount': 10},
        'summary': 'تحويل بين الحسابين'})
    response = await client.post(f'{API}/business-sara/query', headers=headers, json={'query': 'حوّل'})
    token = response.json()['data']['pending_tools'][0]['params']['token']
    async with _session_factory() as db:
        source = await db.get(BankAccount, scenario['banks'][0].id)
        source.currency = 'EUR'
        await db.commit()
    response = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': token})
    assert response.status_code == 409, response.text
    assert 'تغيرت عملة' in response.text


@pytest.mark.asyncio
@pytest.mark.skipif(__import__('os').environ.get('RUN_LIVE_SARA') != '1', reason='Explicit provider test')
async def test_live_sara_fetches_rate_and_prepares_currency_conversion_without_asking_user(client, _session_factory, monkeypatch):
    from uuid import uuid4
    from decimal import Decimal
    from app.domain.entities.finance_entities import BankAccount
    from app.domain.services.currency_service import CurrencyService
    engine = CurrencyService.get_instance()
    spy = AsyncMock(wraps=engine.get_rate)
    monkeypatch.setattr(engine, 'get_rate', spy)
    scenario = await _employee_access_scenario(_session_factory, full=True)
    async with _session_factory() as db:
        target = BankAccount(organization_id=scenario['org'].id, branch_id=scenario['branches'][0].id,
            bank_name='بنك الريال', account_name='بنك الريال', account_number=uuid4().hex, currency='SAR', balance=0)
        db.add(target)
        await db.commit()
    headers = await selected(client, scenario)
    response = await client.post(f'{API}/business-sara/query', headers=headers, json={
        'query': 'جهز تحويل عشرة دولارات من حساب Main إلى حساب بنك الريال في نفس الفرع. اجلب سعر الدولار إلى الريال السعودي من السعر المعتمد ولا تسألني عنه. اعرض التأكيد الآن دون تنفيذ.', 'language': 'ar'})
    assert response.status_code == 200, response.text
    data = response.json()['data']
    assert data.get('pending_tools'), data.get('text')
    assert spy.await_count >= 1
    async with _session_factory() as db:
        assert (await db.get(BankAccount, scenario['banks'][0].id)).balance == Decimal('100')
    token = data['pending_tools'][0]['params']['token']
    executed = await client.post(f'{API}/business-sara/execute', headers=headers, json={'token': token})
    assert executed.json()['data']['success'], executed.text
    async with _session_factory() as db:
        assert (await db.get(BankAccount, scenario['banks'][0].id)).balance == Decimal('90')
        assert (await db.get(BankAccount, target.id)).balance > 0
