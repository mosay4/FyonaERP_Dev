"""Google / Apple identity tokens + Apple client secret, code exchange, revoke.

* ID tokens are RS256 JWTs verified against the provider JWKS (cached per
  Cache-Control max-age, refreshed once on an unknown ``kid``).
* Google: aud = GOOGLE_WEB_CLIENT_ID, iss accounts.google.com.
* Apple: aud = APPLE_BUNDLE_ID, iss https://appleid.apple.com, nonce =
  SHA-256(raw nonce) (or raw) when the client supplied one.
* Apple client secret: ES256 JWT (kid=APPLE_KEY_ID, iss=APPLE_TEAM_ID,
  sub=bundle id, aud=https://appleid.apple.com), valid 150 days (< 6
  months), generated from the .p8 and renewed in memory 7 days early.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import time
from dataclasses import dataclass
from typing import Optional

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

from app.core import outbound_http
from app.core.config import settings
from app.core.logging import get_logger

logger = get_logger("social_auth")

GOOGLE_JWKS = "https://www.googleapis.com/oauth2/v3/certs"
GOOGLE_ISSUERS = ("accounts.google.com", "https://accounts.google.com")
APPLE_JWKS = "https://appleid.apple.com/auth/keys"
APPLE_ISSUER = "https://appleid.apple.com"
APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token"
APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke"
LEEWAY = 120


class SocialTokenError(ValueError):
    def __init__(self, code: str = "invalid_social_token"):
        self.code = code
        super().__init__(code)


@dataclass
class SocialIdentity:
    provider: str
    subject: str
    email: Optional[str]
    email_verified: bool
    is_private_email: bool
    name: Optional[str]


def _b64url(data: str) -> bytes:
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def _b64url_enc(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


# ── JWKS cache ──
_jwks: dict[str, tuple[float, dict]] = {}


async def _fetch_jwks(url: str) -> dict:
    resp = await outbound_http.request("GET", url, idempotent=True, label="jwks")
    if resp.status_code != 200:
        raise SocialTokenError("jwks_unavailable")
    keys = {k.get("kid"): k for k in (resp.json() or {}).get("keys") or [] if k.get("kid")}
    max_age = 3600
    m = re.search(r"max-age=(\d+)", resp.headers.get("cache-control", ""))
    if m:
        max_age = min(max(int(m.group(1)), 60), 86400)
    _jwks[url] = (time.time() + max_age, keys)
    return keys


async def _key_for(url: str, kid: str) -> dict:
    cached = _jwks.get(url)
    keys = cached[1] if cached and cached[0] > time.time() else await _fetch_jwks(url)
    if kid not in keys:
        keys = await _fetch_jwks(url)  # key rotation
    if kid not in keys:
        raise SocialTokenError()
    return keys[kid]


def _rsa_from_jwk(jwk: dict) -> rsa.RSAPublicKey:
    n = int.from_bytes(_b64url(jwk["n"]), "big")
    e = int.from_bytes(_b64url(jwk["e"]), "big")
    return rsa.RSAPublicNumbers(e, n).public_key()


async def _verify_rs256(token: str, jwks_url: str) -> dict:
    try:
        h64, p64, s64 = token.split(".")
        header = json.loads(_b64url(h64))
        claims = json.loads(_b64url(p64))
        sig = _b64url(s64)
    except Exception as exc:  # noqa: BLE001
        raise SocialTokenError() from exc
    if header.get("alg") != "RS256" or not header.get("kid"):
        raise SocialTokenError()
    jwk = await _key_for(jwks_url, header["kid"])
    try:
        _rsa_from_jwk(jwk).verify(sig, f"{h64}.{p64}".encode("ascii"),
                                  padding.PKCS1v15(), hashes.SHA256())
    except (InvalidSignature, KeyError, ValueError) as exc:
        raise SocialTokenError() from exc
    now = time.time()
    if float(claims.get("exp", 0)) < now - LEEWAY:
        raise SocialTokenError("social_token_expired")
    if float(claims.get("iat", now)) > now + LEEWAY:
        raise SocialTokenError()
    return claims


def _aud_ok(claims: dict, expected: str) -> bool:
    aud = claims.get("aud")
    return aud == expected or (isinstance(aud, list) and expected in aud)


def _bool(v) -> bool:
    return v is True or str(v).lower() == "true"


def _nonce_ok(claims: dict, nonce: Optional[str]) -> bool:
    if not nonce:
        return True
    got = str(claims.get("nonce") or "")
    hashed = hashlib.sha256(nonce.encode("utf-8")).hexdigest()
    return bool(got) and (hmac.compare_digest(got, hashed) or hmac.compare_digest(got, nonce))


async def verify_google(id_token: str, nonce: Optional[str] = None) -> SocialIdentity:
    claims = await _verify_rs256(id_token, GOOGLE_JWKS)
    if claims.get("iss") not in GOOGLE_ISSUERS or not _aud_ok(claims, settings.GOOGLE_WEB_CLIENT_ID):
        raise SocialTokenError()
    # Google tokens carry a nonce only when the client requested one; the
    # server nonce is then still consumed by the device proof.
    if claims.get("nonce") and not _nonce_ok(claims, nonce):
        raise SocialTokenError("social_nonce_mismatch")
    if not claims.get("sub"):
        raise SocialTokenError()
    return SocialIdentity(
        provider="google", subject=str(claims["sub"]),
        email=(claims.get("email") or None), email_verified=_bool(claims.get("email_verified")),
        is_private_email=False, name=claims.get("name"),
    )


async def verify_apple(id_token: str, nonce: Optional[str]) -> SocialIdentity:
    claims = await _verify_rs256(id_token, APPLE_JWKS)
    if claims.get("iss") != APPLE_ISSUER or not _aud_ok(claims, settings.APPLE_BUNDLE_ID):
        raise SocialTokenError()
    if not nonce or not _nonce_ok(claims, nonce):
        raise SocialTokenError("social_nonce_mismatch")
    if not claims.get("sub"):
        raise SocialTokenError()
    return SocialIdentity(
        provider="apple", subject=str(claims["sub"]), email=(claims.get("email") or None),
        email_verified=_bool(claims.get("email_verified")),
        is_private_email=_bool(claims.get("is_private_email")), name=None,
    )


# ── Apple client secret ──
_client_secret: tuple[float, str] | None = None
CLIENT_SECRET_TTL = 150 * 86400
CLIENT_SECRET_RENEW_BEFORE = 7 * 86400


def apple_configured() -> bool:
    return bool(settings.APPLE_TEAM_ID and settings.APPLE_KEY_ID
                and settings.APPLE_PRIVATE_KEY_PATH)


def _load_apple_key() -> ec.EllipticCurvePrivateKey:
    with open(settings.APPLE_PRIVATE_KEY_PATH, "rb") as fh:
        key = serialization.load_pem_private_key(fh.read(), password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey):
        raise ValueError("Apple key must be an EC private key")
    return key


def es256_jwt(claims: dict, kid: str, key: ec.EllipticCurvePrivateKey) -> str:
    header = {"alg": "ES256", "kid": kid, "typ": "JWT"}
    signing_input = (_b64url_enc(json.dumps(header, separators=(",", ":")).encode())
                     + "." + _b64url_enc(json.dumps(claims, separators=(",", ":")).encode()))
    der = key.sign(signing_input.encode("ascii"), ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    return signing_input + "." + _b64url_enc(r.to_bytes(32, "big") + s.to_bytes(32, "big"))


def apple_client_secret(now: Optional[float] = None) -> str:
    global _client_secret
    now = now or time.time()
    if _client_secret and _client_secret[0] - CLIENT_SECRET_RENEW_BEFORE > now:
        return _client_secret[1]
    iat = int(now)
    exp = iat + CLIENT_SECRET_TTL
    token = es256_jwt({"iss": settings.APPLE_TEAM_ID, "iat": iat, "exp": exp,
                       "aud": APPLE_ISSUER, "sub": settings.APPLE_BUNDLE_ID},
                      settings.APPLE_KEY_ID, _load_apple_key())
    _client_secret = (float(exp), token)
    return token


async def apple_exchange_code(code: str) -> Optional[str]:
    """Authorization code → refresh token (needed to revoke on deletion)."""
    if not apple_configured() or not code:
        return None
    try:
        resp = await outbound_http.request(
            "POST", APPLE_TOKEN_URL, idempotent=False, label="apple_token",
            data={"client_id": settings.APPLE_BUNDLE_ID, "client_secret": apple_client_secret(),
                  "code": code, "grant_type": "authorization_code"})
    except outbound_http.OutboundError:
        return None
    if resp.status_code != 200:
        logger.warning("apple_code_exchange_failed", http=resp.status_code)
        return None
    try:
        return (resp.json() or {}).get("refresh_token")
    except ValueError:
        return None


async def apple_revoke(refresh_token: str) -> bool:
    if not apple_configured() or not refresh_token:
        return False
    try:
        resp = await outbound_http.request(
            "POST", APPLE_REVOKE_URL, idempotent=True, label="apple_revoke",
            data={"client_id": settings.APPLE_BUNDLE_ID, "client_secret": apple_client_secret(),
                  "token": refresh_token, "token_type_hint": "refresh_token"})
    except outbound_http.OutboundError:
        return False
    ok = resp.status_code == 200
    if not ok:
        logger.warning("apple_revoke_failed", http=resp.status_code)
    return ok
