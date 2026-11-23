import json

import pytest
from httpx import ASGITransport, AsyncClient

from app.core.rate_limiter import InMemoryRateLimiter, RateLimitMiddleware
from app.core.security import create_access_token


async def _ok_app(scope, receive, send):
    body = json.dumps({"ok": True}).encode("utf-8")
    await send(
        {
            "type": "http.response.start",
            "status": 200,
            "headers": [(b"content-type", b"application/json")],
        }
    )
    await send({"type": "http.response.body", "body": body})


@pytest.fixture
def force_memory(monkeypatch):
    """Force the in-memory fallback so tests are deterministic (no Redis)."""

    class _FakeRedis:
        def pipeline(self, *args, **kwargs):
            raise ConnectionError("no redis in tests")

    async def _fake_redis(*args, **kwargs):
        return _FakeRedis()

    monkeypatch.setattr("app.core.rate_limiter.get_redis", _fake_redis)


class _FakeZSetRedis:
    """Faithful in-memory replica of the Redis zset semantics used by the
    limiter. A member already present only gets its score updated (it is NOT
    re-added), which reproduces the same-second-collapse bug if the limiter
    used bare ``str(now)`` members."""

    class _Pipeline:
        def __init__(self, store):
            self.store = store
            self.cmds = []

        def zremrangebyscore(self, key, start, end):
            self.cmds.append(("rem", key, start, end))
            return self

        def zcard(self, key):
            self.cmds.append(("card", key))
            return self

        def zadd(self, key, mapping):
            self.cmds.append(("add", key, mapping))
            return self

        def expire(self, key, ttl):
            self.cmds.append(("expire", key, ttl))
            return self

        async def execute(self):
            results = []
            for cmd in self.cmds:
                kind = cmd[0]
                if kind == "rem":
                    _, key, start, end = cmd
                    zs = self.store.setdefault(key, {})
                    to_remove = [m for m, s in zs.items() if start <= s <= end]
                    for m in to_remove:
                        del zs[m]
                    results.append(len(to_remove))
                elif kind == "card":
                    _, key = cmd
                    results.append(len(self.store.get(key, {})))
                elif kind == "add":
                    _, key, mapping = cmd
                    zs = self.store.setdefault(key, {})
                    added = 0
                    for member, score in mapping.items():
                        if member not in zs:
                            added += 1
                        zs[member] = score
                    results.append(added)
                elif kind == "expire":
                    results.append(True)
            return results

    def __init__(self):
        self.store = {}

    def pipeline(self):
        return self._Pipeline(self.store)


def _token(user_id: str) -> str:
    return create_access_token(user_id=user_id, org_id="org-1", role="owner")


async def test_in_memory_limiter_allows_then_blocks():
    limiter = InMemoryRateLimiter(requests=2, window_seconds=60)
    await limiter.check("k")
    await limiter.check("k")
    with pytest.raises(Exception):
        await limiter.check("k")
    # Different key unaffected
    await limiter.check("other")


async def test_middleware_exempts_health(force_memory):
    app = RateLimitMiddleware(_ok_app, per_ip=1, per_user=1)
    async with AsyncClient(transport=ASGITransport(app=app)) as client:
        r = await client.get("http://test/health")
        assert r.status_code == 200
        r = await client.get("http://test/health")
        assert r.status_code == 200
        r = await client.get("http://test/api/v1/users")
        assert r.status_code == 200


async def test_middleware_blocks_ip_over_limit(force_memory):
    app = RateLimitMiddleware(_ok_app, per_ip=2, per_user=100)
    async with AsyncClient(transport=ASGITransport(app=app)) as client:
        r1 = await client.get("http://test/api/v1/users")
        r2 = await client.get("http://test/api/v1/users")
        r3 = await client.get("http://test/api/v1/users")
        assert r1.status_code == 200
        assert r2.status_code == 200
        assert r3.status_code == 429
        assert r3.json()["success"] is False


