"""Push hardening + unified welcome tests (no network, no real DB).

Covers:
- send_each batching over 500 tokens (400-per-batch chunks)
- single bounded retry on transport failures
- invalid-token classification + cleanup (UNREGISTERED -> is_active=False)
- fan-out target filtering (admins-only never reaches user orgs)
- unified welcome idempotency (same event twice -> 1 row, 1 push)
- trial welcome exact frozen copy
- no-double-push on already-pushed paths
"""
import os
import sys
import types
import uuid as uuid_lib
from unittest.mock import AsyncMock, MagicMock, patch
from uuid import uuid4

import pytest

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")
os.environ.setdefault("CELERY_BROKER_URL", "redis://localhost:6379/1")
os.environ.setdefault("CELERY_RESULT_BACKEND", "redis://localhost:6379/2")

WELCOME_TITLE = "شركة فيونا"
WELCOME_BODY = "يا مراحب ، نورتوا فيونا، ونقدر نقول بعد الان حياتكم الماليه بإذن الله بتتغير للأفضل🫡❤️."


def _ok_response():
    m = MagicMock()
    m.success = True
    m.exception = None
    return m


def _fail_response(code="messaging/registration-token-not-registered"):
    exc = MagicMock()
    exc.code = code
    exc.__str__.return_value = code
    # type name must not accidentally match; keep default MagicMock name out
    type(exc).__name__ = "FirebaseError"
    m = MagicMock()
    m.success = False
    m.exception = exc
    return m


def _batch_result(responses):
    m = MagicMock()
    m.responses = list(responses)
    return m


def _patch_fcm(monkey=None):
    """Patch push_service firewall: enabled + initialized + fake messaging."""
    from app.domain.services import push_service as ps

    calls = {"n": 0}

    p1 = patch.object(ps, "is_enabled", return_value=True)
    p2 = patch.object(ps, "initialize_firebase", return_value=None)
    p3 = patch.object(ps, "_build_message", side_effect=lambda t, **k: ("msg", t))
    return p1, p2, p3, calls


@pytest.mark.asyncio
async def test_send_push_batches_over_500_tokens():
    """550 tokens -> 2 send_each calls (400 + 150), all counted sent."""
    from app.domain.services import push_service as ps

    tokens = [f"tok-{i:04d}-valid-token-string" for i in range(550)]
    sent_batches = []

    def fake_send_each(messages):
        sent_batches.append(list(messages))
        return _batch_result([_ok_response() for _ in messages])

    with patch.object(ps, "is_enabled", return_value=True):
        with patch.object(ps, "initialize_firebase", return_value=None):
            with patch.object(ps, "_build_message", side_effect=lambda t, **k: ("msg", t)):
                import firebase_admin.messaging as fam

                with patch.object(fam, "send_each", side_effect=fake_send_each) as mock_send:
                    result = ps.send_push(tokens, title="t", body="b", data={"action": "open_screen", "action_payload": "notifications"})
    assert mock_send.call_count == 2, f"expected 2 chunk calls, got {mock_send.call_count}"
    assert len(sent_batches[0]) == 400
    assert len(sent_batches[1]) == 150
    assert result["sent"] == 550
    assert result["failed"] == 0
    assert result["invalid_tokens"] == []


@pytest.mark.asyncio
async def test_send_push_single_retry_on_transport_error():
    """One transport blowup -> exactly one re-attempt, then success."""
    from app.domain.services import push_service as ps

    tokens = ["tok-a-valid-0001", "tok-b-valid-0002"]
    attempts = {"n": 0}

    def flaky(messages):
        attempts["n"] += 1
        if attempts["n"] == 1:
            raise RuntimeError("connection reset")
        return _batch_result([_ok_response() for _ in messages])

    with patch.object(ps, "is_enabled", return_value=True):
        with patch.object(ps, "initialize_firebase", return_value=None):
            with patch.object(ps, "_build_message", side_effect=lambda t, **k: ("msg", t)):
                import firebase_admin.messaging as fam

                with patch.object(fam, "send_each", side_effect=flaky) as mock_send:
                    result = ps.send_push(tokens, title="t", body="b", data={"action": "x", "action_payload": "y"})
    assert mock_send.call_count == 2, "exactly one retry expected"
    assert result["sent"] == 2
    assert result["failed"] == 0


