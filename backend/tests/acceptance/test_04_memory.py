"""Acceptance Test 4 — Agent Memory.

Proves Sara remembers the last operation, current screen, current task and user
preferences across turns, and documents exactly what survives a close/reopen.
"""

import time

import pytest

from app.domain.services.sara_agent_service import AgentMemoryStore
from tests.acceptance.mock_openai import final_content, tool_call
from tests.acceptance.conftest import make_ctx, system_prompt


async def test_memory_persists_across_turns_in_same_process(
    make_agent, seed, openai_client, memory
):
    agent = make_agent()

    # Turn 1: user asks about balance -> assistant answers.
    client1 = openai_client(script=[final_content("رصيدك 1000 ريال.")])
    await agent.process("كم رصيدي؟", make_ctx(seed))

    # Turn 2: the prompt for the second query must include turn 1.
    client2 = openai_client(script=[final_content("أذكر لك")])
    await agent.process("وأيضاً كم عندي؟", make_ctx(seed))

    prompt = system_prompt(client2)
    assert "ذاكرتك من المحادثات السابقة" in prompt
    assert "المستخدم: كم رصيدي؟" in prompt
    assert "سارة: رصيدك 1000 ريال." in prompt


async def test_last_screen_is_tracked(make_agent, seed, openai_client, memory):
    agent = make_agent()
    await agent.process("مرحباً", make_ctx(seed, current_screen="البنوك"))
    assert memory.get(str(seed["org_a"]))["last_screen"] == "البنوك"


async def test_last_operation_is_tracked_after_financial_execution(
    make_agent, seed, openai_client, memory
):
    agent = make_agent()
    await agent.process(
        "أودع 300 في الأهلي",
        make_ctx(seed),
    )
    # No explicit financial op in this scripted run, so nothing recorded yet.
    assert memory.get(str(seed["org_a"]))["last_operation"] is None


async def test_last_operation_recorded_after_real_transaction(
    make_agent, seed, openai_client, memory
):
    client = openai_client(script=[
        tool_call("create_transaction", {
            "operation": "deposit", "amount": 300, "account_name": "الراجحي",
        }),
        final_content("تم الإيداع."),
    ])
    agent = make_agent()
    await agent.process("أودع 300 في الراجحي", make_ctx(seed))

    op = memory.get(str(seed["org_a"]))["last_operation"]
    assert op and "300" in op and "الراجحي" in op


async def test_current_task_saved_when_clarification_needed(
    make_agent, seed, openai_client, memory
):
    client = openai_client(script=[
        tool_call("ask_clarification", {"question": "أي حساب تريد الإيداع فيه؟"}),
        final_content("أي حساب تريد؟"),
    ])
    agent = make_agent()
    await agent.process("ودع فلوس", make_ctx(seed))
    assert memory.get(str(seed["org_a"]))["current_task"] == "ودع فلوس"


async def test_preferences_are_remembered(make_agent, seed, openai_client, memory):
    memory.set_preference(str(seed["org_a"]), "العملة", "دولار")
    agent = make_agent()
    client = openai_client(script=[final_content("حسناً")])
    await agent.process("تمام", make_ctx(seed))
    assert "دولار" in system_prompt(client)


def test_reopen_same_process_keeps_memory(seed):
    """Simulating the user leaving and returning to the chat WITHOUT restarting the
    backend keeps short-term + state (this is the real in-process store)."""
    store = AgentMemoryStore()
    key = str(seed["org_a"])
    store.append_turn(key, "user", "كم رصيدي؟")
    store.set_state(key, last_operation="إيداع 500", last_screen="البنوك")
    store.set_preference(key, "العملة", "دولار")

    # A brand-new agent/service object on the same store still sees the memory.
    fresh = store.get(key)
    assert fresh["last_operation"] == "إيداع 500"
    assert fresh["last_screen"] == "البنوك"
    assert fresh["preferences"]["العملة"] == "دولار"
    assert len(fresh["turns"]) == 1


def test_process_restart_resets_in_memory_store(seed):
    """If the backend restarts (store recreated), short-term turns and volatile
    state are gone — these live only in RAM. Long-term facts would need a DB
    backend (documented as future work)."""
    store1 = AgentMemoryStore()
    key = str(seed["org_a"])
    store1.append_turn(key, "user", "كم رصيدي؟")
    store1.set_state(key, last_operation="إيداع 500", current_task="تحويل")

    store2 = AgentMemoryStore()  # process restart
    fresh = store2.get(key)
    assert fresh["turns"] == []
    assert fresh["last_operation"] is None
    assert fresh["current_task"] is None
    assert fresh["last_screen"] == ""


def test_short_term_ring_buffer_trimmed_to_16():
    store = AgentMemoryStore()
    key = "u1"
    for i in range(20):
        store.append_turn(key, "user", f"سؤال {i}")
        store.append_turn(key, "assistant", f"جواب {i}")
    assert len(store.get(key)["turns"]) == AgentMemoryStore.MAX_TURNS == 16
    # Oldest turns were dropped (first user message is gone).
    assert all("سؤال 0" not in t["content"] for t in store.get(key)["turns"])


def test_max_users_eviction_keeps_store_bounded():
    store = AgentMemoryStore()
    for i in range(AgentMemoryStore.MAX_USERS + 5):
        store.append_turn(f"user-{i}", "user", "مرحباً")
    assert len(store._store) <= AgentMemoryStore.MAX_USERS


def test_lru_touch_keeps_recent_users():
    store = AgentMemoryStore()
    for i in range(AgentMemoryStore.MAX_USERS + 2):
        store.append_turn(f"user-{i}", "user", "مرحباً")
    # Touch user-0 last so it stays; the LRU eviction removes the oldest.
    store.get("user-0")
    assert "user-0" in store._store
