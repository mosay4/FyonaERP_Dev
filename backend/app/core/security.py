import hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional
from jose import jwt, JWTError, ExpiredSignatureError
from uuid import uuid4
import bcrypt
from .config import settings


def hash_password(password: str) -> str:
    """Hash a plain-text password using bcrypt."""
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, password_hash: Optional[str]) -> bool:
    """Constant-time password check. Returns False when no hash exists."""
    if not password_hash:
        return False
    try:
        return bcrypt.checkpw(
            password.encode("utf-8"), password_hash.encode("utf-8")
        )
    except ValueError:
        return False


def hash_refresh_token(token: str) -> str:
    """Return a SHA-256 hash of a refresh token so raw tokens are never stored."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def create_access_token(user_id: str, org_id: str, role: str, session_id: Optional[str] = None) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "org": org_id,
        "role": role,
        "type": "access",
        "iat": now,
        "exp": now + timedelta(minutes=settings.JWT_ACCESS_TOKEN_EXPIRE_MINUTES),
        "jti": str(uuid4()),
    }
    if session_id:
        payload["sid"] = session_id
    return jwt.encode(
        payload, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM
    )


def create_refresh_token(user_id: str) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "type": "refresh",
        "iat": now,
        "exp": now + timedelta(days=settings.JWT_REFRESH_TOKEN_EXPIRE_DAYS),
        "jti": str(uuid4()),
    }
    return jwt.encode(
        payload, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM
    )


def create_reset_token(
    email: str, ttl_minutes: int = 10, purpose: str = "reset"
) -> str:
    """Short-lived, single-purpose token issued after OTP verification.

    `purpose` becomes the token type: `reset` may be redeemed by
    /auth/reset-password, while a device-PIN verification (`pin_reset`) is
    only proof of email ownership and can never change the password.
    """
    now = datetime.now(timezone.utc)
    payload = {
        "sub": email.lower(),
        "type": purpose,
        "iat": now,
        "exp": now + timedelta(minutes=ttl_minutes),
        "jti": str(uuid4()),
    }
    return jwt.encode(
        payload, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM
    )


def decode_reset_token(token: str) -> Optional[dict]:
    try:
        payload = jwt.decode(
            token, settings.JWT_SECRET_KEY, algorithms=[settings.JWT_ALGORITHM]
        )
        if payload.get("type") != "reset":
            return None
        return payload
    except ExpiredSignatureError:
        return None
    except JWTError:
        return None


def decode_token(token: str) -> Optional[dict]:
    try:
        payload = jwt.decode(
            token, settings.JWT_SECRET_KEY, algorithms=[settings.JWT_ALGORITHM]
        )
        return payload
    except ExpiredSignatureError:
        return None
    except JWTError:
        return None


# ── Encrypted runtime config (app_config) ──
# Secrets stored in the `app_config` table (e.g. Stripe live secret key) are
# encrypted at rest with Fernet. The key is derived from JWT_SECRET_KEY via
# PBKDF2 (see Settings.config_master_key), so no extra secret needs to be
# provisioned. These helpers must NEVER be used to log secret material.

def _config_fernet():
    from cryptography.fernet import Fernet
    return Fernet(settings.config_master_key)


def encrypt_secret(plain: str) -> str:
    """Return a Fernet-encrypted token for a plaintext secret."""
    return _config_fernet().encrypt(plain.encode("utf-8")).decode("utf-8")


def decrypt_secret(token: str) -> str:
    """Decrypt a value produced by encrypt_secret. Raises on tamper."""
    return _config_fernet().decrypt(token.encode("utf-8")).decode("utf-8")

