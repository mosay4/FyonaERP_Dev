"""Stage 1 branch core: main branch naming, create/rename/archive/reactivate,
main protection, archived rejection, and the all-branches read-only guard."""

import asyncio
import os
import sys
import uuid

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import delete  # noqa: E402
from app.api.v1 import reconciliation as _R  # noqa: E402,F401
from app.core.all_branches_guard import all_branches_blocked  # noqa: E402
from app.core.database import async_session_factory  # noqa: E402
from app.domain.entities.auth_entities import Organization, User  # noqa: E402
from app.domain.entities.sale_entities import Branch  # noqa: E402
from app.domain.services import branch_service as svc  # noqa: E402

PASS, FAIL = [], []


def check(name, cond, extra=""):
    (PASS if cond else FAIL).append(name)
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" {extra}"))


async def main():
    tag = uuid.uuid4().hex[:6]
    async with async_session_factory() as db:
        org = Organization(name=f"Business {tag}", slug=f"b-{tag}",
                           subscription_plan="business")
        db.add(org)
        await db.flush()
        user = User(organization_id=org.id, full_name=f"Owner {tag}",
                    email=f"o{tag}@t.local", phone=f"+96770{tag}", role="owner")
        db.add(user)
        await db.commit()

    b1 = b2 = None
    b1_id = b2_id = None
    try:
        async with async_session_factory() as db:
            b1 = await svc.main_branch(db, org.id)
            await db.commit()
            check("main branch name = business name",
                  b1.name == f"Business {tag}", b1.name)
            check("main is_default", b1.is_default is True)

            b2 = await svc.create_branch(db, org.id, f"Branch {tag}")
            b1_id, b2_id = b1.id, b2.id
            await db.commit()
            check("second branch created", b2 is not None and not b2.is_default)
            try:
                await svc.create_branch(db, org.id, f"Branch {tag}")
                check("duplicate branch name rejected", False)
            except ValueError as e:
                check("duplicate branch name rejected", "بالفعل" in str(e))
                await db.rollback()

        async with async_session_factory() as db:
            b2 = await svc.rename_branch(db, org.id, b2_id, f"Renamed {tag}")
            await db.commit()
            check("rename works", b2.name == f"Renamed {tag}")
            try:
                await svc.archive_branch(db, org.id, b1_id)
                check("main cannot be archived", False)
            except ValueError as e:
                check("main cannot be archived", "الرئيسي" in str(e))
                await db.rollback()

        async with async_session_factory() as db:
            b2 = await svc.archive_branch(db, org.id, b2_id)
            await db.commit()
            check("extra branch archived",
                  b2.is_archived is True and b2.is_active is False)
            try:
                await svc.resolve_branch_for_context(db, org.id, b2_id)
                check("archived branch rejected", False)
            except ValueError as e:
                check("archived branch rejected", "مؤرشف" in str(e))

        async with async_session_factory() as db:
            b2 = await svc.reactivate_branch(db, org.id, b2_id)
            await db.commit()
            check("reactivate restores",
                  b2.is_archived is False and b2.is_active is True)
            active = await svc.resolve_branch_for_context(db, org.id, b2_id)
            check("reactivated branch resolves", active.id == b2.id)

        # ── Server-issued branch scope token ──
        async with async_session_factory() as db:
            tok = svc.issue_scope_token(user.id, org.id, b1_id, False)
            payload = svc.decode_scope_token(tok)
            check("scope token binds user/org/branch",
                  payload is not None and payload.get("org") == str(org.id)
                  and payload.get("branch") == str(b1_id)
                  and payload.get("mode") == "branch", str(payload))
            all_tok = svc.issue_scope_token(user.id, org.id, None, True)
            check("all-mode token", svc.decode_scope_token(all_tok).get("mode") == "all")
            check("tampered token rejected",
                  svc.decode_scope_token(tok + "x") is None)
            from app.core.all_branches_guard import token_is_all
            check("guard recognizes signed all-mode token",
                  token_is_all(all_tok) is True)
            check("guard ignores invalid all token", token_is_all("bad") is False)
            check("all token blocks POST",
                  all_branches_blocked("POST", "/api/v1/customers",
                                       None, all_tok) is True)
            check("all token allows GET",
                  all_branches_blocked("GET", "/api/v1/customers",
                                       None, all_tok) is False)

        # All-branches read-only guard (legacy header still blocked)
        check("all-mode blocks POST", all_branches_blocked(
            "POST", "/api/v1/customers", "all") is True)
        check("all-mode blocks PATCH", all_branches_blocked(
            "PATCH", "/api/v1/invoices/1", "all") is True)
        check("all-mode allows GET", all_branches_blocked(
            "GET", "/api/v1/customers", "all") is False)
        check("all-mode allows auth/session writes", all_branches_blocked(
            "POST", "/api/v1/auth/me", "all") is False)
        check("normal branch scope is not blocked", all_branches_blocked(
            "POST", "/api/v1/customers", "branch") is False)
    finally:
        async with async_session_factory() as db:
            await db.execute(delete(Branch).where(
                Branch.organization_id == org.id))
            await db.execute(delete(User).where(User.id == user.id))
            await db.execute(delete(Organization).where(
                Organization.id == org.id))
            await db.commit()

    print(f"\nPASS={len(PASS)} FAIL={len(FAIL)}")
    if FAIL:
        print("FAILED:", FAIL)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
