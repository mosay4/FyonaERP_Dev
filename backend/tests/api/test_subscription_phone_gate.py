"""Free-subscription phone-gate + phone-add flow (the 8 acceptance scenarios).

Scenarios covered:
  1. New user with NO phone tries the free plan  -> blocked (PHONE_REQUIRED).
  2. User adds a VALID phone                      -> saved as E.164, masked back.
  3. User submits an INVALID phone                -> 400.
  4. User submits a phone owned by ANOTHER user   -> 400 (dedup).
  5. Phone does not match the SELECTED country    -> 400.
  6. User with a valid phone activates free plan  -> 200 success.
  7. User with a PREVIOUS subscription/trial      -> unaffected by the gate.
  8. Direct API call without a frontend (no phone)-> blocked exactly like #1.

All DB access is mocked; no test touches the real database.
"""

from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, MagicMock
from uuid import uuid4

import pytest
from httpx import AsyncClient, ASGITransport

from app.main import app
from app.core.config import settings
from app.core.database import get_db
from app.core.security import create_access_token
from app.domain.entities.auth_entities import Organization, User

pytestmark = pytest.mark.asyncio

UID = uuid4()
ORG_ID = uuid4()


def _result(value):
    """A fake SQLAlchemy Result whose scalar/scalars accessors return value."""
    res = MagicMock()
    res.scalar_one_or_none.return_value = value
    res.scalars.return_value.first.return_value = value
    res.scalars.return_value.all.return_value = value if value else []
    return res


def _make_user(phone=None, phone_country=None, email=None):
    return User(
        id=UID,
        organization_id=ORG_ID,
        full_name="اختبار",
        email=email or f"test-{uuid4().hex[:8]}@test.com",
        phone=phone,
        phone_country=phone_country,
        role="owner",
        created_at=datetime.now(timezone.utc),
    )


def _make_org(trial_end_date=None, status=None):
    return Organization(
        id=ORG_ID,
        name="منظمة اختبار",
        slug=f"org-{uuid4().hex[:8]}",
        subscription_status=status or "pending",
        subscription_plan="trial",
        trial_end_date=trial_end_date,
    )


def _token() -> str:
    return create_access_token(str(UID), str(ORG_ID), "owner")


def _auth_headers() -> dict:
    return {"Authorization": f"Bearer {_token()}"}


def _make_client(execute_results: list):
    results = list(execute_results)

    async def fake_execute(*args, **kwargs):
        if results:
            return results.pop(0)
        raise AssertionError(
            "session.execute called more times than stubbed results"
        )

    session = MagicMock()
    session.execute = fake_execute
    session.commit = AsyncMock()
    session.refresh = AsyncMock()
    session.rollback = AsyncMock()
    session.close = AsyncMock()
    session.flush = AsyncMock()
    app.dependency_overrides[get_db] = lambda: session
    return session


@pytest.fixture(autouse=True)
def _clean_overrides():
    yield
    app.dependency_overrides.clear()


# ── 1 + 8. New user without phone calls the free plan directly (API, no UI) ──
async def test_trial_blocked_when_no_phone():
    user = _make_user(phone=None)
    org = _make_org(trial_end_date=None)
    _make_client([_result(org), _result(user)])
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://localhost") as c:
        resp = await c.post(
            f"{settings.API_PREFIX}/subscription/trial",
            json={"mode": "personal"},
            headers=_auth_headers(),
        )
    assert resp.status_code == 400
    assert "رقم هاتفك" in resp.json()["message"]


# ── 1b. Malformed placeholder phone is treated as missing ──
async def test_trial_blocked_when_phone_is_placeholder():
    user = _make_user(phone="0000000000")
    org = _make_org(trial_end_date=None)
    _make_client([_result(org), _result(user)])
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://localhost") as c:
        resp = await c.post(
            f"{settings.API_PREFIX}/subscription/trial",
            json={"mode": "personal"},
            headers=_auth_headers(),
        )
    assert resp.status_code == 400


