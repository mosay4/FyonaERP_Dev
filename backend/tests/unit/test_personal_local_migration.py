"""Stage 6: a user's existing server Personal rows move to their devices once
(export stable bytes + digest → ack → purge after the grace period), and
nothing of another user or of Business is touched."""

import base64
import json
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from uuid import uuid4

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.core import personal_local_mode
from app.domain.services import personal_local_migration as migration
from tests.unit.test_qa_business_ledger import engine, _seed  # noqa: F401


async def _personal_user(engine):
    from app.domain.entities import personal_entities as pe
    from app.domain.entities.sync_entities import EntityVersion, SyncLog

    from app.core.database import Base
    from app.domain.entities import sync_entities

    async with engine.begin() as conn:
        await conn.run_sync(lambda c: Base.metadata.create_all(c, tables=[
            pe.PersonalBankAccount.__table__, pe.PersonalBudget.__table__,
            pe.PersonalBudgetCategory.__table__, pe.PersonalSavingsGoal.__table__,
            pe.PersonalDebt.__table__, pe.PersonalDebtPayment.__table__,
            pe.PersonalRecurringTransaction.__table__, pe.PersonalTransaction.__table__,
            sync_entities.EntityVersion.__table__, sync_entities.SyncLog.__table__,
            sync_entities.SyncBatch.__table__, sync_entities.ConflictLog.__table__]))
    org, user, _b, _o = await _seed(engine, f"plocal-{uuid4().hex[:20]}@example.test")
    ids = {k: uuid4() for k in ("acct", "cash", "budget", "cat", "goal", "debt", "pay", "rec", "tx", "gone")}
    async with async_sessionmaker(engine, expire_on_commit=False).begin() as db:
        db.add_all([
            pe.PersonalBankAccount(id=ids["acct"], user_id=user, bank_name="الراجحي",
                                   currency="SAR", balance=Decimal("1500.25")),
            pe.PersonalBankAccount(id=ids["cash"], user_id=user, bank_name="كاش",
                                   currency="USD", balance=Decimal("20")),
            pe.PersonalBankAccount(id=ids["gone"], user_id=user, bank_name="قديم",
                                   currency="SAR", balance=Decimal("0"), is_deleted=True),
            pe.PersonalBudget(id=ids["budget"], user_id=user, name="شهري",
                              total_amount=Decimal("1000"), currency="SAR"),
        ])
        await db.flush()
        db.add_all([
            pe.PersonalBudgetCategory(id=ids["cat"], budget_id=ids["budget"], name="طعام",
                                      type="expense", allocated_amount=Decimal("400"),
                                      spent_amount=Decimal("50"), currency="SAR"),
            pe.PersonalSavingsGoal(id=ids["goal"], user_id=user, name="سفر", currency="SAR",
                                   target_amount=Decimal("5000"), current_amount=Decimal("100")),
            pe.PersonalDebt(id=ids["debt"], user_id=user, debt_type="owed_by_me",
                            person_name="أحمد", amount=Decimal("300"), currency="SAR"),
        ])
        await db.flush()
        db.add_all([
            pe.PersonalDebtPayment(id=ids["pay"], debt_id=ids["debt"], user_id=user,
                                   amount=Decimal("100"), currency="SAR"),
            pe.PersonalRecurringTransaction(id=ids["rec"], user_id=user, tx_type="expense",
                                            amount=Decimal("50"), category="اشتراك",
                                            frequency="monthly",
                                            bank_account_id=ids["acct"]),
            pe.PersonalTransaction(id=ids["tx"], user_id=user, tx_type="expense",
                                   amount=Decimal("50"), currency="SAR", category="طعام",
                                   bank_account_id=ids["acct"], budget_id=ids["budget"],
                                   budget_category_id=ids["cat"],
                                   date=datetime(2026, 11, 1, tzinfo=timezone.utc)),
            EntityVersion(organization_id=org, entity_type="personal_transaction",
                          entity_id=ids["tx"], version=2, last_modified_by=user),
            SyncLog(organization_id=org, entity_type="personal_transaction",
                    entity_id=ids["tx"], action="push", status="ok"),
            # Same organization, not Personal: stays.
            SyncLog(organization_id=org, entity_type="invoice", entity_id=uuid4(),
                    action="push", status="ok"),
        ])
    async with engine.begin() as conn:
        await migration.install(conn)
    return org, user, ids


async def _count(conn, table, where, args):
    return await conn.scalar(text(f"SELECT COUNT(*) FROM public.{table} WHERE {where}"), args)


@pytest.mark.asyncio
async def test_export_is_stable_and_digest_is_sha256_of_the_bytes(engine):
    _org, user, ids = await _personal_user(engine)
    async with engine.begin() as conn:
        assert (await migration.status(conn, user=user))["needed"] is True
        first = await migration.export(conn, user=user)
        again = await migration.export(conn, user=user)
    assert again == first
    assert migration.digest_of(first["body"]) == first["digest"]
    body = json.loads(first["body"])
    assert body["format"] == migration.FORMAT and body["snapshot_id"] == first["snapshot_id"]
    ents = body["entities"]
    assert {r["id"] for r in ents["personal_bank_account"]} == {str(ids["acct"]), str(ids["cash"])}
    assert body["balances"] == {str(ids["acct"]): 1500.25, str(ids["cash"]): 20.0}
    budget = ents["personal_budget"][0]
    assert [c["id"] for c in budget["categories"]] == [str(ids["cat"])]
    debt = ents["personal_debt"][0]
    assert debt["paid"] == 100.0 and debt["remaining"] == 200.0 and debt["status"] == "active"
    assert body["counts"] == {k: len(v) for k, v in ents.items()}
    assert len(ents) == 8
    # Canonical: re-encoding gives the same bytes.
    assert migration.canonical(body) == first["body"]


