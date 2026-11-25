"""Sara Unified Tool Contract (P2, backend side).

The JSON contract is the single source of truth: APP_TOOLS schemas,
the pending set used by the agent loop, executors, result envelope and
gateway states must all match it. Any drift fails here — never silently.
"""
import os
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")
os.environ.setdefault("CELERY_BROKER_URL", "redis://localhost:6379/1")
os.environ.setdefault("CELERY_RESULT_BACKEND", "redis://localhost:6379/2")


def _contract_mod():
    from app.domain.services import sara_tool_contract as mod
    return mod


def _svc_mod():
    from app.domain.services import sara_agent_service as mod
    return mod


def test_contract_version_and_states_frozen():
    mod = _contract_mod()
    assert mod.CONTRACT_VERSION == "1.6.0"
    assert mod.CONTRACT["contract_version"] == "1.6.0"
    # Gateway states must never be renamed/redefined (P0 freeze).
    assert mod.GATEWAY_STATES == [
        "confirmed", "local_pending", "failed",
        "unverifiable", "not_found", "sync_failed",
    ]


def test_no_duplicate_tool_ids():
    mod = _contract_mod()
    ids = [t["tool_id"] for t in mod.CONTRACT["tools"]]
    assert len(ids) == len(set(ids))
    assert len(ids) >= 40


def test_every_app_tool_is_in_contract():
    smod = _svc_mod()
    cmod = _contract_mod()
    app_names = {t["function"]["name"] for t in smod.APP_TOOLS}
    contract_ids = set(cmod.tool_ids())
    assert app_names <= contract_ids, app_names - contract_ids


def test_pending_set_is_single_sourced_and_stable():
    smod = _svc_mod()
    cmod = _contract_mod()
    # The exact 24 LLM-callable mutations the loop pends (P2 adds 3 recurring + 4 currency/rate;
    # Sara delete support adds delete_budget + delete_recurring, gateway-executed on device).
    expected = {
        "create_savings_goal", "update_savings_goal", "contribute_to_goal",
        "delete_savings_goal", "create_debt", "update_debt", "pay_debt",
        "delete_debt", "create_bank_account", "update_bank_account",
        "delete_bank_account", "create_budget", "update_budget", "delete_budget",
        "create_recurring", "update_recurring", "delete_recurring",
        "execute_recurring_now", "activate_recurring", "deactivate_recurring",
        "add_currency", "delete_currency", "add_exchange_rate", "update_exchange_rate",
        # Round 15: whole-bank delete + recurring skip/postpone (screen parity).
        "delete_bank", "skip_recurring", "postpone_recurring",
    }
    assert cmod.PENDING_MUTATION_TOOLS == expected
    # And the agent loop consumes the contract set (no second hardcoded list).
    import inspect
    src = inspect.getsource(smod.SaraAgentService.process)
    assert "PENDING_MUTATION_TOOLS" in src
    assert '"create_savings_goal", "update_savings_goal"' not in src


def _backend_schema(name):
    smod = _svc_mod()
    for t in smod.APP_TOOLS:
        if t["function"]["name"] == name:
            fn = t["function"]
            props = fn["parameters"]["properties"]
            return (set(fn["parameters"].get("required", [])),
                    set(props.keys()))
    raise AssertionError(f"missing APP_TOOL {name}")


def test_pended_schemas_match_flutter_contract():
    # Backend LLM schemas for pended tools must carry executable params
    # (registry names + requiredness) — otherwise the device silently drops
    # them at checkCompletion.
    cmod = _contract_mod()
    for tool_id in cmod.PENDING_MUTATION_TOOLS:
        entry = cmod.get_tool(tool_id)
        req, _ = _backend_schema(tool_id)
        assert req == set(entry["required"]), tool_id
    # Spot-check the three P2 alignment fixes.
    req, _ = _backend_schema("create_debt")
    assert req == {"person_name", "amount", "debt_type"}
    req, opts = _backend_schema("update_debt")
    assert req == {"debt_id"} and "person_name" in opts
    assert "name" not in opts
    req, _ = _backend_schema("create_bank_account")
    assert req == {"bank_name", "currency"}


