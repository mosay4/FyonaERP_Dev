from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock
from uuid import uuid4

import pytest
from fastapi import HTTPException

from app.domain.services import employee_presence_service as presence
from app.domain.services.employee_access_policy import GROUPS, allowed, full_access
from app.api.v1.employees import _perm, default_permissions


def workspace(org=None):
    return SimpleNamespace(employee_id=uuid4(), linked_user_id=uuid4(),
        organization_id=org or uuid4(), active_organization_id=None,
        last_seen_at=None)


def session(rows):
    result = SimpleNamespace(scalars=lambda: SimpleNamespace(all=lambda: rows))
    return SimpleNamespace(execute=AsyncMock(return_value=result),
        get=AsyncMock(), commit=AsyncMock())


def test_presence_requires_active_workspace_and_expires_within_sixty_seconds():
    now = datetime.now(timezone.utc)
    ws = workspace()
    ws.last_seen_at = now
    assert not presence.is_online(ws, now)
    ws.active_organization_id = ws.organization_id
    assert presence.is_online(ws, now)
    assert presence.is_online(ws, now + timedelta(seconds=59))
    assert not presence.is_online(ws, now + timedelta(seconds=60))
    ws.linked_user_id = None
    assert not presence.is_online(ws, now)


@pytest.mark.asyncio
@pytest.mark.parametrize('online', [True, False])
async def test_unscoped_or_offline_heartbeat_never_marks_any_workspace_online(online):
    rows = [workspace(), workspace()]
    for ws in rows:
        ws.last_seen_at = datetime.now(timezone.utc)
        ws.active_organization_id = ws.organization_id
    db = session(rows)
    assert not await presence.set_presence(db, uuid4(), online=online)
    assert all(ws.last_seen_at is None and ws.active_organization_id is None for ws in rows)
    db.commit.assert_awaited_once()


@pytest.mark.asyncio
async def test_only_selected_authorized_merchant_is_online(monkeypatch):
    selected, other = workspace(), workspace()
    branch = uuid4()
    user = selected.linked_user_id
    db = session([selected, other])
    db.get.return_value = SimpleNamespace(is_deleted=False, organization_id=selected.organization_id)
    monkeypatch.setattr(presence.access, 'get_member', AsyncMock(return_value=SimpleNamespace(scope_valid_after=None)))
    monkeypatch.setattr(presence.access, 'effective_branch_ids', AsyncMock(return_value=[branch]))
    scope = {'sub': str(user), 'org': str(selected.organization_id), 'mode': 'branch', 'branch': str(branch)}
    assert await presence.set_presence(db, user, scope, True)
    assert presence.is_online(selected)
    assert not presence.is_online(other)
    assert not await presence.set_presence(db, user, scope, False)
    assert not presence.is_online(selected)


@pytest.mark.asyncio
@pytest.mark.parametrize('denial', ['membership', 'deleted', 'branch', 'subject'])
async def test_revoked_deleted_and_unauthorized_workspaces_cannot_be_online(monkeypatch, denial):
    ws = workspace()
    db = session([ws])
    branch = uuid4()
    db.get.return_value = SimpleNamespace(is_deleted=denial == 'deleted', organization_id=ws.organization_id)
    monkeypatch.setattr(presence.access, 'get_member', AsyncMock(return_value=
        None if denial == 'membership' else SimpleNamespace(scope_valid_after=None)))
    monkeypatch.setattr(presence.access, 'effective_branch_ids', AsyncMock(return_value=[] if denial == 'branch' else [branch]))
    scope = {'sub': str(uuid4() if denial == 'subject' else ws.linked_user_id),
        'org': str(ws.organization_id), 'mode': 'branch', 'branch': str(branch)}
    if denial in ('membership', 'subject'):
        with pytest.raises(HTTPException) as exc:
            await presence.set_presence(db, ws.linked_user_id, scope, True)
        assert exc.value.status_code == 403
    else:
        assert not await presence.set_presence(db, ws.linked_user_id, scope, True)
    assert not presence.is_online(ws)


def test_subscription_cannot_be_granted_even_by_legacy_permission_maps():
    assert 'subscription' not in GROUPS
    assert 'subscription' not in default_permissions()
    assert 'subscription' not in _perm('{"subscription": true}')
    assert not allowed({'subscription': True}, 'subscription')
    assert full_access(default_permissions())