@pytest.mark.asyncio
async def test_ack_needs_the_exact_digest_then_starts_grace_and_rebuilds_same_bytes(engine):
    _org, user, _ids = await _personal_user(engine)
    async with engine.begin() as conn:
        first = await migration.export(conn, user=user)
        with pytest.raises(migration.MigrationRejected):
            await migration.acknowledge(conn, user=user, snapshot_id=first["snapshot_id"],
                                        digest="0" * 64)
        now = datetime(2026, 11, 25, 10, tzinfo=timezone.utc)
        done = await migration.acknowledge(conn, user=user, snapshot_id=first["snapshot_id"],
                                           digest=first["digest"], now=now)
        assert done["purge_after"] == (now + personal_local_mode.GRACE).isoformat()
        # A second device: same answer, the grace period does not move.
        later = await migration.acknowledge(conn, user=user, snapshot_id=first["snapshot_id"],
                                            digest=first["digest"], now=now + timedelta(days=2))
        assert later == done
        stored = await conn.scalar(text(
            "SELECT length(body) FROM public.personal_local_migrations WHERE user_id = :u"),
            {"u": user})
        assert stored == 0  # the body is not kept once a device has it
        rebuilt = await migration.export(conn, user=user)
        assert rebuilt == first
        status = await migration.status(conn, user=user)
        assert status["imported"] is True and status["needed"] is False


@pytest.mark.asyncio
async def test_purge_only_after_grace_and_only_that_user(engine):
    org, user, ids = await _personal_user(engine)
    _org2, other, other_ids = await _personal_user(engine)
    async with engine.begin() as conn:
        first = await migration.export(conn, user=user)
        now = datetime(2026, 11, 25, 10, tzinfo=timezone.utc)
        await migration.acknowledge(conn, user=user, snapshot_id=first["snapshot_id"],
                                    digest=first["digest"], now=now)
        # The other user exported but never confirmed: never purged.
        await migration.export(conn, user=other)

        early = await migration.purge_due(conn, now=now + personal_local_mode.GRACE - timedelta(minutes=1))
        assert early == {"users": 0, "rows": 0}
        assert await migration.legacy_rows(conn, user) > 0

        done = await migration.purge_due(conn, now=now + personal_local_mode.GRACE)
        assert done["users"] >= 1 and done["rows"] > 0  # (other tests share the DB)
        assert await migration.legacy_rows(conn, user) == 0
        assert await _count(conn, "sync_logs", "organization_id = :o AND entity_type = 'personal_transaction'",
                            {"o": org}) == 0
        assert await _count(conn, "entity_versions", "entity_id = :i", {"i": ids["tx"]}) == 0
        assert await _count(conn, "sync_logs", "organization_id = :o AND entity_type = 'invoice'",
                            {"o": org}) == 1
        assert await _count(conn, "customers", "organization_id = :o", {"o": org}) == 1
        # Another user: everything intact.
        assert await migration.legacy_rows(conn, other) == 10
        assert await _count(conn, "personal_transactions", "id = :i", {"i": other_ids["tx"]}) == 1
        # Idempotent.
        assert await migration.purge_due(conn, now=now + personal_local_mode.GRACE * 2) == {"users": 0, "rows": 0}
        status = await migration.status(conn, user=user)
        assert status["purged"] is True and status["rows"] == 0
        with pytest.raises(migration.MigrationRejected):
            await migration.export(conn, user=user)


@pytest.mark.asyncio
async def test_status_for_a_user_without_rows(engine):
    _org, user, _b, _o = await _seed(engine, f"plocal-empty-{uuid4().hex[:12]}@example.test")
    async with engine.begin() as conn:
        await migration.install(conn)
        status = await migration.status(conn, user=user)
    assert status == {"local": True, "rows": 0, "needed": False, "imported": False}


@pytest.mark.asyncio
async def test_api_round_trip(engine, monkeypatch):
    from app.api.v1 import personal_local as api

    _org, user, _ids = await _personal_user(engine)
    monkeypatch.setattr(personal_local_mode, "ENABLED", True)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker() as db:
        status = (await api.status(user_id=user, db=db))["data"]
        assert status["needed"] is True
        out = (await api.export(user_id=user, db=db))["data"]
        raw = base64.b64decode(out["body"])
        assert migration.digest_of(raw) == out["digest"]
        acked = (await api.ack(api.AckBody(snapshot_id=out["snapshot_id"], digest=out["digest"]),
                               user_id=user, db=db))["data"]
        assert acked["purge_after"]
    monkeypatch.setattr(personal_local_mode, "ENABLED", False)
    async with maker() as db:
        with pytest.raises(Exception):
            await api.status(user_id=user, db=db)
