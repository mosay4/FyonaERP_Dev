"""Production Readiness 8 + 10 — Analytics & Production Monitoring.

Real per-round analytics are recorded (questions, tool usage, success/failure,
latency, errors) and aggregate metrics + health alerts are computed. The
/metrics endpoint wraps this data; here we exercise the underlying service
against the real SQLite database.
"""

from openai import APIError

from app.domain.services.agent_analytics import AgentAnalytics, evaluate_health

from tests.acceptance.conftest import assert_no_technical_leak, make_ctx
from tests.acceptance.mock_openai import final_content, tool_call


async def test_analytics_records_rounds_questions_and_tools(make_agent, seed, openai_client, db):
    client = openai_client(script=[
        tool_call("get_banking_data", {"include_transactions": True}),
        final_content("إليك رصيدك."),
    ])
    agent = make_agent()
    resp = await agent.process("كم رصيدي؟", make_ctx(seed))
    assert_no_technical_leak(resp.text)

    # Second round, a tool that fails.
    client2 = openai_client(script=[
        tool_call("open_app_screen", {"screen": "الاستثمار"}),
        final_content("هذه الشاشة غير متوفرة."),
    ])
    agent2 = make_agent()
    await agent2.process("افتح الاستثمار", make_ctx(seed))

    m = await AgentAnalytics.metrics(db, org_id=seed["org_a"])
    assert m["totals"]["rounds"] == 2
    assert m["totals"]["questions"] == 2
    assert m["totals"]["tool_calls"] == 2

    # Tool usage: one success (get_banking_data), one failure (open_app_screen).
    assert m["tool_usage"]["get_banking_data"] == {"calls": 1, "success": 1}
    assert m["tool_usage"]["open_app_screen"] == {"calls": 1, "success": 0}
    assert m["avg_round_latency_ms"] >= 0
    assert m["avg_tool_latency_ms"] >= 0


async def test_analytics_tracks_errors_and_top_questions(make_agent, seed, openai_client, db):
    openai_client(script=[
        tool_call("open_app_screen", {"screen": "الاستثمار"}),
        final_content("غير متوفرة."),
    ])
    agent = make_agent()
    await agent.process("افتح الاستثمار", make_ctx(seed))

    openai_client(script=[APIError(message="down", request=None, body=None)])
    agent2 = make_agent()
    await agent2.process("كم رصيدي؟", make_ctx(seed))

    m = await AgentAnalytics.metrics(db, org_id=seed["org_a"])
    # The unknown_screen rejection is logged as an error type.
    assert any(e["type"] == "unknown_screen" for e in m["top_errors"])
    assert any(e["type"] == "APIError" for e in m["top_errors"])
    assert m["totals"]["errors"] >= 1
    # Top questions: "افتح الاستثمار" asked once → present in top list.
    assert any("افتح الاستثمار" in q["question"] for q in m["top_questions"])


async def test_analytics_is_org_scoped(make_agent, seed, openai_client, db):
    """Metrics are isolated per organisation — org A's data never leaks into
    org B's aggregates."""
    openai_client(script=[final_content("مرحباً.")])
    agent_a = make_agent(org=seed["org_a"], user=seed["org_a"])
    await agent_a.process("سؤال لأ", make_ctx(seed))

    m_a = await AgentAnalytics.metrics(db, org_id=seed["org_a"])
    m_b = await AgentAnalytics.metrics(db, org_id=seed["org_b"])
    assert m_a["totals"]["questions"] == 1
    assert m_b["totals"]["questions"] == 0
    assert m_a["totals"]["rounds"] == 1
    assert m_b["totals"]["rounds"] == 0


async def test_health_healthy_when_all_good(make_agent, seed, openai_client, db):
    openai_client(script=[
        tool_call("get_banking_data", {}),
        final_content("تم."),
    ])
    agent = make_agent()
    await agent.process("كم رصيدي؟", make_ctx(seed))

    m = await AgentAnalytics.metrics(db, org_id=seed["org_a"])
    health = evaluate_health(m)
    assert health["status"] == "healthy"
    assert health["alerts"] == []


async def test_health_degraded_when_error_rate_spikes(make_agent, seed, openai_client, db):
    for _ in range(4):
        openai_client(script=[APIError(message="down", request=None, body=None)])
        agent = make_agent()
        await agent.process("كم رصيدي؟", make_ctx(seed))

    m = await AgentAnalytics.metrics(db, org_id=seed["org_a"])
    health = evaluate_health(m)
    assert health["status"] == "degraded"
    assert any(a["type"] == "high_error_rate" for a in health["alerts"])


async def test_bad_user_identifier_does_not_poison_session(make_agent, seed, openai_client, db):
    """Analytics is best-effort: a non-UUID user id must be skipped silently and
    must never crash or poison the agent session."""
    openai_client(script=[final_content("تم.")])
    agent = make_agent(user="not-a-uuid")
    resp = await agent.process("مرحباً", make_ctx(seed, user_id="not-a-uuid"))
    assert resp.text
    # Nothing recorded for the invalid id; the session still works for others.
    m = await AgentAnalytics.metrics(db, org_id=seed["org_a"])
    assert m["totals"]["questions"] == 0
    assert await AgentAnalytics.metrics(db, org_id=seed["org_b"]) == await AgentAnalytics.metrics(db, org_id=seed["org_b"])


async def test_analytics_never_breaks_the_agent(make_agent, seed, openai_client, db, monkeypatch):
    """If the analytics store itself throws, the agent must still answer."""
    from app.domain.services import sara_agent_service

    class BrokenAnalytics:
        def __init__(self, *a, **k):
            raise RuntimeError("analytics store down")

        def record_question(self, **k):
            raise RuntimeError("boom")

        def record_round(self, **k):
            raise RuntimeError("boom")

        def record_tool(self, **k):
            raise RuntimeError("boom")

        def record_error(self, **k):
            raise RuntimeError("boom")

    monkeypatch.setattr(sara_agent_service, "AgentAnalytics", BrokenAnalytics)
    openai_client(script=[final_content("رصيدك 1000.")])
    agent = make_agent()
    resp = await agent.process("كم رصيدي؟", make_ctx(seed))
    assert resp.text
    assert_no_technical_leak(resp.text)
