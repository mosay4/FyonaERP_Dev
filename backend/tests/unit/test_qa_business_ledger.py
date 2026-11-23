"""First-device Business ledger enrollment: one claim, one writer."""

import json
import os
from decimal import Decimal
from types import SimpleNamespace
from uuid import uuid4

from fastapi import HTTPException, Request
import pytest
import pytest_asyncio
from sqlalchemy import text
from sqlalchemy.engine import URL
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.core import qa_business_ledger, qa_directory
from app.domain.services import local_business_cutover as cutover


@pytest_asyncio.fixture
async def engine():
    socket = os.environ.get("FYONA_TEST_CUTOVER_SOCKET")
    if socket is None:
        pytest.skip("A disposable Business cutover socket is required")
    if not cutover.SOCKET_PATH.fullmatch(socket):
        pytest.fail("Refusing to connect to a non-fixture database")
    db = create_async_engine(URL.create(
        "postgresql+asyncpg", username="root", database=cutover.FIXTURE_DB,
        query={"host": socket},
    ))
    try:
        from app.api.v1 import reconciliation  # noqa: F401
        from app.core.database import Base
        from app.domain.entities import (  # noqa: F401
            accounting_entities, branch_entities, business_settings_entities,
            employee_workspace_entities, hr_entities, invoice_entities,
            merchant_entities, purchase_entities, sales_entities,
        )
        async with db.begin() as conn:
            await cutover._require_socket(conn, socket)
            await conn.run_sync(Base.metadata.create_all)
            await conn.execute(text("""
                CREATE TABLE IF NOT EXISTS public.fyona_qa_directory_scope (
                  organization_id UUID PRIMARY KEY,
                  account_id UUID NOT NULL,
                  branch_id UUID NOT NULL UNIQUE
                )
            """))
            installed = await conn.scalar(text(
                "SELECT to_regclass('public.fyona_qa_business_cutovers') IS NOT NULL"
            ))
        if not installed:
            await cutover.install_fixture_guard(db)
        yield db
    finally:
        await db.dispose()


async def _seed(engine, email):
    from app.domain.entities.auth_entities import Organization, User
    from app.domain.entities.business_entities import Customer, Product
    from app.domain.entities.sale_entities import Branch

    org, owner, branch, other = uuid4(), uuid4(), uuid4(), uuid4()
    slug = f"ledger-qa-{org.hex}"
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker.begin() as db:
        db.add(Organization(id=org, slug=slug, name="Synthetic QA ledger"))
        await db.flush()
        db.add_all([
            User(id=owner, organization_id=org, role="owner", full_name="QA Owner",
                 email=email),
            Branch(id=branch, organization_id=org, name="Device ledger trial",
                   is_default=False),
            Branch(id=other, organization_id=org, name="Connected sibling",
                   is_default=True),
        ])
        await db.flush()
        db.add(Customer(id=uuid4(), organization_id=org, branch_id=branch, name="Buyer"))
        db.add(Product(id=uuid4(), organization_id=org, branch_id=other,
                       name="Sibling product", price=Decimal("1.00")))
    return org, owner, branch, other


async def _directory_registered(engine, org, owner, branch):
    async with async_sessionmaker(engine, expire_on_commit=False).begin() as db:
        await db.execute(text("""
            INSERT INTO public.fyona_qa_directory_scope
              (organization_id, account_id, branch_id)
            VALUES (:organization, :account, :branch)
            ON CONFLICT DO NOTHING
        """), {"organization": org, "account": owner, "branch": branch})


