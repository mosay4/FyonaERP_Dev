"""End-to-end tests for platform-admin RBAC (admin_permissions).

Verifies that `/admin/*` endpoints are gated by the DB-backed
`is_platform_admin` flag + per-resource grants, not by the JWT role claim.
"""
import uuid

import pytest
from httpx import AsyncClient, ASGITransport

from app.core.database import get_db
from app.core.security import create_access_token
from app.domain.entities.auth_entities import Organization, User, AdminPermission


def _org():
    return Organization(
        id=uuid.uuid4(), name="منظمة اختبار", slug=f"test-{uuid.uuid4().hex[:8]}",
        subscription_plan="trial", subscription_status="trial",
    )


def _user(org_id, email, is_platform_admin=False, role="owner"):
    return User(
        id=uuid.uuid4(), organization_id=org_id, full_name="مستخدم",
        email=email, role=role, is_platform_admin=is_platform_admin,
    )


async def _seed(async_session_factory):
    async with async_session_factory() as s:
        org = _org()
        s.add(org)
        await s.flush()
        regular = _user(org.id, f"regular-{uuid.uuid4().hex[:8]}@test.com")
        admin = _user(org.id, f"admin-{uuid.uuid4().hex[:8]}@test.com", is_platform_admin=True)
        s.add_all([regular, admin])
        await s.flush()
        s.add(AdminPermission(
            user_id=admin.id, resource="plans",
            can_create=False, can_read=True, can_update=False, can_delete=False,
        ))
        await s.commit()
        return org, regular, admin


def _token(user_id):
    return create_access_token(str(user_id), "some-org", "owner")


def _make_override(async_session_factory):
    async def _db_override():
        async with async_session_factory() as session:
            yield session
    return _db_override


@pytest.mark.asyncio
async def test_admin_rbac_flow(async_session_factory, sync_engine):
    from app.main import app
    org, regular, admin = await _seed(async_session_factory)
    override = _make_override(async_session_factory)
    transport = ASGITransport(app=app)
    app.dependency_overrides[get_db] = override
    client = AsyncClient(transport=transport, base_url="http://localhost")
    try:
        h_admin = {"Authorization": f"Bearer {_token(admin.id)}"}
        h_regular = {"Authorization": f"Bearer {_token(regular.id)}"}

        # Regular org owner (even with JWT role "owner") is denied.
        r = await client.get("/api/v1/admin/plans", headers=h_regular)
        assert r.status_code == 403, r.text

        # Platform admin with plans:read is allowed.
        r = await client.get("/api/v1/admin/plans", headers=h_admin)
        assert r.status_code == 200, r.text
        assert "plans" in r.json()["data"]

        # No plans:delete grant -> 403.
        r = await client.delete("/api/v1/admin/plans/1", headers=h_admin)
        assert r.status_code == 403, r.text

        # No currencies:read grant -> 403.
        r = await client.get("/api/v1/admin/currencies", headers=h_admin)
        assert r.status_code == 403, r.text

        # Permission management: acting admin lacks admin_permissions:update.
        r = await client.put(
            f"/api/v1/admin/admin-permissions/{regular.id}",
            json={"is_platform_admin": True, "permissions": [{"resource": "plans", "actions": ["read"]}]},
            headers=h_admin,
        )
        assert r.status_code == 403, r.text
    finally:
        app.dependency_overrides.clear()
        await client.aclose()


@pytest.mark.asyncio
async def test_admin_permissions_management_endpoints(async_session_factory, sync_engine):
    from app.main import app
    org, regular, admin = await _seed(async_session_factory)
    override = _make_override(async_session_factory)
    transport = ASGITransport(app=app)
    app.dependency_overrides[get_db] = override
    client = AsyncClient(transport=transport, base_url="http://localhost")

    # Grant the acting admin full admin_permissions access.
    async with async_session_factory() as s:
        from sqlalchemy import delete
        await s.execute(delete(AdminPermission).where(AdminPermission.user_id == admin.id))
        s.add_all([
            AdminPermission(user_id=admin.id, resource="admin_permissions",
                            can_read=True, can_update=True, can_create=False, can_delete=False),
            AdminPermission(user_id=admin.id, resource="plans",
                            can_read=True, can_update=True, can_create=False, can_delete=False),
        ])
        await s.commit()

    try:
        h = {"Authorization": f"Bearer {_token(admin.id)}"}

        r = await client.get("/api/v1/admin/admin-permissions/catalog", headers=h)
        assert r.status_code == 200, r.text
        assert "plans" in r.json()["data"]["catalog"]

        r = await client.get("/api/v1/admin/admin-permissions", headers=h)
        assert r.status_code == 200, r.text
        assert r.json()["data"]["total"] >= 1

        # Grant regular user plans:read + admin_permissions:read as a platform admin.
        r = await client.put(
            f"/api/v1/admin/admin-permissions/{regular.id}",
            json={"is_platform_admin": True, "permissions": [
                {"resource": "plans", "actions": ["read", "update"]},
                {"resource": "dashboard", "actions": ["read"]},
            ]},
            headers=h,
        )
        assert r.status_code == 200, r.text
        data = r.json()["data"]
        assert data["is_platform_admin"] is True
        assert "plans:read" in data["admin_permissions"]

        # Regular user can now list plans but not delete.
        h2 = {"Authorization": f"Bearer {_token(regular.id)}"}
        r = await client.get("/api/v1/admin/plans", headers=h2)
        assert r.status_code == 200, r.text
        r = await client.delete("/api/v1/admin/plans/1", headers=h2)
        assert r.status_code == 403, r.text

        # Demote back to non-admin.
        r = await client.put(
            f"/api/v1/admin/admin-permissions/{regular.id}",
            json={"is_platform_admin": False, "permissions": []},
            headers=h,
        )
        assert r.status_code == 200, r.text
        r = await client.get("/api/v1/admin/plans", headers=h2)
        assert r.status_code == 403, r.text

        # Empty grants while keeping platform admin -> 400.
        r = await client.put(
            f"/api/v1/admin/admin-permissions/{regular.id}",
            json={"is_platform_admin": True, "permissions": []},
            headers=h,
        )
        assert r.status_code == 400, r.text
    finally:
        app.dependency_overrides.clear()
        await client.aclose()
