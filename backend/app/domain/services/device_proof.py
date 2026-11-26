"""Device key proofs (ECDSA P-256) and single-use server nonces.

Public key: base64 SubjectPublicKeyInfo DER. Signature: base64 DER ECDSA
(SHA-256) over UTF-8 ``"fyona-device-proof|{nonce}|{device_id}|{purpose}"``.
"""

from __future__ import annotations

import base64
import hashlib
import re
import secrets
from datetime import datetime, timedelta, timezone
from typing import Optional

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.auth2_entities import AuthDeviceNonce

NONCE_TTL_SECONDS = 60
DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{7,63}$")
PURPOSES = frozenset({
    "register_verify", "login", "login_verify", "social", "social_phone_verify",
    "refresh", "approval_code", "make_primary", "phone_change", "claim_primary",
    "account_delete", "social_link",
})


class InvalidPublicKey(ValueError):
    pass


def _b64decode(value: str) -> bytes:
    value = (value or "").strip()
    pad = "=" * (-len(value) % 4)
    try:
        if "-" in value or "_" in value:
            return base64.urlsafe_b64decode(value + pad)
        return base64.b64decode(value + pad, validate=True)
    except Exception as exc:  # noqa: BLE001
        raise ValueError("invalid base64") from exc


def load_public_key(b64_spki: str) -> ec.EllipticCurvePublicKey:
    """Parse + validate a P-256 public key (raises InvalidPublicKey)."""
    try:
        der = _b64decode(b64_spki)
        if not der or len(der) > 200:
            raise ValueError("size")
        key = serialization.load_der_public_key(der)
    except Exception as exc:  # noqa: BLE001
        raise InvalidPublicKey("invalid public key") from exc
    if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(key.curve, ec.SECP256R1):
        raise InvalidPublicKey("public key must be ECDSA P-256")
    return key


def normalize_public_key(b64_spki: str) -> tuple[str, str]:
    """(canonical base64 SPKI DER, sha256 hex fingerprint)."""
    key = load_public_key(b64_spki)
    der = key.public_bytes(serialization.Encoding.DER,
                           serialization.PublicFormat.SubjectPublicKeyInfo)
    return base64.b64encode(der).decode("ascii"), hashlib.sha256(der).hexdigest()


def proof_message(nonce: str, device_id: str, purpose: str) -> bytes:
    return f"fyona-device-proof|{nonce}|{device_id}|{purpose}".encode("utf-8")


def verify_signature(public_key_b64: str, nonce: str, device_id: str, purpose: str,
                     signature_b64: Optional[str]) -> bool:
    if not signature_b64 or not nonce:
        return False
    try:
        key = load_public_key(public_key_b64)
        sig = _b64decode(signature_b64)
        key.verify(sig, proof_message(nonce, device_id, purpose), ec.ECDSA(hashes.SHA256()))
        return True
    except (InvalidSignature, InvalidPublicKey, ValueError):
        return False
    except Exception:  # noqa: BLE001
        return False


def valid_device_id(device_id: Optional[str]) -> bool:
    return bool(device_id) and bool(DEVICE_ID_RE.match(device_id))


async def issue_nonce(db: AsyncSession, device_id: str,
                      now: Optional[datetime] = None) -> tuple[str, int]:
    now = now or datetime.now(timezone.utc)
    # Housekeeping: expired nonces are useless.
    await db.execute(delete(AuthDeviceNonce).where(AuthDeviceNonce.expires_at < now))
    nonce = secrets.token_urlsafe(32)
    db.add(AuthDeviceNonce(nonce=nonce, device_id=device_id,
                           expires_at=now + timedelta(seconds=NONCE_TTL_SECONDS)))
    await db.flush()
    return nonce, NONCE_TTL_SECONDS


async def consume_nonce(db: AsyncSession, nonce: Optional[str], device_id: str,
                        now: Optional[datetime] = None) -> bool:
    """Atomically consume a nonce bound to this device (single use)."""
    if not nonce or len(nonce) > 64:
        return False
    now = now or datetime.now(timezone.utc)
    result = await db.execute(
        delete(AuthDeviceNonce).where(
            AuthDeviceNonce.nonce == nonce,
            AuthDeviceNonce.device_id == device_id,
            AuthDeviceNonce.expires_at >= now,
        )
    )
    return (result.rowcount or 0) == 1


async def check_proof(db: AsyncSession, *, public_key_b64: str, device_id: str,
                      purpose: str, nonce: Optional[str], signature: Optional[str],
                      now: Optional[datetime] = None) -> bool:
    """Nonce is consumed first (a replay never verifies twice)."""
    if purpose not in PURPOSES:
        return False
    if not await consume_nonce(db, nonce, device_id, now=now):
        return False
    return verify_signature(public_key_b64, nonce or "", device_id, purpose, signature)
