"""Stage one owner-approved cash measurement for two named devices on QA only."""

import argparse
import asyncio
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess
from uuid import UUID, uuid4

from run_directory_pilot_lab import MANAGED_ENROLL_ROOT


async def main(args):
    unit = "fyona-directory-qa-enroll.service"
    check = subprocess.check_output(
        ["systemctl", "show", unit, "--value", "--property=Environment"], text=True,
    ).split()
    if not args.confirm or not (MANAGED_ENROLL_ROOT / "ready").is_file() or not {
        "FYONA_QA_REMOTE=1", "FYONA_QA_CASH_RELAY=1", "FYONA_QA_CASH_LINK=1",
    }.issubset(check):
        raise SystemExit("Refusing: the plan must be explicitly approved on the managed QA link service.")

    root = MANAGED_ENROLL_ROOT
    pg, redis, *_ = json.loads((root / "ports.json").read_text())
    if type(pg) is not int or not 1024 < pg < 65536 or pg == 5432:
        raise SystemExit("Refusing a non-QA PostgreSQL endpoint")
    os.chdir(Path("/"))
    os.environ.update(
        DATABASE_URL=f"postgresql+asyncpg://directory_pilot:{(root / 'db-password').read_text().strip()}"
                     f"@127.0.0.1:{pg}/directory_pilot",
        REDIS_URL=f"redis://127.0.0.1:{redis}/0",
        JWT_SECRET_KEY="qa-cash-link-operator-db-only",
        CELERY_BROKER_URL="memory://",
        CELERY_RESULT_BACKEND="cache+memory://",
        FYONA_QA_CASH_RELAY="1",
        FYONA_QA_CASH_LINK="1",
    )
    from app.core.database import engine
    from app.domain.services import local_business_cash as cash, qa_cash_admission as link

    try:
        async with engine.begin() as conn:
            await link.stage(
                conn, cash.CashScope(args.organization, args.branch),
                plan=uuid4(), actor=args.owner, primary=args.primary_session,
                replica=args.second_session, currency=args.currency,
                balance_minor=args.measured_minor, check_ref=args.reconciliation_ref,
                expires_at=datetime.now(timezone.utc) + timedelta(minutes=30),
            )
    finally:
        await engine.dispose()
    print("QA plan saved. No resource or movement exists until both devices confirm their local reservation.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("organization", "branch", "owner", "primary-session", "second-session"):
        parser.add_argument(f"--{name}", required=True, type=UUID)
    parser.add_argument("--currency", required=True)
    parser.add_argument("--measured-minor", required=True, type=int)
    parser.add_argument("--reconciliation-ref", required=True)
    parser.add_argument("--confirm", action="store_true",
                        help="Owner approved two named QA devices and the observed cash amount.")
    asyncio.run(main(parser.parse_args()))
