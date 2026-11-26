"""Auth v2 end-to-end flows against the real routes (mocked providers)."""

import base64
import hashlib
import json
import time

import httpx
import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from sqlalchemy import select

from app.core import outbound_http
from app.core.security import hash_password, verify_password
from app.domain.entities.auth2_entities import AuthDevice, AuthIdentity, OtpChallenge
from app.domain.entities.auth_entities import User, UserSession
from app.domain.entities.notification_entities import AppNotification
from app.domain.services import device_proof, social_auth
from app.domain.services.otp import engine

from tests.unit.auth2_support import (  # noqa: F401
    PASSWORD,
    PHONE,
    PHONE2,
    DeviceKey,
    auth_headers,
    drain,
    env,
    nonce,
    proof,
    register,
)


async def _login(env, dev, phone=PHONE, password=PASSWORD, signed=True):
    body = {"phone_e164": phone, "password": password, "device": dev.payload()}
    if signed:
        body.update(await proof(env, dev, "login"))
    return await env.client.post("/auth2/login", json=body)


async def _verify_new_device(env, dev, verification_id, channel, code_source):
    r = await env.client.post("/auth2/login/verify/start",
                              json={"verification_id": verification_id, "channel": channel})
    assert r.status_code == 200, r.text
    start = r.json()
    await drain(env)
    code = await code_source(start)
    r = await env.client.post("/auth2/login/verify", json={
        "challenge_id": start["challenge_id"], "code": code,
        **(await proof(env, dev, "login_verify"))})
    return start, r


