"""Personal bank account type (جاري current / توفير savings) end to end:
model + schema validation, REST create/update/read, sync push/pull payloads,
and the 122 migration's safety properties.
"""
from uuid import uuid4

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import app.domain.entities.auth_entities  # noqa: F401
import app.domain.entities.business_entities  # noqa: F401
import app.domain.entities.finance_entities  # noqa: F401
import app.domain.entities.invoice_entities  # noqa: F401
import app.domain.entities.notification_entities  # noqa: F401
import app.domain.entities.payment_entities  # noqa: F401
import app.domain.entities.personal_entities  # noqa: F401
import app.domain.entities.purchase_entities  # noqa: F401
import app.domain.entities.sales_entities  # noqa: F401
import app.domain.entities.subscription_invoice_entities  # noqa: F401
import app.domain.entities.suggestions_entities  # noqa: F401
import app.domain.entities.sync_entities  # noqa: F401
from app.api.deps import get_current_org_id, get_current_user_uuid
from app.core.database import Base, get_db
from app.domain.entities.auth_entities import Organization, User
from app.main import app

USER_ID = uuid4()
ORG_ID = uuid4()


@pytest_asyncio.fixture()
async def client(tmp_path):
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path}/account_type.db")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as db:
        db.add(Organization(id=ORG_ID, name="Replay Org", slug=f"replay-{ORG_ID.hex[:8]}"))
        db.add(User(
            id=USER_ID,
            organization_id=ORG_ID,
            full_name="Replay User",
            email=f"replay_{USER_ID.hex[:8]}@test.local",
            role="owner",
            is_platform_admin=True,
        ))
        await db.commit()

    async def _get_db():
        async with factory() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise

    app.dependency_overrides[get_db] = _get_db
    app.dependency_overrides[get_current_user_uuid] = lambda: USER_ID
    app.dependency_overrides[get_current_org_id] = lambda: str(ORG_ID)
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport,
                           base_url="http://127.0.0.1/api/v1") as c:
        yield c
    app.dependency_overrides.clear()
    await engine.dispose()



from pathlib import Path

from pydantic import ValidationError

from app.api.v1.personal_finance import PersonalAccountCreate, PersonalAccountUpdate
from app.domain.entities.personal_entities import (
    PersonalBankAccount,
    effective_account_type,
    normalize_account_type,
)
from app.domain.services.personal_sync import persist_personal, serialize_row


async def _get(client, account_id):
    rows = (await client.get("/personal/finance/accounts")).json()["data"]
    return next(x for x in rows if x["id"] == account_id)


class TestNormalize:
    def test_aliases(self):
        assert normalize_account_type("current") == "current"
        assert normalize_account_type("checking") == "current"
        assert normalize_account_type("جاري") == "current"
        assert normalize_account_type(" Savings ") == "savings"
        assert normalize_account_type("توفير") == "savings"

    def test_blank_is_not_stated(self):
        assert normalize_account_type(None) is None
        assert normalize_account_type("  ") is None

    def test_unknown_rejected(self):
        with pytest.raises(ValueError):
            normalize_account_type("fixed_deposit")

    def test_effective_default_is_current(self):
        assert effective_account_type(PersonalBankAccount(bank_name="x")) == "current"
        assert effective_account_type(
            PersonalBankAccount(bank_name="x", account_type="savings")) == "savings"

    def test_model_column_nullable_without_server_default(self):
        col = PersonalBankAccount.__table__.c.account_type
        assert col.nullable is True
        assert col.server_default is None


class TestSchemas:
    def test_create_accepts_and_normalizes(self):
        assert PersonalAccountCreate(bank_name="b", account_type="checking").account_type == "current"
        assert PersonalAccountCreate(bank_name="b", account_type="savings").account_type == "savings"
        assert PersonalAccountCreate(bank_name="b").account_type is None

    def test_create_rejects_invalid(self):
        with pytest.raises(ValidationError):
            PersonalAccountCreate(bank_name="b", account_type="gold")

    def test_update_rejects_invalid(self):
        with pytest.raises(ValidationError):
            PersonalAccountUpdate(account_type="gold")


class TestApi:
    async def test_create_savings_round_trips(self, client):
        r = await client.post("/personal/finance/accounts", json={
            "bank_name": "Kuraimi", "currency": "USD", "account_type": "savings"})
        assert r.status_code == 201, r.text
        data = r.json()["data"]
        assert data["account_type"] == "savings"
        assert data["account_type_set"] is True
        row = await _get(client, data["id"])
        assert row["account_type"] == "savings" and row["account_type_set"] is True
        single = (await client.get(f"/personal/finance/accounts/{data['id']}")).json()["data"]
        assert single["account_type"] == "savings"

    async def test_same_bank_same_currency_current_and_savings(self, client):
        a = (await client.post("/personal/finance/accounts", json={
            "bank_name": "K", "currency": "USD", "account_type": "current"})).json()["data"]
        b = (await client.post("/personal/finance/accounts", json={
            "bank_name": "K", "currency": "USD", "account_type": "savings"})).json()["data"]
        assert (await _get(client, a["id"]))["account_type"] == "current"
        assert (await _get(client, b["id"]))["account_type"] == "savings"

    async def test_create_without_type_reads_current_but_not_stated(self, client):
        r = await client.post("/personal/finance/accounts", json={
            "bank_name": "Old client", "currency": "SAR"})
        data = r.json()["data"]
        assert data["account_type"] == "current"
        assert data["account_type_set"] is False

    async def test_create_invalid_type_is_422(self, client):
        r = await client.post("/personal/finance/accounts", json={
            "bank_name": "X", "currency": "SAR", "account_type": "gold"})
        assert r.status_code == 422

    async def test_patch_sets_and_keeps_type(self, client):
        data = (await client.post("/personal/finance/accounts", json={
            "bank_name": "P", "currency": "SAR"})).json()["data"]
        r = await client.patch(f"/personal/finance/accounts/{data['id']}",
                               json={"account_type": "savings"})
        assert r.status_code == 200, r.text
        assert r.json()["data"]["account_type"] == "savings"
        assert r.json()["data"]["account_type_set"] is True
        # A later update that does not mention the type keeps it.
        r = await client.patch(f"/personal/finance/accounts/{data['id']}",
                               json={"notes": "n"})
        assert r.json()["data"]["account_type"] == "savings"

    async def test_patch_invalid_type_is_422(self, client):
        data = (await client.post("/personal/finance/accounts", json={
            "bank_name": "Q", "currency": "SAR"})).json()["data"]
        r = await client.patch(f"/personal/finance/accounts/{data['id']}",
                               json={"account_type": "nope"})
        assert r.status_code == 422


