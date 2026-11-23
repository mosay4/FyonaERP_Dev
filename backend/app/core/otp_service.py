"""
One-time password generation, storage and verification (Redis-backed).

Codes are never stored in plain text: a salted SHA-256 digest is persisted.
Keys are scoped by purpose (signup / reset / login) so a code issued for one
flow can never be redeemed in another.
"""

import hashlib
import hmac
import secrets

from app.core.redis import cache_set, cache_get, cache_delete
from app.core.config import settings

OTP_TTL_SECONDS = settings.OTP_TTL_SECONDS or 600
OTP_MAX_ATTEMPTS = settings.OTP_MAX_ATTEMPTS or 5
OTP_COOLDOWN_SECONDS = settings.OTP_COOLDOWN_SECONDS or 60


def _key(purpose: str, email: str) -> str:
    return f"otp:{purpose}:{email.strip().lower()}"


def _cooldown_key(purpose: str, email: str) -> str:
    return f"otp:cooldown:{purpose}:{email.strip().lower()}"


async def create_otp(purpose: str, email: str) -> str:
    otp = f"{secrets.randbelow(1_000_000):06d}"
    salt = secrets.token_hex(8)
    digest = hashlib.sha256(f"{salt}:{otp}".encode()).hexdigest()
    await cache_set(_key(purpose, email), f"{salt}:{digest}:0", OTP_TTL_SECONDS)
    await cache_delete(_cooldown_key(purpose, email))
    return otp


async def verify_otp(purpose: str, email: str, otp: str) -> bool:
    key = _key(purpose, email)
    raw = await cache_get(key)
    if not raw:
        return False
    try:
        salt, digest, attempts = raw.split(":", 2)
        attempts = int(attempts)
    except ValueError:
        await cache_delete(key)
        return False

    if attempts >= OTP_MAX_ATTEMPTS:
        await cache_delete(key)
        return False

    candidate = hashlib.sha256(f"{salt}:{otp.strip()}".encode()).hexdigest()
    if hmac.compare_digest(candidate, digest):
        await cache_delete(key)
        return True

    await cache_set(key, f"{salt}:{digest}:{attempts + 1}", OTP_TTL_SECONDS)
    return False


async def otp_sent_recently(purpose: str, email: str) -> bool:
    return bool(await cache_get(_cooldown_key(purpose, email)))


async def mark_otp_sent(purpose: str, email: str) -> None:
    await cache_set(_cooldown_key(purpose, email), "1", OTP_COOLDOWN_SECONDS)