@pytest.mark.asyncio
async def test_employee_device_copy_is_private_versioned_and_has_no_writer(engine, monkeypatch):
    from datetime import datetime, timedelta, timezone
    from fastapi import FastAPI
    from httpx import ASGITransport, AsyncClient
    from app.api.deps import get_current_session_id, get_current_user_uuid
    from app.api.v1 import branches, qa_employee_finance as transport
    from app.api.v1.employees import employee_finance
    from app.core.database import get_db
    from app.domain.entities.auth_entities import Organization, User, UserSession
    from app.domain.entities.branch_entities import BranchMember
    from app.domain.entities.employee_workspace_entities import EmployeeInvitation, EmployeeWorkspace
    from app.domain.entities.hr_entities import Employee
    from app.domain.services.branch_service import decode_scope_token

    email = f"signup-{uuid4().hex[:24]}@example.test"
    monkeypatch.setattr(qa_business_ledger, "INVITES", frozenset({email}))
    monkeypatch.setattr(qa_directory, "INVITES", frozenset({email}))
    monkeypatch.setenv("FYONA_QA_ENROLL_NEW_LEDGER", "1")
    monkeypatch.setenv("FYONA_QA_EMPLOYEE_FINANCE", "1")
    org, owner, branch, other = await _seed(engine, email)
    await qa_business_ledger.install(engine)
    await _directory_registered(engine, org, owner, branch)
    staff, colleague, unlinked = uuid4(), uuid4(), uuid4()
    file, another_file, invitation = uuid4(), uuid4(), uuid4()
    employer_sessions = [uuid4(), uuid4()]
    sessions = {owner: employer_sessions[0], staff: uuid4(), colleague: uuid4(), unlinked: uuid4()}
    maker = async_sessionmaker(engine, expire_on_commit=False)
    now = datetime.now(timezone.utc)
    async with maker.begin() as db:
        await qa_business_ledger.bind_new_ledger_branch(
            db, _Owner(org, owner, email), _Branch(org, branch),
        )
        shop = await db.get(Organization, org)
        shop.subscription_plan = "business"
        shop.subscription_status = "active"
        shop.subscription_end_date = now + timedelta(hours=6)
        personal = uuid4()
        db.add(Organization(id=personal, name="Fixture personal", slug=personal.hex))
        await db.flush()
        for actor in (staff, colleague, unlinked):
            db.add(User(id=actor, organization_id=personal, full_name="Fixture staff",
                        email=f"{actor.hex}@example.test", role="personal", status="active"))
        await db.flush()
        for actor, sid in [*sessions.items(), (owner, employer_sessions[1])]:
            db.add(UserSession(id=sid, user_id=actor, refresh_token="fixture",
                               expires_at=now + timedelta(days=1)))
        for actor in (staff, colleague, unlinked):
            db.add(BranchMember(organization_id=org, user_id=actor,
                                branch_ids=json.dumps([str(branch), str(other)]),
                                permissions=json.dumps({"banks": False}),
                                status="active"))
        for person, name in ((file, "سالم"), (another_file, "موظف ثاني")):
            db.add(Employee(id=person, organization_id=org, full_name=name,
                            employee_code=person.hex[:10], salary=Decimal("3000"),
                            created_by=owner))
        await db.flush()
        for actor, person, invite in ((staff, file, invitation),
                                      (colleague, another_file, uuid4())):
            db.add(EmployeeWorkspace(employee_id=person, organization_id=org,
                                     linked_user_id=actor, salary_currency="SAR"))
            db.add(EmployeeInvitation(id=invite, organization_id=org, employee_id=person,
                                      invited_user_id=actor, status="accepted"))

    async def select_token(actor, selected, *, all_branches=False):
        async with maker.begin() as db:
            r = await branches.select_branch(branches.BranchSelect(
                organization_id=org, branch_id=selected, all=all_branches,
            ), str(org), actor, db)
            return json.loads(r.body)["data"]["token"]

    token = await select_token(staff, branch)
    claims = decode_scope_token(token)
    assert claims["qa_employee_finance"]["employee_id"] == str(file)
    assert {"qa_directory", "qa_business_ledger"}.isdisjoint(claims)
    async with maker() as db:
        request = Request({
            "type": "http", "path": "/api/v1/employees/me/finance",
            "headers": [(b"x-branch-token", token.encode())],
        })
        with pytest.raises(HTTPException) as legacy_read:
            await employee_finance(file, staff, db, request)
        assert legacy_read.value.status_code == 409
    for actor, selected, all_mode in (
        (unlinked, branch, False), (staff, other, False), (staff, None, True),
    ):
        assert "qa_employee_finance" not in decode_scope_token(
            await select_token(actor, selected, all_branches=all_mode),
        )
    owner_token = await select_token(owner, branch)
    assert decode_scope_token(owner_token)["qa_business_ledger"] is True

    app = FastAPI()
    app.include_router(transport.router)
    identity = [owner, sessions[owner]]

    async def database():
        async with maker.begin() as db:
            yield db

    app.dependency_overrides[get_db] = database
    app.dependency_overrides[get_current_user_uuid] = lambda: identity[0]
    app.dependency_overrides[get_current_session_id] = lambda: identity[1]
    prefix = "/business/employee-finance"
    owner_headers = {"X-Branch-Token": owner_token}
    staff_headers = {"X-Branch-Token": token}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        targets = (await client.get(f"{prefix}/owner", headers=owner_headers)).json()["data"]["targets"]
        assert {r["employee_id"] for r in targets} == {str(file), str(another_file)}
        grant = next(r for r in targets if r["employee_id"] == str(file))
        salary, debt, payment = map(str, (uuid4(), uuid4(), uuid4()))
        paid = {"id": salary, "kind": "salary", "amount_minor": 240000,
                "currency": "SAR", "created_at": now.isoformat()}
        debt_row = {**paid, "id": debt, "kind": "debt", "amount_minor": 10000,
                    "currency": "USD", "direction": "employee_owes"}
        payment_row = {**debt_row, "id": payment, "kind": "debt_settlement",
                       "original_id": debt, "remaining_minor": 4000, "amount_minor": 6000}
        body = {"grant_revision": grant["grant_revision"], "expected_version": 0,
                "receipts": [paid, debt_row, payment_row]}
        dst = f"{prefix}/owner/{file}"
        assert (await client.put(dst, headers=owner_headers,
                                 json={**body, "receipts": [payment_row]})).status_code == 422
        for _ in range(2):  # same reply if the first HTTP response was lost
            saved = await client.put(dst, headers=owner_headers, json=body)
            assert saved.json()["data"]["version"] == 1, saved.text
        assert (await client.put(dst, headers=owner_headers,
                                 json={**body, "expected_version": 1, "receipts": [paid]})).status_code == 409
        identity[1] = employer_sessions[1]
        assert (await client.put(dst, headers=owner_headers, json=body)).status_code == 403

        identity[:] = staff, sessions[staff]
        received = await client.get(f"{prefix}/me", headers=staff_headers)
        assert received.status_code == 200, received.text
        data = received.json()["data"]
        assert received.headers["cache-control"] == "no-store"
        assert data["account_id"] == str(staff) and data["branch_id"] == str(branch)
        assert data["employment"]["id"] == str(invitation)
        assert [s["id"] for s in data["finance"]["salary"]] == [salary]
        assert data["finance"]["balances"] == {"USD": "40.00"}
        assert str(another_file) not in received.text
        assert datetime.fromisoformat(data["expires_at"]) <= now + timedelta(hours=6)
        assert (await client.put(dst, headers=staff_headers, json=body)).status_code == 403
        assert (await client.get(f"{prefix}/me", headers=owner_headers)).status_code == 403
        identity[:] = colleague, sessions[colleague]
        assert (await client.get(f"{prefix}/me", headers=staff_headers)).status_code == 403
        own = await select_token(colleague, branch)
        assert (await client.get(f"{prefix}/me", headers={"X-Branch-Token": own})).json()["data"]["finance"] is None

        identity[:] = staff, sessions[staff]
        async with maker.begin() as db:
            await db.execute(text("""
                UPDATE branch_members SET permissions = '{"banks": true}', updated_at = now()
                WHERE organization_id = :org AND user_id = :staff
            """), {"org": org, "staff": staff})
        assert (await client.get(f"{prefix}/me", headers=staff_headers)).status_code == 403
        new_token = await select_token(staff, branch)
        assert (await client.get(f"{prefix}/me", headers={"X-Branch-Token": new_token})).json()["data"]["finance"] is None
        identity[:] = owner, sessions[owner]
        assert (await client.put(dst, headers=owner_headers, json=body)).status_code == 403
        active = (await client.get(f"{prefix}/owner", headers=owner_headers)).json()["data"]["targets"]
        new_grant = next(row for row in active if row["employee_id"] == str(file))
        assert new_grant["grant_revision"] != grant["grant_revision"]
        republished = await client.put(dst, headers=owner_headers, json={
            **body, "expected_version": 1, "grant_revision": new_grant["grant_revision"],
        })
        assert republished.json()["data"]["version"] == 2
        identity[:] = staff, sessions[staff]
        new_headers = {"X-Branch-Token": new_token}
        assert (await client.get(f"{prefix}/me", headers=new_headers)).json()["data"]["finance"]["balances"] == {"USD": "40.00"}
        async with maker.begin() as db:
            await db.execute(text("""
                UPDATE branch_members SET status = 'revoked', scope_valid_after = now()
                WHERE organization_id = :org AND user_id = :staff
            """), {"org": org, "staff": staff})
        assert (await client.get(f"{prefix}/me", headers=new_headers)).status_code == 403
        async with maker() as db:
            # Nothing from this read projection reached the legacy writers.
            for table in ("employee_salary_payments", "employee_debts", "bank_accounts"):
                assert await db.scalar(text(
                    f"SELECT count(*) FROM {table} WHERE branch_id = :branch"
                ), {"branch": branch}) == 0
            assert await db.scalar(text("""
                SELECT count(*) FROM bank_transactions WHERE organization_id = :org
            """), {"org": org}) == 0
        monkeypatch.delenv("FYONA_QA_EMPLOYEE_FINANCE")
        identity[:] = owner, sessions[owner]
        assert (await client.get(f"{prefix}/owner", headers=owner_headers)).status_code == 404
        assert "qa_employee_finance" not in decode_scope_token(await select_token(colleague, branch))


