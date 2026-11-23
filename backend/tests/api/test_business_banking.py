"""Business banking: cross-currency transfer + cash-delete rules (SQLite)."""
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import uuid4

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine, select, func
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

from app.main import app
from app.core.config import settings
from app.core.database import Base, get_db
from app.core.security import create_access_token
from app.domain.entities import auth_entities  # noqa: F401
from app.domain.entities import finance_entities  # noqa: F401
from app.domain.entities import business_entities  # noqa: F401
from app.domain.entities import invoice_entities  # noqa: F401
from app.domain.entities import sale_entities  # noqa: F401 (branches, receivables, returns)
from app.domain.entities.auth_entities import (
    Organization,
    User,
    UserSession,
    Role,
)
from app.domain.entities.finance_entities import BankAccount, BankTransaction

pytestmark = pytest.mark.asyncio

API = settings.API_PREFIX


@pytest.fixture()
def _sync_engine(tmp_path):
    eng = create_engine(
        f"sqlite:///{tmp_path}/bizbank.db",
        connect_args={"check_same_thread": False},
    )
    Base.metadata.create_all(eng)
    return eng


@pytest.fixture()
def _async_engine(_sync_engine):
    return create_async_engine(f"sqlite+aiosqlite:///{_sync_engine.url.database}")


@pytest.fixture()
def _session_factory(_async_engine):
    return async_sessionmaker(_async_engine, expire_on_commit=False)


@pytest.fixture()
async def db(_session_factory):
    async with _session_factory() as session:
        yield session


@pytest.fixture()
async def client(_session_factory):
    # Mirror production get_db semantics (commit on success, rollback on
    # error): a plain lambda override would skip the commit entirely and
    # every mutating route would silently roll back.
    async with _session_factory() as req_session:
        async def _override():
            try:
                yield req_session
                await req_session.commit()
            except Exception:
                await req_session.rollback()
                raise

        app.dependency_overrides[get_db] = _override
        transport = ASGITransport(app=app)
        async with AsyncClient(
            transport=transport, base_url="http://localhost"
        ) as ac:
            yield ac
        app.dependency_overrides.clear()


def _hdr(user):
    tok = create_access_token(str(user.id), str(user.organization_id), user.role)
    return {"Authorization": f"Bearer {tok}"}


@pytest.fixture()
async def org(db):
    o = Organization(id=uuid4(), name="Biz Bank Org", slug=f"bb-{uuid4().hex[:8]}")
    db.add(o)
    await db.commit()
    return o


@pytest.fixture()
async def owner(db, org):
    db.add(Role(id=uuid4(), organization_id=org.id, name="owner", is_system=True))
    u = User(
        id=uuid4(),
        organization_id=org.id,
        full_name="Owner",
        email=f"o-{uuid4().hex[:8]}@t.com",
        password_hash="x",
        role="owner",
    )
    db.add(u)
    await db.flush()
    db.add(
        UserSession(
            user_id=u.id,
            refresh_token="rt",
            is_active=True,
            expires_at=datetime.now(timezone.utc) + timedelta(days=30),
        )
    )
    await db.commit()
    return u


async def _mk(db, org, bank, number, currency, balance):
    a = BankAccount(
        organization_id=org.id,
        bank_name=bank,
        account_name="Main",
        account_number=number,
        currency=currency,
        balance=Decimal(str(balance)),
    )
    db.add(a)
    await db.commit()
    return a


async def _bal(db, aid):
    return (
        await db.execute(select(BankAccount.balance).where(BankAccount.id == aid))
    ).scalar_one()


async def test_same_currency_transfer(client, owner, org, db):
    a = await _mk(db, org, "Bank A", "1", "SAR", 500)
    b = await _mk(db, org, "Bank B", "2", "SAR", 100)
    r = await client.post(
        f"{API}/banking/transfer",
        json={"from_account_id": str(a.id), "to_account_id": str(b.id), "amount": 200},
        headers=_hdr(owner),
    )
    assert r.status_code == 200, r.text
    assert float(await _bal(db, a.id)) == 300.0
    assert float(await _bal(db, b.id)) == 300.0
    txns = (
        await db.execute(
            select(func.count())
            .select_from(BankTransaction)
            .where(BankTransaction.organization_id == org.id)
        )
    ).scalar_one()
    assert txns == 2


async def test_cross_currency_transfer_needs_to_amount(client, owner, org, db):
    a = await _mk(db, org, "Bank A", "1", "SAR", 500)
    b = await _mk(db, org, "Bank B", "2", "USD", 0)
    r = await client.post(
        f"{API}/banking/transfer",
        json={"from_account_id": str(a.id), "to_account_id": str(b.id), "amount": 100},
        headers=_hdr(owner),
    )
    assert r.status_code == 400
    r = await client.post(
        f"{API}/banking/transfer",
        json={
            "from_account_id": str(a.id),
            "to_account_id": str(b.id),
            "amount": 100,
            "to_amount": 26.66,
            "exchange_rate": 0.2666,
        },
        headers=_hdr(owner),
    )
    assert r.status_code == 200, r.text
    assert float(await _bal(db, a.id)) == 400.0
    assert float(await _bal(db, b.id)) == 26.66


async def test_same_currency_mismatch_rejected(client, owner, org, db):
    a = await _mk(db, org, "Bank A", "1", "SAR", 500)
    b = await _mk(db, org, "Bank B", "2", "SAR", 0)
    r = await client.post(
        f"{API}/banking/transfer",
        json={
            "from_account_id": str(a.id),
            "to_account_id": str(b.id),
            "amount": 100,
            "to_amount": 90,
        },
        headers=_hdr(owner),
    )
    assert r.status_code == 400


async def test_cash_delete_rules(client, owner, org, db):
    sar = await _mk(db, org, "كاش", "CASH", "SAR", 10)
    # last cash cannot go
    r = await client.delete(
        f"{API}/banking/accounts/{sar.id}", headers=_hdr(owner)
    )
    assert r.status_code == 400
    # add USD cash → SAR becomes deletable
    usd = await _mk(db, org, "كاش", "CASH", "USD", 0)
    r = await client.delete(
        f"{API}/banking/accounts/{sar.id}", headers=_hdr(owner)
    )
    assert r.status_code in (200, 204), r.text
    # now USD is the last one → protected again
    r = await client.delete(
        f"{API}/banking/accounts/{usd.id}", headers=_hdr(owner)
    )
    assert r.status_code == 400
    # plain bank deletes freely
    b = await _mk(db, org, "Bank X", "9", "SAR", 0)
    r = await client.delete(
        f"{API}/banking/accounts/{b.id}", headers=_hdr(owner)
    )
    assert r.status_code in (200, 204), r.text
