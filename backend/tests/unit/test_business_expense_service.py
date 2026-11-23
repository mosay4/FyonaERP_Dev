"""Expense parity on an owned ephemeral PostgreSQL cluster, never app DB fixtures.

These are original-route/service checks, NOT expense sync/UI acceptance proof.
"""
from datetime import datetime, timezone
from decimal import Decimal
import os
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
import pytest_asyncio
import sqlalchemy as sa
from fastapi import HTTPException
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.engine import make_url

from app.api.v1 import finance
from app.core.database import Base
from app.domain.entities.auth_entities import Organization
from app.domain.entities.finance_entities import BankAccount, BankTransaction, Expense
from app.domain.entities import hr_entities  # noqa: F401 — employee foreign keys
from app.domain.entities.sale_entities import Branch
from app.domain.models.finance_models import ExpenseCreate
from app.domain.services import bank_money_service, business_expense_service


@pytest_asyncio.fixture
async def database():
    raw = os.getenv("FYONA_TEST_POSTGRES_URL")
    if not raw:
        pytest.skip("An explicit local PostgreSQL test URL is required")
    url = make_url(raw)
    if url.drivername != "postgresql+asyncpg" or url.host not in ("127.0.0.1", "::1", "localhost"):
        pytest.fail("The expense fixture only accepts local PostgreSQL")
    schema = "expense_test_" + uuid4().hex
    admin = create_async_engine(url)
    engine = create_async_engine(url, connect_args={"server_settings": {"search_path": schema}})
    try:
        async with admin.begin() as conn:
            await conn.execute(sa.schema.CreateSchema(schema))
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        yield async_sessionmaker(engine, expire_on_commit=False)
    finally:
        await engine.dispose()
        async with admin.begin() as conn:
            await conn.execute(sa.schema.DropSchema(schema, cascade=True, if_exists=True))
        await admin.dispose()


async def _sale_context(database):
    company, branch = uuid4(), uuid4()
    async with database.begin() as db:
        db.add(Organization(id=company, name="Expense QA", slug=f"expense-{company}"))
        await db.flush()
        db.add(Branch(id=branch, organization_id=company, name="Main", is_default=True))
    return SimpleNamespace(company_id=str(company), branch_id=str(branch)), None, None


async def _customer_account(database, context, currency="SAR"):
    account = uuid4()
    async with database.begin() as db:
        db.add(BankAccount(id=account, organization_id=UUID(context.company_id),
                           branch_id=UUID(context.branch_id), bank_name="Cash",
                           account_name="QA", account_number="001", currency=currency,
                           balance=Decimal("100.00")))
    return account


@pytest.mark.asyncio
async def test_original_expense_crud_preserves_fields_without_bank_effects(database):
    context, _, _ = await _sale_context(database)
    account = await _customer_account(database, context)
    company, branch = UUID(context.company_id), UUID(context.branch_id)
    date = datetime(2025, 2, 3, 4, 5, tzinfo=timezone.utc)
    async with database() as db:
        selected = await db.get(Branch, branch)
        created = await finance.create_expense(ExpenseCreate(
            expense_no='ORIGINAL-EXP', category='Rent', amount=Decimal('12.34'),
            currency=' usd ', description='Original note', payment_method='bank',
            expense_date=date), str(company), selected, db, True)
        identity = created['id']
        assert created['currency'] == 'USD' and created['amount'] == Decimal('12.34')
        assert created['expense_date'] == date and created['bank_account_id'] is None
        assert created['expense_no'] == 'ORIGINAL-EXP' and not created['is_deleted']
        # The existing PUT is partial: unspecified fields must survive.
        updated = await finance.update_expense(identity, ExpenseCreate(
            category='Utilities', amount=Decimal('9.87')), str(company), selected, db, True)
        assert updated['category'] == 'Utilities' and updated['amount'] == Decimal('9.87')
        for field in ('currency', 'description', 'expense_date', 'payment_method', 'expense_no'):
            assert updated[field] == created[field]
        assert (await finance.get_expense(identity, str(company), selected, db, True)) == updated
        assert [r['id'] for r in await finance.list_expenses(1, 50, str(company), selected, db, True)] == [identity]
        await finance.delete_expense(identity, str(company), selected, db, True)
        row = await db.get(Expense, identity)
        assert row.is_deleted and row.deleted_at is not None
        assert await finance.list_expenses(1, 50, str(company), selected, db, True) == []
        with pytest.raises(HTTPException) as missing:
            await finance.get_expense(identity, str(company), selected, db, True)
        assert missing.value.status_code == 404
        await db.commit()
    async with database() as db:
        assert (await db.get(BankAccount, account)).balance == Decimal('100.00')
        assert await db.scalar(sa.select(sa.func.count()).select_from(BankTransaction)
            .where(BankTransaction.organization_id == company)) == 0