class _Owner:
    def __init__(self, org, account, email):
        self.organization_id = org
        self.id = account
        self.email = email
        self.role = "owner"


class _Branch:
    def __init__(self, org, branch):
        self.organization_id = org
        self.id = branch
        self.is_default = False
        self.is_active = True
        self.is_archived = False


@pytest.mark.asyncio
async def test_first_device_enrollment_registers_and_fences_its_writer(engine, monkeypatch):
    from app.api.v1 import branches, business, business_reports, finance, project_settings, reconciliation
    from app.api.deps import BranchScopeContext
    from app.api.v1.employees import DebtBody, SalaryBody, add_debt, pay_salary
    from app.domain.entities.hr_entities import Employee
    from app.domain.services.branch_service import decode_scope_token

    email = f"signup-{uuid4().hex}@example.test"
    monkeypatch.setattr(qa_business_ledger, "INVITES", frozenset({email}))
    monkeypatch.setattr(qa_directory, "INVITES", frozenset({email}))
    # This test covers the earlier per-branch fence, not whole-org local mode.
    from app.core import business_local_mode
    monkeypatch.setattr(business_local_mode, "ENABLED", False)
    org, owner, branch, other = await _seed(engine, email)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    owner_row = _Owner(org, owner, email)
    branch_row = _Branch(org, branch)
    await qa_business_ledger.install(engine)

    # The opt-in is explicit, and a directory-only selection is not a ledger.
    await _directory_registered(engine, org, owner, branch)
    async with maker.begin() as db:
        await qa_business_ledger.bind_new_ledger_branch(db, owner_row, branch_row)
    async with maker() as db:
        assert await qa_business_ledger.for_owner(db, owner_row, branch_row) is False
        saved = await branches.select_branch(
            branches.BranchSelect(branch_id=branch), str(org), owner, db,
        )
        claims = decode_scope_token(json.loads(saved.body)["data"]["token"])
        assert claims.get("qa_directory") is True
        assert "qa_business_ledger" not in claims

    monkeypatch.setenv("FYONA_QA_ENROLL_NEW_LEDGER", "1")
    async with maker.begin() as db:
        await qa_business_ledger.bind_new_ledger_branch(db, owner_row, branch_row)
    async with maker() as db:
        assert await qa_business_ledger.for_owner(db, owner_row, branch_row) is True
        # The claim is pinned to the registered account, never to any owner.
        assert await qa_business_ledger.for_owner(
            db, _Owner(org, uuid4(), email), branch_row,
        ) is False
        for selected, want in ((branch, True), (other, False)):
            selected_response = await branches.select_branch(
                branches.BranchSelect(branch_id=selected), str(org), owner, db,
            )
            data = json.loads(selected_response.body)["data"]
            claims = decode_scope_token(data["token"])
            assert data["branch_id"] == str(selected)
            assert claims.get("qa_business_ledger", False) is want
            selected_scope = await business._category_branch_scope(
                org_id=str(org), user_id=owner, token=data["token"], db=db,
            )
            assert selected_scope.branch_id == selected
        assert await business._category_branch_scope(
            org_id=str(org), user_id=owner, token=None, db=db,
        ) is None

        # These legacy GETs used to create/retag a cash account. Neither the
        # direct nor the mixed scope is allowed to write or show a partial list.
        request = Request({"type": "http", "headers": [], "path": "/business/payment-options"})
        for scope in (
            SimpleNamespace(all_mode=False, branch_id=branch),
            SimpleNamespace(all_mode=True, branch_ids=[other, branch]),
        ):
            with pytest.raises(HTTPException) as accounts:
                await finance.list_bank_accounts(str(org), scope, db, True)
            assert accounts.value.status_code == 409
            with pytest.raises(HTTPException) as payment:
                await finance.payment_options(request, str(org), owner, scope, db, None)
            assert payment.value.status_code == 409
            with pytest.raises(HTTPException) as report:
                await business_reports._scoped(db, scope, org)
            assert report.value.status_code == 409
            assert report.value.detail["code"] == "report_device_scope"
            with pytest.raises(HTTPException) as recon:
                await reconciliation.recon_accounts(str(org), scope, db, True)
            assert recon.value.status_code == 409
            for read in (business.list_categories, business.list_products):
                with pytest.raises(HTTPException) as inventory:
                    await read(org_id=str(org), scope=scope, db=db, _=True)
                assert inventory.value.status_code == 409
                assert inventory.value.detail["code"] == "inventory_device_scope"
            with pytest.raises(HTTPException) as backup:
                await project_settings._connected_backup_branches(db, scope)
            assert backup.value.status_code == 409
        connected = SimpleNamespace(all_mode=False, branch_id=other)
        await business_reports._scoped(db, connected, org)
        assert db.info["report_scope"] == [str(other)]
        assert await project_settings._connected_backup_branches(db, connected) == [other]
        assert json.loads((await reconciliation.recon_accounts(str(org), connected, db, True)).body)["data"] == []
        assert json.loads((await business.list_categories(org_id=str(org), scope=connected, db=db, _=True)).body)["data"] == []
        inventory = await business.list_products(
            org_id=str(org), scope=connected, db=db, _=True, can_view_cost=False,
        )
        assert [p["name"] for p in json.loads(inventory.body)["data"]["items"]] == ["Sibling product"]
        # A registered side cannot use old pickers, a mixed list, or either
        # old transfer writer. Explicit connected pickers still work.
        from app.domain.services.branch_service import issue_scope_token

        all_token = issue_scope_token(owner, org, None, True, [branch, other])
        request_all = Request({
            "type": "http", "path": "/api/v1/branches/transfers",
            "headers": [(b"x-branch-token", all_token.encode())],
        })
        with pytest.raises(HTTPException) as mixed_transfers:
            await branches._guard_transfer_selection(request_all, db, str(org), owner)
        assert mixed_transfers.value.status_code == 409
        options = await branches.transfer_options(other, None, True, str(org), owner, db)
        assert [p["name"] for p in json.loads(options.body)["data"]["products"]] == ["Sibling product"]
        for operation in (
            lambda: branches.transfer_options(branch, None, True, str(org), owner, db),
            lambda: branches.list_transfers(None, None, 1, 20, str(org), owner, db),
            lambda: branches.create_inventory_transfer(
                branches.InventoryTransferCreate(from_branch_id=other, to_branch_id=branch, items=[
                    branches.InventoryTransferLine(from_product_id=uuid4(), quantity=1),
                ]), str(org), owner, db,
            ),
            lambda: business.transfer_stock(
                business.InventoryTransferRequest(product_id=uuid4(), from_branch_id=branch, quantity=1),
                str(org), owner, db, True,
            ),
        ):
            with pytest.raises(HTTPException) as transfer:
                await operation()
            assert transfer.value.status_code == 409
            assert transfer.value.detail["code"] == "transfer_device_scope"
        assert await db.scalar(text(
            "SELECT COUNT(*) FROM branch_transfers WHERE organization_id = :org"
        ), {"org": org}) == 0
        assert await db.scalar(text(
            "SELECT COUNT(*) FROM bank_accounts WHERE branch_id IN (:branch, :other)"
        ), {"branch": branch, "other": other}) == 0
        employee = Employee(
            id=uuid4(), organization_id=org, full_name="Fixture staff",
            employee_code=uuid4().hex[:10], salary=Decimal("1000"), created_by=owner,
        )
        db.add(employee)
        await db.commit()
        scope = BranchScopeContext(None, True, [branch, other])
        payment_data = dict(
            amount="50", currency="SAR", branch_id=branch, bank_account_id=uuid4(),
        )
        for call, payload in (
            (pay_salary, SalaryBody(**payment_data)),
            # No bank effect in this direction; still cannot write a receipt.
            (add_debt, DebtBody(**payment_data, direction="employer_owes")),
        ):
            with pytest.raises(HTTPException) as error:
                await call(employee.id, payload, str(org), owner, db, scope)
            assert error.value.status_code == 409
            assert error.value.detail["code"] == "employee_finance_device_scope"
        with pytest.raises(HTTPException) as connected_payment:
            await pay_salary(employee.id, SalaryBody(
                **{**payment_data, "branch_id": other}
            ), str(org), owner, db, scope)
        assert connected_payment.value.status_code == 422  # normal missing account check

    with pytest.raises(DBAPIError, match="device-only"):
        async with maker.begin() as db:
            await db.execute(text("""
                INSERT INTO invoices (id, organization_id, branch_id, invoice_number,
                                      invoice_type, invoice_date, status, currency)
                VALUES (:id, :org, :branch, 'LEGACY-1', 'sale', CURRENT_DATE, 'draft', 'SAR')
            """), {"id": uuid4(), "org": org, "branch": branch})
    async with maker.begin() as db:
        await db.execute(text("""
            INSERT INTO invoices (id, organization_id, branch_id, invoice_number,
                                  invoice_type, invoice_date, status, currency)
            VALUES (:id, :org, :branch, 'SIBLING-1', 'sale', CURRENT_DATE, 'draft', 'SAR')
        """), {"id": uuid4(), "org": org, "branch": other})


