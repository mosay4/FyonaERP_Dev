"""Acceptance Test 6 — Error handling & recovery.

Covers: missing API key, API 500, auth failure, rate limit, DB failure, unavailable
tool, unknown tool, malformed tool arguments. In every case Sara must answer with a
friendly Arabic message and MUST NOT leak technical details to the user.
"""

import pytest
from types import SimpleNamespace
from openai import AuthenticationError, RateLimitError, APIError

from app.domain.services.sara_agent_service import SaraContextBuilder, ToolExecutor
from tests.acceptance.mock_openai import final_content, tool_call
from tests.acceptance.conftest import (
    assert_no_technical_leak,
    make_ctx,
)


def _fake_response(status=500):
    return SimpleNamespace(
        status_code=status, headers={}, text="error", content=b"error",
        is_error=True, request=None,
    )


async def test_missing_api_key_returns_guidance(make_agent, seed, no_api_key):
    agent = make_agent()
    resp = await agent.process("كم رصيدي؟", make_ctx(seed))
    assert resp.text == "لم يتم تعيين مفتاح OpenAI. يرجى إضافة OPENAI_API_KEY إلى ملف .env."
    assert resp.confidence == 0.0


async def test_api_500_is_friendly(make_agent, seed, openai_client):
    client = openai_client(script=[APIError(
        message="Internal Server Error", request=None, body={"detail": "boom"},
    )])
    agent = make_agent()
    resp = await agent.process("كم رصيدي؟", make_ctx(seed))
    assert "خطأً مؤقتاً" in resp.text
    assert resp.confidence == 0.0
    assert_no_technical_leak(resp.text)


async def test_auth_failure_is_friendly(make_agent, seed, openai_client):
    openai_client(script=[AuthenticationError(
        message="Incorrect API key", response=_fake_response(401), body=None,
    )])
    agent = make_agent()
    resp = await agent.process("كم رصيدي؟", make_ctx(seed))
    assert "مفتاح OpenAI API غير صالح" in resp.text
    assert resp.confidence == 0.0
    assert_no_technical_leak(resp.text)


async def test_rate_limit_is_friendly(make_agent, seed, openai_client):
    openai_client(script=[RateLimitError(
        message="rate limited", response=_fake_response(429), body=None,
    )])
    agent = make_agent()
    resp = await agent.process("كم رصيدي؟", make_ctx(seed))
    assert "حد الطلبات" in resp.text
    assert_no_technical_leak(resp.text)


async def test_database_failure_is_friendly(make_agent, seed, openai_client, monkeypatch):
    """Even if the DB layer blows up while building context, the user never sees it."""
    openai_client(script=[final_content("نفسي أعرف")])

    async def broken_build(self, intent):
        raise RuntimeError("connection lost to postgres")

    monkeypatch.setattr(SaraContextBuilder, "build", broken_build)
    agent = make_agent()
    resp = await agent.process("كم رصيدي؟", make_ctx(seed))

    assert "خطأ غير متوقع" in resp.text
    assert resp.confidence == 0.0
    assert_no_technical_leak(resp.text)


async def test_tool_execution_exception_recovered(make_agent, seed, openai_client, monkeypatch):
    """A tool that raises internally must be recovered by the loop, not crash."""

    async def broken_exec(self, args):
        raise RuntimeError("boom inside tool")

    monkeypatch.setattr(ToolExecutor, "_exec_get_banking_data", broken_exec)

    client = openai_client(script=[
        tool_call("get_banking_data", {}),
        final_content("عذراً، تعذر جلب بيانات الحسابات الآن. حاول لاحقاً."),
    ])
    agent = make_agent()
    resp = await agent.process("كم رصيدي؟", make_ctx(seed))

    assert resp.text  # non-empty friendly answer
    assert_no_technical_leak(resp.text)
    # Reflection guidance was injected after the failure.
    reflected = any(
        m.get("role") == "system" and "بعض الأدوات فشلت" in m.get("content", "")
        for m in client.chat.completions.calls[1]
    )
    assert reflected


async def test_unknown_tool_is_rejected_without_mutation(
    make_agent, seed, openai_client, db
):
    """A malicious/unknown tool name must be refused — no crash, no data change."""
    client = openai_client(script=[
        tool_call("delete_all_accounts", {}),
        final_content("لا يمكنني تنفيذ ذلك."),
    ])
    agent = make_agent()
    resp = await agent.process("امسح كل حساباتي", make_ctx(seed))

    assert resp.text
    assert resp.needs_clarification is True
    unknown_msg = any(
        m.get("role") == "tool" and "أداة غير معروفة" in m.get("content", "")
        for msgs in client.chat.completions.calls for m in msgs
    )
    assert unknown_msg, "unknown tool was not flagged"
    assert_no_technical_leak(resp.text)

    # Nothing was mutated: org A still has its 2 seeded accounts.
    from app.domain.entities.finance_entities import BankAccount
    from sqlalchemy import select, func
    result = await db.execute(
        select(func.count(BankAccount.id)).where(BankAccount.organization_id == seed["org_a"])
    )
    assert result.scalar() == 2


async def test_malformed_tool_arguments_do_not_crash(make_agent, seed, openai_client):
    """Garbage arguments to a tool must not take the agent down."""
    client = openai_client(script=[
        tool_call("get_customer_data", "just-some-garbage-not-a-dict"),
        final_content("حسناً."),
    ])
    agent = make_agent()
    resp = await agent.process("ابحث عن عميل", make_ctx(seed))
    assert resp.text
    assert_no_technical_leak(resp.text)


async def test_tool_error_result_feeds_back_to_model_for_recovery(
    make_agent, seed, openai_client
):
    """When a real tool returns an error dict, the model gets it and recovers."""
    client = openai_client(script=[
        tool_call("create_transaction", {
            "operation": "withdraw", "amount": 999999,
            "account_name": "الراجحي",
        }),
        final_content("رصيدك لا يكفي لهذا السحب."),
    ])
    agent = make_agent()
    resp = await agent.process("اسحب مليون من الراجحي", make_ctx(seed))
    assert resp.text
    assert resp.needs_clarification is True
    assert_no_technical_leak(resp.text)


async def test_unexpected_error_is_generic(make_agent, seed, monkeypatch):
    """Any other unexpected exception -> one generic Arabic message, no internals."""

    class Boom:
        pass

    async def broken_build(self, intent):
        raise Boom()

    monkeypatch.setattr(SaraContextBuilder, "build", broken_build)
    agent = make_agent()
    resp = await agent.process("أي شيء", make_ctx(seed))
    assert "خطأ غير متوقع" in resp.text
    assert_no_technical_leak(resp.text)
