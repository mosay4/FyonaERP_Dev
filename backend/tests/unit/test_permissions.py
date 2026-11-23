import pytest
from uuid import uuid4
from unittest.mock import AsyncMock, MagicMock
from app.infrastructure.repositories.sql_alchemy_auth_repository import SQLAlchemyRoleRepository


class TestPermissionWildcard:
    """Tests that '*' wildcard resource grants access to all resources."""

    @pytest.mark.asyncio
    async def test_owner_wildcard_grants_accounting_create(self):
        """ROLE_PERMISSIONS['owner'] with '*' should allow 'accounting' + 'create'."""
        from app.domain.services.auth_service import ROLE_PERMISSIONS
        owner_perms = ROLE_PERMISSIONS.get("owner", {})
        assert "*" in owner_perms, "Owner must have '*' wildcard in ROLE_PERMISSIONS"
        assert "create" in owner_perms["*"], "Owner '*' must include 'create'"

    @pytest.mark.asyncio
    async def test_owner_has_accounting_permission(self):
        """Owner with '*' should pass user_has_permission for resource 'accounting'."""
        mock_db = AsyncMock()

        user_id = uuid4()
        org_id = uuid4()
        role_id = uuid4()

        # Use MagicMock, not AsyncMock, for data objects
        user = MagicMock()
        user.id = user_id
        user.organization_id = org_id
        user.role = "owner"
        user.is_platform_admin = False

        role = MagicMock()
        role.id = role_id
        role.organization_id = org_id
        role.name = "owner"

        perm = MagicMock()
        perm.can_create = True
        perm.can_read = True
        perm.can_update = True
        perm.can_delete = True

        call_count = [0]

        async def mock_execute(stmt):
            call_count[0] += 1
            result = MagicMock()
            if call_count[0] == 1:
                result.scalar_one_or_none.return_value = user
            elif call_count[0] == 2:
                result.scalar_one_or_none.return_value = role
            elif call_count[0] == 3:
                result.scalar_one_or_none.return_value = perm
            else:
                result.scalar_one_or_none.return_value = None
            return result

        mock_db.execute = mock_execute
        repo = SQLAlchemyRoleRepository(mock_db)

        result = await repo.user_has_permission(user_id, "accounting", "create")
        assert result is True, "Owner with '*' should have permission for all resources"
        assert call_count[0] == 2, "Owner shortcut should only make 2 queries (user, role)"
