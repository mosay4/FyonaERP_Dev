from app.core.security import (
    create_access_token,
    create_refresh_token,
    decode_token,
    hash_refresh_token,
)


def test_refresh_token_hash_is_sha256_hex():
    token = create_refresh_token(user_id="user-1")
    hashed = hash_refresh_token(token)
    assert hashed != token
    assert len(hashed) == 64
    # Same token hashes deterministically; different tokens differ
    assert hash_refresh_token(token) == hashed
    assert hash_refresh_token("other-token") != hashed


def test_access_token_creation():
    token = create_access_token(user_id="user-1", org_id="org-1", role="owner")
    assert token is not None
    payload = decode_token(token)
    assert payload is not None
    assert payload["sub"] == "user-1"
    assert payload["org"] == "org-1"
    assert payload["role"] == "owner"
    assert payload["type"] == "access"


def test_refresh_token_creation():
    token = create_refresh_token(user_id="user-1")
    assert token is not None
    payload = decode_token(token)
    assert payload is not None
    assert payload["sub"] == "user-1"
    assert payload["type"] == "refresh"


def test_invalid_token():
    payload = decode_token("invalid-token")
    assert payload is None


def test_expired_token():
    # Token with immediate expiry
    from jose import jwt
    from app.core.config import settings

    expired = jwt.encode(
        {"sub": "user-1", "exp": 0, "type": "access"},
        settings.JWT_SECRET_KEY,
        algorithm=settings.JWT_ALGORITHM,
    )
    payload = decode_token(expired)
    assert payload is None
