"""Sara Unified Tool Contract (P2) — Python side.

The JSON file next to this module (``sara_tool_contract.v1.json``) is the
single source of truth. This module loads it and exposes:

- ``CONTRACT_VERSION`` — bumped only when the contract itself changes.
- ``PENDING_MUTATION_TOOLS`` — flutter-owned writes the agent loop must NOT
  execute server-side (returned as pending_tools for gateway-verified device
  execution). Single source: the agent loop imports this set.
- ``normalize_result`` — additive envelope guaranteeing the unified result
  keys (tool/success/verified/retryable/error_code) without reshaping data.

Nothing here changes gateway/currency/analytics/timezone/TTS/sync/payments.
"""
import json
import os
from typing import Any, Dict, List, Set

_CONTRACT_PATH = os.path.join(os.path.dirname(__file__), "sara_tool_contract.v1.json")

with open(_CONTRACT_PATH, encoding="utf-8") as _f:
    CONTRACT: Dict[str, Any] = json.load(_f)

CONTRACT_VERSION: str = CONTRACT["contract_version"]
GATEWAY_STATES: List[str] = list(CONTRACT["gateway_states"])

_TOOLS: Dict[str, Dict[str, Any]] = {
    t["tool_id"]: t for t in CONTRACT["tools"]
}

# Flutter-owned writes: the backend loop must pend them, never execute them.
# Exactly the LLM-callable mutation set (flutter-only writes without a backend
# schema — transfer/transaction deletes — can never be pended, so they stay
# out; the drift test pins this list). Budget/recurring deletes ARE pended:
# the device gateway executes them (contract declares gateway verification),
# so Sara can delete budgets and recurring transactions on request.
_PENDING_EXCLUDED = {
    "create_transfer", "delete_transaction",
}
PENDING_MUTATION_TOOLS: Set[str] = {
    tool_id for tool_id, t in _TOOLS.items()
    if t.get("owner") == "flutter" and t.get("category") == "write"
    and tool_id not in _PENDING_EXCLUDED
}

# Backend-executed tools (reads/analytics + the server-side transaction op).
BACKEND_EXECUTED_TOOLS: Set[str] = {
    tool_id for tool_id, t in _TOOLS.items()
    if t.get("owner") in ("backend", "dual")
}


def get_tool(tool_id: str) -> Dict[str, Any]:
    return _TOOLS.get(tool_id, {})


def tool_ids() -> List[str]:
    return list(_TOOLS)


def flutter_tools() -> Dict[str, Dict[str, Any]]:
    return {k: v for k, v in _TOOLS.items() if v.get("owner") in ("flutter", "dual")}


def normalize_result(tool: str, result: Any) -> Dict[str, Any]:
    """Additive unified envelope. Existing keys/data are never removed or
    reshaped; missing contract keys are defaulted so SaraChatPage and the
    LLM loop can rely on one shape."""
    if not isinstance(result, dict):
        result = {"data": result}
    out = dict(result)
    out.setdefault("tool", tool)
    success = out.get("success")
    if success is None:
        success = "error" not in out
        out["success"] = success
    # verified: only a confirmed write (or an error-free read payload)
    # counts — never claim success=true while unverified.
    out.setdefault("verified", bool(success))
    err = out.get("error")
    out["error_code"] = out.get("error_code") or (None if success else "TOOL_FAILED")
    if not success and err and not out.get("message"):
        out["message"] = str(err)
    # retryable unless the failure is a contract-level rejection.
    out.setdefault(
        "retryable",
        (not success) and out["error_code"] not in ("UNKNOWN_TOOL", "VALIDATION_ERROR"),
    )
    return out
