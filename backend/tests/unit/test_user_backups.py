"""User server backups + validated atomic bulk restore (schema 4.0.0).

Real FastAPI app over ASGI transport with dependency-overridden auth/DB
(same pattern as test_personal_sync_replay), real SQLite file, real
validation/atomicity code paths.

Covers: validation (ok/orphan/duplicates/bad amounts), exact round-trip
restore (IDs, Decimal-exact amounts, links), invalid-payload keeps old
data, old-schema rejection, upload/list/download/delete, per-user
isolation, HMAC key stability, retention cap, route registration.
"""
import io
import json
import os
from datetime import datetime, timezone
from uuid import uuid4, UUID

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")
os.environ.setdefault("CELERY_BROKER_URL", "redis://localhost:6379/1")
os.environ.setdefault("CELERY_RESULT_BACKEND", "redis://localhost:6379/2")

import app.domain.entities.auth_entities  # noqa: F401
import app.domain.entities.personal_entities  # noqa: F401
import app.domain.entities.backup_entities  # noqa: F401
import app.domain.entities.sync_entities  # noqa: F401
from app.api.deps import get_current_user_uuid, get_db
from app.core.database import Base
from app.domain.entities.auth_entities import Organization, User
from app.main import app

USER_ID = uuid4()
ORG_ID = uuid4()
OTHER_ID = uuid4()


