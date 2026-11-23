"""Production Readiness 7 — Offline Mode.

When the network / OpenAI service is down, Sara must fail gracefully with a
friendly Arabic message, never crash, never corrupt data, and recover instantly
once connectivity is back.
"""

from decimal import Decimal
from types import SimpleNamespace

from openai import APIError
from sqlalchemy import select

from app.domain.entities.finance_entities import BankAccount

from tests.acceptance.conftest import assert_no_technical_leak, make_ctx
from tests.acceptance.mock_openai import final_content, tool_call


def _offline_error():
    return APIError(message="connection reset", request=None, body=None)


async def _balance(db, name):
    result = await db.execute(select(BankAccount).where(BankAccount.account_name == name))
    return result.scalars().first().balance


async def test_network_down_returns_friendly_message(make_agent, seed, openai_client):
    client = openai_client(script=[_offline_error()])
    agent = make_agent()
    resp = await agent.process("كم رصيدي؟", make_ctx(seed))

    assert "خطأً مؤقتاً" in resp.text
    assert resp.confidence == 0.0
    assert_no_technical_leak(resp.text)


async def test_offline_does_not_crash_repeatedly(make_agent, seed, openai_client):
    """Five consecutive offline calls — still healthy, still friendly."""
    agent = make_agent()
    for _ in range(5):
        openai_client(script=[_offline_error()])
        resp = await agent.process("اعرض معاملاتي", make_ctx(seed))
        assert "خطأً مؤقتاً" in resp.text
        assert_no_technical_leak(resp.text)


async def test_recovery_after_reconnect(make_agent, seed, openai_client, db):
    """Offline → friendly failure → connectivity restored → the SAME request
    succeeds and the DB is intact."""
    openai_client(script=[_offline_error()])
    agent = make_agent()
    first = await agent.process("كم رصيدي؟", make_ctx(seed))
    assert "خطأً مؤقتاً" in first.text

    # Connectivity restored: the request now completes against real data.
    client = openai_client(script=[final_content("رصيدك الحالي 1000 ريال في الراجحي.")])
    agent2 = make_agent()
    second = await agent2.process("كم رصيدي؟", make_ctx(seed))
    assert "1000" in second.text
    assert await _balance(db, "الراجحي") == Decimal("1000.00")
    assert_no_technical_leak(second.text)


async def test_offline_during_data_fetch_does_not_mutate(make_agent, seed, openai_client, db):
    """Data-fetch tools may run before the network drops; they never mutate."""
    client = openai_client(script=[
        tool_call("get_banking_data", {"include_transactions": True}),
        _offline_error(),
    ])
    agent = make_agent()
    resp = await agent.process("كم رصيدي؟", make_ctx(seed))

    assert "خطأً مؤقتاً" in resp.text
    assert_no_technical_leak(resp.text)
    assert await _balance(db, "الراجحي") == Decimal("1000.00")
    assert await _balance(db, "الأهلي") == Decimal("500.00")


async def test_session_state_survives_offline_period(make_agent, seed, openai_client, memory):
    """Memory of a task set before going offline survives the outage."""
    openai_client(script=[_offline_error()])
    agent = make_agent()
    await agent.process("أودع 100", make_ctx(seed))
    # The turn was persisted even though the answer could not be produced.
    turns = memory.get(str(seed["org_a"]))["turns"]
    assert any("أودع 100" in t.get("content", "") for t in turns)
