"""Backend stored-rate auto-conversion for create_transaction (deposit/withdraw).

Single-currency bank + foreign requested currency → converted at the stored
rate and written in the bank's currency (never the raw foreign amount).
Multi-currency bank → refusal listing the real available currencies.
No stored rate → honest no-rate refusal, nothing written.
"""
import os
from decimal import Decimal
from unittest.mock import MagicMock
from uuid import uuid4

import pytest

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")
os.environ.setdefault("CELERY_BROKER_URL", "redis://localhost:6379/1")
os.environ.setdefault("CELERY_RESULT_BACKEND", "redis://localhost:6379/2")

UID = uuid4()


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
    def __init__(self, accounts):
        self.accounts = {a.id: a for a in accounts}
        self.rows = []

    def _one(self, value=None, entities=None):
        m = MagicMock()
        m.scalar_one_or_none.return_value = value
        sc = MagicMock()
        sc.all.return_value = entities or []
        m.scalars.return_value = sc
        return m

    async def execute(self, stmt):
        s = str(stmt)
        try:
            params = list(stmt.compile().params.values())
        except Exception:
            params = []
        if "client_operation_id" in s:
            return self._one(value=None)
        if "personal_bank_accounts" in s:
            from uuid import UUID
            uuids = [p for p in params if isinstance(p, UUID)]
            non_uid = [u for u in uuids if u != UID]
            if non_uid:
                acc = self.accounts.get(non_uid[0])
                found = [acc] if acc is not None else []
                return self._one(entities=found)
            mine = [a for a in self.accounts.values() if a.user_id == UID]
            return self._one(entities=mine)
        return self._one()

    async def get(self, model, pk):
        for r in self.rows:
            if getattr(r, "id", None) == pk:
                return r
        return None

    def add(self, row):
        self.rows.append(row)

    async def flush(self):
        for r in self.rows:
            if getattr(r, "id", None) is None:
                r.id = uuid4()


def _svc(db):
    from app.domain.services import sara_agent_service as mod
    return mod.ToolExecutor(db, uuid4(), UID, lang="ar")


class _Fx:
    """Stored-rate stub: USD->YER_NEW 1542, USD->SAR 3.75, else None."""
    RATES = {("USD", "YER_NEW"): 1542.0, ("USD", "SAR"): 3.75}

    async def convert(self, amount, frm, to):
        r = self.RATES.get((frm, to))
        return None if r is None else round(amount * r, 4)


@pytest.fixture()
def fx(monkeypatch):
    import app.domain.services.currency_service as cs
    monkeypatch.setattr(cs.CurrencyService, "get_instance",
                        classmethod(lambda cls: _Fx()))
    return _Fx()


@pytest.mark.asyncio
async def test_deposit_single_currency_converts(fx):
    acc = _acct("القطيبي", "YER_NEW", 0)
    db = FakeDb([acc])
    svc = _svc(db)
    out = await svc.execute("create_transaction", {
        "operation": "deposit", "amount": 100, "currency": "USD",
        "bank_account_id": str(acc.id), "description": "test"})
    assert out.get("success") is True
    assert len(db.rows) == 1
    row = db.rows[0]
    assert row.currency == "YER_NEW"
    assert Decimal(str(row.amount)) == Decimal("154200")
    assert acc.balance == Decimal("154200")
    msg = out.get("message", "")
    assert "154200" in msg and "YER_NEW" in msg and "USD" in msg
    conv = out.get("conversion") or {}
    assert conv.get("from_currency") == "USD"
    assert conv.get("to_currency") == "YER_NEW"


@pytest.mark.asyncio
async def test_deposit_multi_currency_lists_options(fx):
    a1 = _acct("القطيبي", "YER_NEW", 0)
    a2 = _acct("القطيبي", "USD", 0)
    db = FakeDb([a1, a2])
    svc = _svc(db)
    out = await svc.execute("create_transaction", {
        "operation": "deposit", "amount": 100, "currency": "EUR",
        "bank_account_id": str(a1.id), "description": "test"})
    assert out.get("success") is not True
    assert len(db.rows) == 0
    err = out.get("error", "") or out.get("message", "")
    assert "YER_NEW" in err and "USD" in err


@pytest.mark.asyncio
async def test_deposit_no_rate_writes_nothing(fx):
    acc = _acct("القطيبي", "SAR", 0)
    db = FakeDb([acc])
    svc = _svc(db)
    out = await svc.execute("create_transaction", {
        "operation": "deposit", "amount": 10, "currency": "XYZ",
        "bank_account_id": str(acc.id), "description": "test"})
    assert out.get("success") is not True
    assert len(db.rows) == 0


@pytest.mark.asyncio
async def test_withdraw_converts_and_checks_converted_balance(fx):
    acc = _acct("القطيبي", "SAR", 100)
    db = FakeDb([acc])
    svc = _svc(db)
    # 100 USD -> 375 SAR > 100 balance → insufficient (converted check).
    out = await svc.execute("create_transaction", {
        "operation": "withdraw", "amount": 100, "currency": "USD",
        "bank_account_id": str(acc.id), "description": "test"})
    assert out.get("success") is not True
    assert len(db.rows) == 0
    # 10 USD -> 37.5 SAR fits.
    out2 = await svc.execute("create_transaction", {
        "operation": "withdraw", "amount": 10, "currency": "USD",
        "bank_account_id": str(acc.id), "description": "test"})
    assert out2.get("success") is True
    assert db.rows[0].currency == "SAR"
    assert Decimal(str(db.rows[0].amount)) == Decimal("37.5")
    assert acc.balance == Decimal("62.5")


@pytest.mark.asyncio
async def test_matching_currency_unchanged(fx):
    acc = _acct("الراجحي", "SAR", 1000)
    db = FakeDb([acc])
    svc = _svc(db)
    out = await svc.execute("create_transaction", {
        "operation": "deposit", "amount": 50, "currency": "SAR",
        "bank_account_id": str(acc.id), "description": "test"})
    assert out.get("success") is True
    assert Decimal(str(db.rows[0].amount)) == Decimal("50")
    assert "conversion" not in out