def test_backend_executed_tools_all_have_handlers():
    smod = _svc_mod()
    cmod = _contract_mod()
    inline_actions = {"open_app_screen", "open_entity", "show_suggestions",
                      "create_entity", "export_report", "ask_clarification",
                      "get_app_help"}
    for tool_id in cmod.BACKEND_EXECUTED_TOOLS:
        entry = cmod.get_tool(tool_id)
        if entry.get("owner") == "dual" and tool_id != "create_transaction":
            continue
        if tool_id in inline_actions:
            continue
        assert hasattr(smod.ToolExecutor, f"_exec_{tool_id}"), tool_id


def test_result_envelope_is_additive_and_unified():
    cmod = _contract_mod()
    out = cmod.normalize_result("get_balance", {"accounts": []})
    assert out["tool"] == "get_balance"
    assert out["success"] is True and out["verified"] is True
    assert out["accounts"] == []  # data preserved, never reshaped
    err = cmod.normalize_result("nope", {"error": "Unknown tool: nope"})
    assert err["success"] is False
    assert err["error_code"] == "TOOL_FAILED"
    assert err["retryable"] is True
    assert err["tool"] == "nope"
    unk = cmod.normalize_result("nope", {"error_code": "UNKNOWN_TOOL",
                                         "error": "x", "success": False})
    assert unk["retryable"] is False


def test_create_transaction_dual_schemas_declared():
    cmod = _contract_mod()
    entry = cmod.get_tool("create_transaction")
    assert entry["owner"] == "dual"
    assert set(entry["required"]) == {"type", "amount", "category"}
    assert set(entry["backend_required"]) == {"operation", "amount"}
    assert {"bank_account_id", "currency"} <= set(entry["backend_optional"])
    assert entry["idempotency"] == "opkey"
    # Backend schema must actually expose the binding params.
    _, opts = _backend_schema("create_transaction")
    assert {"bank_account_id", "currency"} <= opts


def _rows(all_list):
    m = MagicMock()
    m.all.return_value = all_list
    sc = MagicMock()
    sc.all.return_value = all_list
    m.scalars.return_value = sc
    m.scalar_one_or_none.return_value = None
    return m


@pytest.mark.asyncio
async def test_backend_create_is_idempotent_on_retry():
    smod = _svc_mod()
    svc = smod.ToolExecutor(AsyncMock(), uuid4(), uuid4(), lang="ar")
    svc._verify_tx = AsyncMock(return_value=True)

    acc = MagicMock()
    acc.id = uuid4()
    acc.bank_name = "الراجحي"
    acc.currency = "SAR"
    acc.balance = __import__("decimal").Decimal("1000")
    acc.is_deleted = False

    def accounts_result():
        m = MagicMock()
        sc = MagicMock()
        sc.all.return_value = [acc]
        m.scalars.return_value = sc
        return m

    args = {"operation": "deposit", "amount": 100,
            "account_name": "الراجحي", "description": "راتب"}

    # First call: no duplicate → writes once.
    db1 = AsyncMock()
    empty_dup = MagicMock()
    empty_dup.scalar_one_or_none.return_value = None
    db1.execute.side_effect = [empty_dup, accounts_result()]
    db1.add = MagicMock()
    db1.flush = AsyncMock()
    svc._db = db1
    out1 = await svc._exec_create_transaction(dict(args))
    assert out1.get("success") is True
    assert out1.get("deduped") is None
    assert db1.add.called

    # Retry with identical args: same op key → original returned, no write.
    existing_id = uuid4()
    db2 = AsyncMock()
    dup = MagicMock()
    dup.scalar_one_or_none.return_value = existing_id
    db2.execute.side_effect = [dup]
    db2.add = MagicMock()
    db2.flush = AsyncMock()
    svc._db = db2
    out2 = await svc._exec_create_transaction(dict(args))
    assert out2.get("success") is True
    assert out2.get("deduped") is True
    assert not db2.add.called
