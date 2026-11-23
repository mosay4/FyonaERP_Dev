"""Backend create_transaction binding (focused fix): bank_account_id +
currency are bound exactly, validated, and atomic.

FakeDb routes the real SQLAlchemy statements the handler emits, so these
tests run the TRUE runtime path (dispatch → handler → add/flush → verify →
envelope) against isolated data. No network, no real DB, no user data.
"""
import asyncio
import os
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4, UUID

import pytest

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")
os.environ.setdefault("CELERY_BROKER_URL", "redis://localhost:6379/1")
os.environ.setdefault("CELERY_RESULT_BACKEND", "redis://localhost:6379/2")

UID = uuid4()
OTHER = uuid4()


def _acct(name, currency, balance, uid=UID):
    a = MagicMock()
    a.id = uuid4()
    a.user_id = uid
    a.bank_name = name
    a.currency = currency
    a.balance = Decimal(str(balance))
    a.is_deleted = False
    return a


class FakeDb:
    """Routes handler statements to in-memory tables (isolated)."""

    def __init__(self, accounts):
        self.accounts = {a.id: a for a in accounts}
        self.rows = []
        self.add_calls = 0

    def _one(self, value=None, entities=None):
        m = MagicMock()
        m.scalar_one_or_none.return_value = value
        sc = MagicMock()
        sc.all.return_value = entities or []
        m.scalars.return_value = sc
        m.all.return_value = entities or []
        return m

    async def execute(self, stmt):
        s = str(stmt)
        try:
            params = list(stmt.compile().params.values())
        except Exception:
            params = []
        if "client_operation_id" in s:
            key = next((p for p in params if isinstance(p, str)
                        and p.startswith("sara:")), None)
            hit = next((r for r in self.rows
                        if getattr(r, "client_operation_id", None) == key
                        and not getattr(r, "is_deleted", False)), None)
            # scalar_one_or_none on select(id) yields the ID, not the row.
            return self._one(value=(hit.id if hit is not None else None))
        if "personal_bank_accounts" in s:
            uuids = [p for p in params if isinstance(p, UUID)]
            non_uid = [u for u in uuids if u != UID]
            if non_uid:
                # ID lookup: exact row or nothing (never the whole list).
                acc = self.accounts.get(non_uid[0])
                found = [acc] if acc is not None and acc.user_id == UID \
                    and not acc.is_deleted else []
                return self._one(entities=found)
            mine = [a for a in self.accounts.values()
                    if a.user_id == UID and not a.is_deleted]
            return self._one(entities=mine)
        return self._one()

    async def get(self, model, pk):
        for r in self.rows:
            if getattr(r, "id", None) == pk:
                return r
        return None

    def add(self, row):
        self.rows.append(row)
        self.add_calls += 1

    async def flush(self):
        # Mimic ORM flush: Python-side defaults (UUID PK) materialize here.
        for r in self.rows:
            if getattr(r, "id", None) is None:
                r.id = uuid4()


def _svc(db, uid=UID):
    from app.domain.services import sara_agent_service as mod
    return mod.ToolExecutor(db, uuid4(), uid, lang="ar"), mod


def _deposit_args(acc_id, currency, amount="100"):
    return {"operation": "deposit", "amount": amount,
            "bank_account_id": str(acc_id), "currency": currency,
            "description": "راتب"}


# ── 1-2: income + expense bind account and currency ─────────────────────────

@pytest.mark.asyncio
async def test_deposit_binds_account_and_currency():
    acc = _acct("الراجحي", "SAR", 1000)
    db = FakeDb([acc])
    svc, _ = _svc(db)
    out = await svc.execute("create_transaction",
                            _deposit_args(acc.id, "SAR", "1500"))
    assert out.get("success") is True
    assert len(db.rows) == 1
    row = db.rows[0]
    assert row.tx_type == "income"
    assert row.amount == Decimal("1500")
    assert row.bank_account_id == acc.id
    assert row.currency == "SAR"
    assert row.user_id == UID
    assert acc.balance == Decimal("2500")


