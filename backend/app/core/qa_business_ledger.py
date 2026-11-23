"""Device-only Business ledger trial for explicitly enrolled new QA branches.

The built-in directory fixture, an existing directory enrollment, and a
new ledger enrollment are distinct. Installing the schema does not enroll
anything. Enrollment is optional, in the transaction creating a new QA
branch; it is not a migration of any previously selected branch.

This is a first-device enrollment, never a migration. Any branch that already
holds legacy financial rows needs the complete documented cutover instead; the
claim is withheld in that case, so the branch keeps its connected behaviour.
"""

import json
import os
from hashlib import sha256
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from app.core.qa_directory import INVITES
from app.domain.services.local_business_cutover import _rules

SCOPE_TABLE = "public.fyona_qa_business_ledger_scope"
PAIR_WRITERS = "public.fyona_qa_ledger_pair_writers"
_OWNERSHIP_FUNCTION = "qa_ledger_row_branches"
# Shared or online-only records stay outside the device ledger. Everything
# else that writes the Business financial ledger is fenced for this branch.
_UNFENCED = frozenset({
    "branches",
    "branch_invitations",
    "org_invoice_designs",
    "merchant_links",
    "settlement_requests",
    "expiry_notifications",
})
FENCED_TABLES = tuple(name for name in sorted(_rules) if name not in _UNFENCED)
# Even a zero-balance account may carry an identity or configuration users
# need. Do not discard it, older order/receipt documents, or their references
# in the first-device flow. Only the separately governed directory is exempt.
GATED_TABLES = tuple(
    name for name in FENCED_TABLES if name not in {"customers", "suppliers"}
)


def _ownership_sql() -> str:
    cases = []
    for table, rule in _rules.items():
        direct = ", ".join(f"(row_data ->> '{column}')::uuid" for column in rule.direct)
        parts = [f"ARRAY[{direct}]::uuid[]"]
        for parent in rule.parents:
            filter_sql = ""
            if parent.discriminator:
                field, value = parent.discriminator
                filter_sql = f"AND row_data ->> '{field}' = '{value}'"
            parts.append(f"""COALESCE((
                SELECT {_OWNERSHIP_FUNCTION}('{parent.table}', to_jsonb(p))
                FROM public.{parent.table} p
                WHERE p.id = (row_data ->> '{parent.column}')::uuid {filter_sql}
            ), ARRAY[]::uuid[])""")
        cases.append(
            f"WHEN '{table}' THEN RETURN array_remove({' || '.join(parts)}, NULL);"
        )
    return f"""
        CREATE OR REPLACE FUNCTION {_OWNERSHIP_FUNCTION}(table_name text, row_data jsonb)
        RETURNS uuid[] LANGUAGE plpgsql VOLATILE
        SET search_path = pg_catalog, public AS $$
        BEGIN
          CASE table_name
            {' '.join(cases)}
          ELSE
            RAISE EXCEPTION 'Unknown QA ledger table';
          END CASE;
        END;
        $$
    """


def _guard_sql() -> str:
    tables = ", ".join(f"public.{name}" for name in FENCED_TABLES)
    return f"""
        CREATE OR REPLACE FUNCTION qa_ledger_write_guard()
        RETURNS trigger LANGUAGE plpgsql VOLATILE
        SET search_path = pg_catalog, public AS $$
        DECLARE affected uuid[] := ARRAY[]::uuid[];
        BEGIN
          IF TG_OP <> 'INSERT' THEN
            affected := {_OWNERSHIP_FUNCTION}(TG_TABLE_NAME, to_jsonb(OLD));
          END IF;
          IF TG_OP <> 'DELETE' THEN
            affected := affected || {_OWNERSHIP_FUNCTION}(TG_TABLE_NAME, to_jsonb(NEW));
          END IF;
          IF EXISTS (SELECT 1 FROM {SCOPE_TABLE} WHERE branch_id = ANY(affected)) THEN
            RAISE EXCEPTION 'QA business ledger is device-only' USING ERRCODE = '23514';
          END IF;
          IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
          RETURN NEW;
        END;
        $$
    """


async def _legacy_empty(conn, branch_id: UUID, *, approved_default_cash=False) -> bool:
    for table in GATED_TABLES:
        if table == "bank_accounts" and approved_default_cash:
            continue
        count = await conn.scalar(text(f"""
            SELECT COUNT(*) FROM public.{table} t
            WHERE {_OWNERSHIP_FUNCTION}('{table}', to_jsonb(t))
              && ARRAY[:branch]::uuid[]
        """), {"branch": branch_id})
        if count:
            return False
    return True


