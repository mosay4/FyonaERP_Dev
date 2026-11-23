"""Production Readiness 3 — Ambiguous Intent.

Ambiguous requests ("افتح الحساب" with 2 accounts, "اعرض التقرير" with many
report types, pronoun-only commands) must trigger a clarification and the
pending task must be remembered for the follow-up — the agent must never guess.
"""

from tests.acceptance.conftest import assert_no_technical_leak, make_ctx
from tests.acceptance.mock_openai import final_content, tool_call


async def test_multiple_accounts_trigger_clarification(make_agent, seed, openai_client, memory):
    client = openai_client(script=[
        tool_call("ask_clarification", {
            "question": "لديك حسابان: الراجحي والأهلي. أي حساب تريد فتحه؟",
            "options": ["الراجحي", "الأهلي"],
        }),
        final_content("لديك حسابان. أي حساب تريد أن أفتحه لك؟"),
    ])
    agent = make_agent()
    resp = await agent.process("افتح الحساب", make_ctx(seed))

    # The task is remembered for the follow-up round.
    assert memory.get(str(seed["org_a"]))["current_task"] == "افتح الحساب"
    # The answer asks, it does not guess.
    assert "أي حساب" in resp.text
    assert resp.actions == []
    assert_no_technical_leak(resp.text)


async def test_clarification_then_concrete_target_resolves(make_agent, seed, openai_client, memory):
    client = openai_client(script=[
        tool_call("ask_clarification", {
            "question": "أي حساب تريد فتحه؟",
        }),
        final_content("لديك حسابان، أخبرني أيهما تريد."),
    ])
    agent = make_agent()
    resp1 = await agent.process("افتح الحساب", make_ctx(seed))
    assert memory.get(str(seed["org_a"]))["current_task"] == "افتح الحساب"

    # Follow-up with a concrete target proceeds directly to the real action.
    client2 = openai_client(script=[
        tool_call("open_entity", {"entity_type": "bank", "name": "الراجحي"}),
        final_content("فتحت لك حساب **الراجحي**."),
    ])
    agent2 = make_agent()
    resp2 = await agent2.process("الراجحي", make_ctx(seed))
    assert resp2.actions[0].action == "open_entity"
    assert resp2.actions[0].params == {"entity_type": "bank", "name": "الراجحي"}
    assert_no_technical_leak(resp1.text)
    assert_no_technical_leak(resp2.text)


async def test_many_report_types_trigger_clarification(make_agent, seed, openai_client):
    client = openai_client(script=[
        tool_call("ask_clarification", {
            "question": "أي تقرير تريد؟ إيرادات، مصروفات، أرباح، أو كشف حساب؟",
        }),
        final_content("أي نوع من التقارير تريد؟"),
    ])
    agent = make_agent()
    resp = await agent.process("اعرض التقرير", make_ctx(seed))

    assert resp.actions == []
    assert "أي" in resp.text
    assert_no_technical_leak(resp.text)


async def test_pronoun_without_antecedent_asks_for_target(make_agent, seed, openai_client):
    client = openai_client(script=[
        tool_call("ask_clarification", {
            "question": "ما الذي تريد حذفه بالضبط؟",
        }),
        final_content("ما الذي تريد حذفه؟"),
    ])
    agent = make_agent()
    resp = await agent.process("احذفه", make_ctx(seed))

    assert resp.actions == []
    assert resp.text
    assert_no_technical_leak(resp.text)


async def test_ambiguous_transfer_asks_before_executing(make_agent, seed, openai_client, db):
    from app.domain.entities.finance_entities import BankAccount
    from sqlalchemy import select

    client = openai_client(script=[
        tool_call("ask_clarification", {
            "question": "من أي حساب تريد التحويل، وإلى أي حساب، وبأي مبلغ؟",
        }),
        final_content("أخبرني بالتفاصيل: الحسابان والمبلغ."),
    ])
    agent = make_agent()
    resp = await agent.process("حوّل", make_ctx(seed))

    assert resp.actions == []
    # Nothing was moved — clarification happened BEFORE any money movement.
    for name in ["الراجحي", "الأهلي"]:
        result = await db.execute(select(BankAccount).where(BankAccount.account_name == name))
        acc = result.scalars().first()
        assert acc.balance in (1000, 500)
