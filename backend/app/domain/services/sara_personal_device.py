"""Personal Sara device mode (Stage 5 of docs/PERSONAL_LOCAL_PLAN.md).

The user's Personal ledger lives only on their devices. When the app sends
``x-fyona-device-sara: personal`` the server never reads a Personal table
for Sara: every Personal read (the prompt context and the read tools) is
turned into a ``device_call`` the phone answers from its own ledger, and the
conversation resumes in ``POST /ai/continue``. The server keeps nothing: the
paused conversation travels to the phone inside a signed ``state`` and comes
back with the answers.

Device call: ``{"id", "method": "TOOL", "path": <tool name>, "params"}``.
Period-based reads carry ``params.bounds`` (UTC edges resolved here from the
user's timezone), so the phone and the server use the same window.
Public exchange rates (get_exchange_rate) stay server-side.
"""
import base64
import hashlib
import hmac
import json
import time
from datetime import datetime
from typing import Any, Dict, List, Optional

DEVICE_HEADER = "x-fyona-device-sara"
DEVICE_VALUE = "personal"

# A tool result above this is refused (same limit as Business Sara).
RESULT_LIMIT = 40000
STATE_LIMIT = 2_000_000
STATE_TTL_SECONDS = 15 * 60

# Personal read tools answered by the phone. Every name the server knows as
# a Personal read (offered to the model or not) is listed, so none can ever
# fall back to a server table in device mode.
DEVICE_READ_TOOLS = {
    "get_banking_data", "get_financial_summary", "get_sales_data",
    "get_financial_analytics", "get_expenses_data", "search_all_transactions",
    "get_bank_accounts", "get_savings_goals", "get_debts", "get_budgets",
    "get_recurring", "search_entity", "get_entity_detail", "get_debt_payments",
    "get_currencies", "get_categories", "get_balance", "get_transactions",
    "get_operation_status",
}
# Reads whose window is a period (resolved here, in the user's timezone).
PERIOD_TOOLS = {"get_financial_summary", "get_sales_data", "get_expenses_data",
                "get_financial_analytics"}


def is_device_request(request) -> bool:
    try:
        return (request.headers.get(DEVICE_HEADER) or "").strip().lower() == DEVICE_VALUE
    except Exception:
        return False


def bounds_for(period: Optional[str], tz_name: str, custom_start=None,
               custom_end=None, now=None) -> Dict[str, str]:
    from app.domain.services.sara_analytics import resolve_period
    start, end, prev_start, prev_end, label = resolve_period(
        period, custom_start, custom_end, now, tz_name)
    return {"period": label, "start": start.isoformat(), "end": end.isoformat(),
            "prev_start": prev_start.isoformat(), "prev_end": prev_end.isoformat(),
            "timezone": tz_name}


def _custom_dates(args: dict):
    start = end = None
    if (args.get("period") or "") == "custom":
        try:
            if args.get("from_date"):
                start = datetime.fromisoformat(str(args["from_date"]))
            if args.get("to_date"):
                end = datetime.fromisoformat(str(args["to_date"]))
        except (ValueError, TypeError):
            start = end = None
    return start, end


def device_call(call_id: str, tool: str, args: Optional[dict], tz_name: str,
                now=None) -> Dict[str, Any]:
    """One read tool → the call the phone answers (target_currency of
    analytics stays here: conversion uses the server's public rates)."""
    params = {k: v for k, v in (args or {}).items() if k != "target_currency"}
    if tool in PERIOD_TOOLS:
        start, end = _custom_dates(args or {})
        params["bounds"] = bounds_for((args or {}).get("period") or "this_month",
                                      tz_name, start, end, now)
    return {"id": call_id, "method": "TOOL", "path": tool, "params": params}


# ── prompt context (the blocks the old server context builder read) ──────
_CONTEXT_KEYS = {
    "banking": ("get_bank_accounts", "accounts"),
    "savings_goals": ("get_savings_goals", "savings_goals"),
    "debts": ("get_debts", "debts"),
    "budgets": ("get_budgets", "budgets"),
    "recurring": ("get_recurring", "recurring"),
    "financial": ("get_financial_summary", None),
    "analytics": ("get_financial_analytics", None),
    "recent_transactions": ("search_all_transactions", "transactions"),
}