@pytest_asyncio.fixture()
async def session(tmp_path):
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path}/sync.db")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as db:
        db.add(Organization(id=ORG_ID, name="Sync Org", slug=f"sync-{ORG_ID.hex[:8]}"))
        db.add(User(id=USER_ID, organization_id=ORG_ID, full_name="Sync User",
                    email=f"sync_{USER_ID.hex[:8]}@test.local", role="owner"))
        await db.commit()
        yield db
    await engine.dispose()


class TestSyncPayloads:
    async def test_push_create_with_type_then_pull_payload(self, session):
        acc_id = uuid4()
        await persist_personal(session, USER_ID, "personal_bank_account", acc_id,
                               {"bank_name": "S", "currency": "USD",
                                "account_type": "savings"}, False)
        row = await session.get(PersonalBankAccount, acc_id)
        assert row.account_type == "savings"
        out = serialize_row(row)
        assert out["account_type"] == "savings" and out["account_type_set"] is True

    async def test_push_without_type_never_resets_savings(self, session):
        acc_id = uuid4()
        await persist_personal(session, USER_ID, "personal_bank_account", acc_id,
                               {"bank_name": "S", "currency": "USD",
                                "account_type": "savings"}, False)
        # An older client pushes the row without the field.
        await persist_personal(session, USER_ID, "personal_bank_account", acc_id,
                               {"bank_name": "S", "currency": "USD", "balance": 5}, False)
        row = await session.get(PersonalBankAccount, acc_id)
        assert row.account_type == "savings"

    async def test_push_device_vocabulary_and_invalid(self, session):
        acc_id = uuid4()
        await persist_personal(session, USER_ID, "personal_bank_account", acc_id,
                               {"bank_name": "S", "currency": "SAR",
                                "account_type": "checking"}, False)
        row = await session.get(PersonalBankAccount, acc_id)
        assert row.account_type == "current"
        # Invalid values are ignored (sync must not fail), type is kept.
        await persist_personal(session, USER_ID, "personal_bank_account", acc_id,
                               {"bank_name": "S", "currency": "SAR",
                                "account_type": "bogus"}, False)
        row = await session.get(PersonalBankAccount, acc_id)
        assert row.account_type == "current"

    async def test_legacy_row_serializes_as_unstated_current(self, session):
        acc_id = uuid4()
        await persist_personal(session, USER_ID, "personal_bank_account", acc_id,
                               {"bank_name": "L", "currency": "SAR"}, False)
        out = serialize_row(await session.get(PersonalBankAccount, acc_id))
        assert out["account_type"] == "current"
        assert out["account_type_set"] is False


class TestMigration122:
    SRC = (Path(__file__).resolve().parents[2] / "migrations" / "versions"
           / "122_personal_bank_account_type.py").read_text(encoding="utf-8")

    def test_chain(self):
        assert 'revision = "122"' in self.SRC
        assert 'down_revision = "121"' in self.SRC

    def test_additive_idempotent_nullable(self):
        assert "add_column_if_missing" in self.SRC
        assert "nullable=True" in self.SRC
        assert "server_default" not in self.SRC.split("def upgrade")[1]
        assert "DROP" not in self.SRC.upper().split("DEF UPGRADE")[1].split("DEF DOWNGRADE")[0]
        assert "UPDATE " not in self.SRC

    def test_init_db_safety_net_adds_column(self):
        src = (Path(__file__).resolve().parents[2] / "app" / "core"
               / "database.py").read_text(encoding="utf-8")
        assert '("personal_bank_accounts", "account_type", "VARCHAR(20)")' in src


class TestSaraNeedsAccount:
    def test_needs_account_lists_type(self):
        from app.domain.services.sara_agent_service import _needs_account_error
        rows = [
            {"id": "1", "name": "K", "currency": "USD", "balance": "1", "account_type": "current"},
            {"id": "2", "name": "K", "currency": "USD", "balance": "2", "account_type": "savings"},
        ]
        out = _needs_account_error(rows, "K", "USD")
        assert out["error_code"] == "NEEDS_ACCOUNT"
        assert [o["account_type"] for o in out["accounts"]] == ["current", "savings"]
        assert "جاري" in out["error"] and "توفير" in out["error"]