async def default_cash_fingerprint(conn, organization_id: UUID, branch_id: UUID) -> str | None:
    """Identify untouched legacy placeholder cards, not arbitrary zero accounts."""
    rows = (await conn.execute(text("""
        SELECT id, currency, account_type,
               (organization_id = :org AND bank_name = 'كاش'
                AND account_name = 'حساب الكاش' AND account_number = 'CASH'
                AND account_type IN ('cash', 'checking') AND balance = 0
                AND iban IS NULL AND bank_group_key IS NULL AND deleted_at IS NULL
                AND is_active IS TRUE AND is_deleted IS FALSE) IS TRUE AS placeholder
          FROM public.bank_accounts WHERE branch_id = :branch ORDER BY id
    """), {"org": organization_id, "branch": branch_id})).all()
    currencies = {row.currency for row in rows}
    if not rows or len(currencies) != len(rows) or not currencies <= {
        "SAR", "USD", "YER_OLD", "YER_NEW",
    } or not all(row.placeholder for row in rows):
        return None
    return sha256(json.dumps([(str(r.id), r.currency, r.account_type) for r in rows],
                             separators=(",", ":")).encode()).hexdigest()


def _existing_grant(user, branch):
    # This credential is supplied only by the private managed QA launcher.
    # Never discover exceptions from client input or while enrolling branches.
    if not INVITES or os.getenv("FYONA_QA_REMOTE") != "1":
        return None
    grants = json.loads(os.getenv("FYONA_QA_EXISTING_LEDGER_GRANTS", "{}"))
    candidate = grants.get(str(branch.id))
    if (
        isinstance(candidate, dict)
        and candidate.get("account") == str(user.id)
        and candidate.get("organization") == str(user.organization_id)
        and user.organization_id == branch.organization_id
        and user.role == "owner"
        and branch.is_default is False
        and branch.is_active
        and not branch.is_archived
    ):
        return candidate
    return None


async def install(engine: AsyncEngine):
    """One-time QA schema. Never called by the application itself."""
    async with engine.begin() as conn:
        await conn.execute(text(f"""
            CREATE TABLE IF NOT EXISTS {SCOPE_TABLE} (
              organization_id UUID PRIMARY KEY,
              account_id UUID NOT NULL,
              branch_id UUID NOT NULL UNIQUE
            )
        """))
        await conn.execute(text(f"""
            CREATE TABLE IF NOT EXISTS {PAIR_WRITERS} (
              organization_id UUID PRIMARY KEY,
              account_id UUID NOT NULL,
              session_id UUID NOT NULL
            )
        """))
        # Every account may register its two branches on the device store.
        # This additive registry change runs once; existing rows keep slot 1.
        for name in ("fyona_qa_directory_scope", "fyona_qa_business_ledger_scope"):
                if not await conn.scalar(text("""
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema='public' AND table_name=:table AND column_name='slot'
                """), {"table": name}):
                    await conn.execute(text(f"""
                        ALTER TABLE public.{name}
                        ADD COLUMN slot SMALLINT NOT NULL DEFAULT 1 CHECK (slot IN (1, 2)),
                        DROP CONSTRAINT {name}_pkey,
                        ADD PRIMARY KEY (organization_id, slot)
                    """))
        await conn.execute(text(_ownership_sql()))
        await conn.execute(text(_guard_sql()))
        if INVITES:
            from app.domain.services.qa_business_party_sharing import install as install_sharing
            await install_sharing(conn)
            from app.domain.services import qa_employee_finance
            if qa_employee_finance.enabled():
                await qa_employee_finance.install(conn)
        for name in FENCED_TABLES:
            await conn.execute(text(f"""
                DROP TRIGGER IF EXISTS qa_ledger_guard ON public.{name}
            """))
            await conn.execute(text(f"""
                CREATE TRIGGER qa_ledger_guard
                BEFORE INSERT OR UPDATE OR DELETE ON public.{name}
                FOR EACH ROW EXECUTE FUNCTION qa_ledger_write_guard()
            """))


def _pair_invite():
    configured = os.getenv("FYONA_QA_LEDGER_PAIR_OWNER")
    return configured if configured in INVITES else None


async def bind_new_ledger_branch(db: AsyncSession, owner, branch, *, session_id=None):
    """Only call from the explicit new-branch creation transaction. Every
    account may register its two branches on the device store, from any of its
    own live devices. A third branch is never adopted."""
    if (
        os.environ.get("FYONA_QA_ENROLL_NEW_LEDGER") != "1"
        or owner.email not in INVITES
        or owner.role != "owner"
        or owner.organization_id != branch.organization_id
        or branch.is_default is not False
        or not branch.is_active
        or branch.is_archived
    ):
        return
    registered = await db.scalar(text("""
        SELECT 1 FROM public.fyona_qa_directory_scope
        WHERE organization_id = :organization AND account_id = :account AND branch_id = :branch
    """), {"organization": owner.organization_id, "account": owner.id, "branch": branch.id})
    if not await _legacy_empty(db, branch.id):
        return
    params = {"organization": owner.organization_id, "account": owner.id, "branch": branch.id}
    registered_rows = await db.scalar(text(f"""
        SELECT COUNT(*) FROM {SCOPE_TABLE} WHERE organization_id=:organization
    """), params)
    if not registered_rows:
        # The directory-first branch opens the account's device store.
        if registered is None:
            return
        if isinstance(session_id, UUID):
            from app.api.v1.qa_business_session import lock_live_user
            if not await lock_live_user(db, owner.id, session_id):
                return
            await db.execute(text(f"""
                INSERT INTO {PAIR_WRITERS} (organization_id, account_id, session_id)
                VALUES (:organization, :account, :session)
            """), {**params, "session": session_id})
    else:
        # The second branch joins the same store; a third is never adopted.
        if registered is not None or registered_rows > 1:
            return
        if not await db.scalar(text(f"""
            SELECT 1 FROM {SCOPE_TABLE} l JOIN public.branches b ON b.id=l.branch_id
            WHERE l.organization_id=:organization AND l.account_id=:account AND l.slot=1
              AND b.is_active AND NOT b.is_archived AND NOT b.is_default
        """), params):
            return
        for table in ("public.fyona_qa_directory_scope", SCOPE_TABLE):
            await db.execute(text(f"""
                INSERT INTO {table} (organization_id, account_id, branch_id, slot)
                VALUES (:organization, :account, :branch, 2)
            """), params)
        return
    await db.execute(text(f"""
        INSERT INTO {SCOPE_TABLE} (organization_id, account_id, branch_id)
        VALUES (:organization, :account, :branch)
        ON CONFLICT DO NOTHING
    """), params)


