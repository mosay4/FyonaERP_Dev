import time
import asyncio
import uuid
from collections import defaultdict
from typing import Optional, Tuple

from fastapi import HTTPException, Request, status
from fastapi.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from app.core.redis import get_redis


class InMemoryRateLimiter:
    """Fallback rate limiter when Redis is unavailable."""

    def __init__(self, requests: int, window_seconds: int):
        self.requests = requests
        self.window_seconds = window_seconds
        self._buckets: dict[str, list[float]] = defaultdict(list)
        self._lock = asyncio.Lock()

    async def check(self, key: str) -> None:
        now = time.time()
        cutoff = now - self.window_seconds
        async with self._lock:
            bucket = self._buckets[key]
            # Keep only timestamps within the window
            bucket[:] = [t for t in bucket if t > cutoff]
            if len(bucket) >= self.requests:
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail="تجاوزت الحد المسموح من الطلبات، حاول لاحقاً",
                )
            bucket.append(now)


class RateLimiter:
    """Redis-backed sliding-window counter (zset per key)."""

    def __init__(self, requests: int, window_seconds: int, key_prefix: str = "rl"):
        self.requests = requests
        self.window_seconds = window_seconds
        self.key_prefix = key_prefix
        self._fallback = InMemoryRateLimiter(requests, window_seconds)

    async def check(self, identifier: str) -> None:
        key = f"{self.key_prefix}:{identifier}"
        redis = await get_redis()
        now = int(time.time())
        window_start = now - self.window_seconds
        try:
            pipe = redis.pipeline()
            pipe.zremrangebyscore(key, 0, window_start)
            pipe.zcard(key)
            # Unique member per request: multiple requests landing in the same
            # second must each count. A bare ``str(now)`` member would collapse
            # same-second requests into a single zset entry and undercount.
            pipe.zadd(key, {f"{now}:{uuid.uuid4().hex}": now})
            pipe.expire(key, self.window_seconds)
            results = await pipe.execute()
            count = results[1]
            if count is not None and int(count) >= self.requests:
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail="تجاوزت الحد المسموح من الطلبات، حاول لاحقاً",
                )
        except HTTPException:
            raise
        except Exception:
            # Redis unavailable — fall back to in-memory
            await self._fallback.check(key)


class RateLimitMiddleware:
    """ASGI middleware enforcing per-IP and per-user request limits.

    - Skips exempt paths (health/version) so monitors are never throttled.
    - Resolves the client IP from ``scope["client"]``. Behind the trusted
      Nginx reverse proxy uvicorn (``--proxy-headers --forwarded-allow-ips
      127.0.0.1``) rewrites ``scope["client"]`` to the real client IP carried
      in the X-Forwarded-For header that Nginx itself sets to ``$remote_addr``.
      The raw X-Forwarded-For header is deliberately IGNORED here: it is
      client-controlled and would let an attacker rotate identities to bypass
      per-IP limits.
    - Resolves the authenticated user from the JWT Bearer token so per-user
      limits are meaningful (the app does not use an ``X-User-ID`` header).
    - Applies tighter limits to auth endpoints (login/OTP) to blunt brute force.
    """

    def __init__(
        self,
        app: ASGIApp,
        per_ip: int = 100,
        per_user: int = 100,
        window_seconds: int = 60,
        auth_path_prefix: str = "/api/v1/auth",
        auth_per_ip: int = 20,
        auth_per_user: int = 10,
        exempt_paths: Tuple[str, ...] = ("/health", "/version"),
        key_prefix: str = "rl",
    ):
        self.app = app
        self.exempt_paths = exempt_paths
        self.auth_path_prefix = auth_path_prefix
        self.general_ip = RateLimiter(per_ip, window_seconds, f"{key_prefix}_ip")
        self.general_user = RateLimiter(per_user, window_seconds, f"{key_prefix}_user")
        self.auth_ip = RateLimiter(auth_per_ip, window_seconds, f"{key_prefix}_auth_ip")
        self.auth_user = RateLimiter(auth_per_user, window_seconds, f"{key_prefix}_auth_user")

    @staticmethod
    def _client_ip(scope: Scope) -> str:
        # scope["client"] is the peer address as resolved by the ASGI server.
        # uvicorn rewrites it to the trusted proxy's X-Forwarded-For value only
        # when --forwarded-allow-ips matches the direct peer (127.0.0.1), so
        # spoofed X-Forwarded-For headers can never change the bucket.
        client = scope.get("client")
        return client[0] if client else "unknown"

    @staticmethod
    def _bearer_user_id(scope: Scope) -> Optional[str]:
        headers = {k.lower(): v for k, v in scope.get("headers", [])}
        auth = headers.get(b"authorization")
        if not auth:
            return None
        value = auth.decode("utf-8", "ignore")
        if not value.startswith("Bearer "):
            return None
        token = value[len("Bearer "):].strip()
        if not token:
            return None
        try:
            from app.core.security import decode_token
            payload = decode_token(token)
        except Exception:
            return None
        if not payload or payload.get("type") != "access":
            return None
        uid = payload.get("sub")
        return str(uid) if uid else None

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        path = scope.get("path", "")
        if path in self.exempt_paths:
            await self.app(scope, receive, send)
            return

        ip = self._client_ip(scope)
        user_id = self._bearer_user_id(scope)
        is_auth = path.startswith(self.auth_path_prefix)
        # The tight auth bucket is for brute-force surfaces (login/OTP/reset).
        # Authenticated profile endpoints (/auth/me, /auth/me/avatar,
        # /auth/me/organization/avatar, /auth/sessions) must use the normal
        # bucket — otherwise a normal profile open (GET + PUT + refresh) can
        # exhaust the 10/min auth limit and block name/photo changes.
        auth_sensitive = is_auth and not (
            path.startswith("/api/v1/auth/me")
            or path.startswith("/api/v1/auth/sessions")
        )

        ip_limiter = self.auth_ip if auth_sensitive else self.general_ip
        user_limiter = self.auth_user if auth_sensitive else self.general_user

        try:
            # The deployed port-80 TCP forwarder presents loopback for all
            # clients. Verified user identities must not share one global IP
            # bucket; never trust a caller-provided forwarding header instead.
            identity = f'{ip}:user:{user_id}' if user_id and not auth_sensitive and ip in ('127.0.0.1', '::1') else ip
            await ip_limiter.check(identity)
            if user_id:
                await user_limiter.check(user_id)
        except HTTPException as exc:
            # Drain the request body so the connection stays reusable, then
            # send the 429 directly (an exception raised here would be turned
            # into a 500 by the outermost ServerErrorMiddleware).
            await Request(scope, receive).body()
            response = JSONResponse(
                status_code=exc.status_code,
                content={"success": False, "message": exc.detail},
            )
            await response(scope, receive, send)
            return

        await self.app(scope, receive, send)
