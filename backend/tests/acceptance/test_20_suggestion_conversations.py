"""Acceptance Test 20 — Suggestion conversations (admin chat view).

The admin dashboard treats all suggestions + replies from a single user as one
conversation stream:
- Conversations are grouped per user and ordered by the most recent activity.
- Each conversation carries an unread count (suggestions the admin has not
  opened yet, tracked by the `admin_read_at` column).
- The message stream merges suggestions and replies in one chronological list.
- Admin can reply to a whole conversation (attaches to the user's latest
  suggestion) and can mark the conversation as read.
- A user's own suggestions show as "from user", admin replies as "from admin".
"""

import json
from uuid import uuid4

import pytest

from app.api.v1.suggestions import (
    create_suggestion,
    admin_list_conversations,
    admin_conversation_messages,
    admin_conversation_reply,
    admin_mark_conversation_read,
)
from app.domain.models.suggestions_models import SuggestionReplyCreate


def _data(resp):
    return json.loads(resp.body)["data"]


async def test_conversations_grouped_by_user_with_unread(seed, db):
    user_a = uuid4()
    user_b = uuid4()
    await create_suggestion(title="من أ 1", body="اقتراح أول", images=[], user_id=user_a, org_id=seed["org_a"], db=db)
    await create_suggestion(title="من أ 2", body="اقتراح ثانٍ", images=[], user_id=user_a, org_id=None, db=db)
    await create_suggestion(title="من ب", body="اقتراح ب", images=[], user_id=user_b, org_id=None, db=db)

    data = _data(await admin_list_conversations(search=None, page=1, per_page=20, _=True, db=db))
    assert data["total"] == 2
    by_user = {c["user_id"]: c for c in data["items"]}
    conv_a = by_user[str(user_a)]
    conv_b = by_user[str(user_b)]
    assert conv_a["suggestions_count"] == 2
    assert conv_a["unread_count"] == 2
    assert conv_b["suggestions_count"] == 1
    assert conv_b["unread_count"] == 1
    assert conv_a["has_reply"] is False


async def test_conversations_search_by_user_and_title(seed, db):
    user = uuid4()
    await create_suggestion(title="فواتير", body="نريد تصدير الفواتير", images=[], user_id=user, org_id=None, db=db)
    await create_suggestion(title="إخفاء", body="شيء مختلف", images=[], user_id=uuid4(), org_id=None, db=db)

    found = _data(await admin_list_conversations(search="فواتير", page=1, per_page=20, _=True, db=db))
    assert found["total"] == 1
    assert found["items"][0]["user_id"] == str(user)


async def test_conversation_messages_merged_stream(seed, db):
    user = uuid4()
    created = _data(await create_suggestion(
        title="دمج", body="رسالة المستخدم الأصلية", images=[], user_id=user, org_id=None, db=db,
    ))
    await admin_conversation_reply(
        user_id=user, body=SuggestionReplyCreate(body="رد الإدارة"), admin_id=uuid4(), _=True, db=db,
    )

    data = _data(await admin_conversation_messages(user_id=user, page=1, per_page=20, _=True, db=db))
    assert data["total"] == 2
    assert data["items"][0]["kind"] == "reply"
    assert data["items"][0]["is_from_admin"] is True
    assert data["items"][0]["body"] == "رد الإدارة"
    assert data["items"][1]["kind"] == "suggestion"
    assert data["items"][1]["is_from_admin"] is False
    assert data["items"][1]["suggestion_id"] == created["id"]


async def test_conversation_reply_attaches_to_latest(seed, db):
    user = uuid4()
    await create_suggestion(title="أول", body="قديم", images=[], user_id=user, org_id=None, db=db)
    latest = _data(await create_suggestion(title="أحدث", body="جديد", images=[], user_id=user, org_id=None, db=db))

    await admin_conversation_reply(
        user_id=user, body=SuggestionReplyCreate(body="رد على الأحدث"), admin_id=uuid4(), _=True, db=db,
    )
    from app.domain.entities.suggestions_entities import SuggestionReply
    from sqlalchemy import select
    row = (await db.execute(
        select(SuggestionReply).order_by(SuggestionReply.created_at.desc()).limit(1)
    )).scalar_one_or_none()
    assert row is not None
    assert str(row.suggestion_id) == latest["id"]
    assert row.admin_id is not None