@pytest.mark.asyncio
async def test_send_push_bad_batch_never_kills_broadcast():
    """First batch transport-dead twice -> counted failed, second batch still sent."""
    from app.domain.services import push_service as ps

    tokens = [f"batch0-tok-{i}" for i in range(400)] + ["batch1-good-token-xyz"]
    calls = []

    def router(messages):
        calls.append(len(messages))
        if len(messages) == 400:
            raise RuntimeError("persistent transport failure")
        return _batch_result([_ok_response() for _ in messages])

    with patch.object(ps, "is_enabled", return_value=True):
        with patch.object(ps, "initialize_firebase", return_value=None):
            with patch.object(ps, "_build_message", side_effect=lambda t, **k: ("msg", t)):
                import firebase_admin.messaging as fam

                with patch.object(fam, "send_each", side_effect=router):
                    result = ps.send_push(tokens, title="t", body="b", data={"action": "x", "action_payload": "y"})
    # batch0: try + 1 retry = 2 calls, batch1: 1 call
    assert len(calls) == 3
    assert result["sent"] == 1
    assert result["failed"] == 400


def test_classify_invalid_tokens_unregistered():
    from app.domain.services.push_service import classify_invalid_tokens

    tokens = ["good-token-aaa", "dead-token-bbb", "other-fail-ccc"]
    ok = _ok_response()
    dead = _fail_response("messaging/registration-token-not-registered")
    other_exc = MagicMock()
    other_exc.code = "messaging/internal-error"
    other_exc.__str__.return_value = "internal error"
    other = MagicMock()
    other.success = False
    other.exception = other_exc
    out = classify_invalid_tokens(tokens, [ok, dead, other])
    assert out == ["dead-token-bbb"]


@pytest.mark.asyncio
async def test_invalid_token_cleanup_deactivates_row():
    """UNREGISTERED response -> deactivate_tokens issues is_active=False."""
    from app.domain.services import push_service as ps

    db = AsyncMock()
    fake_res = MagicMock()
    fake_res.rowcount = 1
    db.execute.return_value = fake_res
    db.commit = AsyncMock()

    n = await ps.deactivate_tokens(db, ["dead-token-xyz"])
    assert n == 1
    assert db.execute.called
    assert db.commit.called
    # The update must target is_active=False (never deletes, never logs tokens).
    executed_stmt = db.execute.call_args.args[0]
    assert "is_active" in str(executed_stmt) or "device_tokens" in str(executed_stmt)


@pytest.mark.asyncio
async def test_notify_user_cleans_invalid_tokens_end_to_end():
    """notify_user(token set with 1 UNREGISTERED) -> background task deactivates it."""
    from app.domain.services import push_service as ps

    good = "good-device-token-0001"
    dead = "dead-device-token-0002"

    async def fake_tokens(db, user_ids):
        return [good, dead]

    def fake_send_each(messages):
        # messages are ("msg", token) stubs from patched _build_message
        resps = []
        for _, tok in messages:
            if tok == dead:
                resps.append(_fail_response("messaging/registration-token-not-registered"))
            else:
                resps.append(_ok_response())
        return _batch_result(resps)

    db = AsyncMock()
    fake_res = MagicMock()
    fake_res.rowcount = 1
    # tokens_for_users is patched; db.execute here is only the cleanup update.
    db.execute.return_value = fake_res
    db.commit = AsyncMock()

    class _DbCM:
        async def __aenter__(self):
            return db
        async def __aexit__(self, *a):
            return False

    with patch.object(ps, "tokens_for_users", side_effect=fake_tokens):
        with patch.object(ps, "is_enabled", return_value=True):
            with patch.object(ps, "initialize_firebase", return_value=None):
                with patch.object(ps, "_build_message", side_effect=lambda t, **k: ("msg", t)):
                    import firebase_admin.messaging as fam

                    with patch.object(fam, "send_each", side_effect=fake_send_each):
                        # Detached fire-and-forget opens its own session —
                        # route it back to the mock db so cleanup assertions hold.
                        with patch(
                            "app.core.database.async_session_factory",
                            MagicMock(return_value=_DbCM()),
                        ):
                            task = await ps.notify_user(
                                db, user_id=uuid4(), title="t", body="b",
                                action="open_screen", action_payload="notifications",
                            )
                            assert task is not None
                            await task
    assert db.execute.called, "cleanup update must run for invalid tokens"
    assert db.commit.called


