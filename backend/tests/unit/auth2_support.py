"""Shared fixtures for the auth v2 tests (isolated SQLite, real routes,
mocked providers — nothing ever leaves the process)."""

from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
from typing import Optional
from uuid import uuid4

import pytest
import pytest_asyncio
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

import app.domain.entities  # noqa: F401  (all tables)
import app.domain.entities.auth2_entities  # noqa: F401
import app.domain.entities.business_entities  # noqa: F401
import app.domain.entities.finance_entities  # noqa: F401
import app.domain.entities.invoice_entities  # noqa: F401
import app.domain.entities.notification_entities  # noqa: F401
import app.domain.entities.payment_entities  # noqa: F401
import app.domain.entities.personal_entities  # noqa: F401
import app.domain.entities.push_entities  # noqa: F401
import app.domain.entities.sales_entities  # noqa: F401
import app.domain.entities.subscription_invoice_entities  # noqa: F401
import app.domain.entities.sync_entities  # noqa: F401
from app.core.database import Base, get_db
from app.domain.services.otp import engine as otp_engine
from app.domain.services.otp import providers
from app.domain.services.otp.providers import SendResult


class FakeProvider:
    def __init__(self, channel: str, name: str):
        self.channel = channel
        self.name = name
        self.sent: list[dict] = []
        self.results: list[SendResult] = []
        self.enabled = True
        self._n = 0

    def configured(self) -> bool:
        return self.enabled

    async def send_code(self, *, to_e164, code, locale, callback_url=None):
        self.sent.append({"to": to_e164, "code": code, "locale": locale,
                          "callback_url": callback_url})
        if self.results:
            return self.results.pop(0)
        self._n += 1
        return SendResult(ok=True, message_id=f"{self.name}-msg-{self._n}")

    @property
    def last_code(self) -> Optional[str]:
        return self.sent[-1]["code"] if self.sent else None


class Clock:
    def __init__(self):
        self.now = datetime.now(timezone.utc)

    def __call__(self):
        return self.now

    def advance(self, seconds: float):
        self.now = self.now + timedelta(seconds=seconds)


class DeviceKey:
    def __init__(self, device_id: Optional[str] = None, name: str = "Galaxy S24"):
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.id = device_id or f"dev-{uuid4().hex[:16]}"
        self.name = name

    @property
    def public_b64(self) -> str:
        der = self.key.public_key().public_bytes(
            serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
        return base64.b64encode(der).decode()

    def payload(self) -> dict:
        return {"id": self.id, "public_key": self.public_b64, "name": self.name,
                "model": "SM-S921B", "os": "Android", "os_version": "14",
                "app_version": "2.0.0"}

    def sign(self, nonce: str, purpose: str) -> str:
        msg = f"fyona-device-proof|{nonce}|{self.id}|{purpose}".encode()
        return base64.b64encode(self.key.sign(msg, ec.ECDSA(hashes.SHA256()))).decode()


@pytest_asyncio.fixture()
async def env(tmp_path, monkeypatch):
    from app.core import rate_limiter
    from app.core.config import settings
    from app.main import app

    async def _allow(self, *_a, **_k):
        return None

    monkeypatch.setattr(rate_limiter.RateLimiter, "check", _allow)
    monkeypatch.setattr(settings, "META_WEBHOOK_APP_SECRET", "test-webhook-secret")
    monkeypatch.setattr(settings, "WHATSAPP_VERIFY_TOKEN", "test-verify-token")
    monkeypatch.setattr(settings, "API_BASE_URL", "https://qa.example.test")
    monkeypatch.setattr(settings, "AUTH_OTP_CAP_IP", "100,200")
    monkeypatch.setattr(settings, "AUTH_OTP_CAP_PHONE", "50,100")
    monkeypatch.setattr(settings, "AUTH_OTP_CAP_DEVICE", "50,100")
    monkeypatch.setattr(settings, "AUTH_OTP_CAP_ACCOUNT", "50,100")

    db_engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path}/auth2.db")
    async with db_engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    factory = async_sessionmaker(db_engine, expire_on_commit=False)

    async def _get_db():
        async with factory() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise

    wa = FakeProvider("whatsapp", "whatsapp_cloud")
    sms = FakeProvider("sms", "smsto")
    providers.register(wa)
    providers.register(sms)
    clock = Clock()
    monkeypatch.setattr(otp_engine, "utcnow", clock)
    monkeypatch.setattr(otp_engine, "session_factory", factory)
    monkeypatch.setattr(otp_engine, "kick_enabled", False)
    monkeypatch.setattr(otp_engine, "_last_receipt_at", None)

    pushes: list = []

    async def _fake_push(tokens, *, data, timeout=8.0):
        pushes.append((list(tokens), dict(data)))
        return {"sent": len(tokens), "failed": 0, "invalid_tokens": []}

    from app.domain.services import push_service

    monkeypatch.setattr(push_service, "_send_data_push_bounded", _fake_push)

    async def _no_notify(*_a, **_k):
        return None

    monkeypatch.setattr(push_service, "notify_user", _no_notify)

    app.dependency_overrides[get_db] = _get_db
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://127.0.0.1/api/v1") as c:
        yield type("Env", (), {"client": c, "factory": factory, "wa": wa, "sms": sms,
                               "clock": clock, "pushes": pushes, "settings": settings})
    app.dependency_overrides.clear()
    providers.reset_defaults()
    await db_engine.dispose()


async def drain(env, rounds: int = 3):
    for _ in range(rounds):
        await otp_engine.run_due()


async def nonce(env, dev: DeviceKey) -> str:
    r = await env.client.post("/auth2/device/nonce", json={"device_id": dev.id})
    assert r.status_code == 200, r.text
    return r.json()["nonce"]


async def proof(env, dev: DeviceKey, purpose: str) -> dict:
    n = await nonce(env, dev)
    return {"nonce": n, "signature": dev.sign(n, purpose)}


def auth_headers(tokens: dict, dev: DeviceKey) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}", "X-Device-Id": dev.id}


PHONE = "+966501234567"
PHONE2 = "+966551234567"
PASSWORD = "Str0ng-Passw0rd!"


async def register(env, dev: DeviceKey, phone: str = PHONE, password: str = PASSWORD,
                   name: str = "مستخدم تجريبي") -> dict:
    r = await env.client.post("/auth2/register/start", json={
        "full_name": name, "phone_e164": phone, "password": password,
        "device": dev.payload(), "idempotency_key": f"reg-{uuid4().hex}"})
    assert r.status_code == 200, r.text
    start = r.json()
    await drain(env)
    code = env.wa.last_code
    r = await env.client.post("/auth2/register/verify", json={
        "challenge_id": start["challenge_id"], "code": code,
        **(await proof(env, dev, "register_verify"))})
    assert r.status_code == 200, r.text
    return r.json()


__all__ = ["env", "drain", "nonce", "proof", "auth_headers", "register", "DeviceKey",
           "FakeProvider", "PHONE", "PHONE2", "PASSWORD", "pytest"]