@pytest.mark.asyncio
async def test_withdraw_binds_account_and_currency():
    acc = _acct("Chase", "USD", 1000)
    db = FakeDb([acc])
    svc, _ = _svc(db)
    out = await svc.execute("create_transaction", {
        "operation": "withdraw", "amount": "19.99",
        "bank_account_id": str(acc.id), "currency": "USD",
        "description": "coffee"})
    assert out.get("success") is True
    row = db.rows[0]
    assert row.tx_type == "expense"
    assert row.amount == Decimal("19.99")  # exact, no rounding
    assert row.bank_account_id == acc.id
    assert row.currency == "USD"
    assert acc.balance == Decimal("1000") - Decimal("19.99")


# ── 3-4: saved IDs equal the sent IDs ───────────────────────────────────────

@pytest.mark.asyncio
async def test_saved_ids_equal_sent_ids():
    acc = _acct("A", "EUR", 500)
    db = FakeDb([acc])
    svc, _ = _svc(db)
    await svc.execute("create_transaction", _deposit_args(acc.id, "EUR", "10"))
    row = db.rows[0]
    assert str(row.bank_account_id) == str(acc.id)
    assert str(row.currency) == "EUR"


# ── 5-6: YER vs YER_NEW never cross ─────────────────────────────────────────

@pytest.mark.asyncio
async def test_ambiguous_yer_requires_old_or_new_without_writing():
    acc = _acct("كاش", "YER", 5000)
    db = FakeDb([acc])
    svc, _ = _svc(db)
    out = await svc.execute("create_transaction",
                            _deposit_args(acc.id, "YER", "100"))
    assert out.get('success') is False
    assert 'YER_OLD' in out['error'] and 'YER_NEW' in out['error']
    assert not db.rows
    assert acc.balance == Decimal('5000')


@pytest.mark.asyncio
async def test_yer_new_stays_yer_new():
    acc = _acct("كاش جديد", "YER_NEW", 5000)
    db = FakeDb([acc])
    svc, _ = _svc(db)
    out = await svc.execute("create_transaction",
                            _deposit_args(acc.id, "YER_NEW", "100"))
    assert out.get("success") is True
    assert db.rows[0].currency == "YER_NEW"


# ── 7-8: unknown / foreign accounts rejected, nothing written ───────────────

@pytest.mark.asyncio
async def test_unknown_account_rejected_without_write():
    db = FakeDb([_acct("A", "SAR", 100)])
    svc, _ = _svc(db)
    out = await svc.execute("create_transaction",
                            _deposit_args(uuid4(), "SAR", "50"))
    assert out.get("success") is not True and "error" in out
    assert db.add_calls == 0 and db.rows == []


@pytest.mark.asyncio
async def test_foreign_account_rejected_without_write():
    mine = _acct("Mine", "SAR", 100)
    foreign = _acct("Theirs", "SAR", 9999, uid=OTHER)
    db = FakeDb([mine, foreign])
    svc, _ = _svc(db)
    before = mine.balance
    out = await svc.execute("create_transaction",
                            _deposit_args(foreign.id, "SAR", "50"))
    assert out.get("success") is not True and "error" in out
    assert db.add_calls == 0 and db.rows == []
    assert mine.balance == before  # untouched


# ── 9-10: bad / mismatched currency rejected, nothing written ───────────────

@pytest.mark.asyncio
async def test_unknown_currency_rejected():
    acc = _acct("A", "SAR", 100)
    db = FakeDb([acc])
    svc, _ = _svc(db)
    out = await svc.execute("create_transaction",
                            _deposit_args(acc.id, "XYZ", "50"))
    assert out.get("success") is not True and "error" in out
    assert db.add_calls == 0


@pytest.mark.asyncio
async def test_currency_mismatch_single_currency_converts_at_stored_rate():
    # Rule change: a single-currency bank auto-converts the requested amount
    # at the stored rate instead of refusing. 50 USD -> SAR at the real
    # engine rate; nothing is ever written in the foreign currency.
    acc = _acct("A", "SAR", 1000)
    db = FakeDb([acc])
    svc, _ = _svc(db)
    out = await svc.execute("create_transaction",
                            _deposit_args(acc.id, "USD", "50"))
    assert out.get("success") is True
    assert len(db.rows) == 1
    assert db.rows[0].currency == "SAR"
    assert db.rows[0].amount == acc.balance - Decimal("1000")
    assert Decimal(str(db.rows[0].amount)) == Decimal("50") * Decimal(str(out["conversion"]["rate"]))
    assert out["conversion"]["from_currency"] == "USD"