# ── Fan-out target filtering ──

class _Scalars:
    def __init__(self, rows):
        self._rows = list(rows)

    def all(self):
        return list(self._rows)

    def first(self):
        return self._rows[0] if self._rows else None

    def unique(self):
        return self


class _Result:
    def __init__(self, scalars=None, scalar=None, scalar_one=None):
        self._scalars = scalars
        self._scalar = scalar
        self._one = scalar_one

    def scalars(self):
        return _Scalars(self._scalars or [])

    def scalar(self):
        return self._scalar

    def scalar_one_or_none(self):
        return self._one


class _FakeSession:
    """Routes fanout queries by call order for the admins-only scenario."""

    def __init__(self, notif, org_admin, org_user):
        self.notif = notif
        self.org_admin = org_admin
        self.org_user = org_user
        self.calls = []
        self.admin_user = MagicMock()
        self.admin_user.email = "admin@x.com"
        self.admin_user.id = uuid4()

    async def execute(self, stmt, *a, **k):
        # Distinguish by compiling to string is brittle with mocks; use order.
        self.calls.append(str(type(stmt)))
        n = len(self.calls)
        if n == 1:  # notif lookup
            return _Result(scalars=[self.notif])
        if n == 2:  # all active orgs
            return _Result(scalars=[self.org_admin, self.org_user])
        if n == 3:  # admin org ids
            return _Result(scalars=[self.org_admin.id])
        # Per-org loop for the single wanted org:
        if n == 4:  # existing count
            return _Result(scalar=0)
        if n == 5:  # pg insert
            return _Result()
        if n == 6:  # users in org
            return _Result(scalars=[self.admin_user])
        return _Result(scalar=0, scalars=[])

    async def commit(self):
        return None


class _FakeSessionCM:
    def __init__(self, session):
        self._s = session

    async def __aenter__(self):
        return self._s

    async def __aexit__(self, *a):
        return False


@pytest.mark.asyncio
async def test_fanout_admins_only_does_not_reach_user_orgs():
    from app.workers import tasks as t

    org_admin = MagicMock()
    org_admin.id = uuid4()
    org_user = MagicMock()
    org_user.id = uuid4()
    notif = MagicMock()
    notif.id = uuid4()
    notif.target = "admins"
    notif.type = "info"
    notif.title = "T"
    notif.message = "M"

    session = _FakeSession(notif, org_admin, org_user)
    fake_factory = MagicMock(return_value=_FakeSessionCM(session))

    with patch.object(t, "async_session_factory", fake_factory):
        with patch.object(t.email_service, "send_email", new=AsyncMock()) as mock_email:
            out = await t._fanout_platform_notification(str(notif.id))
    assert out["status"] == "completed"
    assert out["target"] == "admins"
    assert out["notifications_dispatched"] == 1, "only the admin org must be fanned out"
    # Only 6 executes (1 org loop) — a leak to the user org would add 3 more.
    assert len(session.calls) == 6, f"user org leaked: {len(session.calls)} executes"
    # Product rule: notification fan-out NEVER emails (inbox + push only).
    assert not mock_email.called


# ── Unified welcome ──

