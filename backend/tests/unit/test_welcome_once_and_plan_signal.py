"""Welcome exactly once + plan-change signal + same-currency Sara accounts.

No network, no real DB: fakes only.
"""
import os
from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import pytest

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")


class _Res:
    def __init__(self, one=None, rows=None):
        self._one, self._rows = one, rows or []

    def scalar_one_or_none(self):
        return self._one

    def scalars(self):
        rows = self._rows

        class _S:
            def all(self_inner):
                return list(rows)

            def first(self_inner):
                return rows[0] if rows else None
        return _S()


class _WelcomeDb:
    def __init__(self, org_id):
        self.org = MagicMock()
        self.org.id = org_id
        self.org.subscription_status = "trial"
        self.rows = []
        self.added = []
        self.dedup_sql = []

    async def execute(self, stmt, *a, **k):
        text = str(stmt)
        if "organizations" in text:
            return _Res(one=self.org)
        self.dedup_sql.append(text)
        uid_hits = [r for r in self.rows if "user_id" in text]
        return _Res(one=uid_hits[0] if uid_hits else None)

    def add(self, row):
        self.added.append(row)

    async def flush(self):
        for r in self.added:
            if getattr(r, "id", None) is None:
                r.id = uuid4()

    async def commit(self):
        self.rows.extend(self.added)

    async def rollback(self):
        return None


@pytest.mark.asyncio
async def test_welcome_dedupe_is_user_scoped_and_tagged():
    """Same user + same event under ANOTHER org row → no second row/push."""
    from app.domain.services import subscription_welcome as w

    user_id = uuid4()
    db = _WelcomeDb(uuid4())
    with patch("app.domain.services.push_service.notify_user", new=AsyncMock()) as push:
        first = await w.send_subscription_welcome(db, user_id=user_id, org_id=db.org.id, event="trial")
        # Replay of the free-plan activation under a different org id.
        db.org.id = uuid4()
        second = await w.send_subscription_welcome(db, user_id=user_id, org_id=db.org.id, event="trial")
    assert first is not None and second == first
    assert len(db.added) == 1
    assert push.call_count == 1
    # The dedup lookup matches on the user as well as the org.
    assert any("user_id" in s and "source_notif_id" in s for s in db.dedup_sql)
    # The push carries the stable tray tag shared with the app's local row.
    assert push.call_args.kwargs.get("tag") == w.WELCOME_TRAY_TAG


@pytest.mark.asyncio
async def test_notify_user_forwards_tray_tag_in_data():
    from app.domain.services import push_service as ps

    seen = {}

    async def fake_detached(tokens, *, title, body, data, log_ctx=None):
        seen.update(data)
        return {"sent": 1}

    with patch.object(ps, "tokens_for_users", new=AsyncMock(return_value=["t1"])), \
         patch.object(ps, "_push_visible_split_detached", new=fake_detached):
        task = await ps.notify_user(MagicMock(), user_id=uuid4(), title="a", body="b",
                                    action_payload="notifications", tag="fyona_subscription_welcome")
        await task
    assert seen["notif_tag"] == "fyona_subscription_welcome"


def test_build_message_sets_android_tag_only_when_given():
    pytest.importorskip("firebase_admin")
    from app.domain.services import push_service as ps

    tagged = ps._build_message("tok", title="t", body="b",
                               data={"action_payload": "notifications", "notif_tag": "x1"})
    assert tagged.android.notification.tag == "x1"
    assert tagged.apns is not None
    plain = ps._build_message("tok", title="t", body="b", data={"action_payload": "n"})
    assert plain.android.notification.tag is None
    assert plain.apns is None


@pytest.mark.asyncio
async def test_notify_subscription_changed_is_silent_data_push():
    from app.domain.services import push_service as ps

    db = MagicMock()
    db.execute = AsyncMock(return_value=_Res(rows=[uuid4()]))
    sent = {}

    async def fake_data(tokens, *, data, timeout=8.0):
        sent.update(data)
        return {"sent": len(tokens), "failed": 0, "invalid_tokens": []}

    with patch.object(ps, "tokens_for_users", new=AsyncMock(return_value=["t1"])), \
         patch.object(ps, "_send_data_push_bounded", new=fake_data), \
         patch.object(ps, "_send_push_bounded", new=AsyncMock()) as visible:
        out = await ps.notify_subscription_changed(db, uuid4())
    assert out["sent"] == 1
    assert sent["type"] == ps.SUBSCRIPTION_CHANGED_EVENT
    assert "title" not in sent and "body" not in sent
    visible.assert_not_called()


