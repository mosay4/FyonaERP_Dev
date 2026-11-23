"""Debug diagnostic endpoints must never be reachable in production.

Regression for audit finding: POST /api/v1/debug/test-email was mounted
unconditionally and performed live SMTP sends (returning per-step internals
and tracebacks) with no authentication on the production host.
"""

import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app
from app.core.config import settings


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://localhost") as ac:
        yield ac


async def test_debug_test_email_hidden_in_production(client, monkeypatch):
    """With DEBUG=false the endpoint is indistinguishable from a missing route."""
    monkeypatch.setattr(settings, "DEBUG", False)
    r = await client.post(
        "/api/v1/debug/test-email",
        json={"to": "attacker@example.com", "text": "spam"},
    )
    assert r.status_code == 404


async def test_debug_test_email_hidden_even_invalid_body(client, monkeypatch):
    """Protection applies before payload validation — no SMTP internals leak."""
    monkeypatch.setattr(settings, "DEBUG", False)
    r = await client.post("/api/v1/debug/test-email", json={})
    assert r.status_code == 404
    assert "SMTP" not in r.text


async def test_debug_test_email_active_in_development(client, monkeypatch):
    """In DEBUG mode the route is live (422 = validation ran, not a 404)."""
    monkeypatch.setattr(settings, "DEBUG", True)
    r = await client.post("/api/v1/debug/test-email", json={})
    assert r.status_code == 422
    # FastAPI default 422 validation body proves the route executed past the
    # debug gate and into request validation (a hidden route would be 404).
    assert "detail" in r.json()