async def test_middleware_blocks_authenticated_user(force_memory):
    app = RateLimitMiddleware(_ok_app, per_ip=100, per_user=2)
    headers = {"Authorization": f"Bearer {_token('user-42')}"}
    async with AsyncClient(transport=ASGITransport(app=app)) as client:
        r1 = await client.get("http://test/api/v1/users", headers=headers)
        r2 = await client.get("http://test/api/v1/users", headers=headers)
        r3 = await client.get("http://test/api/v1/users", headers=headers)
        assert r1.status_code == 200
        assert r2.status_code == 200
        assert r3.status_code == 429
        # A different user is not blocked
        other = await client.get(
            "http://test/api/v1/users",
            headers={"Authorization": f"Bearer {_token('user-99')}"},
        )
        assert other.status_code == 200


async def test_middleware_auth_endpoints_get_tighter_limit(force_memory):
    app = RateLimitMiddleware(_ok_app, per_ip=100, auth_per_ip=2)
    async with AsyncClient(transport=ASGITransport(app=app)) as client:
        r1 = await client.post("http://test/api/v1/auth/login")
        r2 = await client.post("http://test/api/v1/auth/login")
        r3 = await client.post("http://test/api/v1/auth/login")
        assert r1.status_code == 200
        assert r2.status_code == 200
        assert r3.status_code == 429
        # General endpoint unaffected
        r4 = await client.get("http://test/api/v1/users")
        assert r4.status_code == 200


async def test_redis_path_counts_same_second_requests(monkeypatch):
    """Multiple requests landing within the same second must each be counted.

    Regression test: the zset member was ``str(now)``, so all same-second
    requests collapsed into ONE member and the counter never grew — the limit
    was never enforced under burst traffic. Each request now uses a unique
    member, so bursts are counted correctly.
    """
    fake = _FakeZSetRedis()

    async def _fake_get_redis(*args, **kwargs):
        return fake

    monkeypatch.setattr("app.core.rate_limiter.get_redis", _fake_get_redis)

    app = RateLimitMiddleware(_ok_app, per_ip=3, per_user=100)
    async with AsyncClient(transport=ASGITransport(app=app)) as client:
        codes = []
        for _ in range(5):
            r = await client.get("http://test/api/v1/x")
            codes.append(r.status_code)

    assert codes[:3] == [200, 200, 200]
    assert codes[3] == 429
    assert codes[4] == 429
    # Every request produced its own zset entry
    assert len(fake.store) == 1
    assert len(next(iter(fake.store.values()))) == 5


async def test_spoofed_xff_cannot_bypass_ip_limit(force_memory):
    """Regression: per-IP limits must key on the ASGI-resolved peer, never on
    the client-controlled X-Forwarded-For header.

    An attacker rotating spoofed XFF values (1.1.1.1 -> 2.2.2.2 -> 3.3.3.3)
    must still be caught by a single bucket. Under the old first-XFF parsing
    this returned 200/200/200 and fully bypassed the limiter.
    """
    app = RateLimitMiddleware(_ok_app, per_ip=2, per_user=100)
    async with AsyncClient(transport=ASGITransport(app=app)) as client:
        r1 = await client.get(
            "http://test/api/v1/users",
            headers={"X-Forwarded-For": "1.1.1.1"},
        )
        r2 = await client.get(
            "http://test/api/v1/users",
            headers={"X-Forwarded-For": "2.2.2.2"},
        )
        r3 = await client.get(
            "http://test/api/v1/users",
            headers={"X-Forwarded-For": "3.3.3.3"},
        )
        assert r1.status_code == 200
        assert r2.status_code == 200
        assert r3.status_code == 429


def test_client_ip_uses_asgi_peer_not_spoofed_xff():
    """Unit-level guarantee: the limiter reads scope['client'] only."""
    scope = {
        "client": ("9.9.9.9", 1234),
        "headers": [(b"x-forwarded-for", b"1.2.3.4, 5.6.7.8")],
    }
    assert RateLimitMiddleware._client_ip(scope) == "9.9.9.9"
