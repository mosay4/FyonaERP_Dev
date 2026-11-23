"""Acceptance Test 21 — Suggestion message edit/delete.

- Owners may edit/delete their own messages within 24h.
- After 24h the owner is refused (403); platform admins may still moderate.
- Replies attach to the explicitly selected ticket (resolve_reply_target),
  never silently to the latest one.
"""

import json
from datetime import datetime, timedelta, timezone
from uuid import UUID, uuid4

import pytest
from sqlalchemy import select

from app.api.v1.suggestions import create_suggestion
from app.domain.entities.suggestions_entities import SuggestionReply
from app.domain.services.suggestions_service import SuggestionService


def _data(resp):
    return json.loads(resp.body)["data"]


async def _ticket(db, user_id=None):
    uid = user_id or uuid4()
    created = _data(await create_suggestion(
        title="ت", body="اقتراح للاختبار", images=[],
        user_id=uid, org_id=None, db=db))
    return uid, created["id"]


async def _user_msg(db, suggestion_id, user_id, body="مرحبا"):
    svc = SuggestionService(db)
    return await svc.add_reply(
        suggestion_id=suggestion_id, user_id=user_id, admin_id=None, body=body)


async def _backdate(db, message_id, days=2):
    await db.execute(
        SuggestionReply.__table__.update()
        .where(SuggestionReply.id == UUID(str(message_id)))
        .values(created_at=datetime.now(timezone.utc) - timedelta(days=days))
    )
    await db.commit()


async def test_owner_edits_own_message_within_24h(seed, db):
    uid, sid = await _ticket(db)
    svc = SuggestionService(db)
    msg = await _user_msg(db, sid, uid, body="نص أول")
    out = await svc.edit_reply(
        message_id=msg.id, user_id=uid, body="نص معدل", is_admin=False)
    assert out.body == "نص معدل"
    assert out.is_edited is True
    assert out.updated_at is not None


async def test_owner_cannot_edit_after_24h(seed, db):
    uid, sid = await _ticket(db)
    svc = SuggestionService(db)
    msg = await _user_msg(db, sid, uid)
    await _backdate(db, msg.id, days=2)
    with pytest.raises(Exception) as exc:
        await svc.edit_reply(
            message_id=msg.id, user_id=uid, body="متأخر", is_admin=False)
    assert exc.value.status_code == 403


async def test_owner_cannot_edit_others_message(seed, db):
    uid_a, sid = await _ticket(db)
    svc = SuggestionService(db)
    msg = await _user_msg(db, sid, uid_a)
    with pytest.raises(Exception) as exc:
        await svc.edit_reply(
            message_id=msg.id, user_id=uuid4(), body="تخريب", is_admin=False)
    assert exc.value.status_code == 403


async def test_admin_can_edit_anytime(seed, db):
    uid, sid = await _ticket(db)
    svc = SuggestionService(db)
    msg = await _user_msg(db, sid, uid)
    await _backdate(db, msg.id, days=10)
    out = await svc.edit_reply(
        message_id=msg.id, user_id=uuid4(), body="تدخل إداري", is_admin=True)
    assert out.body == "تدخل إداري"
    assert out.is_edited is True


async def test_owner_deletes_own_message_within_24h(seed, db):
    uid, sid = await _ticket(db)
    svc = SuggestionService(db)
    msg = await _user_msg(db, sid, uid)
    await svc.delete_reply(message_id=msg.id, user_id=uid, is_admin=False)
    remaining = await svc.list_replies(suggestion_id=sid)
    assert all(r.id != str(msg.id) for r in remaining)


async def test_owner_cannot_delete_after_24h(seed, db):
    uid, sid = await _ticket(db)
    svc = SuggestionService(db)
    msg = await _user_msg(db, sid, uid)
    await _backdate(db, msg.id, days=2)
    with pytest.raises(Exception) as exc:
        await svc.delete_reply(message_id=msg.id, user_id=uid, is_admin=False)
    assert exc.value.status_code == 403


async def test_admin_can_delete_anytime(seed, db):
    uid, sid = await _ticket(db)
    svc = SuggestionService(db)
    msg = await _user_msg(db, sid, uid)
    await _backdate(db, msg.id, days=30)
    await svc.delete_reply(message_id=msg.id, user_id=uuid4(), is_admin=True)
    remaining = await svc.list_replies(suggestion_id=sid)
    assert all(r.id != str(msg.id) for r in remaining)


async def test_reply_targets_selected_ticket_not_latest(seed, db):
    uid = uuid4()
    _, sid_old = await _ticket(db, uid)
    _, sid_new = await _ticket(db, uid)
    svc = SuggestionService(db)
    target = await svc.resolve_reply_target(user_id=uid, suggestion_id=sid_old)
    assert str(target.id) == sid_old
    assert sid_old != sid_new


async def test_edit_empty_body_rejected(seed, db):
    uid, sid = await _ticket(db)
    svc = SuggestionService(db)
    msg = await _user_msg(db, sid, uid)
    with pytest.raises(Exception) as exc:
        await svc.edit_reply(
            message_id=msg.id, user_id=uid, body="   ", is_admin=False)
    assert exc.value.status_code == 400
