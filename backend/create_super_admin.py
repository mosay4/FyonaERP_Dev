# -*- coding: utf-8 -*-
"""Create / ensure the platform super-admin user used by the external Admin Web App.

Reads ADMIN_MASTER_EMAIL + ADMIN_SUPERADMIN_PASSWORD from the environment
(.env). The default credentials (FYONA / msf$mrold$fyona_erp) match the admin
portal login. Run:  python create_super_admin.py
"""
import asyncio
import hashlib
import os
import secrets
import sys
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app.core.database import async_session_factory  # noqa: E402
from app.core.security import hash_password  # noqa: E402
from app.domain.entities.auth_entities import Organization, User, UserSession  # noqa: E402


def _hash_pwd(pwd: str) -> str:
    # Must match app/core/security.verify_password (bcrypt). A local pbkdf2
    # hash here produced users that could never pass /auth/login.
    return hash_password(pwd)


async def main() -> None:
    email = (os.getenv("ADMIN_MASTER_EMAIL", "admin@fyona.erp").strip().lower())
    password = os.getenv("ADMIN_SUPERADMIN_PASSWORD", "msf$mrold$fyona_erp")
    full_name = os.getenv("ADMIN_SUPERADMIN_NAME", "FYONA Super Admin")

    async with async_session_factory() as db:
        existing = (
            await db.execute(select(User).where(User.email.ilike(email)))
        ).scalar_one_or_none()

        org = (
            await db.execute(select(Organization).where(Organization.slug == "fyona-admin"))
        ).scalar_one_or_none()
        if org is None:
            org = Organization(
                name="FYONA Platform",
                slug="fyona-admin",
                subscription_status="active",
            )
            db.add(org)
            await db.flush()

        if existing is None:
            user = User(
                full_name=full_name,
                email=email,
                password_hash=_hash_pwd(password),
                role="super_admin",
                is_platform_admin=True,
                organization_id=org.id,
                email_verified=True,
                preferred_usage_mode="business",
            )
            db.add(user)
            await db.flush()
            db.add(UserSession(
                user_id=user.id,
                refresh_token=secrets.token_urlsafe(64),
                device_name="Admin Web App",
                is_active=True,
                expires_at=datetime.now(timezone.utc) + timedelta(days=3650),
            ))
            print(f"[OK] Created super admin: {email}")
        else:
            existing.is_platform_admin = True
            existing.role = "super_admin"
            existing.email_verified = True
            if os.getenv("RESET_ADMIN_PASSWORD", "").lower() == "1":
                existing.password_hash = _hash_pwd(password)
                print(f"[OK] Reset password for {email}")
            print(f"[OK] Super admin exists: {email}")
        await db.commit()


if __name__ == "__main__":
    asyncio.run(main())