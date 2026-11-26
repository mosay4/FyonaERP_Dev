"""Keyed hashing and at-rest encryption for OTP data (keys derived once
from JWT_SECRET_KEY with domain separation; nothing extra to provision)."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
from functools import lru_cache
from typing import Any, Optional

from cryptography.fernet import Fernet, InvalidToken

from app.core.config import settings


@lru_cache(maxsize=4)
def _key(label: str, secret: str) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", secret.encode("utf-8"),
                               f"fyona.auth2.{label}".encode("utf-8"), 100_000)


def _k(label: str) -> bytes:
    return _key(label, settings.JWT_SECRET_KEY)


@lru_cache(maxsize=2)
def _fernet(secret: str) -> Fernet:
    return Fernet(base64.urlsafe_b64encode(_key("fernet", secret)))


def new_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def code_hmac(challenge_id: str, code: str) -> str:
    return hmac.new(_k("otp"), f"{challenge_id}:{code}".encode("utf-8"),
                    hashlib.sha256).hexdigest()


def code_matches(challenge_id: str, code: str, expected: str) -> bool:
    candidate = code_hmac(challenge_id, (code or "").strip())
    return hmac.compare_digest(candidate, expected or "")


def phone_hash(e164: Optional[str]) -> Optional[str]:
    if not e164:
        return None
    return hmac.new(_k("phone"), e164.encode("utf-8"), hashlib.sha256).hexdigest()


def encrypt(value: str) -> str:
    return _fernet(settings.JWT_SECRET_KEY).encrypt(value.encode("utf-8")).decode("ascii")


def decrypt(token: Optional[str]) -> Optional[str]:
    if not token:
        return None
    try:
        return _fernet(settings.JWT_SECRET_KEY).decrypt(token.encode("ascii")).decode("utf-8")
    except (InvalidToken, ValueError):
        return None


def encrypt_json(value: Any) -> str:
    return encrypt(json.dumps(value, separators=(",", ":"), default=str))


def decrypt_json(token: Optional[str]) -> Optional[Any]:
    raw = decrypt(token)
    if raw is None:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return None


def sign_token(label: str, value: str) -> str:
    """Short URL-safe HMAC (e.g. SMS.to per-message callback token)."""
    mac = hmac.new(_k(label), value.encode("utf-8"), hashlib.sha256).digest()[:18]
    return base64.urlsafe_b64encode(mac).decode("ascii").rstrip("=")


def check_token(label: str, value: str, token: str) -> bool:
    return hmac.compare_digest(sign_token(label, value), token or "")


def mask_e164(e164: Optional[str]) -> str:
    """Log-safe phone: keep the first 4 and last 2 digits only."""
    if not e164:
        return "-"
    digits = "".join(c for c in e164 if c.isdigit())
    if len(digits) <= 6:
        return "+" + "*" * len(digits)
    return "+" + digits[:4] + "*" * (len(digits) - 6) + digits[-2:]
