"""Production Readiness 2 — Hallucination Defense.

When asked about a feature that does not exist (investment page, crypto wallet,
credit cards...), Sara must say it is unavailable — never invent a page or a
route. The agent loop has a real server-side guard: `open_app_screen` and
`open_entity` only accept screens / entity types the app ships.
"""

from tests.acceptance.conftest import assert_no_technical_leak, make_ctx
from tests.acceptance.mock_openai import final_content, tool_call

NONEXISTENT_FEATURES = [
    "افتح صفحة الاستثمار",
    "أرني شاشة الأسهم",
    "أنشئ محفظة عملات رقمية",
    "افتح صفحة البطاقات الائتمانية",
    "اعرض لي شاشة تداول الذهب",
]


async def test_nonexistent_feature_is_honestly_unavailable(make_agent, seed, openai_client):
    for question in NONEXISTENT_FEATURES:
        client = openai_client(script=[
            final_content("هذه الميزة غير متوفرة حالياً في التطبيق."),
        ])
        agent = make_agent()
        resp = await agent.process(question, make_ctx(seed))

        assert resp.text
        assert resp.actions == []  # no fabricated navigation action
        assert_no_technical_leak(resp.text)


async def test_model_cannot_navigate_to_unknown_screen(make_agent, seed, openai_client):
    """Even if the model hallucinates an open_app_screen call for a page that
    does not exist, the agent loop rejects it (unknown_screen) instead of
    emitting a navigation action."""
    client = openai_client(script=[
        tool_call("open_app_screen", {"screen": "الاستثمار"}),
        final_content("عذراً، شاشة الاستثمار غير متوفرة في التطبيق حالياً."),
    ])
    agent = make_agent()
    resp = await agent.process("افتح صفحة الاستثمار", make_ctx(seed))

    # The hallucinated screen was NOT turned into a navigation action.
    assert all(a.action != "open_screen" for a in resp.actions)
    assert_no_technical_leak(resp.text)
    # The rejection was fed back to the model (Observe → Reflect).
    assert any(
        "شاشة غير معروفة" in m.get("content", "")
        for msgs in client.chat.completions.calls for m in msgs
        if m.get("role") == "tool"
    )


async def test_model_cannot_open_unknown_entity_type(make_agent, seed, openai_client):
    client = openai_client(script=[
        tool_call("open_entity", {"entity_type": "investment", "name": "صندوق"}),
        final_content("لا يوجد نوع عنصر بهذا الاسم في التطبيق."),
    ])
    agent = make_agent()
    resp = await agent.process("افتح صندوق الاستثمار", make_ctx(seed))

    assert all(a.action != "open_entity" for a in resp.actions)
    assert_no_technical_leak(resp.text)
    assert any(
        "نوع عنصر غير معروف" in m.get("content", "")
        for msgs in client.chat.completions.calls for m in msgs
        if m.get("role") == "tool"
    )


async def test_known_screen_still_navigates(make_agent, seed, openai_client):
    """Regression guard: real screens must keep working."""
    client = openai_client(script=[
        tool_call("open_app_screen", {"screen": "البنوك"}),
        final_content("تم فتح شاشة **البنوك**."),
    ])
    agent = make_agent()
    resp = await agent.process("افتح البنوك", make_ctx(seed))

    assert resp.actions[0].action == "open_screen"
    assert resp.actions[0].params == {"screen": "البنوك"}