async def test_mark_conversation_read_clears_unread(seed, db):
    user = uuid4()
    await create_suggestion(title="مقروءة", body="سُترى", images=[], user_id=user, org_id=None, db=db)
    await create_suggestion(title="ثانية", body="أيضاً", images=[], user_id=user, org_id=None, db=db)

    before = _data(await admin_list_conversations(search=None, page=1, per_page=20, _=True, db=db))
    assert before["items"][0]["unread_count"] == 2

    resp = await admin_mark_conversation_read(user_id=user, _=True, db=db)
    assert resp.status_code == 200

    after = _data(await admin_list_conversations(search=None, page=1, per_page=20, _=True, db=db))
    assert after["items"][0]["unread_count"] == 0

    # a new suggestion becomes unread again
    await create_suggestion(title="جديدة", body="تظهر كغير مقروءة", images=[], user_id=user, org_id=None, db=db)
    again = _data(await admin_list_conversations(search=None, page=1, per_page=20, _=True, db=db))
    assert again["items"][0]["unread_count"] == 1


async def test_http_conversation_flow(seed, async_session_factory):
    """Full HTTP: a normal user submits, the platform admin opens the
    conversation, replies, and marks it read."""
    try:
        from app.main import app  # may pull optional deps (sentry) not installed here
    except ModuleNotFoundError:
        pytest.skip("app.main unavailable in this environment (optional deps missing)")

    from httpx import AsyncClient, ASGITransport
    from app.core.security import create_access_token
    from app.core.database import get_db
    from app.domain.entities.auth_entities import User

    async def _db_override():
        async with async_session_factory() as session:
            yield session

    admin_uid = uuid4()
    user_uid = uuid4()
    async with async_session_factory() as s:
        s.add_all([
            User(id=admin_uid, organization_id=seed["org_a"], full_name="مدير المنصة", email="conv.admin@test.com",
                 password_hash="x", role="super_admin", is_platform_admin=True),
            User(id=user_uid, organization_id=seed["org_a"], full_name="مستخدم عادي", email="conv.user@test.com",
                 password_hash="x", role="employee"),
        ])
        await s.commit()

    admin_headers = {"Authorization": f"Bearer {create_access_token(str(admin_uid), str(seed['org_a']), 'super_admin')}"}
    user_headers = {"Authorization": f"Bearer {create_access_token(str(user_uid), str(seed['org_a']), 'employee')}"}
    app.dependency_overrides[get_db] = _db_override
    try:
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://localhost") as ac:
            # normal user submits two suggestions
            for body in ("أول رسالة في المحادثة", "رسالة ثانية"):
                r = await ac.post(
                    "/api/v1/suggestions",
                    data={"title": "محادثة", "body": body},
                    headers=user_headers,
                )
                assert r.status_code == 200, r.text

            # a regular user cannot open the admin conversation feed
            r403 = await ac.get("/api/v1/suggestions/conversations", headers=user_headers)
            assert r403.status_code == 403

            # admin sees one conversation with 2 unread
            r1 = await ac.get("/api/v1/suggestions/conversations", headers=admin_headers)
            assert r1.status_code == 200, r1.text
            conv = r1.json()["data"]["items"][0]
            assert conv["user_id"] == str(user_uid)
            assert conv["unread_count"] == 2

            # admin opens the messages stream
            r2 = await ac.get(f"/api/v1/suggestions/conversations/{user_uid}/messages", headers=admin_headers)
            assert r2.status_code == 200, r2.text
            msgs = r2.json()["data"]["items"]
            assert len(msgs) == 2
            assert all(m["is_from_admin"] is False for m in msgs)

            # admin replies inside the conversation
            r3 = await ac.post(
                f"/api/v1/suggestions/conversations/{user_uid}/reply",
                json={"body": "أهلاً، تم استلام اقتراحك"},
                headers=admin_headers,
            )
            assert r3.status_code == 200, r3.text

            # stream now includes the admin reply as "from admin" (newest first)
            r4 = await ac.get(f"/api/v1/suggestions/conversations/{user_uid}/messages", headers=admin_headers)
            msgs4 = r4.json()["data"]["items"]
            assert len(msgs4) == 3
            assert msgs4[0]["is_from_admin"] is True
            assert msgs4[0]["body"] == "أهلاً، تم استلام اقتراحك"

            # mark read -> unread 0, last message is the admin reply
            r5 = await ac.post(f"/api/v1/suggestions/conversations/{user_uid}/read", headers=admin_headers)
            assert r5.status_code == 200, r5.text
            r6 = await ac.get("/api/v1/suggestions/conversations", headers=admin_headers)
            conv6 = r6.json()["data"]["items"][0]
            assert conv6["unread_count"] == 0
            assert conv6["last_is_from_admin"] is True
            assert conv6["last_message"] == "أهلاً، تم استلام اقتراحك"
    finally:
        app.dependency_overrides.clear()
