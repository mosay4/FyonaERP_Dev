"""Audit continuity for the already enrolled QA branches, without DB writes."""
import asyncio
import json
import os
from urllib.parse import urlsplit

from run_directory_pilot_lab import MANAGED_ENROLL_ROOT, PILOT


async def audit():
    db = urlsplit(os.environ["DATABASE_URL"])
    run = MANAGED_ENROLL_ROOT
    port = json.loads((run / "ports.json").read_text())[0]
    if (db.hostname, db.port, db.username, db.path, db.password) != (
        "127.0.0.1", port, "directory_pilot", "/directory_pilot",
        (run / "db-password").read_text().strip(),
    ):
        raise SystemExit("Managed grant audit is limited to the enrollment database")

    from sqlalchemy import text
    from app.core import qa_business_ledger as ledger
    from app.core.database import engine

    delivery_invite = (run / "signup-email-1").read_text().strip()
    result = {}
    try:
        async with engine.begin() as conn:
            await conn.execute(text("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY"))
            existing = (await conn.execute(text("""
                SELECT l.organization_id, l.account_id, l.branch_id,
                       d.branch_id IS NOT NULL AS has_directory,
                       u.email = :email AS delivery_invite
                  FROM fyona_qa_business_ledger_scope l
                  JOIN users u ON u.id=l.account_id AND u.organization_id=l.organization_id
                  JOIN branches b ON b.id=l.branch_id AND b.organization_id=l.organization_id
                  LEFT JOIN fyona_qa_directory_scope d ON (d.organization_id, d.account_id, d.branch_id)
                                                      = (l.organization_id, l.account_id, l.branch_id)
                 WHERE u.role='owner' AND u.status='active'
                   AND b.is_active AND NOT b.is_archived AND NOT b.is_default
            """), {"email": delivery_invite})).all()
            for row in existing:
                org, account, branch = map(str, (row.organization_id, row.account_id, row.branch_id))
                grant = {"organization": org, "account": account}
                if row.delivery_invite and row.has_directory:
                    if not await ledger._legacy_empty(conn, row.branch_id):
                        digest = await ledger.default_cash_fingerprint(conn, row.organization_id, row.branch_id)
                        if not digest or not await ledger._legacy_empty(
                            conn, row.branch_id, approved_default_cash=True,
                        ):
                            raise RuntimeError("Existing QA delivery branch needs a real cutover")
                        grant["default_cash_sha256"] = digest
                    result[branch] = grant
                elif (org, account, branch) == (PILOT["organization"], PILOT["account"], PILOT["branch"]):
                    if not await ledger._legacy_empty(conn, row.branch_id):
                        raise RuntimeError("Existing QA fixture is not device-only")
                    result[branch] = {**grant, "pinned_fixture": True}
            if (sum("pinned_fixture" not in v for v in result.values()) != 1
                    or PILOT["branch"] not in result):
                raise RuntimeError("Unexpected registered QA scopes; review before switching releases")
    finally:
        await engine.dispose()
    return result


if __name__ == "__main__":
    print(json.dumps(asyncio.run(audit())))