class TestDeviceProof:
    async def test_signature_roundtrip_and_nonce_single_use(self, env):
        dev = DeviceKey()
        n = await nonce(env, dev)
        sig = dev.sign(n, "login")
        assert device_proof.verify_signature(dev.public_b64, n, dev.id, "login", sig)
        assert not device_proof.verify_signature(dev.public_b64, n, dev.id, "refresh", sig)
        assert not device_proof.verify_signature(DeviceKey().public_b64, n, dev.id, "login", sig)
        async with env.factory() as db:
            assert await device_proof.check_proof(db, public_key_b64=dev.public_b64,
                                                  device_id=dev.id, purpose="login",
                                                  nonce=n, signature=sig)
            assert not await device_proof.check_proof(db, public_key_b64=dev.public_b64,
                                                      device_id=dev.id, purpose="login",
                                                      nonce=n, signature=sig)
            await db.commit()

    def test_rejects_non_p256_keys(self):
        from cryptography.hazmat.primitives import serialization

        k = ec.generate_private_key(ec.SECP384R1()).public_key().public_bytes(
            serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
        with pytest.raises(device_proof.InvalidPublicKey):
            device_proof.load_public_key(base64.b64encode(k).decode())


class TestRegisterAndLogin:
    async def test_register_creates_primary_trusted_device(self, env):
        dev = DeviceKey()
        auth = await register(env, dev)
        assert auth["access_token"] and auth["refresh_token"] and auth["session_id"]
        assert auth["device"] == {"device_id": dev.id, "is_primary": True, "trusted": True}
        assert auth["user"]["phone"] == PHONE and auth["user"]["phone_verified"] is True
        assert auth["user"]["email"] == ""
        async with env.factory() as db:
            user = (await db.execute(select(User).where(User.phone_e164 == PHONE))).scalar_one()
            assert user.password_hash.startswith("$argon2id$")
            session = (await db.execute(select(UserSession))).scalar_one()
            assert session.fingerprint == dev.id and session.is_primary
        r = await env.client.get("/auth/me", headers=auth_headers(auth, dev))
        assert r.status_code == 200

    async def test_register_rejects_taken_phone_and_bad_input(self, env):
        await register(env, DeviceKey())
        r = await env.client.post("/auth2/register/start", json={
            "full_name": "Other", "phone_e164": PHONE, "password": PASSWORD,
            "device": DeviceKey().payload()})
        assert r.status_code == 409 and r.json()["detail"]["code"] == "phone_taken"
        r = await env.client.post("/auth2/register/start", json={
            "full_name": "Other", "phone_e164": "+1555", "password": PASSWORD,
            "device": DeviceKey().payload()})
        assert r.json()["detail"]["code"] == "invalid_phone"
        r = await env.client.post("/auth2/register/start", json={
            "full_name": "Other", "phone_e164": PHONE2, "password": "short",
            "device": DeviceKey().payload()})
        assert r.json()["detail"]["code"] == "weak_password"

    async def test_register_verify_requires_device_proof(self, env):
        dev = DeviceKey()
        r = await env.client.post("/auth2/register/start", json={
            "full_name": "QA", "phone_e164": PHONE, "password": PASSWORD,
            "device": dev.payload()})
        start = r.json()
        await drain(env)
        other = DeviceKey(device_id=dev.id)
        n = await nonce(env, dev)
        r = await env.client.post("/auth2/register/verify", json={
            "challenge_id": start["challenge_id"], "code": env.wa.last_code,
            "nonce": n, "signature": other.sign(n, "register_verify")})
        assert r.status_code == 401 and r.json()["detail"]["code"] == "invalid_device_proof"
        r = await env.client.post("/auth2/register/verify", json={
            "challenge_id": start["challenge_id"], "code": env.wa.last_code,
            **(await proof(env, dev, "register_verify"))})
        assert r.status_code == 200

    async def test_trusted_device_logs_in_without_otp(self, env):
        dev = DeviceKey()
        await register(env, dev)
        sent = len(env.wa.sent)
        r = await _login(env, dev)
        assert r.status_code == 200, r.text
        assert r.json()["device"]["is_primary"] is True and len(env.wa.sent) == sent
        r = await _login(env, dev, password="Wrong-password-1")
        assert r.status_code == 401 and r.json()["detail"]["code"] == "invalid_credentials"
        r = await _login(env, dev, phone=PHONE2)
        assert r.status_code == 401

    async def test_new_device_primary_approval_flow(self, env):
        primary = DeviceKey(name="Primary phone")
        p_auth = await register(env, primary)
        async with env.factory() as db:
            from app.domain.entities.push_entities import DeviceToken

            user = (await db.execute(select(User))).scalar_one()
            db.add(DeviceToken(user_id=user.id, token="fcm-primary", platform="android"))
            await db.commit()
        new = DeviceKey(name="New tablet")
        r = await _login(env, new, signed=False)
        assert r.status_code == 202, r.text
        body = r.json()
        assert body["needs_verification"] and body["options"] == ["device", "whatsapp"]
        assert body["primary_device"]["name"] == "Primary phone"
        sms_before = len(env.sms.sent)

        async def from_primary(start):
            h = auth_headers(p_auth, primary)
            pending = (await env.client.get("/auth2/approvals/pending", headers=h)).json()
            assert [p["approval_id"] for p in pending] == [start["challenge_id"]]
            assert pending[0]["device"]["name"] == "New tablet"
            r = await env.client.post(f"/auth2/approvals/{start['challenge_id']}/code",
                                      json=await proof(env, primary, "approval_code"),
                                      headers=h)
            assert r.status_code == 200, r.text
            return r.json()["code"]

        start, r = await _verify_new_device(env, new, body["verification_id"], "device",
                                            from_primary)
        assert start["channel"] == "device"
        assert r.status_code == 200, r.text
        assert r.json()["device"] == {"device_id": new.id, "is_primary": False, "trusted": True}
        # FCM data push without the code + in-app notification row.
        assert env.pushes and env.pushes[0][1] == {"type": "login_approval",
                                                   "approval_id": start["challenge_id"]}
        assert all(len(str(v)) != 6 or not str(v).isdigit() for v in env.pushes[0][1].values())
        async with env.factory() as db:
            notif = (await db.execute(select(AppNotification))).scalars().all()
            assert notif and notif[0].route == f"/security/approvals?id={start['challenge_id']}"
        assert len(env.sms.sent) == sms_before
        # Now trusted: signs in without verification.
        assert (await _login(env, new)).status_code == 200

    async def test_new_device_whatsapp_option_and_no_sms(self, env):
        await register(env, DeviceKey())
        new = DeviceKey()
        r = await _login(env, new, signed=False)
        vid = r.json()["verification_id"]
        r = await env.client.post("/auth2/login/verify/start",
                                  json={"verification_id": vid, "channel": "sms"})
        assert r.status_code == 409 and r.json()["detail"]["code"] == "sms_not_allowed"

        async def from_wa(start):
            return env.wa.last_code

        _start, r = await _verify_new_device(env, new, vid, "whatsapp", from_wa)
        assert r.status_code == 200, r.text
        assert env.sms.sent == []

    async def test_approval_code_needs_trusted_caller_and_deny(self, env):
        primary = DeviceKey()
        p_auth = await register(env, primary)
        new = DeviceKey()
        vid = (await _login(env, new, signed=False)).json()["verification_id"]
        start = (await env.client.post("/auth2/login/verify/start", json={
            "verification_id": vid, "channel": "device"})).json()
        await drain(env)
        h = auth_headers(p_auth, primary)
        n = await nonce(env, primary)
        r = await env.client.post(f"/auth2/approvals/{start['challenge_id']}/code",
                                  json={"nonce": n, "signature": new.sign(n, "approval_code")},
                                  headers=h)
        assert r.status_code == 401
        r = await env.client.post(f"/auth2/approvals/{start['challenge_id']}/code",
                                  json=await proof(env, primary, "approval_code"),
                                  headers={**h, "X-Device-Id": new.id})
        assert r.status_code == 403
        r = await env.client.post(f"/auth2/approvals/{start['challenge_id']}/deny", headers=h)
        assert r.status_code == 200
        r = await env.client.post("/auth2/otp/status", json={"challenge_id": start["challenge_id"]})
        assert r.json()["status"] == "failed"

    async def test_device_limit_is_kept(self, env, monkeypatch):
        monkeypatch.setattr(env.settings, "MAX_ACTIVE_SESSIONS", 1)
        await register(env, DeviceKey())
        r = await _login(env, DeviceKey(), signed=False)
        assert r.status_code == 409 and r.json()["detail"]["code"] == "device_limit"

    async def test_legacy_bcrypt_hash_is_rehashed(self, env):
        dev = DeviceKey()
        await register(env, dev)
        import bcrypt

        async with env.factory() as db:
            user = (await db.execute(select(User))).scalar_one()
            user.password_hash = bcrypt.hashpw(PASSWORD.encode(), bcrypt.gensalt()).decode()
            await db.commit()
        assert (await _login(env, dev)).status_code == 200
        async with env.factory() as db:
            user = (await db.execute(select(User))).scalar_one()
            assert user.password_hash.startswith("$argon2id$")
            assert verify_password(PASSWORD, user.password_hash)


class TestDevicesAndRefresh:
    async def _two_devices(self, env):
        primary = DeviceKey()
        p_auth = await register(env, primary)
        second = DeviceKey()
        vid = (await _login(env, second, signed=False)).json()["verification_id"]

        async def from_wa(start):
            return env.wa.last_code

        _s, r = await _verify_new_device(env, second, vid, "whatsapp", from_wa)
        assert r.status_code == 200, r.text
        return primary, p_auth, second, r.json()

    async def test_refresh_is_device_bound_and_revocation_kills_it(self, env):
        primary, p_auth, second, s_auth = await self._two_devices(env)
        r = await env.client.post("/auth2/refresh", json={
            "refresh_token": s_auth["refresh_token"], "device_id": second.id,
            **(await proof(env, second, "refresh"))})
        assert r.status_code == 200, r.text
        s_auth = {**s_auth, **r.json()}
        r = await env.client.post("/auth2/refresh", json={
            "refresh_token": s_auth["refresh_token"], "device_id": primary.id,
            **(await proof(env, primary, "refresh"))})
        assert r.status_code == 401
        devices = (await env.client.get("/auth2/devices",
                                        headers=auth_headers(p_auth, primary))).json()
        assert [d["is_primary"] for d in devices] == [True, False]
        assert devices[0]["current"] is True
        # Second device cannot revoke the primary; primary revokes second.
        r = await env.client.post(f"/auth2/devices/{primary.id}/revoke",
                                  headers=auth_headers(s_auth, second))
        assert r.status_code == 409
        r = await env.client.post(f"/auth2/devices/{second.id}/revoke",
                                  headers=auth_headers(p_auth, primary))
        assert r.status_code == 200
        r = await env.client.post("/auth2/refresh", json={
            "refresh_token": s_auth["refresh_token"], "device_id": second.id,
            **(await proof(env, second, "refresh"))})
        assert r.status_code == 401
        assert r.json()["detail"]["code"] in ("device_revoked", "verification_expired")
        r = await env.client.get("/auth/me", headers=auth_headers(s_auth, second))
        assert r.status_code == 401
        # Next login from the revoked device requires verification again.
        assert (await _login(env, second)).status_code == 202

    async def test_rename_and_make_primary(self, env):
        primary, p_auth, second, s_auth = await self._two_devices(env)
        r = await env.client.post(f"/auth2/devices/{second.id}/rename", json={"name": "مكتب"},
                                  headers=auth_headers(p_auth, primary))
        assert r.status_code == 200 and r.json()["name"] == "مكتب"
        r = await env.client.post(f"/auth2/devices/{primary.id}/make-primary",
                                  json=await proof(env, second, "make_primary"),
                                  headers=auth_headers(s_auth, second))
        assert r.status_code == 403
        r = await env.client.post(f"/auth2/devices/{second.id}/make-primary",
                                  json=await proof(env, primary, "make_primary"),
                                  headers=auth_headers(p_auth, primary))
        assert r.status_code == 200, r.text
        async with env.factory() as db:
            devs = {d.device_id: d.is_primary for d in
                    (await db.execute(select(AuthDevice))).scalars().all()}
            assert devs == {primary.id: False, second.id: True}
            sess = {s.fingerprint: s.is_primary for s in
                    (await db.execute(select(UserSession).where(
                        UserSession.is_active.is_(True)))).scalars().all()}
            assert sess[second.id] is True and sess[primary.id] is False

    async def test_claim_primary_waits_and_can_be_cancelled(self, env):
        from datetime import timedelta

        from app.domain.entities.auth2_entities import PrimaryTransfer
        from app.domain.services.auth2_service import apply_due_primary_transfers

        primary, p_auth, second, s_auth = await self._two_devices(env)
        r = await env.client.post("/auth2/devices/claim-primary",
                                  headers=auth_headers(s_auth, second))
        assert r.status_code == 200 and r.json()["pending"]["status"] == "pending"
        assert r.json()["applies_at"]
        rows = (await env.client.get("/auth2/devices", headers=auth_headers(p_auth, primary))).json()
        claim = {d["device_id"]: d["primary_claim_until"] for d in rows}
        assert claim[second.id] == r.json()["applies_at"] and claim[primary.id] is None
        r = await env.client.post("/auth2/devices/claim-primary/cancel",
                                  headers=auth_headers(p_auth, primary))
        assert r.status_code == 200
        r = await env.client.post("/auth2/devices/claim-primary",
                                  headers=auth_headers(s_auth, second))
        async with env.factory() as db:
            assert await apply_due_primary_transfers(db) == 0
            t = (await db.execute(select(PrimaryTransfer).where(
                PrimaryTransfer.status == "pending"))).scalar_one()
            t.apply_at = t.apply_at - timedelta(hours=49)
            await db.commit()
        async with env.factory() as db:
            assert await apply_due_primary_transfers(db) == 1
        async with env.factory() as db:
            prim = (await db.execute(select(AuthDevice).where(
                AuthDevice.is_primary.is_(True)))).scalar_one()
            assert prim.device_id == second.id


class TestPhoneChangeAndReset:
    async def test_phone_change(self, env):
        dev = DeviceKey()
        auth = await register(env, dev)
        h = auth_headers(auth, dev)
        r = await env.client.post("/auth2/phone/change/start", json={
            "new_phone_e164": PHONE2}, headers=h)
        assert r.status_code == 401 and r.json()["detail"]["code"] == "reauth_required"
        r = await env.client.post("/auth2/phone/change/start", json={
            "new_phone_e164": PHONE2, **(await proof(env, dev, "phone_change"))}, headers=h)
        assert r.status_code == 200, r.text
        start = r.json()
        await drain(env)
        assert env.wa.sent[-1]["to"] == PHONE2
        r = await env.client.post("/auth2/phone/change/verify", json={
            "challenge_id": start["challenge_id"], "code": env.wa.last_code}, headers=h)
        assert r.status_code == 200, r.text
        assert r.json()["user"]["phone"] == PHONE2
        assert (await _login(env, dev, phone=PHONE2)).status_code == 200
        assert (await _login(env, dev, phone=PHONE)).status_code == 401

    async def test_phone_change_to_taken_number(self, env):
        dev = DeviceKey()
        auth = await register(env, dev)
        await register(env, DeviceKey(), phone=PHONE2)
        r = await env.client.post("/auth2/phone/change/start", json={
            "new_phone_e164": PHONE2, "password": PASSWORD}, headers=auth_headers(auth, dev))
        assert r.status_code == 409 and r.json()["detail"]["code"] == "phone_taken"

    async def test_password_reset_with_sms_fallback(self, env):
        dev = DeviceKey()
        await register(env, dev)
        r = await env.client.post("/auth2/password/forgot", json={"phone_e164": PHONE2})
        assert r.status_code == 404
        r = await env.client.post("/auth2/password/forgot", json={"phone_e164": PHONE,
                                                                  "device": dev.payload()})
        assert r.status_code == 200, r.text
        start = r.json()
        await drain(env)
        env.clock.advance(env.settings.AUTH_OTP_DELIVERY_DEADLINE_SECONDS + 1)
        await drain(env)
        status = (await env.client.post("/auth2/otp/status",
                                        json={"challenge_id": start["challenge_id"]})).json()
        assert status["status"] == "fallback_sms" and status["channel"] == "sms"
        r = await env.client.post("/auth2/password/reset", json={
            "challenge_id": start["challenge_id"], "code": env.sms.last_code,
            "new_password": "N3w-Password!"})
        assert r.status_code == 200, r.text
        assert (await _login(env, dev)).status_code == 401
        assert (await _login(env, dev, password="N3w-Password!")).status_code == 200


# ── Social (mocked JWKS) ──
class _Issuer:
    def __init__(self):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.kid = "kid-1"

    def jwks(self):
        nums = self.key.public_key().public_numbers()

        def b64(i):
            raw = i.to_bytes((i.bit_length() + 7) // 8, "big")
            return base64.urlsafe_b64encode(raw).decode().rstrip("=")

        return {"keys": [{"kty": "RSA", "kid": self.kid, "alg": "RS256", "use": "sig",
                          "n": b64(nums.n), "e": b64(nums.e)}]}

    def token(self, claims):
        enc = lambda d: base64.urlsafe_b64encode(  # noqa: E731
            json.dumps(d).encode()).decode().rstrip("=")
        head = enc({"alg": "RS256", "kid": self.kid, "typ": "JWT"})
        body = enc(claims)
        sig = self.key.sign(f"{head}.{body}".encode(), padding.PKCS1v15(), hashes.SHA256())
        return f"{head}.{body}." + base64.urlsafe_b64encode(sig).decode().rstrip("=")


@pytest.fixture()
def issuer():
    iss = _Issuer()
    social_auth._jwks.clear()

    def handler(request: httpx.Request):
        if request.url.path in ("/oauth2/v3/certs", "/auth/keys"):
            return httpx.Response(200, json=iss.jwks(),
                                  headers={"cache-control": "public, max-age=3600"})
        return httpx.Response(404)

    outbound_http.set_transport_for_tests(httpx.MockTransport(handler))
    yield iss
    outbound_http.set_transport_for_tests(None)
    social_auth._jwks.clear()


def _google_claims(sub="g-123", **kw):
    now = int(time.time())
    return {"iss": "https://accounts.google.com", "aud": social_auth.settings.GOOGLE_WEB_CLIENT_ID,
            "sub": sub, "email": "qa@example.com", "email_verified": True, "name": "QA Google",
            "iat": now, "exp": now + 600, **kw}


class TestSocial:
    async def test_google_new_identity_then_phone_then_trusted(self, env, issuer):
        dev = DeviceKey()
        r = await env.client.post("/auth2/social", json={
            "provider": "google", "id_token": issuer.token(_google_claims()),
            "device": dev.payload()})
        assert r.status_code == 200, r.text
        assert r.json()["needs_phone"] is True
        session = r.json()["social_session"]
        r = await env.client.post("/auth2/social/phone/start", json={
            "social_session": session, "phone_e164": PHONE, "idempotency_key": "s-1"})
        assert r.status_code == 200, r.text
        start = r.json()
        await drain(env)
        r = await env.client.post("/auth2/social/phone/verify", json={
            "challenge_id": start["challenge_id"], "code": env.wa.last_code,
            **(await proof(env, dev, "social_phone_verify"))})
        assert r.status_code == 200, r.text
        assert r.json()["device"]["is_primary"] is True
        assert r.json()["user"]["email"] == "qa@example.com"
        async with env.factory() as db:
            ident = (await db.execute(select(AuthIdentity))).scalar_one()
            assert (ident.provider, ident.subject) == ("google", "g-123")
        n = await nonce(env, dev)
        r = await env.client.post("/auth2/social", json={
            "provider": "google", "id_token": issuer.token(_google_claims()),
            "device": dev.payload(), "nonce": n, "signature": dev.sign(n, "social")})
        assert r.status_code == 200 and r.json()["access_token"]
        r = await env.client.post("/auth2/social", json={
            "provider": "google", "id_token": issuer.token(_google_claims()),
            "device": DeviceKey().payload()})
        assert r.status_code == 202 and r.json()["needs_verification"]

    async def test_social_phone_taken(self, env, issuer):
        await register(env, DeviceKey())
        r = await env.client.post("/auth2/social", json={
            "provider": "google", "id_token": issuer.token(_google_claims(sub="g-2")),
            "device": DeviceKey().payload()})
        r = await env.client.post("/auth2/social/phone/start", json={
            "social_session": r.json()["social_session"], "phone_e164": PHONE})
        assert r.status_code == 409 and r.json()["detail"]["code"] == "phone_taken"

    async def test_google_rejects_wrong_audience_issuer_and_expiry(self, env, issuer):
        for claims in (_google_claims(aud="other.apps.googleusercontent.com"),
                       _google_claims(iss="https://evil.example"),
                       _google_claims(exp=int(time.time()) - 3600)):
            r = await env.client.post("/auth2/social", json={
                "provider": "google", "id_token": issuer.token(claims),
                "device": DeviceKey().payload()})
            assert r.status_code == 401, r.text
        forged = _Issuer().token(_google_claims())
        r = await env.client.post("/auth2/social", json={
            "provider": "google", "id_token": forged, "device": DeviceKey().payload()})
        assert r.status_code == 401

    async def test_apple_nonce_and_private_relay(self, env, issuer, monkeypatch):
        dev = DeviceKey()
        n = await nonce(env, dev)
        now = int(time.time())
        claims = {"iss": "https://appleid.apple.com", "aud": social_auth.settings.APPLE_BUNDLE_ID,
                  "sub": "apple-001", "email": "x1@privaterelay.appleid.com",
                  "email_verified": "true", "is_private_email": "true",
                  "nonce": hashlib.sha256(n.encode()).hexdigest(), "iat": now, "exp": now + 600}
        r = await env.client.post("/auth2/social", json={
            "provider": "apple", "id_token": issuer.token(claims), "nonce": n,
            "full_name": "Apple Person", "device": dev.payload()})
        assert r.status_code == 200, r.text
        assert r.json()["needs_phone"] and r.json()["name_required"] is False
        # Replayed nonce is refused.
        r = await env.client.post("/auth2/social", json={
            "provider": "apple", "id_token": issuer.token(claims), "nonce": n,
            "device": dev.payload()})
        assert r.status_code == 401
        n2 = await nonce(env, dev)
        r = await env.client.post("/auth2/social", json={
            "provider": "apple", "id_token": issuer.token({**claims, "nonce": "zzz"}),
            "nonce": n2, "device": dev.payload()})
        assert r.status_code == 401
        # Client variant: separate raw_nonce for Apple + device nonce/proof.
        n3 = await nonce(env, dev)
        raw = "client-raw-nonce-123"
        r = await env.client.post("/auth2/social", json={
            "provider": "apple", "raw_nonce": raw, "nonce": n3,
            "signature": dev.sign(n3, "social"),
            "id_token": issuer.token({**claims, "nonce": hashlib.sha256(raw.encode()).hexdigest()}),
            "device": dev.payload()})
        assert r.status_code == 200, r.text


class TestAppleClientSecret:
    def test_es256_client_secret(self, tmp_path, monkeypatch):
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

        key = ec.generate_private_key(ec.SECP256R1())
        p8 = tmp_path / "AuthKey.p8"
        p8.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                                         serialization.PrivateFormat.PKCS8,
                                         serialization.NoEncryption()))
        monkeypatch.setattr(social_auth.settings, "APPLE_TEAM_ID", "TEAMID1234")
        monkeypatch.setattr(social_auth.settings, "APPLE_KEY_ID", "KEYID12345")
        monkeypatch.setattr(social_auth.settings, "APPLE_PRIVATE_KEY_PATH", str(p8))
        monkeypatch.setattr(social_auth, "_client_secret", None)
        token = social_auth.apple_client_secret()
        h, p, s = token.split(".")
        pad = lambda x: x + "=" * (-len(x) % 4)  # noqa: E731
        header = json.loads(base64.urlsafe_b64decode(pad(h)))
        claims = json.loads(base64.urlsafe_b64decode(pad(p)))
        assert header == {"alg": "ES256", "kid": "KEYID12345", "typ": "JWT"}
        assert claims["iss"] == "TEAMID1234" and claims["sub"] == social_auth.settings.APPLE_BUNDLE_ID
        assert claims["aud"] == "https://appleid.apple.com"
        assert claims["exp"] - claims["iat"] <= 15777000
        raw = base64.urlsafe_b64decode(pad(s))
        der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
        key.public_key().verify(der, f"{h}.{p}".encode(), ec.ECDSA(hashes.SHA256()))
        assert social_auth.apple_client_secret() == token  # cached in memory
        later = social_auth.apple_client_secret(now=claims["exp"] - 86400)
        assert later != token  # renewed before expiry

    async def test_account_delete_revokes_apple(self, env, monkeypatch):
        dev = DeviceKey()
        auth = await register(env, dev)
        revoked = []

        async def fake_revoke(rt):
            revoked.append(rt)
            return True

        monkeypatch.setattr(social_auth, "apple_revoke", fake_revoke)
        from app.domain.services.otp.secrets_box import encrypt

        async with env.factory() as db:
            user = (await db.execute(select(User))).scalar_one()
            db.add(AuthIdentity(user_id=user.id, provider="apple", subject="a-1",
                                refresh_token_enc=encrypt("apple-refresh")))
            await db.commit()
        r = await env.client.post("/auth2/account/delete", json={
            "password": PASSWORD, **(await proof(env, dev, "account_delete"))},
            headers=auth_headers(auth, dev))
        assert r.status_code == 200, r.text
        assert revoked == ["apple-refresh"]
        assert (await _login(env, dev)).status_code == 401


