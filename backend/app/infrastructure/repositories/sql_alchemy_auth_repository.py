from typing import Optional, List
from uuid import UUID
from datetime import datetime, timezone
from sqlalchemy import select, delete
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.auth_entities import (
    Organization,
    User,
    UserSession,
    Role,
    RolePermission,
    AdminPermission,
    PendingRegistration,
)
from app.domain.repositories.auth_repository import (
    OrganizationRepository,
    UserRepository,
    SessionRepository,
    RoleRepository,
    PendingRegistrationRepository,
)


class SQLAlchemyPendingRegistrationRepository(PendingRegistrationRepository):
    def __init__(self, db: AsyncSession):
        self.db = db

    async def create(self, pending: PendingRegistration) -> PendingRegistration:
        self.db.add(pending)
        await self.db.flush()
        return pending

    async def get_by_email(self, email: str) -> Optional[PendingRegistration]:
        result = await self.db.execute(
            select(PendingRegistration).where(PendingRegistration.email == email)
        )
        return result.scalars().first()

    async def delete(self, pending_id: UUID) -> None:
        await self.db.execute(
            delete(PendingRegistration).where(PendingRegistration.id == pending_id)
        )

    async def delete_by_email(self, email: str) -> None:
        await self.db.execute(
            delete(PendingRegistration).where(PendingRegistration.email == email)
        )

    async def delete_expired(self) -> int:
        result = await self.db.execute(
            delete(PendingRegistration).where(
                PendingRegistration.expires_at < datetime.now(timezone.utc)
            )
        )
        return result.rowcount or 0


class SQLAlchemyOrganizationRepository(OrganizationRepository):
    def __init__(self, db: AsyncSession):
        self.db = db

    async def create(self, org: Organization) -> Organization:
        self.db.add(org)
        await self.db.flush()
        return org

    async def get_by_id(self, org_id: UUID) -> Optional[Organization]:
        result = await self.db.execute(
            select(Organization).where(Organization.id == org_id)
        )
        return result.scalar_one_or_none()

    async def get_by_slug(self, slug: str) -> Optional[Organization]:
        result = await self.db.execute(
            select(Organization).where(Organization.slug == slug)
        )
        return result.scalar_one_or_none()

    async def update(self, org: Organization) -> Organization:
        await self.db.flush()
        return org

    async def delete(self, org_id: UUID) -> None:
        await self.db.execute(delete(Organization).where(Organization.id == org_id))


class SQLAlchemyUserRepository(UserRepository):
    def __init__(self, db: AsyncSession):
        self.db = db

    async def create(self, user: User) -> User:
        self.db.add(user)
        await self.db.flush()
        return user

    async def get_by_id(self, user_id: UUID) -> Optional[User]:
        result = await self.db.execute(select(User).where(User.id == user_id))
        return result.scalar_one_or_none()

    async def get_by_email(self, email: str) -> Optional[User]:
        result = await self.db.execute(select(User).where(User.email == email))
        return result.scalars().first()

    async def get_by_email_ci(self, email: str) -> Optional[User]:
        """Case-insensitive lookup for legacy mixed-case rows."""
        from sqlalchemy import func as _func

        result = await self.db.execute(
            select(User).where(
                _func.lower(User.email) == (email or "").strip().lower()
            )
        )
        return result.scalars().first()

    async def get_by_firebase_uid(self, firebase_uid: str) -> Optional[User]:
        result = await self.db.execute(select(User).where(User.firebase_uid == firebase_uid))
        return result.scalars().first()

    async def get_by_phone(self, phone: str) -> Optional[User]:
        result = await self.db.execute(select(User).where(User.phone == phone))
        return result.scalars().first()

    async def list_by_org(
        self, org_id: UUID, skip: int = 0, limit: int = 20
    ) -> List[User]:
        result = await self.db.execute(
            select(User)
            .where(User.organization_id == org_id)
            .offset(skip)
            .limit(limit)
            .order_by(User.created_at.desc())
        )
        return list(result.scalars().all())

    async def update(self, user: User) -> User:
        await self.db.flush()
        return user


