from typing import Optional
import logging
from redis.asyncio import Redis, ConnectionPool
from redis.exceptions import RedisError, ConnectionError as RedisConnectionError, TimeoutError as RedisTimeoutError
from .config import settings

logger = logging.getLogger("fyona.redis")

_pool: Optional[ConnectionPool] = None
_redis: Optional[Redis] = None

# Exceptions that indicate Redis is unreachable or unhealthy.
_REDIS_ERRORS = (RedisError, RedisConnectionError, RedisTimeoutError, ConnectionError, OSError)


async def get_redis() -> Redis:
    global _pool, _redis
    if _redis is None:
        _pool = ConnectionPool.from_url(settings.REDIS_URL, decode_responses=True)
        _redis = Redis(connection_pool=_pool)
    return _redis


async def close_redis() -> None:
    global _redis, _pool
    if _redis:
        await _redis.close()
        _redis = None
    if _pool:
        await _pool.disconnect()
        _pool = None


async def cache_get(key: str) -> Optional[str]:
    try:
        redis = await get_redis()
        return await redis.get(key)
    except _REDIS_ERRORS:
        logger.warning("cache_get_failed", extra={"key": key})
        return None


async def cache_set(key: str, value: str, expire: int = 300) -> None:
    try:
        redis = await get_redis()
        await redis.setex(key, expire, value)
    except _REDIS_ERRORS:
        logger.warning("cache_set_failed", extra={"key": key, "expire": expire})


async def cache_delete(key: str) -> None:
    try:
        redis = await get_redis()
        await redis.delete(key)
    except _REDIS_ERRORS:
        logger.warning("cache_delete_failed", extra={"key": key})


async def cache_delete_pattern(pattern: str) -> None:
    try:
        redis = await get_redis()
        keys = await redis.keys(pattern)
        if keys:
            await redis.delete(*keys)
    except _REDIS_ERRORS:
        logger.warning("cache_delete_pattern_failed", extra={"pattern": pattern})
