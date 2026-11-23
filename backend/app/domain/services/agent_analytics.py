"""Sara agent analytics + production monitoring.

Records every agent round / tool call / error / user question into the
agent_analytics_events table (same transaction as the request) and exposes
aggregate metrics plus a health evaluation with alert thresholds.

Analytics is best-effort: it must never break or slow the agent, so all writes
are wrapped and silent on failure.
"""

from typing import Optional
from uuid import UUID

from sqlalchemy import select, func, case
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.analytics_entities import AgentAnalyticsEvent


class AgentAnalytics:
    """Per-user recorder bound to the request session."""

    @staticmethod
    def _as_uuid(value) -> Optional[UUID]:
        try:
            return UUID(str(value))
        except (TypeError, ValueError, AttributeError):
            return None

    def __init__(self, db: AsyncSession, org_id, user_id):
        self._db = db
        # Only valid UUID identifiers are recorded; anything else is skipped so a
        # bad identifier can never poison the session (best-effort analytics).
        self._org_id = self._as_uuid(org_id)
        self._user_id = self._as_uuid(user_id)

    # ── recording (best-effort, never raises) ──────────────────────────
    def _add(self, **fields) -> None:
        if self._org_id is None or self._user_id is None:
            return
        try:
            self._db.add(AgentAnalyticsEvent(
                org_id=self._org_id, user_id=self._user_id, **fields,
            ))
        except Exception:
            pass

    def record_question(self, *, question: str) -> None:
        self._add(event_type="question", question=(question or "")[:500])

    def record_tool(self, *, tool_name: str, success: bool,
                    latency_ms: int = 0, error_type: Optional[str] = None) -> None:
        self._add(event_type="tool", tool_name=tool_name, success=bool(success),
                  latency_ms=int(latency_ms), error_type=error_type)

    def record_error(self, *, error_type: str) -> None:
        self._add(event_type="error", error_type=error_type[:64])

    def record_round(self, *, rounds: int, tool_count: int, tool_failures: int,
                     latency_ms: int) -> None:
        self._add(event_type="round", rounds=int(rounds), tool_count=int(tool_count),
                  tool_failures=int(tool_failures), latency_ms=int(latency_ms))

    # ── aggregation ────────────────────────────────────────────────────
    @staticmethod
    async def metrics(db: AsyncSession, org_id: Optional[UUID] = None,
                      since=None) -> dict:
        filters = []
        if org_id is not None:
            filters.append(AgentAnalyticsEvent.org_id == org_id)
        if since is not None:
            filters.append(AgentAnalyticsEvent.created_at >= since)

        async def one(sel):
            return (await db.execute(sel)).scalar_one_or_none() or 0

        base = [*filters, AgentAnalyticsEvent.event_type == "round"]
        totals = {
            "rounds": await one(select(func.count()).select_from(AgentAnalyticsEvent).where(*filters, AgentAnalyticsEvent.event_type == "round")),
            "tool_calls": await one(select(func.count()).select_from(AgentAnalyticsEvent).where(*filters, AgentAnalyticsEvent.event_type == "tool")),
            "errors": await one(select(func.count()).select_from(AgentAnalyticsEvent).where(*filters, AgentAnalyticsEvent.event_type == "error")),
            "questions": await one(select(func.count()).select_from(AgentAnalyticsEvent).where(*filters, AgentAnalyticsEvent.event_type == "question")),
        }

        tool_rows = (await db.execute(
            select(
                AgentAnalyticsEvent.tool_name,
                func.count(),
                func.sum(case((AgentAnalyticsEvent.success.is_(True), 1), else_=0)),
            )
            .where(*filters, AgentAnalyticsEvent.event_type == "tool")
            .group_by(AgentAnalyticsEvent.tool_name)
        )).all()
        tool_usage = {
            name: {"calls": int(cnt), "success": int(ok or 0)}
            for name, cnt, ok in tool_rows if name
        }

        err_rows = (await db.execute(
            select(AgentAnalyticsEvent.error_type, func.count())
            .where(*filters, AgentAnalyticsEvent.error_type.isnot(None))
            .group_by(AgentAnalyticsEvent.error_type)
            .order_by(func.count().desc()).limit(10)
        )).all()
        top_errors = [{"type": t or "unknown", "count": int(c)} for t, c in err_rows]

        q_rows = (await db.execute(
            select(AgentAnalyticsEvent.question, func.count())
            .where(*filters, AgentAnalyticsEvent.question.isnot(None))
            .group_by(AgentAnalyticsEvent.question)
            .order_by(func.count().desc()).limit(10)
        )).all()
        top_questions = [{"question": q, "count": int(c)} for q, c in q_rows]

        return {
            "totals": totals,
            "tool_usage": tool_usage,
            "avg_round_latency_ms": round(float(await one(
                select(func.avg(AgentAnalyticsEvent.latency_ms)).where(*base)
            ) or 0), 1),
            "avg_tool_latency_ms": round(float(await one(
                select(func.avg(AgentAnalyticsEvent.latency_ms)).where(
                    *filters, AgentAnalyticsEvent.event_type == "tool"
                )
            ) or 0), 1),
            "avg_tools_per_round": round(float(await one(
                select(func.avg(AgentAnalyticsEvent.tool_count)).where(*base)
            ) or 0), 2),
            "avg_tool_failures_per_round": round(float(await one(
                select(func.avg(AgentAnalyticsEvent.tool_failures)).where(*base)
            ) or 0), 2),
            "top_errors": top_errors,
            "top_questions": top_questions,
        }


def evaluate_health(metrics: dict) -> dict:
    """Evaluate agent health against alert thresholds.

    Returns status "healthy" or "degraded" with the list of triggered alerts.
    """
    totals = metrics.get("totals", {})
    rounds = totals.get("rounds", 0)
    errors = totals.get("errors", 0)
    alerts = []

    if rounds:
        error_rate = errors / rounds
        if error_rate > 0.5:
            alerts.append({"type": "high_error_rate", "value": round(error_rate, 3)})
        avg_tools = metrics.get("avg_tools_per_round", 0)
        if avg_tools > 4:
            alerts.append({"type": "tool_loop_detected", "value": avg_tools})
        avg_fail = metrics.get("avg_tool_failures_per_round", 0)
        if avg_fail > 2:
            alerts.append({"type": "high_tool_failures_per_round", "value": avg_fail})

    tool_usage = metrics.get("tool_usage", {})
    total_calls = sum(t["calls"] for t in tool_usage.values())
    total_ok = sum(t["success"] for t in tool_usage.values())
    if total_calls:
        failure_rate = 1 - (total_ok / total_calls)
        if failure_rate > 0.5:
            alerts.append({"type": "high_tool_failure_rate", "value": round(failure_rate, 3)})

    avg_latency = metrics.get("avg_round_latency_ms", 0)
    if avg_latency > 8000:
        alerts.append({"type": "slow_response", "value": avg_latency})

    return {
        "status": "degraded" if alerts else "healthy",
        "alerts": alerts,
    }