@pytest.mark.asyncio
async def test_currency_mismatch_multi_currency_refuses_with_options():
    # A multi-currency bank never auto-picks: refusal lists the real
    # available currencies so Sara asks the user to choose. Nothing written.
    a1 = _acct("A", "SAR", 1000)
    a2 = _acct("A", "USD", 1000)
    db = FakeDb([a1, a2])
    svc, _ = _svc(db)
    out = await svc.execute("create_transaction",
                            _deposit_args(a1.id, "EUR", "50"))
    assert out.get("success") is not True and "error" in out
    assert db.add_calls == 0 and db.rows == []
    err = out["error"]
    assert "SAR" in err and "USD" in err
    assert a1.balance == Decimal("1000") and a2.balance == Decimal("1000")


# ── 11: no partial transaction on any failure ───────────────────────────────

@pytest.mark.asyncio
async def test_no_partial_state_on_failure():
    acc = _acct("A", "SAR", 30)
    db = FakeDb([acc])
    svc, _ = _svc(db)
    out = await svc.execute("create_transaction", {
        "operation": "withdraw", "amount": "100",
        "bank_account_id": str(acc.id), "currency": "SAR"})
    assert "error" in out  # insufficient balance
    assert db.rows == [] and db.add_calls == 0
    assert acc.balance == Decimal("30")


# ── 12-13: amount and type preserved ────────────────────────────────────────

@pytest.mark.asyncio
async def test_amount_and_type_preserved_exactly():
    acc = _acct("A", "SAR", 10000)
    db = FakeDb([acc])
    svc, _ = _svc(db)
    await svc.execute("create_transaction",
                      _deposit_args(acc.id, "SAR", "19.99"))
    row = db.rows[0]
    assert row.amount == Decimal("19.99")
    assert row.tx_type == "income"


# ── 14-15: idempotent retry + concurrent identical → one row ────────────────

@pytest.mark.asyncio
async def test_retry_identical_call_dedupes():
    acc = _acct("A", "SAR", 10000)
    db = FakeDb([acc])
    svc, _ = _svc(db)
    args = _deposit_args(acc.id, "SAR", "250")
    first = await svc.execute("create_transaction", dict(args))
    second = await svc.execute("create_transaction", dict(args))
    assert first.get("success") is True
    assert second.get("success") is True
    assert second.get("deduped") is True
    assert len(db.rows) == 1


@pytest.mark.asyncio
async def test_concurrent_identical_calls_create_one_row():
    acc = _acct("A", "SAR", 10000)
    db = FakeDb([acc])
    svc, _ = _svc(db)
    args = _deposit_args(acc.id, "SAR", "300")
    results = await asyncio.gather(
        svc.execute("create_transaction", dict(args)),
        svc.execute("create_transaction", dict(args)),
    )
    assert all(r.get("success") is True for r in results)
    assert len(db.rows) == 1
    assert acc.balance == Decimal("10300")  # applied exactly once


# ── runtime read-back: stored row matches the request ───────────────────────

@pytest.mark.asyncio
async def test_runtime_readback_matches_request():
    acc = _acct("الراجحي", "SAR", 2000)
    db = FakeDb([acc])
    svc, _ = _svc(db)
    out = await svc.execute("create_transaction",
                            _deposit_args(acc.id, "SAR", "700"))
    assert out.get("success") is True
    assert out.get("tool") == "create_transaction"
    assert len(db.rows) == 1
    stored = await db.get(None, db.rows[0].id)
    assert stored is not None
    assert stored.id is not None
    assert stored.amount == Decimal("700")
    assert stored.tx_type == "income"
    assert stored.bank_account_id == acc.id
    assert stored.currency == "SAR"
    assert stored.user_id == UID
    # Same-account second op with a different amount is a NEW row (no collapse).
    await svc.execute("create_transaction",
                      _deposit_args(acc.id, "SAR", "701"))
    assert len(db.rows) == 2