class _WelcomeDb:
    """Minimal welcome-flow fake: org active, notifications keyed by source id."""

    def __init__(self, org_id, user_id, status="active"):
        self.org = MagicMock()
        self.org.id = org_id
        self.org.subscription_status = status
        self.store = {}
        self.add_calls = []
        self.commits = 0

    async def execute(self, stmt, *a, **k):
        from app.domain.entities.notification_entities import AppNotification as _AN
        from app.domain.entities.auth_entities import Organization as _Org

        text = ""
        try:
            text = str(stmt)
        except Exception:
            text = ""
        # Route: org lookup contains "organizations"; dedup contains source_notif_id.
        if "organizations" in text:
            return _Result(scalar_one=self.org)
        if "app_notifications" in text or "source_notif_id" in text or "AppNotification" in text:
            # Return any stored row (single-event test) else None.
            rows = list(self.store.values())
            row = rows[0] if rows else None
            # For the welcome helper both .scalar_one_or_none() shapes appear.
            return _Result(scalars=rows, scalar_one=row)
        # Default: behave as empty dedup.
        rows = list(self.store.values())
        row = rows[0] if rows else None
        return _Result(scalars=rows, scalar_one=row)

    def add(self, row):
        self.add_calls.append(row)

    async def flush(self):
        # Assign an id like the ORM would, then stage by source id.
        for row in self.add_calls:
            if getattr(row, "id", None) is None:
                row.id = uuid4()
            sid = getattr(row, "source_notif_id", None)
            if sid is not None:
                self.store[(str(row.organization_id), str(sid))] = row

    async def commit(self):
        self.commits += 1

    async def rollback(self):
        return None


@pytest.mark.asyncio
async def test_welcome_exact_text_and_payloads():
    from app.domain.services import subscription_welcome as w

    assert w.WELCOME_TITLE == WELCOME_TITLE
    assert w.WELCOME_BODY == WELCOME_BODY

    org_id, user_id = uuid4(), uuid4()
    db = _WelcomeDb(org_id, user_id, status="active")
    with patch("app.domain.services.push_service.notify_user", new=AsyncMock()) as mock_push:
        nid = await w.send_subscription_welcome(
            db, user_id=user_id, org_id=org_id, event="trial"
        )
    assert nid is not None
    assert len(db.add_calls) == 1
    row = db.add_calls[0]
    assert row.title == "شركة فيونا"
    assert row.message == "يا مراحب ، نورتوا فيونا، ونقدر نقول بعد الان حياتكم الماليه بإذن الله بتتغير للأفضل🫡❤️."
    assert row.action_payload == "notifications"
    assert mock_push.called
    kwargs = mock_push.call_args.kwargs
    assert kwargs.get("title") == "شركة فيونا"

    # Paid keeps the invoice deep-link.
    org2, user2 = uuid4(), uuid4()
    db2 = _WelcomeDb(org2, user2, status="active")
    with patch("app.domain.services.push_service.notify_user", new=AsyncMock()):
        await w.send_subscription_welcome(
            db2, user_id=user2, org_id=org2,
            event="stripe:pi_123", invoice_no="INV-20260101-0001",
        )
    assert db2.add_calls[0].action_payload == "/subscription/invoice?invoice_no=INV-20260101-0001"


@pytest.mark.asyncio
async def test_welcome_idempotent_same_event_twice_one_row_one_push():
    from app.domain.services import subscription_welcome as w

    org_id, user_id = uuid4(), uuid4()
    db = _WelcomeDb(org_id, user_id, status="active")
    with patch("app.domain.services.push_service.notify_user", new=AsyncMock()) as mock_push:
        first = await w.send_subscription_welcome(
            db, user_id=user_id, org_id=org_id, event="stripe:pi_same",
            invoice_no="INV-20260101-0009",
        )
        second = await w.send_subscription_welcome(
            db, user_id=user_id, org_id=org_id, event="stripe:pi_same",
            invoice_no="INV-20260101-0009",
        )
    assert first is not None
    assert second == first
    assert len(db.add_calls) == 1, "DB constraint path must keep exactly 1 row"
    assert mock_push.call_count == 1, "second (duplicate) event must not push again"


