import json
from decimal import Decimal
from uuid import uuid4
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException
from sqlalchemy import select

from tests.unit.test_notifications_visibility import pg_url, db  # noqa: F401
from app.api.deps import BranchScopeContext, get_branch_scope, get_branch_context
from app.api.v1.employees import SalaryBody, DebtBody, pay_salary, add_debt
from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.hr_entities import Employee
from app.domain.entities.sale_entities import Branch
from app.domain.entities.branch_entities import BranchMember
from app.domain.entities.employee_workspace_entities import EmployeeWorkspace, EmployeeDebt
from app.domain.entities.finance_entities import BankAccount, BankTransaction
from app.domain.entities.notification_entities import AppNotification
from app.domain.entities.business_settings_entities import BusinessProjectSettings
from app.domain.services import employee_finance_service as finance
from app.domain.services import branch_access_service as access, branch_service
from app.core.all_branches_guard import all_branches_blocked


@pytest.mark.parametrize('model', [SalaryBody, DebtBody])
@pytest.mark.parametrize('field', ['amount', 'fx_rate'])
@pytest.mark.parametrize('value', ['0', '-1', 'NaN', 'Infinity'])
def test_finance_rejects_nonpositive_and_nonfinite_decimals(model, field, value):
    from pydantic import ValidationError
    values = {'amount': '1', 'direction': 'employee_owes', field: value}
    with pytest.raises(ValidationError):
        model(**values)


async def seed(db):
    org = Organization(id=uuid4(), name='Merchant', slug=uuid4().hex)
    db.add(org); await db.flush()
    owner = User(id=uuid4(), organization_id=org.id, email=f'{uuid4()}@test.invalid', full_name='Merchant', role='owner')
    linked = User(id=uuid4(), organization_id=org.id, email=f'{uuid4()}@test.invalid', full_name='Linked', role='staff')
    db.add_all([owner, linked]); await db.flush()
    branches = [Branch(id=uuid4(), organization_id=org.id, name=f'Branch {i}', is_default=i == 0, is_active=True, is_archived=False) for i in range(3)]
    db.add_all(branches); await db.flush()
    employee = Employee(id=uuid4(), organization_id=org.id, employee_code=uuid4().hex[:10], full_name='Employee', salary=Decimal('1500'), created_by=owner.id)
    db.add(employee); await db.flush()
    ws = EmployeeWorkspace(employee_id=employee.id, organization_id=org.id, linked_user_id=linked.id, salary_currency='SAR')
    bank = BankAccount(id=uuid4(), organization_id=org.id, branch_id=branches[0].id, bank_name='Bank', account_name='USD Account', account_number=uuid4().hex, currency='USD', balance=Decimal('500'))
    db.add_all([ws, bank]); await db.commit()
    return org, owner, linked, employee, branches, bank


def payload(response):
    return json.loads(response.body)['data']


@pytest.mark.asyncio
async def test_salary_multicurrency_snapshot_exact_account_and_notification(db, monkeypatch):
    org, owner, linked, employee, branches, bank = await seed(db)
    push = AsyncMock(); monkeypatch.setattr(finance, 'notify_user', push)
    scope = BranchScopeContext(None, True, [b.id for b in branches[:2]])
    body = SalaryBody(idempotency_key='salary-safe-retry', amount='100', currency='USD', exchange_rate='3.75', branch_id=branches[0].id, bank_account_id=bank.id)
    result = payload(await pay_salary(employee.id, body, str(org.id), owner.id, db, scope))
    repeated = payload(await pay_salary(employee.id, body, str(org.id), owner.id, db, scope))
    assert repeated['id'] == result['id']
    assert result['currency'] == 'USD' and result['base_currency'] == 'SAR'
    assert result['converted_amount'] == '375.00' and result['exchange_rate'] == '3.75'
    assert Decimal(str(result['remaining_salary'])) == Decimal('1125')
    await db.refresh(bank); assert bank.balance == Decimal('400')
    tx = (await db.execute(select(BankTransaction).where(BankTransaction.bank_account_id == bank.id))).scalar_one()
    assert tx.amount == Decimal('100') and tx.currency == 'USD' and tx.running_balance == Decimal('400')
    notice = (await db.execute(select(AppNotification).where(AppNotification.user_id == linked.id))).scalar_one()
    assert notice.is_system and notice.domain == 'main'
    assert f'record_id={result["id"]}' in notice.route and f'employee_id={employee.id}' in notice.route
    assert push.await_args.kwargs['action_payload'] == notice.route


