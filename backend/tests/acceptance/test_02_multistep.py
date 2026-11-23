"""Acceptance Test 2 — Multi-step tasks executed end-to-end without user input.

Each command is fulfilled by a *sequence* of tools; we assert the exact order,
that each step actually ran against the DB, and that the user received one final
response only.
"""

from decimal import Decimal

import pytest

from app.domain.entities.finance_entities import BankAccount
from sqlalchemy import select

from tests.acceptance.mock_openai import final_content, tool_call
from tests.acceptance.conftest import assert_no_technical_leak, make_ctx


def _steps_as(resp):
    return [(a.action, a.params) for a in resp.actions]


async def test_create_goal_then_open_it(make_agent, seed, openai_client, memory):
    client = openai_client(script=[
        tool_call("create_entity", {"entity_type": "goal", "name": "سيارة"}),
        tool_call("open_entity", {"entity_type": "goal", "name": "سيارة"}),
        final_content("تم إنشاء هدف الادخار **سيارة**، وفتحت لك صفحته."),
    ])
    agent = make_agent()
    resp = await agent.process("أنشئ هدف ادخار ثم افتحه", make_ctx(seed))

    assert _steps_as(resp) == [
        ("create_entity", {"entity_type": "goal", "name": "سيارة"}),
        ("open_entity", {"entity_type": "goal", "name": "سيارة"}),
    ]
    # 2 tool rounds + 1 final round, executed sequentially by the agent.
    assert len(client.chat.completions.calls) == 3
    assert_no_technical_leak(resp.text)


async def test_create_budget_then_open_report(make_agent, seed, openai_client):
    client = openai_client(script=[
        tool_call("create_entity", {"entity_type": "goal", "name": "احتياطي طوارئ"}),
        tool_call("open_app_screen", {"screen": "التقارير"}),
        final_content("تم إنشاء الهدف ثم فتحت شاشة **التقارير**."),
    ])
    agent = make_agent()
    resp = await agent.process("أنشئ هدف ادخار ثم افتح التقرير", make_ctx(seed))

    assert _steps_as(resp) == [
        ("create_entity", {"entity_type": "goal", "name": "احتياطي طوارئ"}),
        ("open_screen", {"screen": "التقارير"}),
    ]
    assert len(client.chat.completions.calls) == 3


async def test_show_customers_then_open_first_one(make_agent, seed, openai_client):
    def observe_customers(messages):
        # The model observes the REAL customer list, then opens the first one.
        tool_result = next(
            m["content"] for m in reversed(messages)
            if m.get("role") == "tool"
        )
        assert "شركة النور" in tool_result
        return tool_call("open_entity", {"entity_type": "customer", "name": "شركة النور"})

    client = openai_client(script=[
        tool_call("get_customer_data", {}),
        observe_customers,
        final_content("إليك العملاء، وفتحت صفحة **شركة النور**."),
    ])
    agent = make_agent()
    resp = await agent.process("اعرض العملاء ثم افتح أول عميل", make_ctx(seed))

    assert _steps_as(resp) == [
        ("open_entity", {"entity_type": "customer", "name": "شركة النور"}),
    ]
    assert len(client.chat.completions.calls) == 3


async def test_create_transaction_then_show_it(make_agent, seed, openai_client, db, memory):
    client = openai_client(script=[
        tool_call("create_transaction", {
            "operation": "deposit", "amount": 250, "account_name": "الراجحي",
            "description": "إيداع اختبار قبول",
        }),
        tool_call("open_entity", {"entity_type": "transaction", "name": "إيداع اختبار قبول"}),
        final_content("تم إيداع 250 ريال في الراجحي، وعرضت العملية لك."),
    ])
    agent = make_agent()
    resp = await agent.process("أنشئ معاملة ثم اعرضها", make_ctx(seed))

    actions = resp.actions
    # refresh_data is auto-appended after a successful financial operation.
    assert actions[0].action == "create_transaction" or actions[0].action == "refresh_data"
    assert _steps_as(resp)[-1] == ("open_entity", {"entity_type": "transaction", "name": "إيداع اختبار قبول"})
    assert len(client.chat.completions.calls) == 3

    # The real DB was mutated by the tool: 1000 + 250 = 1250.
    result = await db.execute(select(BankAccount).where(BankAccount.account_name == "الراجحي"))
    acc = result.scalars().first()
    assert acc.balance == Decimal("1250.00")

    # Memory recorded the operation for future context.
    assert "إيداع" in memory.get(str(seed["org_a"]))["last_operation"]


async def test_compound_command_five_steps_in_one_conversation(make_agent, seed, openai_client):
    """A long compound command: fetch, create, open, report, summarize."""
    client = openai_client(script=[
        tool_call("get_banking_data", {"include_transactions": True}),
        tool_call("create_entity", {"entity_type": "goal", "name": "سفر"}),
        tool_call("open_entity", {"entity_type": "bank", "name": "الراجحي"}),
        tool_call("export_report", {"report_type": "financial_summary", "period": "this_month"}),
        final_content("نفذت 4 خطوات: جلب الحسابات، إنشاء هدف، فتح الحساب، وتصدير التقرير."),
    ])
    agent = make_agent()
    resp = await agent.process(
        "اعرض حساباتي ثم أنشئ هدف سفر ثم افتح حساب الراجحي ثم صدّر تقرير ملخص",
        make_ctx(seed),
    )

    steps = _steps_as(resp)
    # get_banking_data is a data fetch (produces no UI action); the other three
    # tools each produced an action, in order.
    assert steps == [
        ("create_entity", {"entity_type": "goal", "name": "سفر"}),
        ("open_entity", {"entity_type": "bank", "name": "الراجحي"}),
        ("export_pdf", {"report_type": "financial_summary", "period": "this_month"}),
    ]
    # The data-fetch tool DID execute: a tool message with real account data exists.
    assert any(
        m.get("role") == "tool" and "الراجحي" in m.get("content", "")
        for msgs in client.chat.completions.calls for m in msgs
    )
    assert len(client.chat.completions.calls) == 5  # 4 tool rounds + final
    assert_no_technical_leak(resp.text)