@pytest.mark.asyncio
async def test_welcome_no_push_when_already_pushed():
    """Pre-existing welcome row -> returns its id, never pushes."""
    from app.domain.services import subscription_welcome as w

    org_id, user_id = uuid4(), uuid4()
    db = _WelcomeDb(org_id, user_id, status="active")
    # Seed the store as if a previous attempt already welcomed this event.
    existing = MagicMock()
    existing.id = uuid4()
    db.store[("seed", "seed")] = existing  # any row makes dedup hit
    with patch("app.domain.services.push_service.notify_user", new=AsyncMock()) as mock_push:
        out = await w.send_subscription_welcome(
            db, user_id=user_id, org_id=org_id, event="manual:req-1"
        )
    assert out == existing.id
    assert db.add_calls == []
    assert mock_push.call_count == 0


@pytest.mark.asyncio
async def test_welcome_never_before_active_status():
    from app.domain.services import subscription_welcome as w

    org_id, user_id = uuid4(), uuid4()
    db = _WelcomeDb(org_id, user_id, status="pending")
    with patch("app.domain.services.push_service.notify_user", new=AsyncMock()) as mock_push:
        out = await w.send_subscription_welcome(
            db, user_id=user_id, org_id=org_id, event="trial"
        )
    assert out is None
    assert db.add_calls == []
    assert mock_push.call_count == 0


@pytest.mark.asyncio
async def test_trial_endpoint_uses_unified_welcome_event():
    """activate_trial delegates to the unified helper with event='trial'."""
    import json
    from unittest.mock import AsyncMock as _AM

    from app.api.v1.subscription import activate_trial

    org = MagicMock()
    org.id = uuid4()
    org.trial_end_date = None
    org.has_used_free_plan = False
    org.subscription_status = None

    db = _AM()
    user_result = MagicMock()
    user_result.scalar_one_or_none.return_value = None
    db.execute.return_value = user_result

    with patch("app.api.v1.subscription._get_org", return_value=org):
        with patch(
            "app.domain.services.subscription_welcome.send_subscription_welcome",
            new=_AM(return_value=uuid4()),
        ) as mock_welcome:
            result = await activate_trial(body={}, user_id=uuid4(), org_id="org-test", db=db)
    assert json.loads(result.body)["success"] is True
    assert mock_welcome.called
    assert mock_welcome.call_args.kwargs.get("event") == "trial"


# ── Android data-only transport (rich local render everywhere) ──

def _data_msg(token="tok-android-0001"):
    from app.domain.services import push_service as ps

    return ps._build_message(
        token, title="T", body="B",
        data={"action": "open_screen", "action_payload": "notifications"},
        data_only=True,
    )


def _notif_msg(token="tok-ios-0001"):
    from app.domain.services import push_service as ps

    return ps._build_message(
        token, title="T", body="B",
        data={"action": "open_screen", "action_payload": "notifications"},
        data_only=False,
    )


def test_data_only_message_has_no_notification_block():
    """Android shape: title/body travel INSIDE data; no notification{}."""
    msg = _data_msg()
    assert getattr(msg, "notification", None) is None
    assert msg.data["title"] == "T"
    assert msg.data["body"] == "B"
    assert msg.data["action"] == "open_screen"
    assert msg.data["action_payload"] == "notifications"


def test_legacy_message_keeps_notification_block():
    """notification{} shape keeps title/body + full data routing payload."""
    msg = _notif_msg()
    assert msg.notification is not None
    assert msg.notification.title == "T"
    assert msg.notification.body == "B"
    # data[] still carries title/body/action for foreground + deep-link.
    assert msg.data["title"] == "T"
    assert msg.data["body"] == "B"
    assert msg.data["action"] == "open_screen"
    assert msg.data["action_payload"] == "notifications"
    # Small-icon disc is black (brand), never white/system.
    assert msg.android.notification.color == "#000000"
    # OS tray uses the app channel (SOUND 1) + default notification icon.
    assert msg.android.notification.channel_id == "suggestions_channel"