@pytest.mark.asyncio
async def test_install_does_not_adopt_the_pinned_directory_fixture(engine, monkeypatch):
    email = f"signup-{uuid4().hex}@example.test"
    monkeypatch.setattr(qa_business_ledger, "INVITES", frozenset({email}))
    org, owner, branch, _ = await _seed(engine, email)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    await _directory_registered(engine, org, owner, branch)
    monkeypatch.setenv('FYONA_QA_BRANCH', str(branch))
    await qa_business_ledger.install(engine)
    owner_row, branch_row = _Owner(org, owner, email), _Branch(org, branch)
    async with maker() as db:
        assert await qa_business_ledger.for_owner(db, owner_row, branch_row) is False
        assert not await qa_business_ledger.contains_registered_branch(db, [branch])


@pytest.mark.asyncio
async def test_qa_upgrade_preserves_only_an_audited_existing_cash_placeholder(engine, monkeypatch):
    email = f"signup-{uuid4().hex[:24]}@example.test"
    monkeypatch.setattr(qa_business_ledger, "INVITES", frozenset({email}))
    monkeypatch.setenv("FYONA_QA_REMOTE", "1")
    monkeypatch.setenv("FYONA_QA_ENROLL_NEW_LEDGER", "1")
    org, owner, branch, other = await _seed(engine, email)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    await _directory_registered(engine, org, owner, branch)
    owner_row, branch_row = _Owner(org, owner, email), _Branch(org, branch)
    params = {"id": uuid4(), "org": org, "owner": owner, "branch": branch}
    async with maker.begin() as db:
        await db.execute(text("""
            INSERT INTO bank_accounts (id, organization_id, branch_id, bank_name,
                                       account_name, account_number, account_type,
                                       currency, balance, is_active, is_deleted)
            VALUES (:id, :org, :branch, 'كاش', 'حساب الكاش', 'CASH', 'checking',
                    'USD', 0, true, false)
        """), params)
    await qa_business_ledger.install(engine)
    async with maker.begin() as db:
        digest = await qa_business_ledger.default_cash_fingerprint(db, org, branch)
        assert digest is not None
        monkeypatch.setenv("FYONA_QA_EXISTING_LEDGER_GRANTS", json.dumps({
            str(branch): {"account": str(owner), "organization": str(org),
                          "default_cash_sha256": digest},
        }))
        await qa_business_ledger.bind_new_ledger_branch(db, owner_row, branch_row)
        assert not await qa_business_ledger.for_owner(db, owner_row, branch_row)
        # Simulate the already recorded grant from the previous QA release.
        await db.execute(text("""
            INSERT INTO fyona_qa_business_ledger_scope (organization_id, account_id, branch_id)
            VALUES (:org, :owner, :branch)
        """), params)
        assert await qa_business_ledger.for_owner(db, owner_row, branch_row)
        assert not await qa_business_ledger.for_owner(db, owner_row, _Branch(org, other))
        monkeypatch.setenv("FYONA_QA_REMOTE", "0")
        assert not await qa_business_ledger.for_owner(db, owner_row, branch_row)
        monkeypatch.setenv("FYONA_QA_REMOTE", "1")
        monkeypatch.setenv("FYONA_QA_EXISTING_LEDGER_GRANTS", "{}")
        assert not await qa_business_ledger.for_owner(db, owner_row, branch_row)
    async with maker() as db:
        with pytest.raises(DBAPIError, match="QA business ledger is device-only"):
            await db.execute(text("UPDATE bank_accounts SET balance = 1 WHERE id = :id"), params)


