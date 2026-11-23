"""Acceptance Test 5 — Context (App) Awareness.

Sara must know: current screen, subscription plan/status, network status, user
type, and the current user's data — and this must visibly change her prompts.
"""

import pytest

from app.domain.services.knowledge_base import format_relationships_for_prompt
from tests.acceptance.mock_openai import final_content, tool_call
from tests.acceptance.conftest import make_ctx, system_prompt


async def test_all_app_state_fields_reach_the_prompt(make_agent, seed, openai_client):
    client = openai_client(script=[final_content("تمام")])
    agent = make_agent()
    ctx = make_ctx(
        seed,
        subscription_plan="Premium",
        subscription_status="active",
        network_status="offline",
        current_tab="wallet",
        current_screen="البنوك",
        last_screen="التحليلات",
        last_operation="تحويل 200 إلى الأهلي",
        pending_operations=["إنشاء ميزانية"],
        user_name="مريم",
    )
    await agent.process("ماذا تعرف عن وضعي؟", ctx)

    prompt = system_prompt(client)
    assert "Premium (active)" in prompt
    assert "- حالة الإنترنت: offline" in prompt
    assert "- التبويب النشط: wallet" in prompt
    assert "- آخر شاشة زارها: التحليلات" in prompt
    assert "- آخر عملية نفذها: تحويل 200 إلى الأهلي" in prompt
    assert "- عمليات معلقة: إنشاء ميزانية" in prompt
    assert "مريم" in prompt
    assert "- الشاشة الحالية: البنوك" in prompt


async def test_personal_vs_business_scope_affects_prompt(make_agent, seed, openai_client):
    agent = make_agent()

    client = openai_client(script=[final_content("حسناً")])
    await agent.process("أي سؤال", make_ctx(seed, account_type="personal"))
    personal_prompt = system_prompt(client)
    assert "أنت في وضع الحساب الشخصي فقط" in personal_prompt
    assert "نوع الحساب: شخصي" in personal_prompt
    assert "create_transaction" in personal_prompt  # personal finance ops allowed

    client2 = openai_client(script=[final_content("حسناً")])
    await agent.process("أي سؤال", make_ctx(seed, account_type="business"))
    business_prompt = system_prompt(client2)
    assert "أنت سارة، الوكيل الذكي لتطبيق FYONA ERP" in business_prompt
    assert "نوع الحساب: أعمال" in business_prompt
    assert "لا تستخدم create_transaction في وضع الأعمال" in business_prompt


async def test_business_only_features_hidden_in_personal(make_agent, seed, openai_client):
    """Personal scope must not leak business-feature guidance into the prompt."""
    client = openai_client(script=[final_content("هذه ميزة في باقة الأعمال")])
    agent = make_agent()
    await agent.process("أبي أشتغل بالعملاء والمبيعات", make_ctx(seed, account_type="personal"))
    prompt = system_prompt(client)
    assert "أنت سارة، الوكيل الذكي لتطبيق FYONA ERP" not in prompt  # no business persona
    assert "لا تستخدم create_transaction في وضع الأعمال" not in prompt
    assert "أنت في وضع الحساب الشخصي فقط" in prompt
    # Business how-to knowledge was not injected for a personal account.
    assert "أوامر البيع" not in prompt


async def test_knowledge_graph_relationships_injected(make_agent, seed, openai_client):
    client = openai_client(script=[final_content("حسناً")])
    agent = make_agent()
    await agent.process("كم رصيدي في المحفظة؟", make_ctx(seed))

    rel = format_relationships_for_prompt("المحفظة")
    assert rel  # feature "المحفظة" exists in the graph
    assert rel in system_prompt(client)


async def test_real_user_data_injected_for_balance_query(make_agent, seed, openai_client):
    client = openai_client(script=[final_content("رصيدك 1000")])
    agent = make_agent()
    await agent.process("كم رصيدي؟", make_ctx(seed))

    prompt = system_prompt(client)
    assert "البيانات المتاحة" in prompt
    assert "الراجحي" in prompt  # real seeded account name reached the prompt
    assert "1000.00" in prompt


async def test_context_differs_by_network_state(make_agent, seed, openai_client):
    """Offline state reaches the prompt so Sara can mention connectivity."""
    client = openai_client(script=[final_content("يبدو أنك غير متصل بالإنترنت.")])
    agent = make_agent()
    await agent.process("حسابي؟", make_ctx(seed, network_status="offline"))
    assert "offline" in system_prompt(client)
