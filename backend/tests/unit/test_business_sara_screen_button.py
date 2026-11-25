"""Business Sara never promises a screen button without attaching it.

Regression (owner, Business): «افتح البنوك» got «اضغط الزر لفتح شاشة البنوك»
with no button — the Personal-only safety net never ran for Business.
"""
import json
from types import SimpleNamespace
from uuid import uuid4

import pytest

from app.api.v1 import business_sara
from app.domain.models.m5_models import AIQuery
from app.domain.services.sara_screen_links import (
    BUSINESS_FALLBACK_ROUTES, missing_open_action, screen_from_text,
)
from app.main import app


@pytest.mark.parametrize('text,route', [
    ('افتح البنوك', '/banks'),
    ('open the banks', '/banks'),
    ('افتح الصندوق', '/banks'),
    ('ودني للخزينة', '/banks'),
    ('افتح الديون', '/debts'),
    ('ابي ديون العملاء', '/debts/customers'),
    ('افتح العملاء', '/customers'),
    ('open suppliers', '/suppliers'),
    ('افتح المنتجات', '/inventory'),
    ('افتح المخزون', '/inventory'),
    ('افتح الفواتير', '/invoices'),
    ('افتح التقارير', '/reports'),
    ('افتح المطابقة', '/reconciliation'),
    ('افتح الموظفين', '/employees'),
    ('افتح الفروع', '/branches'),
    ('open settings', '/settings'),
    ('افتح المصروفات', '/business/income-expense'),
    ('وديني للتقارير', '/reports'),
])
def test_business_words_name_business_screens(text, route):
    assert screen_from_text(text, 'business')[2] == route
    assert route in BUSINESS_FALLBACK_ROUTES


def test_personal_table_is_unchanged():
    assert screen_from_text('افتح البنوك')[2] == '/personal/banks'
    assert missing_open_action('افتح البنوك', 'اضغط الزر', [])['route'] == '/personal/banks'


def test_business_reply_promising_button_gets_it():
    out = missing_open_action('open the banks', 'Press the button to open the banks screen.', [],
                              section='business')
    assert out['route'] == '/banks'
    assert missing_open_action('افتح البنوك', 'تفضل', [{'action': 'open_screen'}], section='business') is None
    assert missing_open_action('كم رصيدي؟', 'رصيدك 500', [], section='business') is None


def _reply(content=None):
    return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(
        content=content, tool_calls=None, reasoning_content=None))])


@pytest.fixture
def model(monkeypatch):
    script, seen = [], []

    async def create(messages, **_):
        seen.append([dict(m) for m in messages])
        return script.pop(0)

    monkeypatch.setattr(business_sara, 'client', lambda: SimpleNamespace(
        chat=SimpleNamespace(completions=SimpleNamespace(create=create))))

    async def context(db, uid):
        return {}
    monkeypatch.setattr(business_sara, 'load_context', context)
    monkeypatch.setattr(business_sara, 'subscription_reply', lambda *a: None)
    monkeypatch.setattr(business_sara, 'cross_section_reply', lambda *a: None)
    monkeypatch.setattr(business_sara, 'policy', lambda c: '')
    return script, seen


def _identity():
    return {'org': str(uuid4()), 'uid': str(uuid4()),
            'scope': SimpleNamespace(all_mode=False, branch_id=uuid4())}


@pytest.mark.asyncio
async def test_answer_attaches_missing_banks_button_and_states_the_rule(model):
    script, seen = model
    script.append(_reply('اضغط الزر لفتح شاشة البنوك.'))
    out = await business_sara.answer(AIQuery(query='افتح البنوك', account_type='business'),
                                     SimpleNamespace(app=app), _identity(), None)
    assert out['actions'][0]['action'] == 'open_screen'
    assert out['actions'][0]['params']['route'] == '/banks'
    system = seen[0][0]['content']
    assert 'open_app_screen' in system and 'قاعدة الأزرار' in system
    assert '/branches' in system and '/reconciliation' in system


@pytest.mark.asyncio
async def test_device_continue_reads_the_question_from_the_resumed_conversation(model):
    script, _ = model
    script.append(_reply('Tap the button to open your customers.'))
    state = {'messages': [{'role': 'user', 'content': 'open customers'}], 'steps': 2,
             'actions': [], 'device_routes': ['GET /customers']}
    out = await business_sara.answer(
        AIQuery(query='', account_type='business', language='en'),
        SimpleNamespace(app=app), _identity(), None, device=True,
        resume={**state, 'results': []})
    assert out['actions'][0]['params'] == {'screen': 'Customers', 'route': '/customers'}
    assert out['actions'][0]['label'] == 'Open Customers'
