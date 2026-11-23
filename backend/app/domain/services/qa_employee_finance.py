"""Read copies of committed device receipts, not a second payroll ledger."""
import json
import os
from datetime import datetime, timezone
from hashlib import sha256
from typing import Literal
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, model_validator
from sqlalchemy import and_, select, text

from app.core import qa_directory
from app.domain.entities.auth_entities import User
from app.domain.entities.branch_entities import BranchMember
from app.domain.entities.employee_workspace_entities import EmployeeInvitation, EmployeeWorkspace
from app.domain.entities.hr_entities import Employee
from . import branch_access_service as access

PUBLISHERS = "public.fyona_qa_employee_finance_publishers"
SNAPSHOTS = "public.fyona_qa_employee_finance_snapshots"


def enabled():
    return bool(qa_directory.INVITES) and os.getenv("FYONA_QA_EMPLOYEE_FINANCE") == "1"


async def available(db):
    return enabled() and db.get_bind().dialect.name == "postgresql" and await db.scalar(text(f"""
        SELECT to_regclass('{SNAPSHOTS}') IS NOT NULL
           AND to_regclass('{PUBLISHERS}') IS NOT NULL
    """))


async def install(conn):
    await conn.execute(text(f"""
        CREATE TABLE IF NOT EXISTS {PUBLISHERS} (
          branch_id uuid PRIMARY KEY REFERENCES public.fyona_qa_business_ledger_scope(branch_id),
          session_id uuid NOT NULL
        )
    """))
    await conn.execute(text(f"""
        CREATE TABLE IF NOT EXISTS {SNAPSHOTS} (
          branch_id uuid NOT NULL REFERENCES {PUBLISHERS}(branch_id),
          employee_id uuid NOT NULL,
          recipient_id uuid NOT NULL,
          grant_revision text NOT NULL,
          version integer NOT NULL CHECK (version > 0),
          records jsonb NOT NULL,
          PRIMARY KEY (branch_id, employee_id)
        )
    """))


async def registered_account(db, branch):
    from app.core.qa_business_ledger import SCOPE_TABLE
    if branch.is_default or branch.is_archived or not branch.is_active:
        return None
    return await db.scalar(text(f"""
        SELECT l.account_id FROM {SCOPE_TABLE} l
        JOIN public.fyona_qa_directory_scope d USING (organization_id, account_id, branch_id)
        JOIN public.users u ON u.id = l.account_id AND u.organization_id = l.organization_id
        WHERE l.organization_id = :org AND l.branch_id = :branch
          AND u.status = 'active' AND u.role = 'owner'
          AND u.email = ANY(CAST(:invites AS text[]))
        FOR SHARE OF l, d
    """), {"org": branch.organization_id, "branch": branch.id,
           "invites": sorted(qa_directory.INVITES)})


async def recipients(db, branch, *, user_id=None):
    """Only real accepted employment, with current access to this exact branch.

    A branch invitation, an owner of another business, or a link without a
    matching member never inherits access to the device records.
    """
    org = branch.organization_id
    query = select(Employee, EmployeeWorkspace, BranchMember, EmployeeInvitation.id).join(
        EmployeeWorkspace, and_(EmployeeWorkspace.employee_id == Employee.id,
                                EmployeeWorkspace.organization_id == org),
    ).join(BranchMember, and_(BranchMember.user_id == EmployeeWorkspace.linked_user_id,
                             BranchMember.organization_id == org),
    ).join(EmployeeInvitation, and_(
        EmployeeInvitation.employee_id == Employee.id,
        EmployeeInvitation.organization_id == org,
        EmployeeInvitation.invited_user_id == BranchMember.user_id,
        EmployeeInvitation.status == "accepted",
    )).join(User, User.id == BranchMember.user_id).where(
        Employee.organization_id == org, Employee.is_deleted.is_(False), Employee.status == "active",
        BranchMember.status == "active", User.status == "active",
    )
    if user_id is not None:
        query = query.where(BranchMember.user_id == user_id)
    rows = (await db.execute(query.with_for_update(
        read=True, of=[Employee, EmployeeWorkspace, BranchMember, EmployeeInvitation],
    ).execution_options(populate_existing=True))).all()
    # Duplicate linked files for one account are ambiguous. Fail closed for
    # that account instead of picking the first one.
    counts = {}
    for _, _, member, _ in rows:
        counts[member.user_id] = counts.get(member.user_id, 0) + 1
    return [
        (employee, workspace, member, sha256(json.dumps([
            str(member.id), str(member.updated_at), str(member.scope_valid_after),
            member.branch_ids, member.all_branches, member.permissions, workspace.branch_ids, str(invite),
        ], separators=(",", ":")).encode()).hexdigest(), invite)
        for employee, workspace, member, invite in rows
        if counts[member.user_id] == 1
        and (member.all_branches or branch.id in access._ids(member.branch_ids))
        and (workspace.branch_ids is None or branch.id in access._ids(workspace.branch_ids))
    ]


