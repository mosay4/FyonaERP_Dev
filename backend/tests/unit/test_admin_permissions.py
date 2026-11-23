import pytest
from uuid import uuid4
from unittest.mock import AsyncMock, MagicMock
from app.infrastructure.repositories.sql_alchemy_auth_repository import SQLAlchemyRoleRepository
from app.domain.services.admin_permissions import (
    ADMIN_PERMISSIONS,
    admin_permission_codes,
    permission_codes_to_rows,
    all_admin_permission_codes,
)


def _user(is_platform_admin: bool):
    u = MagicMock()
    u.id = uuid4()
    u.is_platform_admin = is_platform_admin
    return u


def _perm_rows(*rows):
    perms = []
    for resource, actions in rows:
        p = MagicMock()
        p.resource = resource
        p.can_create = "create" in actions
        p.can_read = "read" in actions
        p.can_update = "update" in actions
        p.can_delete = "delete" in actions
        perms.append(p)
    return perms


class TestAdminPermissionsCatalog:
    """Catalog sanity checks for platform-admin permissions."""

    def test_catalog_covers_core_resources(self):
        for resource in ("plans", "organizations", "admin_users", "currencies", "banners", "admin_permissions"):
            assert resource in ADMIN_PERMISSIONS

    def test_codes_roundtrip(self):
        codes = ["plans:read", "plans:update", "dashboard:read"]
        rows = permission_codes_to_rows(codes)
        assert len(rows) == 2
        out = admin_permission_codes(_perm_rows(*[(r["resource"], [a for a in ("create", "read", "update", "delete") if r[f"can_{a}"]]) for r in rows]))
        assert set(out) == set(codes)

    def test_all_codes_non_empty(self):
        assert all_admin_permission_codes()
        assert all(":" in c for c in all_admin_permission_codes())


class TestUserHasAdminPermission:
    @pytest.mark.asyncio
    async def test_non_admin_denied(self):
        mock_db = AsyncMock()
        mock_db.execute = AsyncMock()

        async def _execute(stmt):
            result = MagicMock()
            result.scalar_one_or_none.return_value = _user(False)
            return result

        mock_db.execute = _execute
        repo = SQLAlchemyRoleRepository(mock_db)
        assert await repo.user_has_admin_permission(uuid4(), "plans", "read") is False

    @pytest.mark.asyncio
    async def test_legacy_admin_without_rows_has_full_access(self):
        user = _user(True)
        calls = {"n": 0}

        async def _execute(stmt):
            result = MagicMock()
            if calls["n"] == 0:
                result.scalar_one_or_none.return_value = user
            else:
                result.scalars.return_value = MagicMock(all=MagicMock(return_value=[]))
            calls["n"] += 1
            return result

        mock_db = AsyncMock()
        mock_db.execute = _execute
        repo = SQLAlchemyRoleRepository(mock_db)
        assert await repo.user_has_admin_permission(user.id, "currencies", "delete") is True

    @pytest.mark.asyncio
    async def test_granted_resource_action_passes(self):
        user = _user(True)
        rows = _perm_rows(("plans", ("read", "update")), ("currencies", ("read",)))

        async def _execute(stmt):
            result = MagicMock()
            if isinstance(stmt, type):
                pass
            result.scalar_one_or_none.return_value = user
            result.scalars.return_value = MagicMock(all=MagicMock(return_value=rows))
            return result

        mock_db = AsyncMock()
        mock_db.execute = _execute
        repo = SQLAlchemyRoleRepository(mock_db)
        assert await repo.user_has_admin_permission(user.id, "plans", "read") is True
        assert await repo.user_has_admin_permission(user.id, "plans", "delete") is False
        assert await repo.user_has_admin_permission(user.id, "banners", "read") is False

    @pytest.mark.asyncio
    async def test_wildcard_row_grants_all(self):
        user = _user(True)
        rows = _perm_rows(("*", ("create", "read", "update", "delete")))

        async def _execute(stmt):
            result = MagicMock()
            result.scalar_one_or_none.return_value = user
            result.scalars.return_value = MagicMock(all=MagicMock(return_value=rows))
            return result

        mock_db = AsyncMock()
        mock_db.execute = _execute
        repo = SQLAlchemyRoleRepository(mock_db)
        assert await repo.user_has_admin_permission(user.id, "settings", "update") is True
        assert await repo.user_has_admin_permission(user.id, "health", "read") is True
