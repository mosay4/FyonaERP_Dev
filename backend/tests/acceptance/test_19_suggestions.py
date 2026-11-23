"""Acceptance Test 19 — Product Suggestions.

Users (personal + business) submit free-text suggestions with optional images;
platform admins review them in the dashboard:
- Suggestion created with images persisted under uploads/suggestion_images.
- list_mine only ever returns the caller's own suggestions.
- Admin list is gated by the `suggestions:read` permission (DB-backed) and
  joins user/org display info.
- Admin can flip status (pending/proposed/in_progress/completed/rejected) and add a note.
- Images are served only to the owner or a platform admin.
- Missing body is rejected.
"""

import json
import os
from io import BytesIO
from uuid import uuid4

import pytest
from fastapi import UploadFile

from app.api.v1.suggestions import (
    create_suggestion,
    list_mine,
    admin_list_suggestions,
    admin_update_suggestion,
    serve_suggestion_image,
)
from app.domain.models.suggestions_models import SuggestionUpdate
from app.domain.services.suggestions_service import UPLOAD_DIR


def _image(name="screen.png", content=b"PNG-FAKE-DATA"):
    return UploadFile(filename=name, file=BytesIO(content))


def _data(resp):
    return json.loads(resp.body)["data"]


async def test_create_suggestion_with_images(seed, db):
    uid = uuid4()
    resp = await create_suggestion(
        title="قائمة جانبية",
        body="أقترح إضافة قسم للملاحظات في القائمة الجانبية",
        images=[_image("a.png", b"AAA"), _image("b.jpg", b"BBB")],
        user_id=uid, org_id=None, db=db,
    )
    data = _data(resp)
    assert data["status"] == "pending"
    assert data["user_id"] == str(uid)
    assert data["organization_id"] is None
    assert data["title"] == "قائمة جانبية"
    assert len(data["images"]) == 2
    try:
        for fname in data["images"]:
            path = os.path.join(UPLOAD_DIR, fname)
            assert os.path.isfile(path), f"image not on disk: {path}"
    finally:
        for fname in data["images"]:
            path = os.path.join(UPLOAD_DIR, fname)
            if os.path.isfile(path):
                os.remove(path)


async def test_create_suggestion_requires_body(seed, db):
    with pytest.raises(Exception) as exc:
        await create_suggestion(
            title="فارغ", body="   ",
            images=[], user_id=uuid4(), org_id=None, db=db,
        )
    assert exc.value.status_code == 400


async def test_list_mine_is_isolated_per_user(seed, db):
    user_a, user_b = uuid4(), uuid4()
    r1 = await create_suggestion(title="من أ", body="اقتراح أ", images=[], user_id=user_a, org_id=seed["org_a"], db=db)
    await create_suggestion(title="من ب", body="اقتراح ب", images=[], user_id=user_b, org_id=None, db=db)
    a_id = _data(r1)["id"]

    mine_a = _data(await list_mine(user_id=user_a, db=db))
    mine_b = _data(await list_mine(user_id=user_b, db=db))

    assert len(mine_a) == 1 and mine_a[0]["id"] == a_id
    assert mine_a[0]["organization_id"] == str(seed["org_a"])
    assert all(s["user_id"] == str(user_a) for s in mine_a)
    assert all(s["user_id"] == str(user_b) for s in mine_b)


async def test_admin_list_is_gated_and_joins_user(seed, db):
    from app.domain.models.suggestions_models import SuggestionAdminResponse

    uid = uuid4()
    await create_suggestion(title="أولوية", body="أضيفوا تقارير PDF", images=[], user_id=uid, org_id=seed["org_a"], db=db)

    # admin (permission dependency satisfied) can list
    resp = _data(await admin_list_suggestions(status_filter=None, search=None, page=1, per_page=20, _=True, db=db))
    assert resp["total"] == 1
    item = resp["items"][0]
    assert item["user_name"] == ""  # no user row seeded -> display info falls back to empty
    assert SuggestionAdminResponse(**item)  # schema valid


async def test_admin_search_and_status_filter(seed, db):
    await create_suggestion(title="بحث", body="أريد خاصية الظلام", images=[], user_id=uuid4(), org_id=None, db=db)
    await create_suggestion(title="أخرى", body="خاصية مختلفة تماماً", images=[], user_id=uuid4(), org_id=None, db=db)

    found = _data(await admin_list_suggestions(status_filter=None, search="الظلام", page=1, per_page=20, _=True, db=db))
    assert found["total"] == 1
    assert "الظلام" in found["items"][0]["body"]

    none_pending = _data(await admin_list_suggestions(status_filter="completed", search=None, page=1, per_page=20, _=True, db=db))
    assert none_pending["total"] == 0