# ── 6. User with a valid phone activates the free plan ──
async def test_trial_allowed_with_valid_phone():
    user = _make_user(phone="+967777304569", phone_country="YE")
    org = _make_org(trial_end_date=None)
    _make_client([_result(org), _result(user)])
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://localhost") as c:
        resp = await c.post(
            f"{settings.API_PREFIX}/subscription/trial",
            json={"mode": "personal"},
            headers=_auth_headers(),
        )
    assert resp.status_code == 200
    assert resp.json()["success"] is True


# ── 7. Existing subscription/trial user is unaffected by the gate ──
async def test_active_trial_user_not_blocked():
    user = _make_user(phone=None)  # no phone — must still get the "already active" path
    org = _make_org(trial_end_date=datetime.now(timezone.utc) + timedelta(hours=5))
    _make_client([_result(org), _result(user)])
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://localhost") as c:
        resp = await c.post(
            f"{settings.API_PREFIX}/subscription/trial",
            json={"mode": "personal"},
            headers=_auth_headers(),
        )
    assert resp.status_code == 200
    assert "نشطة بالفعل" in resp.json()["message"]


async def test_expired_trial_user_rejected_once_only_not_phone():
    user = _make_user(phone=None)
    org = _make_org(trial_end_date=datetime.now(timezone.utc) - timedelta(hours=1))
    _make_client([_result(org), _result(user)])
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://localhost") as c:
        resp = await c.post(
            f"{settings.API_PREFIX}/subscription/trial",
            json={"mode": "personal"},
            headers=_auth_headers(),
        )
    assert resp.status_code == 400
    assert "مرة واحدة فقط" in resp.json()["message"]


# ── 2. Add a valid phone ──
async def test_add_valid_phone_saves_e164_and_returns_masked():
    user = _make_user(phone=None)
    org = _make_org()
    # call order: user.get_by_id -> phone.get_by_phone -> org.get_by_id
    _make_client([_result(user), _result(None), _result(org)])
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://localhost") as c:
        resp = await c.post(
            f"{settings.API_PREFIX}/auth/me/phone",
            json={"phone": "777304569", "country": "YE"},
            headers=_auth_headers(),
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["phone"] == "+967777304569"
    assert body["phone_complete"] is True
    assert body["phone_masked"] == "+967 *****4569"
    assert "777304569" not in body["phone_masked"]


# ── 3. Invalid phone ──
async def test_add_invalid_phone_rejected():
    user = _make_user(phone=None)
    _make_client([_result(user), _result(None)])
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://localhost") as c:
        resp = await c.post(
            f"{settings.API_PREFIX}/auth/me/phone",
            json={"phone": "12345", "country": "YE"},
            headers=_auth_headers(),
        )
    assert resp.status_code == 400


# ── 4. Phone already owned by another user ──
async def test_add_duplicate_phone_rejected():
    user = _make_user(phone=None)
    other = _make_user(phone="+967777304569", email="other@test.com")
    other.id = uuid4()
    _make_client([_result(user), _result(other)])
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://localhost") as c:
        resp = await c.post(
            f"{settings.API_PREFIX}/auth/me/phone",
            json={"phone": "+967777304569", "country": "YE"},
            headers=_auth_headers(),
        )
    assert resp.status_code == 400
    assert "حساب آخر" in resp.json()["message"]


# ── 5. Phone does not match the selected country ──
async def test_add_phone_country_mismatch_rejected():
    user = _make_user(phone=None)
    _make_client([_result(user), _result(None)])
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://localhost") as c:
        resp = await c.post(
            f"{settings.API_PREFIX}/auth/me/phone",
            json={"phone": "+966512345678", "country": "YE"},  # Saudi number, YE selected
            headers=_auth_headers(),
        )
    assert resp.status_code == 400
    assert "الدولة" in resp.json()["message"]


# ── PUT /auth/me with a phone must not bypass validation ──
async def test_put_me_phone_also_validates():
    user = _make_user(phone=None)
    org = _make_org()
    _make_client([_result(user), _result(None), _result(org)])
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://localhost") as c:
        resp = await c.put(
            f"{settings.API_PREFIX}/auth/me",
            json={"phone": "+967777304569"},
            headers=_auth_headers(),
        )
    assert resp.status_code == 200
    assert resp.json()["phone"] == "+967777304569"
