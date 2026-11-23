"""Check database row counts inside container.
Run with: PYTHONPATH=/app python scripts/_count_rows.py
"""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import asyncio
from app.core.database import async_session_factory
from app.domain.entities.auth_entities import Organization, User, UserSession
from sqlalchemy import select, func


async def count():
    async with async_session_factory() as db:
        for model, name in [
            (Organization, "Orgs"),
            (User, "Users"),
            (UserSession, "Sessions"),
        ]:
            result = await db.execute(select(func.count(model.id)))
            print(f"{name}={result.scalar()}")


asyncio.run(count())