async def select_claim(db, user, branch):
    if user.status != "active" or access.is_owner(user, branch.organization_id) \
            or not await available(db) or await registered_account(db, branch) is None:
        return None
    rows = await recipients(db, branch, user_id=user.id)
    if len(rows) != 1:
        return None
    employee, _, _, revision, _ = rows[0]
    return {"employee_id": str(employee.id), "revision": revision}


class Receipt(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: UUID
    kind: Literal["salary", "debt", "debt_settlement"]
    currency: str = Field(pattern=r"^[A-Z][A-Z0-9_]{1,19}$")
    amount_minor: int = Field(strict=True, gt=0, le=999_999_999_999)
    created_at: AwareDatetime
    notes: str | None = Field(default=None, max_length=200)
    bank_name: str | None = Field(default=None, max_length=200)
    cash_effect: Literal["none", "debit"] | None = None
    direction: Literal["employee_owes", "employer_owes"] | None = None
    original_id: UUID | None = None
    remaining_minor: int | None = Field(default=None, strict=True, ge=0, le=999_999_999_999)


class Publication(BaseModel):
    model_config = ConfigDict(extra="forbid")
    grant_revision: str = Field(pattern=r"^[a-f0-9]{64}$")
    expected_version: int = Field(strict=True, ge=0, lt=2**31 - 1)
    receipts: list[Receipt] = Field(max_length=2000)

    @model_validator(mode="after")
    def complete(self):
        ids = set()
        debts = {}
        settlements = {}
        for row in self.receipts:
            if row.id in ids:
                raise ValueError("Repeated receipt")
            ids.add(row.id)
            if row.kind == "salary":
                if row.direction is not None or row.original_id is not None or row.remaining_minor is not None:
                    raise ValueError("Invalid salary receipt")
            elif row.kind == "debt":
                if row.direction is None or row.original_id is not None or row.remaining_minor is not None:
                    raise ValueError("Invalid debt receipt")
                debts[row.id] = row
            else:
                if row.direction is None or row.original_id is None or row.remaining_minor is None:
                    raise ValueError("Invalid settlement receipt")
                steps = settlements.setdefault(row.original_id, {})
                before = row.amount_minor + row.remaining_minor
                if before in steps:
                    raise ValueError("Conflicting settlements")
                steps[before] = row
        for debt_id, steps in settlements.items():
            debt = debts.get(debt_id)
            if debt is None:
                raise ValueError("Incomplete debt history")
            remaining = debt.amount_minor
            for _ in steps:
                row = steps.get(remaining)
                if row is None or debt.currency != row.currency or debt.direction != row.direction:
                    raise ValueError("Incomplete debt history")
                remaining = row.remaining_minor
        return self

    def records(self):
        return [
            row.model_dump(mode="json", exclude_none=True)
            for row in sorted(self.receipts, key=lambda row: row.id)
        ]


async def snapshot(db, branch_id, employee_id):
    return (await db.execute(text(f"""
        SELECT recipient_id, grant_revision, version, records
        FROM {SNAPSHOTS} WHERE branch_id = :branch AND employee_id = :employee
    """), {"branch": branch_id, "employee": employee_id})).mappings().one_or_none()


def finance_view(records, employee, organization, branch):
    """The same fields the existing self-service screens already display."""
    def money(minor):
        # Keep the signed amounts exact instead of casting money to float.
        whole, cents = divmod(abs(minor), 100)
        return f"{'-' if minor < 0 else ''}{whole}.{cents:02}"

    settled = {}
    for row in records:
        if row["kind"] == "debt_settlement":
            original = row["original_id"]
            settled[original] = settled.get(original, 0) + row["amount_minor"]
    salary, debts, balances = [], [], {}
    for row in sorted(records, key=lambda row: (
        datetime.fromisoformat(row["created_at"]).astimezone(timezone.utc), row["id"]
    ), reverse=True):
        minor, currency = row["amount_minor"], row["currency"]
        receipt = {
            "id": row["id"], "invoice_no": row["id"], "amount": money(minor),
            "currency": currency, "payment_currency": currency,
            "notes": row.get("notes"), "bank_name": row.get("bank_name"),
            "cash_effect": row.get("cash_effect"),
            "employee_name": employee.full_name, "organization_name": organization.name,
            "branch_name": branch.name,
        }
        if row["kind"] == "salary":
            salary.append({**receipt, "paid_at": row["created_at"]})
            continue
        if row["kind"] == "debt":
            remaining = minor - settled.get(row["id"], 0)
            sign = 1 if row["direction"] == "employee_owes" else -1
            balances[currency] = balances.get(currency, 0) + sign * remaining
            receipt.update(kind="charge", outstanding_amount=money(remaining))
        else:
            receipt.update(kind="settlement", original_debt_invoice=row["original_id"],
                           remaining_amount=money(row["remaining_minor"]), base_currency=currency)
        debts.append({**receipt, "created_at": row["created_at"], "direction": row["direction"]})
    return {
        "employee_id": str(employee.id), "organization_id": str(organization.id),
        "salary": salary, "debts": debts, "balances": {c: money(n) for c, n in balances.items()},
    }