def context_keys(category: str) -> List[str]:
    """The prompt context blocks per intent (order kept from the old server builder)."""
    keys = []
    if category in ("balance", "transaction", "analysis", "search", "general", "delete", "create"):
        keys.append("banking")
    if category in ("delete", "create"):
        keys += ["savings_goals", "debts", "budgets", "recurring"]
    if category in ("analysis", "sales"):
        keys.append("financial")
    if category == "analysis":
        keys.append("analytics")
    if category == "search":
        keys.append("recent_transactions")
    return keys


def context_calls(category: str, period: Optional[str], tz_name: str, now=None) -> List[dict]:
    calls = []
    for key in context_keys(category):
        tool, _ = _CONTEXT_KEYS[key]
        args = {"period": period or "this_month"} if tool in PERIOD_TOOLS else {}
        if key == "recent_transactions":
            args = {"limit": 10}
        calls.append(device_call(f"ctx:{key}", tool, args, tz_name, now))
    return calls


def _payload(result: Any) -> Any:
    """A device answer is {success, data} (router envelope) or the data."""
    if isinstance(result, dict) and "data" in result and "success" in result:
        return result.get("data")
    return result


def context_from_results(results: List[dict]) -> Dict[str, Any]:
    """Device answers of the context calls → the prompt's `data` dict,
    in the context key order. Failed reads are left out."""
    answered = {str(r.get("id")): r.get("result") for r in results or [] if isinstance(r, dict)}
    data: Dict[str, Any] = {}
    for key, (_, field) in _CONTEXT_KEYS.items():
        result = answered.get(f"ctx:{key}")
        if result is None or (isinstance(result, dict) and result.get("success") is False):
            continue
        value = _payload(result)
        if field is not None:
            value = value.get(field) if isinstance(value, dict) else None
            if not isinstance(value, list):
                continue
        elif not isinstance(value, dict):
            continue
        data[key] = value
    order = list(_CONTEXT_KEYS)
    return {k: data[k] for k in sorted(data, key=order.index)}


def encode_result(result: Any) -> str:
    encoded = json.dumps(_payload(result) if not (isinstance(result, dict) and result.get("success") is False)
                         else result, ensure_ascii=False, default=str)
    if len(encoded) > RESULT_LIMIT:
        encoded = json.dumps({"coverage": "response_too_large",
                              "message": "Too large: ask with filters (period, query, limit)."})
    return encoded


def failed(result: Any) -> bool:
    return isinstance(result, dict) and (result.get("success") is False or bool(result.get("error")))


# ── signed state: the server keeps nothing between rounds ────────────────
def _key() -> bytes:
    from app.core.config import settings
    return hashlib.sha256(("sara-personal-device:" + settings.JWT_SECRET_KEY).encode()).digest()


def _canonical(body: dict, user_id: str) -> bytes:
    return (str(user_id) + "\n" + json.dumps(body, ensure_ascii=False, sort_keys=True,
                                             separators=(",", ":"), default=str)).encode()


def seal(body: dict, user_id: str) -> dict:
    body = {**body, "exp": int(time.time()) + STATE_TTL_SECONDS}
    sig = hmac.new(_key(), _canonical(body, user_id), hashlib.sha256).digest()
    return {**body, "sig": base64.urlsafe_b64encode(sig).decode()}


def unseal(state: Any, user_id: str) -> dict:
    """The phone's copy of the paused conversation, verified. Raises
    ValueError when it was altered, expired or belongs to someone else."""
    if not isinstance(state, dict):
        raise ValueError("bad state")
    body = {k: v for k, v in state.items() if k != "sig"}
    expected = base64.urlsafe_b64encode(
        hmac.new(_key(), _canonical(body, user_id), hashlib.sha256).digest()).decode()
    if not hmac.compare_digest(expected, str(state.get("sig") or "")):
        raise ValueError("bad signature")
    if int(body.get("exp") or 0) < time.time():
        raise ValueError("expired")
    return body


async def convert_analytics(result: Any, target: Optional[str]) -> Any:
    """Explicit cross-currency total for device analytics, with the
    server's public rates (convert_net_totals)."""
    if not target or not isinstance(result, dict):
        return result
    from app.domain.services.sara_analytics import convert_net_totals
    facts = result.get("facts") if isinstance(result.get("facts"), dict) else {}
    money = facts.get("money_by_currency") or []
    return {**result, "conversion": await convert_net_totals(money, target)}
