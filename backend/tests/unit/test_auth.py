import pytest
from jose import jwt
from pydantic import ValidationError
from unittest.mock import AsyncMock, patch
from app.core import otp_service
from app.core.security import (
    create_access_token,
    create_refresh_token,
    decode_reset_token,
    decode_token,
)
from app.core.config import settings
from app.domain.models.auth_models import ForgotPasswordRequest, VerifyOtpRequest
from app.domain.services.auth_service import AuthService


class TestTokenCreation:
    def test_access_token_contains_correct_claims(self):
        token = create_access_token("user-id-1", "org-id-1", "owner")
        payload = decode_token(token)
        assert payload["sub"] == "user-id-1"
        assert payload["org"] == "org-id-1"
        assert payload["role"] == "owner"
        assert payload["type"] == "access"
        assert "jti" in payload
        assert "iat" in payload
        assert "exp" in payload

    def test_refresh_token_contains_correct_claims(self):
        token = create_refresh_token("user-id-1")
        payload = decode_token(token)
        assert payload["sub"] == "user-id-1"
        assert payload["type"] == "refresh"
        assert "jti" in payload

    def test_token_expiry(self):
        token = create_access_token("u1", "o1", "owner")
        payload = decode_token(token)
        exp = payload["exp"]
        iat = payload["iat"]
        # Access token: 60 minutes (JWT_ACCESS_TOKEN_EXPIRE_MINUTES in config)
        assert (exp - iat) == settings.JWT_ACCESS_TOKEN_EXPIRE_MINUTES * 60

    def test_invalid_token_returns_none(self):
        assert decode_token("invalid.jwt.token") is None

    def test_expired_token_returns_none(self):
        expired = jwt.encode(
            {"sub": "u1", "exp": 0, "type": "access"},
            settings.JWT_SECRET_KEY,
            algorithm=settings.JWT_ALGORITHM,
        )
        assert decode_token(expired) is None

    def test_wrong_secret_returns_none(self):
        token = jwt.encode(
            {"sub": "u1", "exp": 9999999999, "type": "access"},
            "wrong-secret",
            algorithm=settings.JWT_ALGORITHM,
        )
        assert decode_token(token) is None


class _FakeUser:
    def __init__(self, email: str = "someone@example.com", provider: str = "google"):
        self.email = email
        self.auth_provider = provider


def _service_for(user: _FakeUser) -> AuthService:
    user_repo = AsyncMock()
    user_repo.get_by_email = AsyncMock(return_value=user)
    service = AuthService(AsyncMock(), user_repo, AsyncMock(), AsyncMock())
    # Never actually send mail from unit tests.
    service._send_otp = AsyncMock()
    return service


class TestDevicePinPurpose:
    """The device PIN reuses the email-code channel but is NOT a password
    reset: it only proves the address is yours, so external logins (Google,
    which has no password) can unlock their app like anyone else."""

    async def test_google_account_gets_a_pin_code(self):
        service = _service_for(_FakeUser(provider="google"))
        data = await service.forgot_password("someone@example.com", purpose="pin")
        assert "expires_in_seconds" in data
        service._send_otp.assert_awaited_once()
        assert service._send_otp.await_args.args[0] == "pin"

    async def test_google_account_still_cannot_reset_a_password(self):
        service = _service_for(_FakeUser(provider="google"))
        with pytest.raises(ValueError):
            await service.forgot_password("someone@example.com")

    async def test_email_account_can_request_either(self):
        service = _service_for(_FakeUser(provider="email"))
        await service.forgot_password("someone@example.com")
        await service.forgot_password("someone@example.com", purpose="pin")
        assert service._send_otp.await_count == 2

    async def test_pin_token_cannot_reset_the_password(self):
        service = _service_for(_FakeUser(provider="google"))
        with patch.object(
            otp_service, "verify_otp", new=AsyncMock(return_value=True)
        ):
            token = await service.verify_otp(
                "someone@example.com", "123456", "pin"
            )
        assert decode_token(token)["type"] == "pin_reset"
        # /auth/reset-password only accepts type == "reset".
        assert decode_reset_token(token) is None

    async def test_reset_token_still_resets_the_password(self):
        service = _service_for(_FakeUser(provider="email"))
        with patch.object(
            otp_service, "verify_otp", new=AsyncMock(return_value=True)
        ):
            token = await service.verify_otp(
                "someone@example.com", "123456", "reset"
            )
        assert decode_reset_token(token) is not None


class TestPurposeValidation:
    def test_forgot_password_accepts_pin(self):
        request = ForgotPasswordRequest(email="a@b.com", purpose="pin")
        assert request.purpose == "pin"

    def test_forgot_password_rejects_unknown_purpose(self):
        with pytest.raises(ValidationError):
            ForgotPasswordRequest(email="a@b.com", purpose="anything")

    def test_verify_otp_accepts_pin(self):
        request = VerifyOtpRequest(email="a@b.com", otp="123456", purpose="pin")
        assert request.purpose == "pin"

    def test_verify_otp_rejects_unknown_purpose(self):
        with pytest.raises(ValidationError):
            VerifyOtpRequest(email="a@b.com", otp="123456", purpose="whatever")
