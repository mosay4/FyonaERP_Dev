"""Acceptance Test 1 — the full Agent cycle and dynamic tool selection.

Proves: Reason → Plan → Tool Selection → Tool Execution (real DB) → Observation →
Reflection → Final Response, with the exact tools used at every step.
"""

import asyncio

import pytest

from app.domain.services.sara_agent_service import APP_TOOLS, ToolExecutor
from tests.acceptance.mock_openai import final_content, tool_call, parallel_tool_calls
from tests.acceptance.conftest import (
    assert_no_technical_leak,
    last_tool_message,
    system_prompt,
    make_ctx,
)


async def test_full_agent_cycle_reason_plan_tool_observe_reflect_respond(
    make_agent, seed, openai_client, memory
):
    steps = []

    def reason_plan(messages):
        # Step 1 — the model REASONS about the request and PLANS a data fetch.
        steps.append("reason+plan")
        prompt = messages[0]["content"]
        assert "Reason → Plan → Act → Observe → Reflect → Respond" in prompt
        return tool_call("get_banking_data", {"include_transactions": True, "limit": 5})

    def observe(messages):
        # Step 2 — the model OBSERVES the real tool result (from the seeded DB).
        steps.append("observe")
        result = last_tool_message(messages)
        assert "الراجحي" in result, f"real bank data missing: {result}"
        assert "1000.00" in result, f"real balance missing: {result}"
        return tool_call("show_suggestions", {"suggestions": ["افتح البنوك", "أنشئ هدف ادخار"]})

    def reflect_respond(messages):
        # Step 3 — the model REFLECTS and writes the FINAL response.
        steps.append("reflect+respond")
        return final_content("رصيدك في حساب الراجحي 1000 ريال. تحب أفتح شاشة **البنوك**؟")

    client = openai_client(script=[reason_plan, observe, reflect_respond])
    agent = make_agent()
    resp = await agent.process("كم رصيدي؟", make_ctx(seed))

    # The loop ran the full cycle in 3 rounds.
    assert steps == ["reason+plan", "observe", "reflect+respond"]
    assert len(client.chat.completions.calls) == 3

    # Final response reached the user, suggestions were parsed from the tool.
    assert resp.text == "رصيدك في حساب الراجحي 1000 ريال. تحب أفتح شاشة **البنوك**؟"
    assert resp.suggestions == ["افتح البنوك", "أنشئ هدف ادخار"]
    assert resp.confidence == 0.9

    # The tool the model picked was actually EXECUTED against the real DB:
    # the second create() call carries the real tool result.
    assert_no_technical_leak(resp.text)


def test_tool_selection_is_dynamic_and_data_driven():
    """All 15 tools are offered to the model; executor dispatch is registry-free."""
    assert len(APP_TOOLS) == 15
    names = {t["function"]["name"] for t in APP_TOOLS}
    assert "open_entity" in names
    assert "create_transaction" in names
    assert "ask_clarification" in names

    # Every tool that is executed through ToolExecutor has a handler via the
    # getattr convention -> adding a new data tool = APP_TOOLS entry + _exec_*,
    # no dispatch table to edit. This is exactly the data-driven dispatch used
    # by the agent loop (`hasattr(tool_executor, "_exec_<name>")`).
    registered = {
        name.replace("_exec_", "")
        for name in dir(ToolExecutor)
        if name.startswith("_exec_")
    }
    # Frontend-only / special tools handled directly by the loop's branches.
    loop_special = {
        "open_app_screen", "show_suggestions", "create_entity", "export_report",
        "get_app_help", "open_entity", "ask_clarification",
    }
    data_tools = registered & names
    assert names == data_tools | (loop_special & names), (
        names - (data_tools | loop_special)
    )
    assert "search_all_transactions" in data_tools


async def test_all_tools_are_offered_to_the_model(make_agent, seed, openai_client):
    client = openai_client(script=[final_content("حسناً")])
    agent = make_agent()
    await agent.process("مرحباً", make_ctx(seed))
    offered = client.chat.completions.call_kwargs[0]["tools"]
    assert {t["function"]["name"] for t in offered} == {t["function"]["name"] for t in APP_TOOLS}


async def test_model_decides_tool_choice_not_a_fixed_intent(make_agent, seed, openai_client):
    """The same user message is fulfilled with different tools depending on the
    model's decision — intent only shapes context, never the execution path."""
    client = openai_client(script=[
        tool_call("get_financial_summary", {"period": "this_month"}),
        final_content("ملخص هذا الشهر جاهز."),
    ])
    agent = make_agent()
    await agent.process("أبي ملخص شهري", make_ctx(seed))

    # The tool chosen (get_financial_summary) was executed and returned real data.
    assert "tool" in [m["role"] for m in client.chat.completions.calls[1]]
    result = last_tool_message(client.chat.completions.calls[1])
    assert "income" in result or "expense" in result


async def test_parallel_tool_calls_in_one_round(make_agent, seed, openai_client):
    """Independent steps can be issued in the same round (parallel Act)."""
    client = openai_client(script=[
        parallel_tool_calls(
            {"name": "get_banking_data", "arguments": {}},
            {"name": "show_suggestions", "arguments": {"suggestions": ["أ", "ب", "ج"]}},
        ),
        final_content("تم جلب البيانات والاقتراحات."),
    ])
    agent = make_agent()
    resp = await agent.process("اعطيني وضع حساباتي", make_ctx(seed))

    assert resp.suggestions[:3] == ["أ", "ب", "ج"]
    # Two tools executed in one round + one final round = 2 create() calls.
    assert len(client.chat.completions.calls) == 2


async def test_reflection_injected_after_failed_tool(make_agent, seed, openai_client):
    """When a real tool returns an error, a self-reflection system message is
    injected so the model can recover instead of stopping."""
    client = openai_client(script=[
        tool_call("create_transaction", {
            "operation": "deposit", "amount": 500, "account_name": "بنك غير موجود",
        }),
        final_content("لم أجد حسابك. حساباتك المتاحة: الراجحي, الأهلي."),
    ])
    agent = make_agent()
    resp = await agent.process("أودع 500 في حساب البنك", make_ctx(seed))

    # Real executor returned an error (account doesn't exist) and the loop
    # injected the reflection guidance before the final answer.
    error_result = last_tool_message(client.chat.completions.calls[1])
    assert "لم أجد الحساب" in error_result
    reflected = any(
        m.get("role") == "system" and "بعض الأدوات فشلت" in m.get("content", "")
        for m in client.chat.completions.calls[1]
    )
    assert reflected, "self-reflection message was not injected"

    # User sees only the friendly Arabic answer — never the raw error JSON.
    assert_no_technical_leak(resp.text)
    assert resp.needs_clarification is True
    assert "الراجحي" in resp.text