@pytest.mark.asyncio
@pytest.mark.parametrize('boundary', ['branch', 'company'])
async def test_original_expense_scope_is_applied_before_limit_and_all_mutations(database, boundary):
    context, _, _ = await _sale_context(database)
    company, branch = UUID(context.company_id), UUID(context.branch_id)
    async with database() as db:
        row = await business_expense_service.create_expense(
            db, company, branch, ExpenseCreate(amount=Decimal('2.50')))
        await db.commit()
        wrong_company = uuid4() if boundary == 'company' else company
        wrong_branch = uuid4() if boundary == 'branch' else branch
        scope = SimpleNamespace(id=wrong_branch)
        assert await finance.list_expenses(1, 1, str(wrong_company), scope, db, True) == []
        for action in (
            lambda: finance.get_expense(row.id, str(wrong_company), scope, db, True),
            lambda: finance.update_expense(row.id, ExpenseCreate(amount=Decimal('1')),
                str(wrong_company), scope, db, True),
            lambda: finance.delete_expense(row.id, str(wrong_company), scope, db, True),
        ):
            with pytest.raises(HTTPException) as denied:
                await action()
            assert denied.value.status_code == 404
        await db.refresh(row)
        assert row.amount == Decimal('2.50') and not row.is_deleted
        all_scope = SimpleNamespace(all_mode=True, branch_ids=(branch,), branch_id=None)
        assert [r['id'] for r in await finance.list_expenses(1, 1, str(company), all_scope, db, True)] == [row.id]
        empty_scope = SimpleNamespace(all_mode=True, branch_ids=(), branch_id=None)
        assert await finance.list_expenses(1, 1, str(company), empty_scope, db, True) == []
        with pytest.raises(HTTPException) as invalid:
            await finance.list_expenses(1, 1, str(company), object(), db, True)
        assert invalid.value.status_code == 403


@pytest.mark.asyncio
async def test_categorized_withdrawal_expense_and_bank_are_atomic_not_crud_reversals(database):
    context, _, _ = await _sale_context(database)
    account = await _customer_account(database, context, currency='USD')
    company, branch = UUID(context.company_id), UUID(context.branch_id)
    async with database() as db:
        await bank_money_service.withdraw(db, company, branch, account, Decimal('12.34'),
            'Taxi receipt', is_expense=True, category='Travel')
        await db.rollback()
    async with database() as db:
        assert (await db.get(BankAccount, account)).balance == Decimal('100.00')
        assert await db.scalar(sa.select(sa.func.count()).select_from(Expense)
            .where(Expense.organization_id == company)) == 0
        assert await db.scalar(sa.select(sa.func.count()).select_from(BankTransaction)
            .where(BankTransaction.organization_id == company)) == 0
        await bank_money_service.withdraw(db, company, branch, account, Decimal('12.34'),
            'Taxi receipt', is_expense=True, category='Travel')
        await db.commit()
    async with database() as db:
        selected = await db.get(Branch, branch)
        expense = (await finance.list_expenses(1, 50, str(company), selected, db, True))[0]
        tx = (await db.scalars(sa.select(BankTransaction)
            .where(BankTransaction.organization_id == company))).one()
        assert expense['bank_account_id'] == account and expense['currency'] == 'USD'
        assert expense['amount'] == tx.amount == Decimal('12.34')
        assert expense['expense_date'] == tx.date and expense['description'] == tx.description
        assert expense['category'] == 'Travel' and expense['payment_method'] == 'cash'
        assert tx.tx_type == 'withdrawal' and tx.running_balance == Decimal('87.66')
        await finance.update_expense(expense['id'], ExpenseCreate(amount=Decimal('20.00')),
            str(company), selected, db, True)
        await finance.delete_expense(expense['id'], str(company), selected, db, True)
        await db.commit()
    async with database() as db:
        assert (await db.get(BankAccount, account)).balance == Decimal('87.66')
        txs = (await db.scalars(sa.select(BankTransaction)
            .where(BankTransaction.organization_id == company))).all()
        assert len(txs) == 1 and txs[0].amount == Decimal('12.34')