@pytest.mark.asyncio
async def test_visible_split_android_vs_ios():
    """Default ANDROID_DATA_ONLY=False -> every token gets notification shape."""
    from app.domain.services import push_service as ps

    seen = {}

    async def fake_cleanup(db, tokens, title, body, data, log_ctx=None,
                           data_only=False):
        seen[tuple(sorted(tokens))] = data_only
        return {"sent": len(tokens), "failed": 0, "invalid_tokens": []}

    async def fake_plats(db, tokens):
        return {"tok-a": "android", "tok-i": "ios", "tok-u": ""}

    with patch.object(ps, "ANDROID_DATA_ONLY", False):
        with patch.object(ps, "_push_and_cleanup", side_effect=fake_cleanup):
            with patch.object(ps, "token_platforms", side_effect=fake_plats):
                out = await ps._push_visible_split(
                    MagicMock(), ["tok-a", "tok-i", "tok-u"],
                    title="T", body="B", data={"action": "open_screen"},
                    log_ctx={"type": "push"},
                )
    assert out["sent"] == 3
    # Single notification{} batch for all platforms (no data-only split).
    assert seen == {("tok-a", "tok-i", "tok-u"): False}, seen


@pytest.mark.asyncio
async def test_data_only_kill_switch_splits_android():
    """ANDROID_DATA_ONLY=True (opt-in) still sends data-only to android."""
    from app.domain.services import push_service as ps

    seen = {}

    async def fake_cleanup(db, tokens, title, body, data, log_ctx=None,
                           data_only=False):
        seen[tuple(sorted(tokens))] = data_only
        return {"sent": len(tokens), "failed": 0, "invalid_tokens": []}

    async def fake_plats(db, tokens):
        return {"tok-a": "android", "tok-i": "ios"}

    with patch.object(ps, "ANDROID_DATA_ONLY", True):
        with patch.object(ps, "_push_and_cleanup", side_effect=fake_cleanup):
            with patch.object(ps, "token_platforms", side_effect=fake_plats):
                out = await ps._push_visible_split(
                    MagicMock(), ["tok-a", "tok-i"],
                    title="T", body="B", data={"action": "open_screen"},
                    log_ctx={},
                )
    assert out["sent"] == 2
    assert seen[("tok-a",)] is True
    assert seen[("tok-i",)] is False


@pytest.mark.asyncio
async def test_default_android_tokens_get_os_renderable_push():
    """Regression: visible Android pushes must carry notification{} so the
    OS paints the Notification Tray in background/terminated (data-only
    never reaches a dead process)."""
    from app.domain.services import push_service as ps

    assert ps.ANDROID_DATA_ONLY is False, (
        "visible pushes must default to OS-renderable notification{}"
    )
    msg = ps._build_message(
        "tok-android-0001", title="T", body="B",
        data={"action": "open_screen", "action_payload": "notifications"},
        data_only=False,
    )
    assert msg.notification is not None
    assert msg.notification.title == "T"
    assert msg.notification.body == "B"
    assert msg.data["action_payload"] == "notifications"
    assert msg.android.notification.channel_id == "suggestions_channel"


@pytest.mark.asyncio
async def test_notify_all_users_routes_through_visible_split():
    """Admin broadcast (target=all) routes through _push_visible_split.

    Ensures every user-visible push uses the single transport split
    (notification{} by default so the OS tray works in background/killed).
    """
    from app.domain.services import push_service as ps

    class _Rows:
        def scalars(self):
            return self

        def all(self):
            return ["tok-android-0001"]

    class _DB:
        async def execute(self, *a, **k):
            return _Rows()

    split_called = {}

    async def fake_split(db, tokens, *, title, body, data, log_ctx=None):
        split_called["tokens"] = list(tokens)
        split_called["log_ctx"] = log_ctx
        return {"sent": len(tokens), "failed": 0, "invalid_tokens": []}

    with patch.object(ps, "_push_visible_split", side_effect=fake_split):
        task = await ps.notify_all_users(
            _DB(), title="FYONA ERP", body="جاهز",
            action_payload="notifications",
        )
        assert task is not None
        await task

    assert split_called.get("tokens") == ["tok-android-0001"], split_called
    assert (split_called.get("log_ctx") or {}).get("type") == "push_all"