async def pair_writer_scope(db, user, branch, session_id):
    """The account's registered branches on any of its devices. None when this
    branch is not on the device store."""
    if not INVITES or user.organization_id != branch.organization_id:
        return None
    peers = (await db.execute(text(f"""
        SELECT b.id, b.name FROM {SCOPE_TABLE} l JOIN public.branches b
          ON b.id=l.branch_id AND b.organization_id=l.organization_id
        WHERE l.organization_id=:org AND l.account_id=:account
          AND b.is_active AND NOT b.is_archived AND NOT b.is_default
        ORDER BY l.slot
    """), {"org": branch.organization_id, "account": user.id})).all()
    return {str(peer.id): peer.name for peer in peers} or None


async def for_owner(db: AsyncSession, user, branch) -> bool:
    """The claim exists only for the registered account while it is still the
    branch's sole writer. Registration itself is the authorization: it is
    created only by the pinned enrollment paths, and it names one account."""
    incumbent = _existing_grant(user, branch)
    if await registered_owner(db, user, branch):
        approved = incumbent and incumbent.get("default_cash_sha256")
        matched = bool(approved) and approved == await default_cash_fingerprint(
            db, branch.organization_id, branch.id,
        )
        return await _legacy_empty(db, branch.id, approved_default_cash=matched)
    if incumbent and incumbent.get("pinned_fixture") is True \
            and str(branch.id) == os.getenv("FYONA_QA_BRANCH") and user.email not in INVITES:
        # Preserve only the pre-existing sandbox fixture, without granting it
        # an invite or access to the new remote sharing transports.
        existing = await db.scalar(text(f"""
            SELECT 1 FROM {SCOPE_TABLE}
            WHERE organization_id = :org AND account_id = :account AND branch_id = :branch
        """), {"org": branch.organization_id, "account": user.id, "branch": branch.id})
        return existing is not None and await _legacy_empty(db, branch.id)
    return False


async def registered_owner(db: AsyncSession, user, branch) -> bool:
    """Current registry check for an already-issued *signed* grant. This
    never issues or renews a grant and is not a legacy-emptiness attestation."""
    if (
        user.email not in INVITES
        or user.role != "owner"
        or user.organization_id != branch.organization_id
        or branch.is_default is not False
        or not branch.is_active
        or branch.is_archived
    ):
        return False
    registered = await db.scalar(text(f"""
        SELECT 1 FROM {SCOPE_TABLE} l
        JOIN public.fyona_qa_directory_scope d USING (organization_id, account_id, branch_id)
        WHERE l.organization_id = :organization AND l.account_id = :account AND l.branch_id = :branch
    """), {"organization": user.organization_id, "account": user.id, "branch": branch.id})
    return registered is not None


async def contains_registered_branch(db: AsyncSession, branch_ids) -> bool:
    """Used by legacy reads which would otherwise lazily write cash rows."""
    ids = [branch_id for branch_id in branch_ids if branch_id is not None]
    if not INVITES or not ids:
        return False
    return await db.scalar(text(f"""
        SELECT EXISTS (SELECT 1 FROM {SCOPE_TABLE} WHERE branch_id = ANY(CAST(:ids AS uuid[])))
    """), {"ids": ids}) is True


async def contains_registered_ledger(db: AsyncSession, organization_id: UUID) -> bool:
    return bool(INVITES) and await db.scalar(text(f"""
        SELECT EXISTS (SELECT 1 FROM {SCOPE_TABLE} WHERE organization_id = :org)
    """), {"org": organization_id}) is True


async def is_registered_branch(session_factory, branch_id) -> bool:
    if not INVITES or branch_id is None:
        return False
    try:
        branch_id = UUID(str(branch_id))
    except ValueError:
        return False
    async with session_factory() as db:
        return await contains_registered_branch(db, [branch_id])
