"""Numerical reference for the local ledger, using the original services.

Uses only the disposable socket used by the cash authority tests. No app
lifespan, notification pushes, network FX providers or production database.
"""

import os
import re
from decimal import Decimal
from uuid import uuid4

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine


@pytest.mark.asyncio
async def test_original_opening_debt_and_group_settlement_reference():
    socket = os.environ.get("FYONA_TEST_CASH_SOCKET")
    if socket is None:
        pytest.skip("A disposable Unix socket is required")
    if not re.fullmatch(r"/tmp/opencode/fyona-cash-[a-zA-Z0-9]+/socket", socket):
        pytest.fail("Refusing to connect to a non-fixture database")

    # These modules define models but the test does not use the configured
    # app engine, settings secrets, or environment from the application host.
    from app.api.v1 import reconciliation  # noqa: F401 (model registration)
    from app.core.database import Base
    from app.domain.entities import hr_entities  # noqa: F401 (model registration)
    from app.domain.entities.auth_entities import Organization, User
    from app.domain.entities.business_entities import Customer, Supplier
    from app.domain.entities.finance_entities import BankAccount, BankTransaction
    from app.domain.entities.invoice_entities import Invoice, Payment
    from app.domain.models.invoice_models import PartyPaymentRequest
    from app.domain.services import bank_money_service as banks, merchant_link_service as links
    from app.domain.services import sale_service as sales

    engine = create_async_engine("postgresql+asyncpg://root@/postgres",
                                 connect_args={"host": socket})
    try:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        maker = async_sessionmaker(engine, expire_on_commit=False)
        async with maker() as db:
            tag = uuid4().hex
            org = Organization(name="Numerical reference", slug=tag)
            db.add(org)
            await db.flush()
            actor = User(organization_id=org.id, full_name="QA Owner",
                         email=f"{tag}@example.test", role="owner")
            customer = Customer(organization_id=org.id, name="QA Buyer")
            supplier = Supplier(organization_id=org.id, name="QA Vendor")
            db.add_all([actor, customer, supplier])
            await db.flush()
            till = await banks.create_account(db, org.id, None, {
                "bank_name": "Cash", "account_name": "SAR till",
                "account_number": "1", "currency": "SAR",
            })
            usd = await banks.create_account(db, org.id, None, {
                "bank_name": "Cash", "account_name": "USD till",
                "account_number": "2", "currency": "USD", "balance": "10",
            })
            older = await links.create_opening_debt(
                db, org.id, actor.id, "customer", customer.id, Decimal("30.00"), "SAR",
            )
            newer = await links.create_opening_debt(
                db, org.id, actor.id, "customer", customer.id, Decimal("20.00"), "SAR",
            )
            group_data = await links.create_debt_group(
                db, org.id, actor.id, "supplier", supplier.id, "Group",
            )
            from uuid import UUID
            group = UUID(group_data["id"])
            grouped = await links.create_opening_debt(
                db, org.id, actor.id, "supplier", supplier.id, Decimal("30.00"), "SAR",
            )
            invoice = await db.get(Invoice, UUID(grouped["invoice_id"]))
            invoice.debt_group_id = group
            await db.commit()

            collect = await sales.add_customer_payment(
                db, org.id, actor.id, customer.id,
                PartyPaymentRequest(bank_account_id=till.id, amount=Decimal("40.00"),
                                    currency="SAR"),
                notify_linked=False,
            )
            assert collect["applied"] == 40
            assert collect["invoices"] == [older["invoice_id"], newer["invoice_id"]]
            over = await sales.add_customer_payment(
                db, org.id, actor.id, customer.id,
                PartyPaymentRequest(bank_account_id=till.id, amount=Decimal("10.50"),
                                    currency="SAR", invoice_id=UUID(newer["invoice_id"])),
                notify_linked=False,
            )
            assert (over["applied"], over["surplus"]) == (10, .5)
            assert (await db.get(BankAccount, till.id)).balance == Decimal("50.50")

            paid = await sales.add_supplier_payment(
                db, org.id, actor.id, supplier.id,
                PartyPaymentRequest(bank_account_id=usd.id, amount=Decimal("9.00"),
                                    currency="USD", debt_group_id=group,
                                    exchange_rate=Decimal("3.75")),
                notify_linked=False,
            )
            assert (paid["applied"], paid["surplus"]) == (30, 1)
            assert (await db.get(BankAccount, usd.id)).balance == Decimal("1.00")
            part = (await db.scalars(select(Payment).where(Payment.invoice_id == invoice.id))).one()
            assert part.original_amount == Decimal("8.00")
            assert part.exchange_rate == Decimal("3.75000000")
            movements = (await db.scalars(select(BankTransaction).where(
                BankTransaction.bank_account_id == usd.id,
            ))).all()
            assert len(movements) == 2
    finally:
        await engine.dispose()