@pytest.mark.asyncio
async def test_payment_requires_correct_branch_currency_and_balance(db, monkeypatch):
    org, owner, linked, employee, branches, bank = await seed(db)
    monkeypatch.setattr(finance, 'notify_user', AsyncMock())
    scope = BranchScopeContext(None, True, [b.id for b in branches[:2]])
    for values in [
        {'branch_id': branches[1].id},
        {'branch_id': branches[2].id},
        {'currency': 'SAR'},
        {'amount': '501'},
    ]:
        body = SalaryBody(**{'amount': '100', 'currency': 'USD', 'exchange_rate': '3.75', 'branch_id': branches[0].id, 'bank_account_id': bank.id, **values})
        with pytest.raises(HTTPException):
            await pay_salary(employee.id, body, str(org.id), owner.id, db, scope)
    await db.refresh(bank); assert bank.balance == Decimal('500')
    db.add(BusinessProjectSettings(organization_id=org.id, settings='{"allow_negative":true}'))
    await db.commit()
    result = payload(await pay_salary(employee.id, SalaryBody(amount='501', currency='USD', exchange_rate='3.75', branch_id=branches[0].id, bank_account_id=bank.id), str(org.id), owner.id, db, scope))
    await db.refresh(bank); assert bank.balance == Decimal('-1')
    assert result['base_currency'] == 'SAR'


@pytest.mark.asyncio
@pytest.mark.parametrize('direction', ['employee_owes', 'employer_owes'])
async def test_debt_charge_and_settlement_use_original_currency_and_reverse_cashflow(db, monkeypatch, direction):
    org, owner, linked, employee, branches, bank = await seed(db)
    monkeypatch.setattr(finance, 'notify_user', AsyncMock())
    scope = BranchScopeContext(None, True, [b.id for b in branches[:2]])
    common = dict(direction=direction, currency='SAR', payment_currency='USD', exchange_rate='3.75', branch_id=branches[0].id, bank_account_id=bank.id)
    charged = payload(await add_debt(employee.id, DebtBody(amount='100', **common), str(org.id), owner.id, db, scope))
    assert charged['amount'] == 375 and charged['currency'] == 'SAR' and charged['payment_currency'] == 'USD'
    await db.refresh(bank); assert bank.balance == (Decimal('400') if direction == 'employee_owes' else Decimal('500'))
    assert charged['cash_effect'] == ('debit' if direction == 'employee_owes' else 'none')
    transactions = select(BankTransaction).where(BankTransaction.bank_account_id == bank.id)
    assert len((await db.execute(transactions)).scalars().all()) == (1 if direction == 'employee_owes' else 0)
    settled = payload(await add_debt(employee.id, DebtBody(amount='40', kind='settlement', **common), str(org.id), owner.id, db, scope))
    assert settled['converted_amount'] == '150.00' and settled['remaining_amount'] == '225.00'
    await db.refresh(bank); assert bank.balance == (Decimal('440') if direction == 'employee_owes' else Decimal('460'))
    assert settled['cash_effect'] == ('credit' if direction == 'employee_owes' else 'debit')
    txs = (await db.execute(transactions)).scalars().all()
    assert len(txs) == (2 if direction == 'employee_owes' else 1)
    settlement_tx = next(tx for tx in txs if tx.reference == settled['invoice_no'])
    assert settlement_tx.tx_type == ('deposit' if direction == 'employee_owes' else 'withdrawal')
    assert settlement_tx.amount == Decimal('40') and settlement_tx.currency == 'USD'
    with pytest.raises(HTTPException):
        await add_debt(employee.id, DebtBody(amount='61', kind='settlement', **common), str(org.id), owner.id, db, scope)
    await db.refresh(bank)
    assert bank.balance == (Decimal('440') if direction == 'employee_owes' else Decimal('460'))
    assert len((await db.execute(transactions)).scalars().all()) == len(txs)
    notices = (await db.execute(select(AppNotification).where(AppNotification.user_id == linked.id))).scalars().all()
    assert len(notices) == 2 and all('kind=debt' in row.route for row in notices)


