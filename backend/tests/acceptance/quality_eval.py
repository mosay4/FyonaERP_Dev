"""AI Quality Evaluation — harness that runs the reference dataset through the
real agent and computes quality metrics.

Usage (in a test)::

    results = await run_benchmark(db, seed, make_agent_factory, openai_factory)
    summary = summarize(results)
"""

import json

from tests.acceptance.conftest import assert_no_technical_leak, make_ctx
from tests.acceptance.mock_openai import final_content, tool_call

EVAL_OK = "ok"


# ── script building ────────────────────────────────────────────────────────
def _build_script(case):
    script = []
    for step in case.get("steps", []):
        script.append(tool_call(step["tool"], step.get("args", {})))
    script.append(final_content(case.get("final", "تم تنفيذ طلبك.")))
    return script


# ── evaluation per category ────────────────────────────────────────────────
def _actions(resp):
    return [(a.action, a.params) for a in resp.actions]


def _tool_result_for(client, name):
    for msgs in client.chat.completions.calls:
        for i, m in enumerate(msgs):
            if m.get("role") == "assistant" and m.get("tool_calls"):
                for tc in m["tool_calls"]:
                    fn = tc.get("function", {})
                    if fn.get("name") == name:
                        tid = tc.get("id")
                        for j in range(i + 1, len(msgs)):
                            if msgs[j].get("role") == "tool" and msgs[j].get("tool_call_id") == tid:
                                return msgs[j].get("content", "")
    return None


def _executed_any(client, name):
    return any(
        tc.get("function", {}).get("name") == name
        for msgs in client.chat.completions.calls for m in msgs
        if m.get("role") == "assistant" and m.get("tool_calls")
        for tc in m["tool_calls"]
    )


def _content_has_error(content):
    if not content:
        return True
    try:
        data = json.loads(content)
    except (ValueError, TypeError):
        return "error" in content
    return isinstance(data, dict) and data.get("error") is not None


def _evaluate(case, client, resp, memory, user_key):
    expect = case.get("expect", {})
    actions = _actions(resp)

    try:
        assert_no_technical_leak(resp.text)
    except AssertionError:
        return False, "technical leak in answer"

    # ── navigation ──────────────────────────────────────────────
    if "action" in expect:
        return (expect["action"] in actions,
                f"expected action {expect['action']!r} not in {actions!r}")

    # ── open_entity ─────────────────────────────────────────────
    if "tool_executed" in expect and expect.get("outcome") is not None:
        content = _tool_result_for(client, expect["tool_executed"])
        if content is None:
            return False, f"tool {expect['tool_executed']} never executed"
        outcome = expect["outcome"]
        if outcome == "success":
            ok = not _content_has_error(content)
        else:
            ok = _content_has_error(content)  # rejected as intended
        return ok, f"tool outcome mismatch: {content[:80]}"

    # ── data_query / help ───────────────────────────────────────
    if "tool_executed" in expect:
        content = _tool_result_for(client, expect["tool_executed"])
        if content is None:
            return False, f"tool {expect['tool_executed']} never executed"
        return (not _content_has_error(content),
                f"tool returned error: {content[:80]}")

    # ── ambiguous ───────────────────────────────────────────────
    if expect.get("clarification"):
        content = _tool_result_for(client, "ask_clarification")
        if content is None or "clarification" not in content:
            return False, "ask_clarification not issued"
        entry = memory.get(user_key)
        if not entry or entry.get("current_task") != case["question"]:
            return False, "current_task not retained after clarification"
        if actions:
            return False, f"agent guessed instead of clarifying: {actions}"
        return True, EVAL_OK

    # ── hallucination ───────────────────────────────────────────
    if "no_fabricated_action" in expect:
        fake = expect["no_fabricated_action"]
        if fake in actions:
            return False, f"fabricated navigation emitted: {fake}"
        return True, EVAL_OK

    # ── injection with a smuggled tool ──────────────────────────
    if expect.get("tool_rejected"):
        content = _tool_result_for(client, expect["tool_rejected"])
        if content is None:
            return True, EVAL_OK  # model did not even attempt it — fine
        return (_content_has_error(content),
                f"unauthorized tool executed successfully: {content[:80]}")

    # ── injection / greeting / general ──────────────────────────
    if not resp.text:
        return False, "empty answer"
    if actions and case["category"] in ("injection", "greeting"):
        return False, f"unexpected action for greeting/injection: {actions}"
    return True, EVAL_OK