async def test_admin_update_status_and_note(seed, db):
    created = _data(await create_suggestion(title="تحديث", body="نرغب بتصدير Excel", images=[], user_id=uuid4(), org_id=None, db=db))
    sid = created["id"]

    resp = await admin_update_suggestion(
        suggestion_id=sid,
        update=SuggestionUpdate(status="rejected", admin_note="موجود مسبقاً"),
        _=True, db=db,
    )
    updated = _data(resp)
    assert updated["status"] == "rejected"
    assert updated["admin_note"] == "موجود مسبقاً"

    # user now sees the review outcome in their list
    mine = _data(await list_mine(user_id=created["user_id"], db=db))
    assert mine[0]["status"] == "rejected"
    assert mine[0]["admin_note"] == "موجود مسبقاً"


async def test_image_serving_permission(seed, db):
    from app.domain.entities.auth_entities import User

    owner = uuid4()
    created = _data(await create_suggestion(
        title="صور", body="رفع صور", images=[_image("secret.png", b"SECRET")],
        user_id=owner, org_id=None, db=db,
    ))
    fname = created["images"][0]
    stranger = uuid4()
    admin = uuid4()
    db.add_all([
        User(id=stranger, organization_id=seed["org_a"], full_name="مستخدم عادي", email="img.user@test.com",
             password_hash="x", role="employee"),
        User(id=admin, organization_id=seed["org_a"], full_name="مدير المنصة", email="img.admin@test.com",
             password_hash="x", role="super_admin", is_platform_admin=True),
    ])
    await db.commit()
    try:
        # owner can read
        resp = await serve_suggestion_image(filename=fname, user_id=owner, db=db)
        assert resp.status_code == 200
        assert os.path.basename(resp.path) == fname

        # another user cannot
        with pytest.raises(Exception) as exc:
            await serve_suggestion_image(filename=fname, user_id=stranger, db=db)
        assert exc.value.status_code == 403

        # platform admin can
        resp = await serve_suggestion_image(filename=fname, user_id=admin, db=db)
        assert resp.status_code == 200

        # missing file -> 404
        with pytest.raises(Exception) as exc:
            await serve_suggestion_image(filename="nope.png", user_id=owner, db=db)
        assert exc.value.status_code == 404
    finally:
        path = os.path.join(UPLOAD_DIR, fname)
        if os.path.isfile(path):
            os.remove(path)


async def test_http_flow_with_real_auth(seed, async_session_factory):
    """Full HTTP: create + list via ASGI with a real platform-admin JWT."""
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
    normal_uid = uuid4()
    async with async_session_factory() as s:
        s.add_all([
            User(id=admin_uid, organization_id=seed["org_a"], full_name="مدير المنصة", email="http.admin@test.com",
                 password_hash="x", role="super_admin", is_platform_admin=True),
            User(id=normal_uid, organization_id=seed["org_a"], full_name="مستخدم عادي", email="http.user@test.com",
                 password_hash="x", role="employee"),
        ])
        await s.commit()

    admin_headers = {"Authorization": f"Bearer {create_access_token(str(admin_uid), str(seed['org_a']), 'super_admin')}"}
    normal_headers = {"Authorization": f"Bearer {create_access_token(str(normal_uid), str(seed['org_a']), 'employee')}"}
    app.dependency_overrides[get_db] = _db_override
    try:
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://localhost") as ac:
            # unauthenticated -> 401/403
            r0 = await ac.get("/api/v1/suggestions/mine")
            assert r0.status_code in (401, 403)

            # non-platform-admin is rejected from the admin feed
            r4 = await ac.get("/api/v1/suggestions", headers=normal_headers)
            assert r4.status_code == 403

            # create with an image
            r1 = await ac.post(
                "/api/v1/suggestions",
                data={"title": "من التطبيق", "body": "اقتراح من داخل التطبيق"},
                files={"images": ("shot.png", b"HTTP-PNG", "image/png")},
                headers=admin_headers,
            )
            assert r1.status_code == 200, r1.text
            data1 = r1.json()["data"]
            assert data1["status"] == "pending"
            assert len(data1["images"]) == 1

            # admin list returns it
            r2 = await ac.get("/api/v1/suggestions", headers=admin_headers)
            assert r2.status_code == 200
            assert r2.json()["data"]["total"] >= 1

            # admin updates it
            r3 = await ac.patch(
                f"/api/v1/suggestions/{data1['id']}",
                json={"status": "in_progress", "admin_note": "قيد التنفيذ"},
                headers=admin_headers,
            )
            assert r3.status_code == 200, r3.text
            assert r3.json()["data"]["status"] == "in_progress"
    finally:
        app.dependency_overrides.clear()
