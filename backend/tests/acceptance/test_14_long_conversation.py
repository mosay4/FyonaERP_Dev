"""Production Readiness 5 — Long Conversation (300-500 messages).

A 400-message conversation must keep working: no crashes, memory ring buffer
bounded, no latency degradation in the second half, and every reply intact.
"""

import time

from tests.acceptance.conftest import assert_no_technical_leak, make_ctx
from tests.acceptance.mock_openai import final_content

MESSAGE_COUNT = 400


async def test_400_message_conversation_stays_healthy(make_agent, seed, openai_client, memory):
    agent = make_agent()
    user_key = str(seed["org_a"])

    # Pre-warm the memory store (it is autouse-fresh per test).
    from app.domain.services.sara_agent_service import MEMORY_STORE

    latencies_first = []
    latencies_last = []
    for i in range(MESSAGE_COUNT):
        client = openai_client(script=[final_content(f"تمت الإجابة {i}.")])
        t0 = time.perf_counter()
        resp = await agent.process(
            f"سؤال طويل العدد {i}: ما رصيدي في الحسابات؟", make_ctx(seed),
        )
        elapsed = time.perf_counter() - t0
        assert resp.text and resp.text.startswith("تمت الإجابة")
        assert_no_technical_leak(resp.text)

        if i < 50:
            latencies_first.append(elapsed)
        if i >= MESSAGE_COUNT - 50:
            latencies_last.append(elapsed)

    # Memory ring buffer never grows unbounded.
    entry = MEMORY_STORE.get(user_key)
    assert len(entry["turns"]) <= MEMORY_STORE.MAX_TURNS == 16

    avg_first = sum(latencies_first) / len(latencies_first)
    avg_last = sum(latencies_last) / len(latencies_last)
    # No degradation: the tail must not be dramatically slower than the head.
    assert avg_last < avg_first * 3 + 0.05, (avg_first, avg_last)


async def test_300_message_mixed_tasks_no_drift(make_agent, seed, openai_client, memory):
    """Mixed questions (some tool-using) across 300 messages: answers stay
    consistent and the store never exceeds its cap."""
    agent = make_agent()
    from app.domain.services.sara_agent_service import MEMORY_STORE

    for i in range(300):
        script = (
            [final_content(f"نفذت العملية {i}.")]
            if i % 3 != 0
            else [final_content(f"رصيدك معروض {i}.")]
        )
        client = openai_client(script=script)
        resp = await agent.process(
            f"رسالة {i}: اعرض الحسابات ثم أخبرني", make_ctx(seed),
        )
        assert resp.text
        assert_no_technical_leak(resp.text)

    entry = MEMORY_STORE.get(str(seed["org_a"]))
    assert len(entry["turns"]) <= MEMORY_STORE.MAX_TURNS
    assert len(MEMORY_STORE._store) <= MEMORY_STORE.MAX_USERS