@pytest.mark.asyncio
async def test_two_of_three_permitted_all_token_never_expands_or_becomes_readonly(db):
    org, owner, linked, employee, branches, bank = await seed(db)
    member = BranchMember(organization_id=org.id, user_id=linked.id, status='active', all_branches=False, branch_ids=json.dumps([str(b.id) for b in branches[:2]]))
    db.add(member); await db.commit()
    assert await access.can_view_all(db, org.id, linked.id)
    ids = await access.effective_branch_ids(db, org.id, linked.id)
    token = branch_service.issue_scope_token(linked.id, org.id, None, True, ids)
    scope = await get_branch_scope(str(org.id), linked.id, token, db)
    assert set(scope.branch_ids) == {b.id for b in branches[:2]}
    assert not all_branches_blocked('POST', '/api/v1/customers', 'all', token)
    selected = await get_branch_context(org_id=str(org.id), user_id=linked.id,
        x_branch_token=token, x_branch_id=None, branch_id=str(branches[1].id), db=db)
    assert selected.id == branches[1].id
    with pytest.raises(HTTPException) as exc:
        await get_branch_context(org_id=str(org.id), user_id=linked.id,
            x_branch_token=token, x_branch_id=None, branch_id=str(branches[2].id), db=db)
    assert exc.value.status_code == 403
    member.branch_ids = json.dumps([str(b.id) for b in branches]); await db.commit()
    scope = await get_branch_scope(str(org.id), linked.id, token, db)
    assert branches[2].id not in scope.branch_ids
    member.branch_ids = json.dumps([str(branches[0].id)]); await db.commit()
    # A once-valid all token remains safely scoped after one branch is revoked.
    assert access.intersect_scope_ids(branch_service.decode_scope_token(token), await access.effective_branch_ids(db, org.id, linked.id)) == [branches[0].id]


@pytest.mark.asyncio
async def test_permitted_all_lists_and_direct_customer_details_hide_third_branch(db):
    from app.api.v1.business import list_customers, get_customer, list_branches
    from app.domain.entities.business_entities import Customer
    org, owner, linked, employee, branches, bank = await seed(db)
    customers = [Customer(organization_id=org.id, branch_id=branch.id, name=f'Customer {i}') for i, branch in enumerate(branches)]
    db.add_all(customers); await db.commit()
    scope = BranchScopeContext(None, True, [b.id for b in branches[:2]])
    result = payload(await list_customers(org_id=str(org.id), scope=scope, db=db, _=True))
    assert {row['name'] for row in result['items']} == {'Customer 0', 'Customer 1'}
    assert payload(await get_customer(customers[1].id, str(org.id), scope, db, True))['name'] == 'Customer 1'
    with pytest.raises(HTTPException) as exc:
        await get_customer(customers[2].id, str(org.id), scope, db, True)
    assert exc.value.status_code == 404
    visible_branches = payload(await list_branches(str(org.id), scope, db, True))
    assert {row['id'] for row in visible_branches} == {str(b.id) for b in branches[:2]}


@pytest.mark.asyncio
async def test_decimal_conversion_never_fetches_sources_and_missing_rate_never_defaults_one(monkeypatch):
    service = finance.CurrencyService.get_instance()
    monkeypatch.setattr(service, 'get_all_rates', AsyncMock(return_value={'global': {'USD': 1, 'SAR': '3.75'}}))
    rate, value = await finance.conversion(Decimal('0.10'), 'USD', 'SAR')
    assert rate == Decimal('3.75') and value == Decimal('0.38')
    with pytest.raises(HTTPException):
        await finance.conversion(Decimal('10'), 'MISSING', 'SAR')
    assert finance.decimal_rate('USD', 'YER_OLD', {'yemen': {'sanaa': {'USD': {'average': '533.5'}}}}) == Decimal('533.5')