@pytest_asyncio.fixture()
async def client(tmp_path, monkeypatch):
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path}/backups.db")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    factory = async_sessionmaker(engine, expire_on_commit=False)
    async with factory() as db:
        db.add(Organization(id=ORG_ID, name="Backup Org", slug=f"bk-{ORG_ID.hex[:8]}"))
        for uid, admin in ((USER_ID, True), (OTHER_ID, True)):
            db.add(User(
                id=uid, organization_id=ORG_ID,
                full_name=f"Backup User {uid.hex[:4]}",
                email=f"bk_{uid.hex[:8]}@test.local",
                role="owner", is_platform_admin=admin,
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

    import app.core.storage as storage_mod
    from app.core.storage import LocalStorage
    monkeypatch.setattr(storage_mod, "get_storage",
                        lambda: LocalStorage(str(tmp_path / "store")))
    app.dependency_overrides[get_db] = _get_db
    app.dependency_overrides[get_current_user_uuid] = lambda: USER_ID
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport,
                           base_url="http://127.0.0.1/api/v1") as c:
        yield c
    app.dependency_overrides.clear()
    await engine.dispose()


def _other_client_overrides():
    app.dependency_overrides[get_current_user_uuid] = lambda: OTHER_ID


def _full_entities(suffix=""):
    acc_cash, acc_usd = str(uuid4()), str(uuid4())
    goal, debt, bud = str(uuid4()), str(uuid4()), str(uuid4())
    cat_fly, cat_stay = str(uuid4()), str(uuid4())
    rec, tx_out, tx_in, tx_exp, pay = (str(uuid4()) for _ in range(5))
    now = datetime.now(timezone.utc).isoformat()
    return {
        "accounts": [
            {"id": acc_cash, "bank_name": f"Cash{suffix}", "currency": "YER_OLD",
             "balance": "54000.50", "notes": None},
            {"id": acc_usd, "bank_name": f"Vault{suffix}", "currency": "USD",
             "balance": "100.25", "notes": "n"},
        ],
        "transactions": [
            {"id": tx_out, "tx_type": "transfer_out", "amount": "100",
             "currency": "USD", "category": "تحويل", "description": "t",
             "bank_account_id": acc_usd, "date": now},
            {"id": tx_in, "tx_type": "transfer_in", "amount": "54000",
             "currency": "YER_OLD", "category": "تحويل", "description": "t",
             "bank_account_id": acc_cash, "date": now},
            {"id": tx_exp, "tx_type": "expense", "amount": "10.99",
             "currency": "SAR", "category": "food", "description": "x",
             "bank_account_id": acc_cash, "date": now,
             "goal_id": goal, "budget_id": bud, "budget_category_id": cat_fly,
             "payment_method": "cash", "exchange_rate": "3.75000000",
             "exchange_rate_currency": "USD", "fx_source": "test"},
        ],
        "goals": [
            {"id": goal, "name": f"Car{suffix}", "target_amount": "500000",
             "current_amount": "100000.75", "currency": "YER_NEW",
             "deadline": "2027-01-01", "icon": "CAR", "is_completed": False},
        ],
        "debts": [
            {"id": debt, "debt_type": "receivable", "person_name": f"Ali{suffix}",
             "amount": "1000000", "currency": "YER_OLD",
             "description": None, "due_date": "2026-11-23",
             "is_paid": False, "reminder": True},
        ],
        "debt_payments": [
            {"id": pay, "debt_id": debt, "amount": "50000.25",
             "currency": "YER_OLD", "payment_date": now, "notes": "p"},
        ],
        "budgets": [
            {"id": bud, "name": f"Trip{suffix}", "period_type": "monthly",
             "total_amount": "1000000", "currency": "SAR",
             "bank_account_ids": [], "budget_types": ["expenses"],
             "categories": [
                 {"id": cat_fly, "name": "flights", "type": "expense",
                  "amount": "300000", "currency": "SAR"},
                 {"id": cat_stay, "name": "stay", "type": "expense",
                  "amount": "100000", "currency": "SAR"},
             ]},
        ],
        "recurring": [
            {"id": rec, "name": f"Rent{suffix}", "tx_type": "expense",
             "amount": "1500", "currency": "SAR", "category": "rent",
             "description": None, "frequency": "monthly", "interval_value": 1,
             "next_run_date": "2026-10-01", "bank_account_id": acc_usd,
             "is_active": True},
        ],
    }


def _restore_body(entities, schema_version="4.0.0"):
    return {"schema_version": schema_version, "backup_id": str(uuid4()),
            "entities": entities}


def _items(payload):
    data = payload["data"]
    if isinstance(data, dict) and isinstance(data.get("items"), list):
        return data["items"]
    assert isinstance(data, list), data
    return data


async def _counts(c):
    out = {}
    for key, path in (
        ("accounts", "/personal/finance/accounts"),
        ("transactions", "/personal/finance/transactions"),
        ("goals", "/personal/finance/goals"),
        ("debts", "/personal/finance/debts"),
        ("budgets", "/personal/finance/budgets"),
        ("recurring", "/personal/finance/recurring"),
    ):
        r = await c.get(path)
        assert r.status_code == 200, (path, r.text)
        out[key] = len(_items(r.json()))
    return out


class TestBulkRestoreV2:
    async def test_roundtrip_exact(self, client):
        ents = _full_entities()
        r = await client.post("/personal/finance/restore", json=_restore_body(ents))
        assert r.status_code == 200, r.text
        data = r.json()["data"]
        assert data["verified"] is True
        assert data["expected"] == {"accounts": 2, "transactions": 3, "goals": 1,
                                    "debts": 1, "debt_payments": 1, "budgets": 1,
                                    "recurring": 1, "budget_categories": 2}

        from decimal import Decimal as _D
        accs = _items((await client.get("/personal/finance/accounts")).json())
        cash = next(a for a in accs if a["id"] == ents["accounts"][0]["id"])
        assert cash["currency"] == "YER_OLD"
        assert _D(str(cash["balance"])) == _D("54000.50")
        assert len(accs) == 2

        txs = _items((await client.get("/personal/finance/transactions")).json())
        by_id = {t["id"]: t for t in txs}
        assert len(by_id) == 3
        out_leg, in_leg = by_id[ents["transactions"][0]["id"]], by_id[ents["transactions"][1]["id"]]
        assert out_leg["bank_account_id"] == ents["accounts"][1]["id"]
        assert in_leg["bank_account_id"] == ents["accounts"][0]["id"]
        assert _D(str(out_leg["amount"])) == _D("100")
        assert _D(str(in_leg["amount"])) == _D("54000")
        exp = by_id[ents["transactions"][2]["id"]]
        assert exp["goal_id"] == ents["goals"][0]["id"]
        assert exp["budget_id"] == ents["budgets"][0]["id"]
        assert exp["budget_category_id"] == ents["budgets"][0]["categories"][0]["id"]

        debts = _items((await client.get("/personal/finance/debts")).json())
        assert len(debts) == 1
        assert debts[0]["id"] == ents["debts"][0]["id"]
        assert _D(str(debts[0]["amount"])) == _D("1000000")

        goals = _items((await client.get("/personal/finance/goals")).json())
        assert _D(str(goals[0]["current_amount"])) == _D("100000.75")
        assert goals[0]["currency"] == "YER_NEW"

    async def test_invalid_keeps_old_data(self, client):
        # NOTE: account names stay exact ("Cash") so the list endpoint's
        # existing auto-cash behavior does not add a third row.
        ents = _full_entities()
        r = await client.post("/personal/finance/restore", json=_restore_body(ents))
        assert r.status_code == 200, r.text
        bad = _full_entities("-bad")
        bad["transactions"][0]["bank_account_id"] = str(uuid4())  # orphan
        r2 = await client.post("/personal/finance/restore", json=_restore_body(bad))
        assert r2.status_code == 422, r2.text
        assert "orphan" in r2.text
        counts = await _counts(client)
        assert counts == {"accounts": 2, "transactions": 3, "goals": 1,
                          "debts": 1, "budgets": 1, "recurring": 1}

    async def test_preexisting_rows_preserved_not_wiped(self, client):
        # A newer row outside the backup must survive the restore untouched.
        extra = {"bank_name": "Newer", "currency": "SAR", "balance": 7}
        r0 = await client.post("/personal/finance/accounts", json=extra)
        assert r0.status_code == 201, r0.text
        extra_id = r0.json()["data"]["id"]
        ents = _full_entities()
        r = await client.post("/personal/finance/restore", json=_restore_body(ents))
        assert r.status_code == 200, r.text
        accs = _items((await client.get("/personal/finance/accounts")).json())
        assert {a["id"] for a in accs} >= {
            extra_id, ents["accounts"][0]["id"], ents["accounts"][1]["id"]}
        assert next(a for a in accs if a["id"] == extra_id)["bank_name"] == "Newer"

    async def test_same_id_updates_without_duplicate(self, client):
        ents = _full_entities()
        r = await client.post("/personal/finance/restore", json=_restore_body(ents))
        assert r.status_code == 200, r.text
        # Same stable IDs, changed values → update in place, never duplicate.
        changed = _full_entities()
        for section in ("accounts", "transactions", "goals", "debts",
                        "debt_payments", "budgets", "recurring"):
            changed[section] = ents[section]
        changed["debts"][0] = dict(ents["debts"][0], amount="2000000")
        r2 = await client.post("/personal/finance/restore", json=_restore_body(changed))
        assert r2.status_code == 200, r2.text
        assert r2.json()["data"]["verified"] is True
        debts = _items((await client.get("/personal/finance/debts")).json())
        assert len(debts) == 1
        from decimal import Decimal as _D
        assert _D(str(debts[0]["amount"])) == _D("2000000")
        assert debts[0]["id"] == ents["debts"][0]["id"]

    async def test_cash_merge_no_duplicate(self, client):
        # Reset-created stub (new UUID, zero) + snapshot row (old UUID):
        # they merge into ONE row, transactions remapped, no duplicate.
        stub = {"bank_name": "Cash", "currency": "USD", "balance": 0}
        r0 = await client.post("/personal/finance/accounts", json=stub)
        assert r0.status_code == 201, r0.text
        stub_id = r0.json()["data"]["id"]
        old_id, tx1 = str(uuid4()), str(uuid4())
        now = datetime.now(timezone.utc).isoformat()
        body = _restore_body({
            "accounts": [{"id": old_id, "bank_name": "Cash",
                          "currency": "USD", "balance": "50"}],
            "transactions": [{"id": tx1, "tx_type": "expense", "amount": "5",
                              "currency": "USD", "category": "x",
                              "bank_account_id": old_id, "date": now}],
            "goals": [], "debts": [], "debt_payments": [],
            "budgets": [], "recurring": [],
        })
        r = await client.post("/personal/finance/restore", json=body)
        assert r.status_code == 200, r.text
        data = r.json()["data"]
        assert data["verified"] is True
        assert data["merged_accounts"] == [
            {"snapshot_id": old_id, "kept_id": stub_id,
             "key": ["cash", "USD"]}]
        accs = _items((await client.get("/personal/finance/accounts")).json())
        cash_usd = [a for a in accs
                    if a["bank_name"] == "Cash" and a["currency"] == "USD"]
        assert len(cash_usd) == 1
        assert cash_usd[0]["id"] == stub_id
        from decimal import Decimal as _D
        assert _D(str(cash_usd[0]["balance"])) == _D("50")
        txs = _items((await client.get("/personal/finance/transactions")).json())
        assert txs[0]["bank_account_id"] == stub_id

    async def test_old_schema_rejected(self, client):
        r = await client.post(
            "/personal/finance/restore",
            json=_restore_body(_full_entities(), schema_version="3.0.0"))
        assert r.status_code == 422, r.text
        assert "Unsupported restore schema" in r.text

    async def test_duplicate_ids_rejected(self, client):
        ents = _full_entities()
        ents["accounts"].append(dict(ents["accounts"][0]))
        r = await client.post("/personal/finance/restore", json=_restore_body(ents))
        assert r.status_code == 422, r.text

    async def test_repeated_restore_identical(self, client):
        body = _restore_body(_full_entities())
        r1 = await client.post("/personal/finance/restore", json=body)
        r2 = await client.post("/personal/finance/restore", json=body)
        assert r1.status_code == r2.status_code == 200
        assert r1.json()["data"]["verified"] is True
        assert r2.json()["data"]["verified"] is True
        assert r1.json()["data"]["expected"] == r2.json()["data"]["expected"]
        assert await _counts(client) == {"accounts": 2, "transactions": 3, "goals": 1,
                                         "debts": 1, "budgets": 1, "recurring": 1}


class TestServerBackupsApi:
    def _snap(self, uid, counts=None):
        return {"schema_version": "4.0.0", "user_uuid": str(uid),
                "app_version": "test", "counts": counts or {"accounts": 2},
                "meta": {}, "data": {"x": 1}}

    async def test_upload_list_download_delete(self, client):
        files = {"file": ("FYONA_ERP_Backup.json",
                          json.dumps(self._snap(USER_ID)).encode(),
                          "application/json")}
        up = await client.post("/backups", files=files)
        assert up.status_code == 201, up.text
        created = up.json()["data"]
        assert created["version"] == 1
        assert created["record_count"] == 2
        assert created["filename"].startswith("FYONA_ERP_Backup_v1_")

        listed = (await client.get("/backups")).json()["data"]
        assert len(listed["backups"]) == 1
        assert listed["latest"]["id"] == created["id"]

        meta = (await client.get(f"/backups/{created['id']}")).json()["data"]
        assert meta["checksum"] == created["checksum"]

        dl = await client.get(f"/backups/{created['id']}/download")
        assert dl.status_code == 200
        assert json.loads(dl.content.decode())["counts"] == {"accounts": 2}

        up2 = await client.post("/backups", files=files)
        assert up2.json()["data"]["version"] == 2

        gone = await client.delete(f"/backups/{created['id']}")
        assert gone.status_code == 204
        listed2 = (await client.get("/backups")).json()["data"]
        assert len(listed2["backups"]) == 1

    async def test_user_isolation(self, client):
        files = {"file": ("b.json", json.dumps(self._snap(USER_ID)).encode(),
                          "application/json")}
        created = (await client.post("/backups", files=files)).json()["data"]

        _other_client_overrides()
        listed = (await client.get("/backups")).json()["data"]
        assert listed["backups"] == [] and listed["latest"] is None
        assert (await client.get(f"/backups/{created['id']}")).status_code == 404
        assert (await client.get(f"/backups/{created['id']}/download")).status_code == 404
        assert (await client.delete(f"/backups/{created['id']}")).status_code == 404

        app.dependency_overrides[get_current_user_uuid] = lambda: USER_ID
        foreign = {"file": ("b.json", json.dumps(self._snap(OTHER_ID)).encode(),
                            "application/json")}
        r = await client.post("/backups", files=foreign)
        assert r.status_code == 403, r.text

    async def test_retention_keeps_ten_verified(self, client):
        files = {"file": ("b.json", json.dumps(self._snap(USER_ID)).encode(),
                          "application/json")}
        for _ in range(12):
            r = await client.post("/backups", files=files)
            assert r.status_code == 201, r.text
        listed = (await client.get("/backups")).json()["data"]["backups"]
        assert len(listed) == 10
        versions = sorted(v["version"] for v in listed)
        assert versions == list(range(3, 13))

    async def test_hmac_key_stable(self, client):
        k1 = (await client.get("/backups/key")).json()["data"]["key_b64"]
        k2 = (await client.get("/backups/key")).json()["data"]["key_b64"]
        assert k1 == k2 and len(k1) > 20

    async def test_bad_schema_rejected(self, client):
        snap = self._snap(USER_ID)
        snap["schema_version"] = "3.0.0"
        files = {"file": ("b.json", json.dumps(snap).encode(), "application/json")}
        r = await client.post("/backups", files=files)
        assert r.status_code == 422, r.text
        assert (await client.get("/backups")).json()["data"]["backups"] == []

    async def test_corrupt_file_rejected(self, client):
        files = {"file": ("b.json", b"{not json", "application/json")}
        r = await client.post("/backups", files=files)
        assert r.status_code == 400, r.text


def test_routes_registered():
    import app.main as main_mod
    paths = set()
    for route in main_mod.app.routes:
        path = getattr(route, "path", "")
        if path:
            paths.add(path)
    for expected in ("/api/v1/backups", "/api/v1/backups/key",
                     "/api/v1/backups/{backup_id}",
                     "/api/v1/backups/{backup_id}/download"):
        assert expected in paths, expected
