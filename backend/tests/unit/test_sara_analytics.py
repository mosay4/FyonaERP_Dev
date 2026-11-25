"""Sara Financial Analytics after Stage 6 (docs/PERSONAL_LOCAL_PLAN.md).

The analytics snapshot is computed on the phone from its own ledger
(personal_analytics.dart; its behaviour is pinned by the shared parity
fixture test/fixtures/personal_analytics_parity.json). The server keeps the
period windows, the FX conversion of per-currency nets and the prompt rules,
and has no code path that reads the Personal tables.

No network, no real DB.
"""
import inspect
import os
from uuid import uuid4

import pytest

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")
os.environ.setdefault("CELERY_BROKER_URL", "redis://localhost:6379/1")
os.environ.setdefault("CELERY_RESULT_BACKEND", "redis://localhost:6379/2")


def test_server_analytics_reads_no_personal_table():
    from app.domain.services import sara_analytics as mod
    assert not hasattr(mod, "build_financial_analytics")
    assert "personal_entities" not in inspect.getsource(mod)
    # Kept: shared windows + explicit conversion.
    assert callable(mod.resolve_period) and callable(mod.convert_net_totals)


def test_sara_service_has_no_personal_table_reads():
    from app.domain.services import sara_agent_service as mod
    from app.domain.services import sara_personal_device as device
    assert not hasattr(mod, "SaraContextBuilder")
    for tool in device.DEVICE_READ_TOOLS:
        assert not hasattr(mod.ToolExecutor, f"_exec_{tool}"), tool


@pytest.mark.asyncio
async def test_conversion_unavailable_without_rate_and_explicit_with_rate():
    from app.domain.services.sara_analytics import convert_net_totals
    nets = [{"currency_id": "SAR", "net": "100.00"}, {"currency_id": "USD", "net": "10.00"}]

    async def none(frm, to):
        return {}

    gone = await convert_net_totals(nets, "SAR", fx_get_rate=none)
    assert gone["status"] == "unavailable" and gone["missing_currencies"] == ["USD"]

    async def rate(frm, to):
        return {"rate": "3.75", "freshness": "fresh", "source": "test"}

    okay = await convert_net_totals(nets, "sar", fx_get_rate=rate)
    assert okay["status"] == "ok"
    assert {line["converted"] for line in okay["lines"]} == {"100.00", "37.50"}


def test_prompt_rules_cover_analytics_both_languages():
    from app.domain.services import sara_agent_service as mod
    from app.domain.models.agent_models import AgentContext
    intent = mod.IntentClassification(category="analysis", needs_data=True)
    ctx = AgentContext(user_id=str(uuid4()), user_name="ت",
                       account_type="personal", language="ar")
    ar = mod.build_dynamic_prompt(ctx, intent, {"analytics": {"meta": {}}})
    assert "0ب" in ar and "analytics" in ar
    assert "فصل العملات" in ar  # P0 currency rules intact
    ctx_en = AgentContext(user_id=str(uuid4()), user_name="t",
                          account_type="personal", language="en")
    en = mod.build_dynamic_prompt(ctx_en, intent, {"analytics": {"meta": {}}})
    assert "0b" in en and "analytics" in en
    assert "Currency separation" in en  # P0 currency rules intact
