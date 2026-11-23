"""Run existing chat runtime tests ONLY against a disposable local test cluster.

The caller creates/owns the temporary PostgreSQL cluster and shuts it down.
Never defaults to the application's configured/production database.
"""
import asyncio
import os
import sys
from pathlib import Path

from sqlalchemy.engine import make_url

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

url = make_url(os.environ.get("DATABASE_URL", "sqlite://"))
socket = str(url.query.get("host", ""))
if (url.drivername != "postgresql+asyncpg" or url.host is not None or
        url.database != "fyona_chat_test" or
        not socket.startswith("/tmp/fyona-chat-pg.")):
    raise SystemExit("Refusing anything except a disposable chat-pg Unix socket/test database")

from app.core.database import Base, engine  # noqa: E402
from tests import test_chat_runtime, test_chat_edit_runtime, test_chat_album_runtime  # noqa: E402
from app.domain.entities import hr_entities, sale_entities  # noqa: E402,F401
from app.domain.services import debt_notification_service  # noqa: E402,F401


async def main():
    try:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        for module in (test_chat_runtime, test_chat_edit_runtime, test_chat_album_runtime):
            print(module.__name__, flush=True)
            await module.main()
    finally:
        await engine.dispose()


if __name__ == "__main__":
    asyncio.run(main())
