"""Trial activation writes the in-app welcome row (device tray is client-side).

Uses AsyncMock for the database; never touches a real Postgres.
"""
import os
import json
from uuid import uuid4
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

os.environ.setdefault("JWT_SECRET_KEY", "test-secret-key-at-least-sixteen")
os.environ.setdefault("DATABASE_URL", "postgresql+asyncpg://test:test@localhost/test")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379")


@pytest.mark.asyncio
async def test_trial_activation_writes_welcome_notification():
    """activate_trial inserts an AppNotification with the welcome greeting."""
    from app.api.v1.subscription import activate_trial
    from app.domain.entities.notification_entities import AppNotification

    org = MagicMock()
    org.trial_end_date = None
    org.has_used_free_plan = False
    org.subscription_status = None

    db = AsyncMock()
    # User lookup for the soft phone log -> no user, skip.
    user_result = MagicMock()
    user_result.scalar_one_or_none.return_value = None
    db.execute.return_value = user_result

    with patch(
        "app.api.v1.subscription._get_org", return_value=org
    ):
        result = await activate_trial(
            body={}, user_id=uuid4(), org_id="org-test", db=db
        )

    assert json.loads(result.body)["success"] is True
    added = [
        call.args[0]
        for call in db.add.call_args_list
        if isinstance(call.args[0], AppNotification)
    ]
    assert len(added) == 1, f"expected 1 welcome row, got {len(added)}"
    row = added[0]
    assert "نورتوا فيونا" in (row.message or "")
    assert row.action_payload == "notifications"


@pytest.mark.asyncio
async def test_trial_notification_failure_never_breaks_activation():
    """If the welcome insert fails, the trial itself still activates."""
    from app.api.v1.subscription import activate_trial
    from app.domain.entities.notification_entities import AppNotification

    org = MagicMock()
    org.trial_end_date = None
    org.has_used_free_plan = False

    db = AsyncMock()
    user_result = MagicMock()
    user_result.scalar_one_or_none.return_value = None
    db.execute.return_value = user_result

    real_add = db.add

    def flaky_add(row):
        if isinstance(row, AppNotification):
            raise RuntimeError("disk full")
        return real_add(row)

    db.add.side_effect = flaky_add

    with patch(
        "app.api.v1.subscription._get_org", return_value=org
    ):
        result = await activate_trial(
            body={}, user_id=uuid4(), org_id="org-test", db=db
        )

    body = json.loads(result.body)
    assert body["success"] is True
    assert "hours_remaining" in body["data"]