@pytest.mark.asyncio
@pytest.mark.parametrize("legacy", ["account", "product"])
async def test_legacy_financial_rows_withhold_the_claim_for_that_branch(engine, monkeypatch, legacy):
    email = f"signup-{uuid4().hex}@example.test"
    monkeypatch.setattr(qa_business_ledger, "INVITES", frozenset({email}))
    org, owner, branch, other = await _seed(engine, email)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    await _directory_registered(engine, org, owner, branch)
    params = {"id": uuid4(), "org": org, "branch": branch}
    async with maker.begin() as db:
        if legacy == "account":
            await db.execute(text("""
                INSERT INTO bank_accounts (id, organization_id, branch_id, bank_name,
                                           account_name, account_number, account_type,
                                           currency, balance)
                VALUES (:id, :org, :branch, 'Cash', 'Cash', 'CASH', 'cash', 'SAR', 0)
            """), params)
        else:
            await db.execute(text("""
                INSERT INTO products (id, organization_id, branch_id, name, price)
                VALUES (:id, :org, :branch, 'Legacy product', 0)
            """), params)
    monkeypatch.setenv('FYONA_QA_BRANCH', str(branch))
    monkeypatch.setenv("FYONA_QA_ENROLL_NEW_LEDGER", "1")
    await qa_business_ledger.install(engine)
    owner_row, branch_row = _Owner(org, owner, email), _Branch(org, branch)
    async with maker.begin() as db:
        await qa_business_ledger.bind_new_ledger_branch(db, owner_row, branch_row)
    async with maker() as db:
        assert await qa_business_ledger.for_owner(db, owner_row, branch_row) is False
        assert not await qa_business_ledger.contains_registered_branch(db, [branch])
    # Other branches keep their connected writer.
    async with maker.begin() as db:
        await db.execute(text("""
            INSERT INTO products (id, organization_id, branch_id, name, price)
            VALUES (:id, :org, :branch, 'Connected product', 0)
        """), {"id": uuid4(), "org": org, "branch": other})
