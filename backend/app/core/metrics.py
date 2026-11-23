"""Prometheus metrics for FYONA ERP API.

Exports request rate, latency histograms, error counters, and active-request
gauges.  The /metrics endpoint (wired in main.py) exposes these to Prometheus.

Endpoints are normalised to <method> <path> with dynamic segments replaced
(<uuid>, <id>) so label cardinality stays bounded.
"""

from __future__ import annotations

import re
import time as _time

from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST
from starlette.types import ASGIApp, Receive, Scope, Send


# ── Metric definitions ──────────────────────────────────────────────────────

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"],
)

REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "endpoint"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0),
)

IN_PROGRESS = Gauge(
    "http_requests_in_progress",
    "Number of requests currently being processed",
    ["method"],
)

ERROR_COUNT = Counter(
    "http_errors_total",
    "Total HTTP error responses (4xx + 5xx)",
    ["method", "endpoint", "status"],
)


# ── Path normaliser ────────────────────────────────────────────────────────

_UUID_RE = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
_NUM_RE = re.compile(r"\b\d+\b")


def _normalise_path(path: str) -> str:
    """Replace dynamic path segments with placeholders."""
    path = _UUID_RE.sub("<uuid>", path)
    path = _NUM_RE.sub("<id>", path)
    return path


# ── Middleware ──────────────────────────────────────────────────────────────

class PrometheusMiddleware:
    """ASGI middleware that records request count, latency, in-progress
    gauge and error counts for every request to /metrics excluded."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        path: str = scope.get("path", "")
        if path == "/metrics":
            await self.app(scope, receive, send)
            return

        method: str = scope.get("method", "GET")
        endpoint = _normalise_path(path)

        IN_PROGRESS.labels(method=method).inc()
        start = _time.monotonic()
        status_code = 500

        async def send_wrapper(message):
            nonlocal status_code
            if message["type"] == "http.response.start":
                status_code = message.get("status", 500)
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            duration = _time.monotonic() - start
            REQUEST_COUNT.labels(method=method, endpoint=endpoint, status=status_code).inc()
            REQUEST_DURATION.labels(method=method, endpoint=endpoint).observe(duration)
            IN_PROGRESS.labels(method=method).dec()
            if status_code >= 400:
                ERROR_COUNT.labels(method=method, endpoint=endpoint, status=status_code).inc()
