"""First-branch directory enrollment for an owned, disposable QA database."""

import json
import os
import re
from urllib.parse import urlsplit
from uuid import UUID

from sqlalchemy import text

from app.core.config import settings


def _invited_emails():
    raw = os.environ.get("FYONA_QA_DIRECTORY_INVITES")
    if raw is None:
        return frozenset()
    db = urlsplit(settings.DATABASE_URL)
    if (db.hostname, db.username, db.path) != ("127.0.0.1", "directory_pilot", "/directory_pilot"):
        raise RuntimeError("Directory enrollment may only use its disposable QA database")
    emails = json.loads(raw)
    if not isinstance(emails, list) or not emails or not all(
        isinstance(e, str) and re.fullmatch(r"signup-[a-f0-9]{24}@example\.test", e)
        for e in emails
    ):
        raise RuntimeError("Expected private synthetic QA invites")
    return frozenset(emails)


INVITES = _invited_emails()


async def install(engine):
    if not INVITES:
        return
    async with engine.begin() as conn:
        # Keep an organization bound to the first explicit branch, even if that
        # branch is later archived or removed. Another branch is never promoted.
        await conn.execute(text("""
            CREATE TABLE IF NOT EXISTS fyona_qa_directory_scope (
              organization_id UUID PRIMARY KEY,
              account_id UUID NOT NULL,
              branch_id UUID NOT NULL UNIQUE
            )
        """))
        await conn.execute(text("""
            CREATE OR REPLACE FUNCTION fyona_qa_directory_write_guard()
            RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF TG_OP <> 'INSERT' THEN
                IF EXISTS (SELECT 1 FROM fyona_qa_directory_scope WHERE branch_id = OLD.branch_id) THEN
                  RAISE EXCEPTION 'QA directory is device-only' USING ERRCODE = '23514';
                END IF;
              END IF;
              IF TG_OP = 'DELETE' THEN
                RETURN OLD;
              END IF;
              IF EXISTS (SELECT 1 FROM fyona_qa_directory_scope WHERE branch_id = NEW.branch_id) THEN
                RAISE EXCEPTION 'QA directory is device-only' USING ERRCODE = '23514';
              END IF;
              RETURN NEW;
            END
            $$
        """))
        for party_table in ("customers", "suppliers"):
            await conn.execute(text(
                f"DROP TRIGGER IF EXISTS fyona_qa_directory_guard ON {party_table}"
            ))
            await conn.execute(text(f"""
                CREATE TRIGGER fyona_qa_directory_guard
                BEFORE INSERT OR UPDATE OR DELETE ON {party_table}
                FOR EACH ROW EXECUTE FUNCTION fyona_qa_directory_write_guard()
            """))


async def bind_first_branch(db, owner, branch):
    """Runs inside the original branch-create transaction and registry lock."""
    if (not INVITES or owner.email not in INVITES or
            owner.role != "owner" or owner.organization_id != branch.organization_id or
            branch.is_default is not False):
        return
    await db.execute(text("""
        INSERT INTO fyona_qa_directory_scope (organization_id, account_id, branch_id)
        VALUES (:organization, :account, :branch)
        ON CONFLICT DO NOTHING
    """), {"organization": owner.organization_id, "account": owner.id, "branch": branch.id})


async def for_owner(db, user, branch) -> bool:
    if (not INVITES or user.email not in INVITES or user.role != "owner" or
            user.organization_id != branch.organization_id or not branch.is_active or
            branch.is_archived):
        return False
    found = await db.scalar(text("""
        SELECT 1 FROM fyona_qa_directory_scope
        WHERE organization_id = :organization AND account_id = :account AND branch_id = :branch
    """), {"organization": user.organization_id, "account": user.id, "branch": branch.id})
    return found is not None


async def is_registered_branch(session_factory, branch_id) -> bool:
    if not INVITES or branch_id is None:
        return False
    try:
        branch_id = UUID(str(branch_id))
    except ValueError:
        return False
    async with session_factory() as db:
        return await db.scalar(text("""
            SELECT 1 FROM fyona_qa_directory_scope WHERE branch_id = :branch
        """), {"branch": branch_id}) is not None