class TestLegacyAndAdmin:
    async def test_email_routes_are_gone(self, env):
        r = await env.client.post("/auth/login", json={"email": "a@b.co", "password": "x" * 8})
        assert r.status_code == 410 and r.json()["detail"]["code"] == "gone"
        r = await env.client.post("/auth/register", json={
            "full_name": "x", "email": "a@b.co", "password": "x" * 8})
        assert r.status_code == 410

    async def test_legacy_login_flag_for_qa(self, env, monkeypatch):
        monkeypatch.setattr(env.settings, "AUTH_LEGACY_EMAIL_ROUTES", "login")
        r = await env.client.post("/auth/login", json={"email": "a@b.co", "password": "x" * 8})
        assert r.status_code == 401
        r = await env.client.post("/auth/register", json={
            "full_name": "xx", "email": "a@b.co", "password": "x" * 8})
        assert r.status_code == 410

    async def test_admin_metrics_and_budgets(self, env):
        dev = DeviceKey()
        auth = await register(env, dev)
        h = auth_headers(auth, dev)
        assert (await env.client.get("/auth2/admin/otp-metrics", headers=h)).status_code == 403
        async with env.factory() as db:
            user = (await db.execute(select(User))).scalar_one()
            user.is_platform_admin = True
            await db.commit()
        r = await env.client.get("/auth2/admin/otp-metrics", headers=h)
        assert r.status_code == 200, r.text
        data = r.json()
        assert data["challenges"]["by_status"]["verified"] == 1
        assert data["spend"]["sms"]["daily_usd"] == pytest.approx(0.30)
        r = await env.client.put("/auth2/admin/otp-budgets", json={
            "sms": {"daily_usd": 0.5}, "global": {"monthly_usd": 20}}, headers=h)
        assert r.status_code == 200, r.text
        assert r.json()["budgets"]["sms"]["daily_usd"] == 0.5
        assert r.json()["budgets"]["global"]["monthly_usd"] == 20
