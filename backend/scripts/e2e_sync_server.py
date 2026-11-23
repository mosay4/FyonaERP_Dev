"""Local E2E server for the offline-first personal-sync test suite.

Boots the REAL FastAPI application against a throwaway SQLite database so the
Flutter integration tests can exercise the complete client <-> server sync
protocol (operation replay, idempotency, multi-device convergence) without
Postgres/Redis.

Usage:
    python scripts/e2e_sync_server.py <db_path> <port>

Prints one line `E2E_READY {json}` on stdout with the signed access token and
identity, then serves until killed.
"""
import asyncio
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

BACKEND_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_DIR))

DB_PATH = sys.argv[1] if len(sys.argv) > 1 else str(BACKEND_DIR / "e2e_sync.db")
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8099

# ── Environment must be set BEFORE importing app.config/app.core.database ──
os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{DB_PATH}"
os.environ.setdefault("REDIS_URL", "redis://127.0.0.1:6399/0")
os.environ.setdefault("CELERY_BROKER_URL", "memory://")
os.environ.setdefault("CELERY_RESULT_BACKEND", "memory://")
os.environ["RATE_LIMIT_ENABLED"] = "false"
os.environ["DEBUG"] = "true"
os.environ["EXCHANGE_RATE_HOST_KEY"] = ""
os.environ["EGCURRENCY_API_KEY"] = ""
os.environ["OPENAI_API_KEY"] = ""

from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine  # noqa: E402

import app.domain.entities.auth_entities  # noqa: E402,F401
import app.domain.entities.business_entities  # noqa: E402,F401
import app.domain.entities.finance_entities  # noqa: E402,F401
import app.domain.entities.invoice_entities  # noqa: E402,F401
import app.domain.entities.sale_entities  # noqa: E402,F401  (branches + per-branch stock)
import app.domain.entities.branch_entities  # noqa: E402,F401
import app.domain.entities.notification_entities  # noqa: E402,F401
import app.domain.entities.payment_entities  # noqa: E402,F401
import app.domain.entities.personal_entities  # noqa: E402,F401
import app.domain.entities.purchase_entities  # noqa: E402,F401
import app.domain.entities.sales_entities  # noqa: E402,F401
import app.domain.entities.subscription_invoice_entities  # noqa: E402,F401
import app.domain.entities.suggestions_entities  # noqa: E402,F401
import app.domain.entities.sync_entities  # noqa: E402,F401
from app.core.database import Base  # noqa: E402
from app.core.security import create_access_token  # noqa: E402
from app.domain.entities.auth_entities import (  # noqa: E402
    Organization,
    User,
    UserSession,
)


async def seed() -> dict:
    engine = create_async_engine(f"sqlite+aiosqlite:///{DB_PATH}")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)

    factory = async_sessionmaker(engine, expire_on_commit=False)
    org_id = uuid4()
    user_id = uuid4()
    session_id = uuid4()
    async with factory() as db:
        org = Organization(id=org_id, name="E2E Org", slug=f"e2e-{org_id.hex[:8]}")
        user = User(
            id=user_id,
            organization_id=org_id,
            full_name="E2E User",
            email=f"e2e_{user_id.hex[:8]}@test.local",
            role="owner",
            is_platform_admin=True,
            status="active",
        )
        session = UserSession(
            id=session_id,
            user_id=user_id,
            refresh_token=f"e2e-refresh-{uuid4().hex}",
            device_name="e2e-runner",
            is_active=True,
            is_primary=True,
            expires_at=datetime.now(timezone.utc) + timedelta(days=30),
        )
        db.add_all([org, user, session])
        await db.commit()

    await engine.dispose()
    token = create_access_token(str(user_id), str(org_id), "owner", str(session_id))
    return {
        "token": token,
        "user_id": str(user_id),
        "org_id": str(org_id),
        "session_id": str(session_id),
        "db": DB_PATH,
    }


def main() -> None:
    info = asyncio.run(seed())
    print("E2E_READY " + json.dumps(info), flush=True)

    import uvicorn

    from app.main import app

    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="info")


if __name__ == "__main__":
    main()