class SQLAlchemySessionRepository(SessionRepository):
    def __init__(self, db: AsyncSession):
        self.db = db

    async def create(self, session: UserSession) -> UserSession:
        self.db.add(session)
        await self.db.flush()
        return session

    async def update(self, session: UserSession) -> UserSession:
        await self.db.flush()
        return session

    async def get(self, session_id: UUID) -> Optional[UserSession]:
        result = await self.db.execute(
            select(UserSession).where(UserSession.id == session_id)
        )
        return result.scalar_one_or_none()

    async def get_active_by_fingerprint(
        self, user_id: UUID, fingerprint: str
    ) -> Optional[UserSession]:
        if not fingerprint:
            return None
        result = await self.db.execute(
            select(UserSession)
            .where(
                UserSession.user_id == user_id,
                UserSession.is_active,
                UserSession.fingerprint == fingerprint,
            )
            .order_by(UserSession.created_at.desc())
        )
        now = datetime.now(timezone.utc)
        for s in result.scalars().all():
            exp = s.expires_at
            if exp is not None:
                if exp.tzinfo is None:
                    exp = exp.replace(tzinfo=timezone.utc)
                if exp <= now:
                    continue
            return s
        return None

    async def get_by_refresh_token(self, token: str) -> Optional[UserSession]:
        result = await self.db.execute(
            select(UserSession).where(
                UserSession.refresh_token == token, UserSession.is_active
            )
        )
        return result.scalar_one_or_none()

    async def deactivate(self, session_id: UUID) -> None:
        await self.db.execute(
            UserSession.__table__.update()
            .where(UserSession.id == session_id)
            .values(is_active=False)
        )

    async def deactivate_all_for_user(self, user_id: UUID) -> None:
        await self.db.execute(
            UserSession.__table__.update()
            .where(UserSession.user_id == user_id, UserSession.is_active)
            .values(is_active=False)
        )

    async def deactivate_expired_for_user(self, user_id: UUID) -> None:
        await self.db.execute(
            UserSession.__table__.update()
            .where(
                UserSession.user_id == user_id,
                UserSession.is_active,
                UserSession.expires_at <= datetime.now(timezone.utc),
            )
            .values(is_active=False)
        )

    async def list_active_for_user(self, user_id: UUID) -> List[UserSession]:
        result = await self.db.execute(
            select(UserSession)
            .where(UserSession.user_id == user_id, UserSession.is_active)
            .order_by(UserSession.created_at.desc())
        )
        # Expired sessions are dead weight: the refresh endpoint rejects
        # them, so listing them as "active" only confuses session screens.
        now = datetime.now(timezone.utc)
        out: List[UserSession] = []
        for s in result.scalars().all():
            exp = s.expires_at
            if exp is not None:
                if exp.tzinfo is None:
                    exp = exp.replace(tzinfo=timezone.utc)
                if exp <= now:
                    continue
            out.append(s)
        return out

    async def update_custom_name(self, session_id: UUID, custom_name: str) -> None:
        await self.db.execute(
            UserSession.__table__.update()
            .where(UserSession.id == session_id)
            .values(custom_name=custom_name)
        )


