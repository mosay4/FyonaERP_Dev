"""Personal Sara never promises a screen button without attaching it.

Regression (owner, Personal, Arabic): «رسلي لي زر التقارير هنا» asked a
second time got «الزر تحت جاهز — اضغط عليه ويوديك مباشرة لـ التقارير.» with
no action. The loop now derives the open_screen action from the words.
"""
import os

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")
os.environ.setdefault("CELERY_BROKER_URL", "redis://localhost:6379/1")
os.environ.setdefault("CELERY_RESULT_BACKEND", "redis://localhost:6379/2")

from app.domain.services.sara_screen_links import (  # noqa: E402
    missing_open_action, screen_from_text,
)


def test_reply_promising_button_without_action_gets_reports_link():
    out = missing_open_action(
        "رسلي لي زر التقارير هنا",
        "الزر تحت جاهز — اضغط عليه ويوديك مباشرة لـ التقارير.",
        [],
    )
    assert out == {"screen": "التقارير", "screen_en": "Reports", "route": "/personal/reports"}


def test_existing_navigation_action_is_kept_as_is():
    assert missing_open_action("افتح التقارير", "تفضل", [{"action": "open_screen"}]) is None
    assert missing_open_action("صدر تقرير PDF", "اضغط الزر", [{"action": "export_pdf"}]) is None


def test_no_screen_request_no_link():
    assert missing_open_action("كم رصيدي؟", "رصيدك 500 ريال سعودي", []) is None


def test_dialect_words_are_not_misread():
    # «وديني» contains «دين» — must still be the reports screen.
    assert screen_from_text("وديني للتقارير")[2] == "/personal/reports"
    assert screen_from_text("افتح البنوك")[2] == "/personal/banks"
    assert screen_from_text("ابي الاشتراكات المتكررة")[2] == "/personal/recurring"
    assert screen_from_text("زر الميزانيات")[2] == "/personal/budget"
    assert screen_from_text("open my goals")[2] == "/personal/savings"


def test_agent_loop_attaches_the_missing_action():
    import inspect
    from app.domain.services import sara_agent_service as smod
    # The loop lives in _run (process prepares it; device mode resumes it).
    src = inspect.getsource(smod.SaraAgentService.process) + inspect.getsource(smod.SaraAgentService._run)
    assert "missing_open_action(query, answer, actions)" in src
    assert "SCREEN_BUTTON_RULE_AR" in src


def test_new_personal_tools_are_exposed_and_pended():
    from app.domain.services import sara_agent_service as smod
    from app.domain.services.sara_tool_contract import PENDING_MUTATION_TOOLS
    names = {t["function"]["name"] for t in smod.APP_TOOLS}
    for tool in ("delete_bank", "skip_recurring", "postpone_recurring"):
        assert tool in names and tool in PENDING_MUTATION_TOOLS, tool
    export = next(t for t in smod.APP_TOOLS if t["function"]["name"] == "export_report")
    assert "kind" in export["function"]["parameters"]["properties"]
    run_now = next(t for t in smod.APP_TOOLS if t["function"]["name"] == "execute_recurring_now")
    assert {"bank_account_id", "currency"} <= set(run_now["function"]["parameters"]["properties"])