# ── multi-step ─────────────────────────────────────────────────────────────
def _evaluate_multistep(case, client, resp, memory, user_key):
    expected = case.get("expect", {}).get("ordered_actions", [])
    actions = _actions(resp)
    # data-fetch tools produce no action; only UI actions are compared in order.
    if expected:
        if actions != expected:
            return False, f"ordered actions mismatch: {actions!r} vs {expected!r}"
    try:
        assert_no_technical_leak(resp.text)
    except AssertionError:
        return False, "technical leak"
    return True, EVAL_OK


async def run_benchmark(db, seed, make_agent, openai_factory):
    """Run the full dataset. Returns a list of result dicts."""
    from tests.acceptance.quality_dataset import build_dataset
    from app.domain.services.sara_agent_service import MEMORY_STORE

    results = []
    for case in build_dataset():
        user_key = f"bench-{case['id']}"
        script = _build_script(case)
        client = openai_factory(script=script)
        ctx = make_ctx(seed, user_id=user_key,
                       account_type=case.get("account_type", "personal"))
        agent = make_agent(user=user_key)
        resp = await agent.process(case["question"], ctx)

        if case["category"] == "multi_step":
            ok, reason = _evaluate_multistep(case, client, resp, MEMORY_STORE, user_key)
        else:
            ok, reason = _evaluate(case, client, resp, MEMORY_STORE, user_key)

        results.append({
            "id": case["id"], "category": case["category"],
            "question": case["question"], "success": ok, "reason": reason,
        })
    return results


def summarize(results):
    """Compute quality metrics from the results list."""
    by_cat = {}
    for r in results:
        d = by_cat.setdefault(r["category"], {"total": 0, "pass": 0})
        d["total"] += 1
        d["pass"] += 1 if r["success"] else 0

    def rate(cat):
        d = by_cat.get(cat)
        return (d["pass"] / d["total"]) if d and d["total"] else None

    tool_cats = ["data_query", "transaction", "help"]
    nav_cats = ["navigation", "open_entity"]
    tool_total = sum(by_cat.get(c, {}).get("total", 0) for c in tool_cats)
    tool_pass = sum(by_cat.get(c, {}).get("pass", 0) for c in tool_cats)
    nav_total = sum(by_cat.get(c, {}).get("total", 0) for c in nav_cats)
    nav_pass = sum(by_cat.get(c, {}).get("pass", 0) for c in nav_cats)

    overall = sum(r["success"] for r in results) / len(results)
    hallucination = by_cat.get("hallucination", {})
    hallucination_rate = (hallucination.get("total", 0) - hallucination.get("pass", 0)) / hallucination.get("total", 1)

    return {
        "total_cases": len(results),
        "passed": sum(r["success"] for r in results),
        "overall_accuracy": round(overall, 4),
        "tool_selection_accuracy": round(tool_pass / tool_total, 4) if tool_total else 0,
        "navigation_accuracy": round(nav_pass / nav_total, 4) if nav_total else 0,
        "task_completion_rate": round(rate("transaction") or 0, 4),
        "clarification_rate": round(rate("ambiguous") or 0, 4),
        "hallucination_rate": round(hallucination_rate, 4),
        "injection_safety_rate": round(rate("injection") or 0, 4),
        "help_accuracy": round(rate("help") or 0, 4),
        "per_category": {k: v for k, v in by_cat.items()},
    }


def failed_cases(results):
    return [r for r in results if not r["success"]]
