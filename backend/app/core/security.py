import hashlib
from datetime import datetime, timedelta, timezone
from typing import Optional
from jose import jwt, JWTError, ExpiredSignatureError
from uuid import uuid4
import bcrypt
from .config import settings


try:  # argon2id is the default; bcrypt hashes keep verifying (rehash on login)
    from argon2 import PasswordHasher as _PasswordHasher
    from argon2 import exceptions as _argon2_exc

    _ARGON2 = _PasswordHasher(time_cost=3, memory_cost=65536, parallelism=2)
except Exception:  # pragma: no cover - argon2-cffi missing: bcrypt only
    _ARGON2 = None
    _argon2_exc = None

# Verified against when the account does not exist, so a missing phone and a
# wrong password cost the same time.
_DUMMY_HASH: Optional[str] = None


def hash_password(password: str) -> str:
    """Hash a plain-text password (argon2id; bcrypt when argon2 is absent)."""
    if _ARGON2 is not None:
        return _ARGON2.hash(password)
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, password_hash: Optional[str]) -> bool:
    """Constant-time password check (argon2id or legacy bcrypt).

    Returns False when no hash exists."""
    if not password_hash:
        return False
    if password_hash.startswith("$argon2"):
        if _ARGON2 is None:
            return False
        try:
            return _ARGON2.verify(password_hash, password)
        except Exception:
            return False
    try:
        return bcrypt.checkpw(
            password.encode("utf-8"), password_hash.encode("utf-8")
        )
    except ValueError:
        return False


def password_needs_rehash(password_hash: Optional[str]) -> bool:
    """True for legacy bcrypt hashes or outdated argon2 parameters."""
    if not password_hash or _ARGON2 is None:
        return False
    if not password_hash.startswith("$argon2id"):
        return True
    try:
        return _ARGON2.check_needs_rehash(password_hash)
    except Exception:
        return False


def burn_password_check(password: str) -> None:
    """Spend the same time as a real verification (unknown account)."""
    global _DUMMY_HASH
    if _DUMMY_HASH is None:
        _DUMMY_HASH = hash_password("fyona-dummy-password-never-used")
    verify_password(password, _DUMMY_HASH)


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