class SQLAlchemyRoleRepository(RoleRepository):
    def __init__(self, db: AsyncSession):
        self.db = db

    async def create(self, role: Role) -> Role:
        self.db.add(role)
        await self.db.flush()
        return role

    async def get_by_id(self, role_id: UUID) -> Optional[Role]:
        result = await self.db.execute(select(Role).where(Role.id == role_id))
        return result.scalar_one_or_none()

    async def list_by_org(self, org_id: UUID) -> List[Role]:
        result = await self.db.execute(
            select(Role).where(Role.organization_id == org_id)
        )
        return list(result.scalars().all())

    async def assign_permission(self, permission: RolePermission) -> RolePermission:
        self.db.add(permission)
        await self.db.flush()
        return permission

    async def get_permissions_for_role(self, role_id: UUID) -> List[RolePermission]:
        result = await self.db.execute(
            select(RolePermission).where(RolePermission.role_id == role_id)
        )
        return list(result.scalars().all())

    async def user_has_permission(
        self, user_id: UUID, resource: str, action: str
    ) -> bool:
        # Get user's role
        user_result = await self.db.execute(select(User).where(User.id == user_id))
        user = user_result.scalar_one_or_none()
        if not user:
            return False
        # Platform admin has all permissions
        if user.is_platform_admin:
            return True
        # Invited branch member acting inside a company context: evaluate the
        # LIVE membership row (revocation takes effect immediately). The
        # member's own Personal organization and role are never changed.
        try:
            from app.core.business_context import get_active_business_org
            from app.domain.entities.branch_entities import BranchMember
            import json as _json

            active = get_active_business_org()
            if active is not None:
                owner_here = (
                    user.role or "").lower() == "owner" and \
                    str(user.organization_id) == str(active)
                if owner_here:
                    return True
                member = (await self.db.execute(
                    select(BranchMember).where(
                        BranchMember.organization_id == active,
                        BranchMember.user_id == user_id,
                        BranchMember.status == "active",
                    )
                )).scalar_one_or_none()
                if member is not None:
                    try:
                        perms = _json.loads(member.permissions or "{}")
                    except Exception:
                        perms = {}
                    entry = perms.get(resource) if isinstance(perms, dict) else None
                    if isinstance(entry, dict):
                        return bool(entry.get(action))
                    if isinstance(entry, bool):
                        return entry if action == "read" else False
                    wildcard = perms.get("*") if isinstance(perms, dict) else None
                    if isinstance(wildcard, dict):
                        return bool(wildcard.get(action))
                    return False
                if str(user.organization_id) != str(active):
                    return False
        except Exception:
            pass
        # Find role by name (User.role stores role key like "owner")
        role_result = await self.db.execute(
            select(Role).where(
                Role.organization_id == user.organization_id,
                Role.name == user.role,
                Role.is_system,
            )
        )
        role = role_result.scalar_one_or_none()
        if not role:
            return False
        # Owner role has full access to all resources
        if role.name == "owner":
            return True
        # Wildcard: check if role has "*" (all resources) permission
        wildcard_result = await self.db.execute(
            select(RolePermission).where(
                RolePermission.role_id == role.id,
                RolePermission.resource == "*",
            )
        )
        wildcard_perm = wildcard_result.scalar_one_or_none()
        if wildcard_perm:
            action_map = {
                "create": wildcard_perm.can_create,
                "read": wildcard_perm.can_read,
                "update": wildcard_perm.can_update,
                "delete": wildcard_perm.can_delete,
            }
            return action_map.get(action, False)
        # Exact resource match
        perm_result = await self.db.execute(
            select(RolePermission).where(
                RolePermission.role_id == role.id,
                RolePermission.resource == resource,
            )
        )
        permission = perm_result.scalar_one_or_none()
        if not permission:
            return False
        action_map = {
            "create": permission.can_create,
            "read": permission.can_read,
            "update": permission.can_update,
            "delete": permission.can_delete,
        }
        return action_map.get(action, False)

    async def user_has_admin_permission(
        self, user_id: UUID, resource: str, action: str
    ) -> bool:
        user_result = await self.db.execute(select(User).where(User.id == user_id))
        user = user_result.scalar_one_or_none()
        if not user or not user.is_platform_admin:
            return False
        perm_result = await self.db.execute(
            select(AdminPermission).where(AdminPermission.user_id == user_id)
        )
        rows = list(perm_result.scalars().all())
        # Legacy platform admin without explicit grants has full access.
        if not rows:
            return True
        action_key = f"can_{action}"
        for perm in rows:
            if perm.resource == "*" and getattr(perm, action_key, False):
                return True
        for perm in rows:
            if perm.resource == resource and getattr(perm, action_key, False):
                return True
        return False

    async def list_admin_permissions(self, user_id: UUID) -> List[AdminPermission]:
        result = await self.db.execute(
            select(AdminPermission).where(AdminPermission.user_id == user_id)
        )
        return list(result.scalars().all())

    async def replace_admin_permissions(
        self, user_id: UUID, row_dicts: List[dict]
    ) -> None:
        await self.db.execute(
            delete(AdminPermission).where(AdminPermission.user_id == user_id)
        )
        for row in row_dicts:
            self.db.add(AdminPermission(user_id=user_id, **row))
        await self.db.flush()
