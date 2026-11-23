"""Sara app-catalog tests: every section is known, openable and explained.

The product requirement: Sara must understand every request, know every
section/button/feature, open any route with the user's own permissions and
never fall back to a blanket "I'm only financial" refusal.
"""
import os

import pytest

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")


def test_catalog_covers_the_whole_app():
    from app.domain.services.knowledge_base import all_screens, all_routes

    screens = all_screens()
    routes = all_routes()
    assert len(screens) >= 80
    assert len(routes) >= 80
    assert all(r.startswith("/") for r in routes)
    # No duplicated routes — one canonical entry per screen.
    assert len(routes) == len([s for s in screens if s.get("route")])


def test_catalog_includes_key_sections_in_both_languages():
    from app.domain.services.knowledge_base import all_screens

    by_route = {s["route"]: s for s in all_screens()}
    for route in (
        "/personal/banks",
        "/personal/recurring",
        "/customers",
        "/pos",
        "/projects",
        "/reports",
        "/settings",
        "/subscription",
    ):
        assert route in by_route, f"missing route {route}"
        assert by_route[route]["name_ar"]
        assert by_route[route]["desc_ar"]
        assert by_route[route]["name_en"]
        assert by_route[route]["desc_en"]


def test_live_app_catalog_is_merged_into_the_prompt_map():
    from app.domain.services.knowledge_base import format_app_catalog_for_prompt

    base = format_app_catalog_for_prompt()
    assert "- البنوك (/personal/banks)" in base
    merged = format_app_catalog_for_prompt([
        {"route": "/brand-new-feature", "title": "ميزة جديدة", "summary": "أضافتها الإدارة"},
    ])
    assert "- ميزة جديدة (/brand-new-feature): أضافتها الإدارة" in merged


def test_knowledge_lookup_answers_extra_screens():
    from app.domain.services.knowledge_base import get_knowledge, search_knowledge

    pos = get_knowledge("نقطة البيع")
    assert pos.get("deep_link") == "/pos"
    results = search_knowledge("كيف أستخدم نقطة البيع؟", account_type="business")
    assert any(r.get("deep_link") == "/pos" for r in results)


def test_agent_knows_all_screens_and_routes():
    from app.domain.services import sara_agent_service as svc

    assert "نقطة البيع" in svc.KNOWN_SCREENS
    assert "المشاريع" in svc.KNOWN_SCREENS
    assert "/pos" in svc.KNOWN_ROUTES
    assert "/personal/banks" in svc.KNOWN_ROUTES

    tool = next(
        t for t in svc.APP_TOOLS
        if t["function"]["name"] == "open_app_screen"
    )
    assert "route" in tool["function"]["parameters"]["properties"]


def test_prompts_never_contain_the_blanket_refusal():
    from app.domain.models.agent_models import AgentContext, IntentClassification
    from app.domain.services import sara_agent_service as svc

    ctx = AgentContext(
        user_id="u1",
        user_name="User",
        account_type="personal",
        screen_catalog=[
            {"route": "/brand-new-feature", "title": "ميزة جديدة", "summary": "أضافتها الإدارة"},
        ],
    )
    intent = IntentClassification(category="general")
    prompt_ar = svc._build_prompt_ar(ctx, intent, {})
    assert "اعتذر باستمرار" not in prompt_ar
    assert "ممنوع تجاوب على أي سؤال خارج هالمجال" not in prompt_ar
    assert "لا ترفض" in prompt_ar
    assert "تشرح أي قسم أو زر" in prompt_ar

    ctx_en = AgentContext(user_id="u1", user_name="User", account_type="personal")
    prompt_en = svc._build_prompt_en(ctx_en, intent, {})
    assert "MUST NOT answer questions outside this scope" not in prompt_en
    assert "Never refuse questions about the app" in prompt_en
