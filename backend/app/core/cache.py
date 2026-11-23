"""Tenant-aware Redis caching utilities.

All cache keys are prefixed with the organization ID to enforce tenant isolation.
"""
import json
import hashlib
from functools import wraps
from typing import Callable, Optional, Any

from app.core.redis import cache_get, cache_set, cache_delete_pattern


def _make_key(org_id: Any, prefix: str, **params) -> str:
    """Build a deterministic cache key: cache:{prefix}:{org_id}:{params_hash}."""
    param_str = json.dumps(params, sort_keys=True, default=str)
    param_hash = hashlib.md5(param_str.encode()).hexdigest()[:12]
    return f"cache:{prefix}:{org_id}:{param_hash}"


async def tenant_cache_get(org_id: Any, prefix: str, **params) -> Optional[dict]:
    """Get a cached value for the given tenant + prefix + params."""
    key = _make_key(org_id, prefix, **params)
    raw = await cache_get(key)
    if raw is None:
        return None
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None


async def tenant_cache_set(org_id: Any, prefix: str, data: Any, ttl: int = 60, **params) -> None:
    """Set a cached value for the given tenant + prefix + params."""
    key = _make_key(org_id, prefix, **params)
    raw = json.dumps(data, default=str)
    await cache_set(key, raw, expire=ttl)


async def tenant_cache_invalidate(org_id: Any, prefix: str) -> None:
    """Delete all cached values matching a tenant + prefix."""
    pattern = f"cache:{prefix}:{org_id}:*"
    await cache_delete_pattern(pattern)
