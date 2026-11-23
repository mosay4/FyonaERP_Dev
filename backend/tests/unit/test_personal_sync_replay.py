"""Server-side operation replay semantics for the personal section.

These tests exercise the REAL FastAPI routes against an isolated in-memory
SQLite database (dependency-overridden), covering the guarantees the offline
sync engine relies on:

  * client-generated UUIDs make every create idempotent (exactly-once replay),
  * `client_operation_id` dedupes repeated intents,
  * `X-Sync-Replay` lets a queued movement land against a concurrently
    soft-deleted parent and skips the live-balance guard (the device validated
    the intent against its synchronised snapshot),
  * every reversal is EXACT (goal credit / debt paid / bank balance),
  * pull tombstones stay tombstones and derived debt totals are enriched.
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
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path}/replay.db")
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


async def _create_account(client, balance=1000.0, name="Bank") -> str:
    r = await client.post("/personal/finance/accounts",
                          json={"bank_name": name, "currency": "SAR", "balance": balance})
    assert r.status_code == 201, r.text
    return r.json()["data"]["id"]


async def _account_balance(client, account_id) -> float:
    r = await client.get("/personal/finance/accounts")
    row = next(x for x in r.json()["data"] if x["id"] == account_id)
    return float(row["balance"])


class TestIdempotentCreate:
    async def test_transaction_same_client_uuid_applied_once(self, client):
        account = await _create_account(client)
        tx_id = str(uuid4())
        body = {
            "id": tx_id,
            "tx_type": "expense",
            "amount": 120,
            "category": "Food",
            "bank_account_id": account,
            "client_operation_id": "op-intent-1",
        }
        r1 = await client.post("/personal/finance/transactions", json=body)
        assert r1.status_code == 201
        # Same UUID re-delivered (network retry / duplicate replay).
        r2 = await client.post("/personal/finance/transactions", json=body)
        assert r2.status_code == 201
        assert r2.json()["data"].get("deduped") is True
        assert await _account_balance(client, account) == 880.0

    async def test_transaction_same_operation_id_dedupes_even_with_new_uuid(self, client):
        account = await _create_account(client)
        body = {
            "id": str(uuid4()),
            "tx_type": "income",
            "amount": 50,
            "category": "Salary",
            "bank_account_id": account,
            "client_operation_id": "op-intent-2",
        }
        await client.post("/personal/finance/transactions", json=body)
        body["id"] = str(uuid4())  # different entity id, same intent key
        r = await client.post("/personal/finance/transactions", json=body)
        assert r.json()["data"].get("deduped") is True
        assert await _account_balance(client, account) == 1050.0

    async def test_entity_create_by_client_uuid_is_idempotent(self, client):
        bank_id = str(uuid4())
        body = {"id": bank_id, "bank_name": "Once", "currency": "SAR", "balance": 700}
        r1 = await client.post("/personal/finance/accounts", json=body)
        r2 = await client.post("/personal/finance/accounts", json=body)
        assert r1.status_code == 201 and r2.status_code == 201
        rows = (await client.get("/personal/finance/accounts")).json()["data"]
        assert len([x for x in rows if x["id"] == bank_id]) == 1
        assert await _account_balance(client, bank_id) == 700.0


class TestReplaySemantics:
    async def test_replay_skips_insufficient_balance_guard(self, client):
        account = await _create_account(client, balance=10)
        body = {
            "id": str(uuid4()),
            "tx_type": "expense",
            "amount": 500,
            "category": "Historical",
            "bank_account_id": account,
        }
        r_live = await client.post("/personal/finance/transactions", json=body)
        assert r_live.status_code == 400, "live path still validates funds"
        r_replay = await client.post(
            "/personal/finance/transactions", json=body,
            headers={"X-Sync-Replay": "1"})
        assert r_replay.status_code == 201
        assert await _account_balance(client, account) == -490.0

    async def test_replay_lands_against_soft_deleted_account(self, client):
        account = await _create_account(client, balance=100)
        assert (await client.delete(f"/personal/finance/accounts/{account}")).status_code == 204
        body = {
            "id": str(uuid4()),
            "tx_type": "expense",
            "amount": 30,
            "category": "PreDelete",
            "bank_account_id": account,
        }
        r_live = await client.post("/personal/finance/transactions", json=body)
        assert r_live.status_code == 400
        r_replay = await client.post(
            "/personal/finance/transactions", json=body,
            headers={"X-Sync-Replay": "1"})
        assert r_replay.status_code == 201
        # The tombstone is NOT overwritten by the replay's ledger record.
        pull = await client.post("/sync/pull", json={"full_sync": True})
        bank_entries = [
            e for e in pull.json()["data"]["entities"]
            if e["entity_type"] == "personal_bank_account" and e["entity_id"] == account
        ]
        assert bank_entries and bank_entries[-1]["deleted"] is True


class TestExactAccounting:
    async def test_goal_contribution_exact_credit_and_reversal(self, client):
        account = await _create_account(client, balance=1000)
        goal = (await client.post("/personal/finance/goals", json={
            "name": "Car", "target_amount": 5000, "current_amount": 0, "currency": "SAR",
        })).json()["data"]["id"]
        tx_id = str(uuid4())
        r = await client.post(f"/personal/finance/goals/{goal}/contribute", json={
            "amount": 300, "goal_amount": 80, "currency": "SAR",
            "bank_account_id": account, "tx_id": tx_id,
            "client_operation_id": "op-contrib-1",
        })
        assert r.status_code == 200
        assert r.json()["data"]["contribution_tx"]["id"] == tx_id
        assert await _account_balance(client, account) == 700.0
        goals = (await client.get("/personal/finance/goals")).json()["data"]
        assert next(g for g in goals if g["id"] == goal)["current_amount"] == 80

        # Duplicate replay with the same tx_id must NOT double-charge.
        r_dup = await client.post(f"/personal/finance/goals/{goal}/contribute", json={
            "amount": 300, "goal_amount": 80, "currency": "SAR",
            "bank_account_id": account, "tx_id": tx_id,
            "client_operation_id": "op-contrib-1",
        })
        assert r_dup.json()["data"].get("deduped") is True
        assert await _account_balance(client, account) == 700.0

        # Delete reverses the EXACT credited amount (goal_amount), not 300.
        assert (await client.delete(f"/personal/finance/transactions/{tx_id}")).status_code == 204
        assert await _account_balance(client, account) == 1000.0
        goals = (await client.get("/personal/finance/goals")).json()["data"]
        assert next(g for g in goals if g["id"] == goal)["current_amount"] == 0

    async def test_debt_payment_exact_and_reversal(self, client):
        account = await _create_account(client, balance=1000)
        debt = (await client.post("/personal/finance/debts", json={
            "debt_type": "payable", "person_name": "Ali", "amount": 500,
            "currency": "SAR",
        })).json()["data"]["id"]
        tx_id = str(uuid4())
        r = await client.post(f"/personal/finance/debts/{debt}/payments", json={
            "amount": 200, "bank_account_id": account, "payment_method": "bank",
            "tx_id": tx_id, "client_operation_id": "op-pay-1",
        })
        assert r.status_code == 201
        assert await _account_balance(client, account) == 800.0
        debts = (await client.get("/personal/finance/debts")).json()["data"]
        row = next(d for d in debts if d["id"] == debt)
        assert row["paid"] == 200 and row["remaining"] == 300

        # Duplicate replay (same tx_id) is deduped.
        r_dup = await client.post(f"/personal/finance/debts/{debt}/payments", json={
            "amount": 200, "bank_account_id": account, "payment_method": "bank",
            "tx_id": tx_id, "client_operation_id": "op-pay-1",
        })
        assert r_dup.json()["data"].get("deduped") is True
        assert await _account_balance(client, account) == 800.0

        # Deleting the linked transaction removes the payment + restores funds.
        assert (await client.delete(f"/personal/finance/transactions/{tx_id}")).status_code == 204
        assert await _account_balance(client, account) == 1000.0
        debts = (await client.get("/personal/finance/debts")).json()["data"]
        row = next(d for d in debts if d["id"] == debt)
        assert row["paid"] == 0 and row["remaining"] == 500 and row["is_paid"] is False

    async def test_debt_payment_cross_currency_credit_and_reversal(self, client):
        # Goals-style: the account moves in ITS currency, the debt is
        # credited the converted value (debt_amount) in debt currency.
        r = await client.post("/personal/finance/accounts",
                              json={"bank_name": "FXBank", "currency": "USD", "balance": 1000})
        assert r.status_code == 201, r.text
        account = r.json()["data"]["id"]
        debt = (await client.post("/personal/finance/debts", json={
            "debt_type": "payable", "person_name": "Lina", "amount": 1000,
            "currency": "SAR",
        })).json()["data"]["id"]
        tx_id = str(uuid4())
        r = await client.post(f"/personal/finance/debts/{debt}/payments", json={
            "amount": 100, "currency": "USD", "debt_amount": 375,
            "bank_account_id": account, "payment_method": "bank",
            "tx_id": tx_id, "client_operation_id": "op-pay-fx-1",
        })
        assert r.status_code == 201, r.text
        # Account moved 100 USD; debt credited 375 SAR.
        assert await _account_balance(client, account) == 900.0
        debts = (await client.get("/personal/finance/debts")).json()["data"]
        row = next(d for d in debts if d["id"] == debt)
        assert row["paid"] == 375 and row["remaining"] == 625

        # Receivable collection needs no balance and adds funds.
        r = await client.post("/personal/finance/accounts",
                              json={"bank_name": "EmptyCash", "currency": "SAR", "balance": 0})
        assert r.status_code == 201, r.text
        empty = r.json()["data"]["id"]
        debt2 = (await client.post("/personal/finance/debts", json={
            "debt_type": "receivable", "person_name": "Hadi", "amount": 800,
            "currency": "SAR",
        })).json()["data"]["id"]
        r = await client.post(f"/personal/finance/debts/{debt2}/payments", json={
            "amount": 250, "bank_account_id": empty, "payment_method": "cash",
            "client_operation_id": "op-collect-1",
        })
        assert r.status_code == 201, r.text
        assert await _account_balance(client, empty) == 250.0

        # Delete reverses the EXACT credited amount (debt_amount), not 100.
        assert (await client.delete(f"/personal/finance/transactions/{tx_id}")).status_code == 204
        assert await _account_balance(client, account) == 1000.0
        debts = (await client.get("/personal/finance/debts")).json()["data"]
        row = next(d for d in debts if d["id"] == debt)
        assert row["paid"] == 0 and row["remaining"] == 1000

    async def test_update_transaction_adjusts_goal_by_exact_delta(self, client):
        account = await _create_account(client, balance=1000)
        goal = (await client.post("/personal/finance/goals", json={
            "name": "Trip", "target_amount": 9000, "current_amount": 0, "currency": "SAR",
        })).json()["data"]["id"]
        tx = (await client.post("/personal/finance/transactions", json={
            "tx_type": "expense", "amount": 100, "category": "Save",
            "goal_id": goal, "bank_account_id": account,
        })).json()["data"]["id"]
        goals = (await client.get("/personal/finance/goals")).json()["data"]
        assert next(g for g in goals if g["id"] == goal)["current_amount"] == 100

        r = await client.patch(f"/personal/finance/transactions/{tx}", json={"amount": 250})
        assert r.status_code == 200
        goals = (await client.get("/personal/finance/goals")).json()["data"]
        assert next(g for g in goals if g["id"] == goal)["current_amount"] == 250

        assert (await client.delete(f"/personal/finance/transactions/{tx}")).status_code == 204
        goals = (await client.get("/personal/finance/goals")).json()["data"]
        assert next(g for g in goals if g["id"] == goal)["current_amount"] == 0

    async def test_debt_paid_totals_enriched_in_pull(self, client):
        account = await _create_account(client, balance=1000)
        debt = (await client.post("/personal/finance/debts", json={
            "debt_type": "payable", "person_name": "Sara", "amount": 400,
            "currency": "SAR",
        })).json()["data"]["id"]
        await client.post(f"/personal/finance/debts/{debt}/payments", json={
            "amount": 150, "bank_account_id": account, "payment_method": "bank",
        })
        pull = await client.post("/sync/pull", json={"full_sync": True})
        entries = [
            e for e in pull.json()["data"]["entities"]
            if e["entity_type"] == "personal_debt" and e["entity_id"] == debt
        ]
        assert entries, "debt must be present in the ledger"
        data = entries[-1]["data"]
        assert data["paid"] == 150
        assert data["remaining"] == 250
        assert data["status"] == "active"

    async def test_budget_pull_carries_categories(self, client):
        # A pulled budget row must include its categories: clients upsert
        # pulled rows over their mirror, and an empty list would wipe
        # locally-held categories (appear/disappear flicker + whole-budget
        # withdrawals with no category picker).
        r = await client.post("/personal/finance/budgets", json={
            "name": "Dec", "amount": 100000, "currency": "YER_OLD",
            "categories": [
                {"name": "Food", "type": "expense", "allocated_amount": 40000},
                {"name": "Rent", "type": "expense", "allocated_amount": 50000},
            ],
        })
        assert r.status_code == 201, r.text
        budget = r.json()["data"]["id"]
        pull = await client.post("/sync/pull", json={"full_sync": True})
        entries = [
            e for e in pull.json()["data"]["entities"]
            if e["entity_type"] == "personal_budget" and e["entity_id"] == budget
        ]
        assert entries, "budget must be present in the ledger"
        data = entries[-1]["data"]
        assert data["name"] == "Dec"
        names = sorted(c["name"] for c in (data["categories"] or []))
        assert names == ["Food", "Rent"], f"pull must carry categories, got: {data['categories']}"


class TestPullPerformance:
    async def test_pull_returns_all_operations(self, client):
        # 200 ops (the local rate limiter caps 300/min). The 500+ operation
        # stress runs against the full E2E server with the limiter disabled
        # (see test/e2e/personal_sync_e2e_test.dart).
        account = await _create_account(client, balance=100000)
        for i in range(200):
            r = await client.post("/personal/finance/transactions", json={
                "id": str(uuid4()),
                "tx_type": "income" if i % 2 == 0 else "expense",
                "amount": 1,
                "category": f"C{i}",
                "bank_account_id": account,
            })
            assert r.status_code == 201, r.text
        pull = await client.post("/sync/pull", json={"full_sync": True})
        entities = pull.json()["data"]["entities"]
        tx_count = len([e for e in entities if e["entity_type"] == "personal_transaction"])
        assert tx_count == 200
        assert await _account_balance(client, account) == 100000.0