@pytest.mark.asyncio
async def test_admin_plan_change_signals_member_devices():
    from app.api.v1 import admin

    org = MagicMock()
    org.id = uuid4()
    org.subscription_status = "active"
    org.subscription_end_date = None
    org.subscription_start_date = None
    org.subscription_plan = "personal"
    org.section_subscriptions = {}
    db = MagicMock()
    db.execute = AsyncMock(return_value=_Res(one=org))
    db.commit = AsyncMock()
    db.refresh = AsyncMock()
    body = admin.OrgSubscriptionBody(action="change_plan", plan_name="premium")
    with patch("app.domain.services.push_service.notify_subscription_changed",
               new=AsyncMock()) as signal, \
         patch.object(admin, "_org_dict", return_value={}):
        await admin.manage_org_subscription(str(org.id), body, db=db, _=None)
    signal.assert_awaited_once()
    assert signal.await_args.args[1] == org.id


@pytest.mark.asyncio
async def test_admin_plan_signal_failure_never_breaks_request():
    from app.api.v1 import admin

    with patch("app.domain.services.push_service.notify_subscription_changed",
               new=AsyncMock(side_effect=RuntimeError("fcm down"))):
        await admin._signal_subscription_changed(MagicMock(), uuid4())


# ── Same currency twice in one bank (جاري + توفير) ──

def _rows():
    return [
        {"id": "chk", "name": "الكريمي", "currency": "USD", "balance": "100", "type": "bank"},
        {"id": "sav", "name": "الكريمي", "currency": "USD", "balance": "900", "type": "bank"},
        {"id": "sar", "name": "بنك", "currency": "SAR", "balance": "0", "type": "bank"},
    ]


def test_same_currency_rows_and_needs_account_shape():
    from app.domain.services import sara_agent_service as sara

    rows = sara._same_currency_rows(_rows(), "الكريمي", "usd")
    assert [r["id"] for r in rows] == ["chk", "sav"]
    err = sara._needs_account_error(rows, "الكريمي", "USD")
    assert err["error_code"] == "NEEDS_ACCOUNT"
    assert [o["id"] for o in err["accounts"]] == ["chk", "sav"]
    assert "bank_account_id" in err["error"]


@pytest.mark.asyncio
async def test_prepare_banking_asks_which_same_currency_account():
    from app.domain.services import sara_agent_service as sara

    executor = MagicMock(_db=None, _org_id="o", _user_id="u")
    rows = _rows()  # the phone's own account list (device mode)
    out = await sara.prepare_personal_banking(executor, {
        "operation": "deposit", "account_name": "الكريمي", "currency": "USD", "amount": 5},
        accounts=rows)
    assert out["error_code"] == "NEEDS_ACCOUNT"
    assert {o["id"] for o in out["accounts"]} == {"chk", "sav"}
    # Once the user picks, the exact id runs on exactly that account.
    out = await sara.prepare_personal_banking(executor, {
        "operation": "deposit", "bank_account_id": "sav", "currency": "USD", "amount": 5},
        accounts=rows)
    assert out["tool"] == "create_transaction"
    assert out["params"]["account_id"] == "sav"
    executor._exec_get_exchange_rate = AsyncMock(return_value={"rate": 3.75})
    out = await sara.prepare_personal_banking(executor, {
        "operation": "transfer", "from_account_name": "الكريمي", "from_currency": "USD",
        "to_account_name": "بنك", "to_currency": "SAR", "amount": 5}, accounts=rows)
    assert out["error_code"] == "NEEDS_ACCOUNT"


@pytest.mark.asyncio
async def test_server_deposit_by_name_never_picks_first_same_currency_row():
    from app.domain.services import sara_agent_service as sara

    chk = MagicMock(id=uuid4(), bank_name="الكريمي", currency="USD", balance=100, user_id="u")
    sav = MagicMock(id=uuid4(), bank_name="الكريمي", currency="USD", balance=900, user_id="u")
    db = MagicMock()
    calls = {"n": 0}

    async def execute(stmt, *a, **k):
        calls["n"] += 1
        if calls["n"] == 1:      # client_operation_id dedup
            return _Res(one=None)
        return _Res(rows=[chk, sav])

    db.execute = execute
    db.add = MagicMock()
    self_ = MagicMock(_db=db, _user_id="u", _is_en=False)
    out = await sara.ToolExecutor._create_transaction_locked(
        self_, {"account_name": "الكريمي", "currency": "USD"}, "deposit", 5, "op-1")
    assert out.get("error_code") == "NEEDS_ACCOUNT"
    db.add.assert_not_called()
    assert chk.balance == 100 and sav.balance == 900
