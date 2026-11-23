"""Acceptance Test 8 — Performance.

Measures average response latency, rounds per task, per-tool execution time,
memory usage and (as a network proxy) the number of model round-trips.
"""

import time
import tracemalloc

import pytest

from app.domain.services.sara_agent_service import ToolExecutor
from tests.acceptance.mock_openai import final_content, tool_call
from tests.acceptance.conftest import make_ctx


async def test_average_response_time_single_round(make_agent, seed, openai_client):
    client = openai_client(script=[final_content("رد سريع.")])
    agent = make_agent()

    latencies = []
    for _ in range(50):
        t0 = time.perf_counter()
        resp = await agent.process("مرحباً", make_ctx(seed))
        latencies.append((time.perf_counter() - t0) * 1000)
        assert resp.text

    avg = sum(latencies) / len(latencies)
    # With a mock transport, a round should complete in well under 1s.
    assert avg < 1000, f"avg latency too high: {avg:.1f} ms"
    assert max(latencies) < 2000, f"max latency too high: {max(latencies):.1f} ms"


async def test_rounds_per_task_type(make_agent, seed, openai_client):
    agent = make_agent()

    # Single-step: 1 tool round + final = 2 model calls.
    c1 = openai_client(script=[
        tool_call("get_banking_data", {}),
        final_content("تم."),
    ])
    await agent.process("رصيدي؟", make_ctx(seed))
    assert len(c1.chat.completions.calls) == 2

    # Multi-step: 3 tool rounds + final = 4 model calls.
    c2 = openai_client(script=[
        tool_call("get_customer_data", {}),
        tool_call("open_entity", {"entity_type": "customer", "name": "شركة النور"}),
        tool_call("show_suggestions", {"suggestions": ["افتح العملاء"]}),
        final_content("تم."),
    ])
    await agent.process("اعرض العملاء ثم افتح الأول", make_ctx(seed))
    assert len(c2.chat.completions.calls) == 4

    # Simple Q&A with no tools: 1 model call.
    c3 = openai_client(script=[final_content("أهلاً.")])
    await agent.process("أهلاً", make_ctx(seed))
    assert len(c3.chat.completions.calls) == 1


async def test_network_proxy_matches_rounds(make_agent, seed, openai_client):
    """Each round = one network request to the model (proxy for traffic)."""
    client = openai_client(script=[
        tool_call("get_banking_data", {}),
        final_content("تم."),
    ])
    agent = make_agent()
    await agent.process("رصيدي؟", make_ctx(seed))
    assert len(client.chat.completions.calls) == 2


async def test_tool_execution_timing_all_data_tools(db, seed):
    executor = ToolExecutor(db, seed["org_a"])
    cases = [
        ("get_banking_data", {"include_transactions": True}),
        ("get_financial_summary", {"period": "this_month"}),
        ("get_customer_data", {}),
        ("get_inventory_data", {}),
        ("get_sales_data", {"period": "this_month"}),
        ("get_expenses_data", {"period": "this_year"}),
        ("search_all_transactions", {"query": "ر"}),
    ]
    for tool, args in cases:
        t0 = time.perf_counter()
        result = await executor.execute(tool, args)
        elapsed = (time.perf_counter() - t0) * 1000
        assert isinstance(result, dict), tool
        assert not result.get("error"), f"{tool} errored: {result}"
        assert elapsed < 200, f"{tool} took {elapsed:.1f} ms"


async def test_memory_usage_bounded(make_agent, seed, openai_client):
    openai_client(script=[final_content("رد.")])
    agent = make_agent()

    tracemalloc.start()
    try:
        for _ in range(100):
            await agent.process("مرحباً", make_ctx(seed))
        current, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()

    # 100 sequential turns must not blow up memory (bounded by the ring buffer).
    assert peak - current < 20 * 1024 * 1024, f"memory growth too high: {peak - current} bytes"


async def test_tool_roundtrip_includes_real_data_quickly(make_agent, seed, openai_client):
    t0 = time.perf_counter()
    client = openai_client(script=[
        tool_call("get_expenses_data", {"period": "this_year"}),
        final_content("تم."),
    ])
    agent = make_agent()
    resp = await agent.process("عطني مصاريف السنة", make_ctx(seed))
    elapsed_ms = (time.perf_counter() - t0) * 1000
    assert resp.text
    assert elapsed_ms < 2000
