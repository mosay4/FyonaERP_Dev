"""Check Redis connectivity inside container.
Run with: PYTHONPATH=/app python scripts/_ping_redis.py
"""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import asyncio
from app.core.redis import get_redis


async def test():
    r = await get_redis()
    result = await r.ping()
    print(result)


asyncio.run(test())
