"""Acceptance Test 3 — Deep Navigation.

The backend must emit open_entity actions carrying the *exact* entity identity
(name and/or id), not just a generic screen — so Flutter can deep-link to the
specific item. Route resolution itself is verified in the Flutter suite.
"""

import pytest

from tests.acceptance.mock_openai import final_content, tool_call
from tests.acceptance.conftest import assert_no_technical_leak, make_ctx


DEEP_NAV_CASES = [
    # entity_type, name, id, expected action params
    ("bank", "الراجحي", None),
    ("goal", "سيارة", "goal-123"),
    ("customer", "شركة النور", "cust-456"),
    ("invoice", "فاتورة 2024-001", "inv-789"),
    ("product", "منتج أ", "prod-111"),
    ("transaction", "إيداع اختبار", "tx-222"),
    ("expense", "عشاء", "exp-333"),
    ("recurring", "إيجار", "rec-444"),
]


async def test_open_entity_actions_carry_exact_identity(make_agent, seed, openai_client):
    agent = make_agent()
    for entity_type, name, entity_id in DEEP_NAV_CASES:
        args = {"entity_type": entity_type}
        if name:
            args["name"] = name
        if entity_id:
            args["id"] = entity_id

        client = openai_client(script=[
            tool_call("open_entity", args),
            final_content(f"فتحت {name}"),
        ])
        resp = await agent.process(f"افتح {name}", make_ctx(seed))

        assert len(resp.actions) == 1, f"expected one action for {entity_type}"
        action = resp.actions[0]
        assert action.action == "open_entity"
        assert action.params == args, f"identity lost for {entity_type}: {action.params}"
        assert action.label and name in action.label, f"label missing name for {entity_type}"
        assert_no_technical_leak(resp.text)


async def test_open_app_screen_for_reports(make_agent, seed, openai_client):
    client = openai_client(script=[
        tool_call("open_app_screen", {"screen": "التقارير"}),
        final_content("فتحت شاشة **التقارير**."),
    ])
    agent = make_agent()
    resp = await agent.process("افتح التقارير", make_ctx(seed))
    assert resp.actions[0].action == "open_screen"
    assert resp.actions[0].params == {"screen": "التقارير"}


async def test_open_entity_without_identity_still_navigates_to_section(
    make_agent, seed, openai_client
):
    """If the model only knows the type (no name/id), the action still flows and
    Flutter falls back to the section list page."""
    client = openai_client(script=[
        tool_call("open_entity", {"entity_type": "customer"}),
        final_content("فتحت العملاء."),
    ])
    agent = make_agent()
    resp = await agent.process("افتح العملاء", make_ctx(seed))
    assert resp.actions[0].action == "open_entity"
    assert resp.actions[0].params == {"entity_type": "customer"}


async def test_deep_nav_after_data_fetch_uses_real_identity(make_agent, seed, openai_client):
    """Model observes the real customer, then deep-opens that exact customer."""
    def observe(messages):
        result = next(
            m["content"] for m in reversed(messages) if m.get("role") == "tool"
        )
        assert "شركة النور" in result
        return tool_call("open_entity", {"entity_type": "customer", "name": "شركة النور"})

    client = openai_client(script=[
        tool_call("get_customer_data", {}),
        observe,
        final_content("ها هو العميل: **شركة النور**."),
    ])
    agent = make_agent()
    resp = await agent.process("ابحث عن عميل وافتحه", make_ctx(seed))
    assert resp.actions[-1].params == {"entity_type": "customer", "name": "شركة النور"}
