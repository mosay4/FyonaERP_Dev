import asyncio
import time

from fastapi import APIRouter, Response
from sqlalchemy import text

from ...core.logging import get_logger
from ...core.config import settings
from ...core.redis import get_redis
from ...core.database import engine


async def _check_db() -> tuple[str, str]:
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        return "database", "ok"
    except Exception as e:
        return "database", f"error: {e}"


async def _check_redis() -> tuple[str, str]:
    try:
        redis = await get_redis()
        await redis.ping()
        return "redis", "ok"
    except Exception as e:
        return "redis", f"error: {e}"


async def _check_minio() -> tuple[str, str]:
    # In local dev MinIO often not running — avoid 1.5s TCP timeout by probing quickly
    endpoint = settings.S3_ENDPOINT_URL or ""
    if not endpoint:
        return "minio", "skipped"
    # Quick socket probe with 0.15s timeout before doing HTTP
    try:
        import socket
        from urllib.parse import urlparse
        parsed = urlparse(endpoint)
        host = parsed.hostname or "localhost"
        port = parsed.port or 9000
        # 0.15s TCP connect probe — if port closed, OS returns quickly
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.15)
        try:
            s.connect((host, port))
            s.close()
        except OSError:
            s.close()
            return "minio", "error: not running (port closed)"
    except Exception:
        pass
    try:
        import httpx
        async with httpx.AsyncClient(timeout=0.4) as client:
            try:
                r = await asyncio.wait_for(client.get(f"{endpoint}/minio/health/live"), timeout=0.4)
                return "minio", "ok" if r.status_code == 200 else f"http_{r.status_code}"
            except asyncio.TimeoutError:
                return "minio", "error: timeout 0.4s"
    except Exception as e:
        msg = str(e)[:80]
        return "minio", f"error: {msg}"

router = APIRouter(tags=["Health"])
logger = get_logger("health")

_startup_time = time.time()
# Cache version at import to avoid spawning git on every health request (was 1.5s)
try:
    from app.core.version import get_version_info as _get_ver
    _cached_version = _get_ver()
except Exception:
    _cached_version = {"app": settings.APP_NAME, "version": settings.APP_VERSION, "commit": "unknown", "environment": "development"}


def _version_info():
    return _cached_version


# ── Liveness: is the process alive and not stuck? ──
@router.get("/health/live")
async def liveness_check():
    uptime = time.time() - _startup_time
    return {
        "status": "alive",
        "uptime_seconds": round(uptime, 1),
        "version": settings.APP_VERSION,
    }


# ── Readiness: can this instance serve traffic? ──
# Returns 503 if any *critical* dependency is down.
@router.get("/health/ready")
async def readiness_check(response: Response):
    results = await asyncio.gather(_check_db(), _check_redis(), _check_minio())
    checks = dict(results)
    healthy = not any(v.startswith("error") for k, v in checks.items() if k in ("database", "redis"))

    status_code = 200 if healthy else 503
    response.status_code = status_code

    return {
        "status": "ready" if healthy else "degraded",
        "version": _version_info(),
        "checks": checks,
    }


# ── Full health (verbose, used by deploy script / monitoring) ──
# Returns 503 if any *critical* dependency is down (same logic as readiness).
@router.get("/health")
async def health_check(response: Response):
    results = await asyncio.gather(_check_db(), _check_redis(), _check_minio())
    checks = dict(results)
    healthy = not any(v.startswith("error") for k, v in checks.items() if k in ("database", "redis"))

    status_code = 200 if healthy else 503
    response.status_code = status_code

    uptime = time.time() - _startup_time
    return {
        "status": "healthy" if healthy else "degraded",
        "uptime_seconds": round(uptime, 1),
        "version": _version_info(),
        "checks": checks,
    }

