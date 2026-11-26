"""OTP engine state machine (mocked providers, isolated SQLite)."""

import asyncio
import hashlib
import hmac
import json

import pytest
from sqlalchemy import func, select

from app.domain.entities.auth2_entities import OtpChallenge, OtpDelivery
from app.domain.services.otp import costs, engine
from app.domain.services.otp.engine import OtpError
from app.domain.services.otp.providers import (
    SendResult,
    SmsToProvider,
    WhatsAppCloudProvider,
    classify_meta_error,
)
from app.domain.services.otp.secrets_box import mask_e164, sign_token

from tests.unit.auth2_support import PHONE, drain, env  # noqa: F401


async def _start(env, purpose="signup", **kw):
    async with env.factory() as db:
        ch = await engine.start(db, purpose=purpose, phone_e164=kw.pop("phone", PHONE),
                                ip=kw.pop("ip", "203.0.113.5"),
                                device_id=kw.pop("device_id", "dev-aaaaaaaaaaaa"),
                                country="SA", **kw)
        await db.commit()
        return ch.id


async def _get(env, cid) -> OtpChallenge:
    async with env.factory() as db:
        return await engine.get(db, cid)


async def _view(env, cid) -> dict:
    async with env.factory() as db:
        ch = await engine.get(db, cid)
        v = await engine.status_view(db, ch)
        await db.commit()
        return v


async def _sms_rows(env, cid) -> int:
    async with env.factory() as db:
        return (await db.execute(select(func.count()).select_from(OtpDelivery).where(
            OtpDelivery.challenge_id == cid, OtpDelivery.channel == "sms"))).scalar()


async def _wa_status(env, message_id, status, code=None):
    async with env.factory() as db:
        cid = await engine.apply_whatsapp_status(db, message_id=message_id, status=status,
                                                 error_code=code)
        await db.commit()
    if cid:
        await engine.process(cid)


class TestHappyPath:
    async def test_whatsapp_first_then_delivered_never_sms(self, env):
        cid = await _start(env)
        assert (await _get(env, cid)).status == "queued"
        await drain(env)
        ch = await _get(env, cid)
        assert ch.status == "sent" and ch.channel == "whatsapp"
        assert len(env.wa.sent) == 1 and env.wa.sent[0]["to"] == PHONE
        await _wa_status(env, ch.wa_message_id, "delivered")
        env.clock.advance(60)
        await drain(env)
        ch = await _get(env, cid)
        assert ch.status == "delivered"
        assert env.sms.sent == [] and await _sms_rows(env, cid) == 0
        assert (await _view(env, cid))["can_request_sms"] is False

    async def test_code_is_hashed_not_stored_plain(self, env):
        cid = await _start(env)
        await drain(env)
        ch = await _get(env, cid)
        code = env.wa.last_code
        assert len(code) == 6 and code.isdigit()
        assert code not in (ch.code_hmac or "") and code not in (ch.code_enc or "")
        assert PHONE not in (ch.target_enc or "")

    async def test_verify_single_use_and_secrets_wiped(self, env):
        cid = await _start(env)
        await drain(env)
        code = env.wa.last_code
        async with env.factory() as db:
            ch, _payload, phone = await engine.verify(db, cid, code, purposes={"signup"})
            await db.commit()
        assert phone == PHONE
        ch = await _get(env, cid)
        assert ch.status == "verified" and ch.code_enc is None and ch.target_enc is None
        async with env.factory() as db:
            with pytest.raises(OtpError) as e:
                await engine.verify(db, cid, code, purposes={"signup"})
        assert e.value.code == "otp_already_used"


class TestFallback:
    async def test_deadline_without_receipt_falls_back_to_sms_once(self, env):
        cid = await _start(env)
        await drain(env)
        assert (await _view(env, cid))["can_request_sms"] is False  # WhatsApp still likely
        env.clock.advance(env.settings.AUTH_OTP_DELIVERY_DEADLINE_SECONDS + 1)
        await drain(env)
        ch = await _get(env, cid)
        assert ch.status == "fallback_sms" and ch.channel == "sms" and ch.sms_sent
        assert len(env.sms.sent) == 1
        assert env.sms.sent[0]["code"] == env.wa.sent[0]["code"]  # same code
        assert env.sms.sent[0]["callback_url"].startswith(
            "https://qa.example.test/api/v1/webhooks/smsto/")
        env.clock.advance(120)
        await drain(env)
        async with env.factory() as db:
            ch = await engine.get(db, cid)
            with pytest.raises(OtpError) as e:
                await engine.resend(db, ch, "sms")
        assert e.value.code == "sms_not_allowed"
        assert len(env.sms.sent) == 1 and await _sms_rows(env, cid) == 1

    async def test_no_auto_fallback_without_webhook_receipts(self, env, monkeypatch):
        monkeypatch.setattr(env.settings, "META_WEBHOOK_APP_SECRET", None)
        monkeypatch.setattr(env.settings, "META_APP_SECRET", None)
        cid = await _start(env)
        await drain(env)
        env.clock.advance(60)
        await drain(env)
        assert env.sms.sent == []
        # ...but the user may still ask for SMS after the deadline.
        assert (await _view(env, cid))["can_request_sms"] is True

    @pytest.mark.parametrize("code", ["131026", "131049", "131050"])
    async def test_permanent_whatsapp_failure_webhook_triggers_sms(self, env, code):
        cid = await _start(env, purpose="phone_change")
        await drain(env)
        ch = await _get(env, cid)
        await _wa_status(env, ch.wa_message_id, "failed", code)
        ch = await _get(env, cid)
        assert ch.wa_status == "failed" and ch.wa_error_code == code
        assert ch.status == "fallback_sms" and len(env.sms.sent) == 1

    async def test_permanent_send_error_triggers_sms(self, env):
        env.wa.results = [SendResult(ok=False, error_code="131026", permanent=True)]
        cid = await _start(env, purpose="password_reset")
        await drain(env)
        assert (await _get(env, cid)).status == "fallback_sms"
        assert len(env.sms.sent) == 1

    async def test_temporary_error_is_retried_on_whatsapp(self, env):
        env.wa.results = [SendResult(ok=False, error_code="130429", permanent=False)]
        cid = await _start(env)
        await drain(env)
        ch = await _get(env, cid)
        assert ch.status == "queued" and ch.wa_attempts == 1
        env.clock.advance(3)
        await drain(env)
        ch = await _get(env, cid)
        assert ch.status == "sent" and len(env.wa.sent) == 2 and env.sms.sent == []

    async def test_new_device_never_sms(self, env):
        env.wa.results = [SendResult(ok=False, error_code="131026", permanent=True)]
        cid = await _start(env, purpose="new_device")
        await drain(env)
        ch = await _get(env, cid)
        assert ch.status == "failed" and env.sms.sent == []
        env.clock.advance(120)
        assert (await _view(env, cid))["can_request_sms"] is False
        async with env.factory() as db:
            with pytest.raises(OtpError):
                await engine.resend(db, await engine.get(db, cid), "sms")
        assert env.sms.sent == []

    async def test_late_whatsapp_failure_after_sms_keeps_sms_state(self, env):
        cid = await _start(env)
        await drain(env)
        wamid = (await _get(env, cid)).wa_message_id
        env.clock.advance(env.settings.AUTH_OTP_DELIVERY_DEADLINE_SECONDS + 1)
        await drain(env)
        assert (await _get(env, cid)).status == "fallback_sms"
        await _wa_status(env, wamid, "failed", "131026")
        ch = await _get(env, cid)
        assert ch.status == "fallback_sms" and ch.wa_status == "failed"
        assert len(env.sms.sent) == 1

    async def test_late_delivered_receipt_cancels_pending_fallback(self, env):
        cid = await _start(env)
        await drain(env)
        ch = await _get(env, cid)
        env.clock.advance(10)
        await _wa_status(env, ch.wa_message_id, "read")
        env.clock.advance(60)
        await drain(env)
        assert (await _get(env, cid)).status == "read" and env.sms.sent == []


class TestConcurrency:
    async def test_parallel_sms_attempts_send_exactly_one(self, env):
        env.wa.results = [SendResult(ok=False, error_code="131026", permanent=True)]
        cid = await _start(env)
        async with env.factory() as db:
            ch = await engine.get(db, cid)
            ch.status = "fallback_sms"
            ch.channel = "sms"
            ch.wa_status = "failed"
            await db.commit()

        async def attempt():
            async with env.factory() as db:
                await engine._send_sms(db, cid)

        await asyncio.gather(*(attempt() for _ in range(6)))
        await asyncio.gather(*(engine.process(cid) for _ in range(4)))
        assert len(env.sms.sent) == 1
        assert await _sms_rows(env, cid) == 1

    async def test_db_unique_index_blocks_second_sms_row(self, env):
        from sqlalchemy.exc import IntegrityError

        cid = await _start(env)
        async with env.factory() as db:
            db.add(OtpDelivery(challenge_id=cid, channel="sms", provider="smsto", cost_usd=0))
            await db.commit()
        async with env.factory() as db:
            db.add(OtpDelivery(challenge_id=cid, channel="sms", provider="smsto", cost_usd=0))
            with pytest.raises(IntegrityError):
                await db.commit()


class TestLimits:
    async def test_expiry_after_five_minutes(self, env):
        cid = await _start(env)
        await drain(env)
        code = env.wa.last_code
        env.clock.advance(301)
        async with env.factory() as db:
            with pytest.raises(OtpError) as e:
                await engine.verify(db, cid, code, purposes={"signup"})
        assert e.value.code == "otp_expired"
        ch = await _get(env, cid)
        assert ch.status == "expired" and ch.code_enc is None

    async def test_wrong_attempts_lock(self, env):
        cid = await _start(env)
        await drain(env)
        good = env.wa.last_code
        bad = "000000" if good != "000000" else "111111"
        for i in range(4):
            async with env.factory() as db:
                with pytest.raises(OtpError) as e:
                    await engine.verify(db, cid, bad, purposes={"signup"})
            assert e.value.code == "otp_invalid_code"
            assert e.value.extra["attempts_left"] == 4 - i
        async with env.factory() as db:
            with pytest.raises(OtpError) as e:
                await engine.verify(db, cid, bad, purposes={"signup"})
        assert e.value.code == "otp_locked"
        async with env.factory() as db:
            with pytest.raises(OtpError) as e:
                await engine.verify(db, cid, good, purposes={"signup"})
        assert e.value.code == "otp_locked"

    async def test_purpose_is_bound(self, env):
        cid = await _start(env, purpose="password_reset")
        await drain(env)
        async with env.factory() as db:
            with pytest.raises(OtpError) as e:
                await engine.verify(db, cid, env.wa.last_code, purposes={"signup"})
        assert e.value.code == "otp_not_found"

    async def test_resend_cooldowns_and_new_code(self, env):
        cid = await _start(env)
        await drain(env)
        first = env.wa.last_code
        async with env.factory() as db:
            with pytest.raises(OtpError) as e:
                await engine.resend(db, await engine.get(db, cid))
        assert e.value.code == "otp_cooldown" and 0 < e.value.retry_after <= 30
        expected = [30, 60, 120]
        for i, wait in enumerate(expected):
            env.clock.advance(wait + 1)
            async with env.factory() as db:
                await engine.resend(db, await engine.get(db, cid))
                await db.commit()
            await drain(env)
            v = await _view(env, cid)
            if i + 1 < len(expected):
                assert expected[i + 1] - 1 <= v["resend_after"] <= expected[i + 1]
        env.clock.advance(200)
        async with env.factory() as db:
            with pytest.raises(OtpError) as e:
                await engine.resend(db, await engine.get(db, cid))
        assert e.value.code == "otp_resend_limit"
        assert len(env.wa.sent) == 4
        async with env.factory() as db:
            with pytest.raises(OtpError):
                await engine.verify(db, cid, first if first != env.wa.last_code else "x",
                                    purposes={"signup"})

    async def test_caps_per_phone_hour(self, env, monkeypatch):
        monkeypatch.setattr(env.settings, "AUTH_OTP_CAP_PHONE", "2,5")
        await _start(env, ip="198.51.100.1", device_id="dev-111111111111")
        await _start(env, ip="198.51.100.2", device_id="dev-222222222222")
        with pytest.raises(OtpError) as e:
            await _start(env, ip="198.51.100.3", device_id="dev-333333333333")
        assert e.value.code == "otp_rate_limited" and e.value.status == 429
        assert e.value.retry_after > 0

    async def test_caps_per_ip_and_device(self, env, monkeypatch):
        monkeypatch.setattr(env.settings, "AUTH_OTP_CAP_IP", "1,10")
        await _start(env, phone="+966501111111")
        with pytest.raises(OtpError):
            await _start(env, phone="+966502222222", device_id="dev-other0000000")
        monkeypatch.setattr(env.settings, "AUTH_OTP_CAP_IP", "100,100")
        monkeypatch.setattr(env.settings, "AUTH_OTP_CAP_DEVICE", "1,10")
        with pytest.raises(OtpError):
            await _start(env, phone="+966503333333", ip="198.51.100.77")

    async def test_idempotency_key(self, env):
        a = await _start(env, idempotency_key="k-1")
        b = await _start(env, idempotency_key="k-1")
        assert a == b
        with pytest.raises(OtpError) as e:
            await _start(env, idempotency_key="k-1", phone="+966509999999")
        assert e.value.code == "idempotency_conflict"


class TestBudgets:
    async def test_sms_budget_blocks_fallback(self, env, monkeypatch):
        monkeypatch.setattr(env.settings, "AUTH_OTP_BUDGET_SMS_DAILY_USD", 0.10)
        monkeypatch.setattr(env.settings, "AUTH_OTP_COST_SMS_DEFAULT_USD", 0.08)
        env.wa.results = [SendResult(ok=False, error_code="131026", permanent=True)] * 2
        first = await _start(env, phone="+966501111111")
        await drain(env)
        assert len(env.sms.sent) == 1 and (await _get(env, first)).status == "fallback_sms"
        second = await _start(env, phone="+966502222222")
        await drain(env)
        ch = await _get(env, second)
        assert ch.status == "failed" and len(env.sms.sent) == 1
        async with env.factory() as db:
            s = await costs.spend_summary(db, engine.utcnow())
        assert s["sms"]["spent_today_usd"] == pytest.approx(0.08)

    async def test_admin_override_and_whatsapp_budget(self, env):
        async with env.factory() as db:
            await costs.set_budget(db, "whatsapp", daily_usd=0, monthly_usd=None)
            await db.commit()
        with pytest.raises(OtpError) as e:
            await _start(env, purpose="new_device")
        assert e.value.code == "otp_unavailable"

    async def test_country_estimates(self, monkeypatch, env):
        monkeypatch.setattr(env.settings, "AUTH_OTP_COST_SMS_BY_COUNTRY", '{"ye": 0.12}')
        assert costs.estimate("sms", "YE") == 0.12
        assert costs.estimate("sms", "SA") == env.settings.AUTH_OTP_COST_SMS_DEFAULT_USD


class TestProviders:
    def test_whatsapp_template_payload(self, monkeypatch):
        from app.core.config import settings

        monkeypatch.setattr(settings, "WHATSAPP_TEMPLATE_NAME", "fyona_login_code")
        p = WhatsAppCloudProvider.build_payload("+966501234567", "123456", "en-US")
        assert p["to"] == "966501234567" and p["type"] == "template"
        t = p["template"]
        assert t["name"] == "fyona_login_code" and t["language"] == {"code": "en"}
        assert t["components"][0] == {"type": "body",
                                      "parameters": [{"type": "text", "text": "123456"}]}
        assert t["components"][1]["type"] == "button"
        assert t["components"][1]["sub_type"] == "url"
        assert t["components"][1]["parameters"] == [{"type": "text", "text": "123456"}]
        assert WhatsAppCloudProvider.build_payload("+9671", "1", "ar")["template"][
            "language"] == {"code": "ar"}

    def test_smsto_payload(self, monkeypatch):
        from app.core.config import settings

        monkeypatch.setattr(settings, "SMS_SENDER_ID", "FYONA")
        p = SmsToProvider.build_payload("+966501234567", "654321", "ar", "https://cb")
        assert p["to"] == "+966501234567" and p["sender_id"] == "FYONA"
        assert p["callback_url"] == "https://cb" and "654321" in p["message"]
        assert len(p["message"]) <= 70  # single UCS-2 part

    def test_meta_error_classification(self):
        for code in (131026, 131049, 131050, 132001, 100, 190):
            assert classify_meta_error(code) is True
        for code in (130429, 131000, 131016, 131056):
            assert classify_meta_error(code) is False
        assert classify_meta_error(None, 503) is False
        assert classify_meta_error(None, 400) is True

    async def test_whatsapp_http_adapter(self, monkeypatch):
        import httpx

        from app.core import outbound_http
        from app.core.config import settings

        monkeypatch.setattr(settings, "WHATSAPP_ACCESS_TOKEN", "tok-test")
        monkeypatch.setattr(settings, "WHATSAPP_PHONE_NUMBER_ID", "12345")
        seen = {}

        def handler(request: httpx.Request):
            seen["url"] = str(request.url)
            seen["auth"] = request.headers["authorization"]
            body = json.loads(request.content)
            if body["to"] == "966500000000":
                return httpx.Response(400, json={"error": {"code": 131026, "title": "x"}})
            return httpx.Response(200, json={"messages": [{"id": "wamid.ABC"}]})

        outbound_http.set_transport_for_tests(httpx.MockTransport(handler))
        try:
            ok = await WhatsAppCloudProvider().send_code(to_e164="+966501234567",
                                                         code="123456", locale="ar")
            bad = await WhatsAppCloudProvider().send_code(to_e164="+966500000000",
                                                          code="123456", locale="ar")
        finally:
            outbound_http.set_transport_for_tests(None)
        assert ok.ok and ok.message_id == "wamid.ABC"
        assert seen["url"].endswith("/12345/messages") and seen["auth"] == "Bearer tok-test"
        assert not bad.ok and bad.permanent and bad.error_code == "131026"

    async def test_smsto_http_adapter(self, monkeypatch):
        import httpx

        from app.core import outbound_http
        from app.core.config import settings

        monkeypatch.setattr(settings, "SMS_TO_API_KEY", "sms-test")

        def handler(request: httpx.Request):
            assert request.url.path == "/sms/send"
            assert request.headers["authorization"] == "Bearer sms-test"
            return httpx.Response(200, json={"success": True, "message_id": "m-1",
                                             "message": "queued"})

        outbound_http.set_transport_for_tests(httpx.MockTransport(handler))
        try:
            r = await SmsToProvider().send_code(to_e164="+966501234567", code="1",
                                                locale="en", callback_url=None)
        finally:
            outbound_http.set_transport_for_tests(None)
        assert r.ok and r.message_id == "m-1"

    def test_log_masking(self):
        assert mask_e164("+966501234567") == "+9665******67"


def _sig(raw: bytes, secret="test-webhook-secret") -> str:
    return "sha256=" + hmac.new(secret.encode(), raw, hashlib.sha256).hexdigest()


class TestWebhooks:
    async def test_verify_handshake(self, env):
        r = await env.client.get("/webhooks/whatsapp", params={
            "hub.mode": "subscribe", "hub.verify_token": "test-verify-token",
            "hub.challenge": "12345"})
        assert r.status_code == 200 and r.text == "12345"
        r = await env.client.get("/webhooks/whatsapp", params={
            "hub.mode": "subscribe", "hub.verify_token": "wrong", "hub.challenge": "1"})
        assert r.status_code == 403

    async def test_signed_status_is_applied_once(self, env):
        cid = await _start(env)
        await drain(env)
        wamid = (await _get(env, cid)).wa_message_id
        body = json.dumps({"entry": [{"changes": [{"value": {"statuses": [
            {"id": wamid, "status": "delivered", "timestamp": "1"}]}}]}]}).encode()
        r = await env.client.post("/webhooks/whatsapp", content=body,
                                  headers={"X-Hub-Signature-256": _sig(body)})
        assert r.status_code == 200 and r.json()["applied"] == 1
        assert (await _get(env, cid)).status == "delivered"
        r = await env.client.post("/webhooks/whatsapp", content=body,
                                  headers={"X-Hub-Signature-256": _sig(body)})
        assert r.status_code == 200
        async with env.factory() as db:
            from app.domain.entities.auth2_entities import OtpEvent

            n = (await db.execute(select(func.count()).select_from(OtpEvent).where(
                OtpEvent.kind == "wa_webhook_delivered"))).scalar()
        assert n == 1

    async def test_bad_signature_rejected(self, env):
        body = b'{"entry": []}'
        r = await env.client.post("/webhooks/whatsapp", content=body,
                                  headers={"X-Hub-Signature-256": _sig(body, "other")})
        assert r.status_code == 401
        r = await env.client.post("/webhooks/whatsapp", content=body)
        assert r.status_code == 401

    async def test_failed_webhook_then_sms_callback(self, env):
        cid = await _start(env)
        await drain(env)
        wamid = (await _get(env, cid)).wa_message_id
        body = json.dumps({"entry": [{"changes": [{"value": {"statuses": [
            {"id": wamid, "status": "failed", "errors": [{"code": 131026}]}]}}]}]}).encode()
        r = await env.client.post("/webhooks/whatsapp", content=body,
                                  headers={"X-Hub-Signature-256": _sig(body)})
        assert r.status_code == 200
        await drain(env)
        assert len(env.sms.sent) == 1
        url = env.sms.sent[0]["callback_url"]
        path = url.split("/api/v1", 1)[1]
        r = await env.client.post(path, json={"messageId": "x", "status": "DELIVERED"})
        assert r.status_code == 200, r.text
        assert (await _get(env, cid)).status == "delivered"
        token = path.rsplit("/", 1)[1]
        forged = token.split(".")[0] + "." + sign_token("other", "x")
        r = await env.client.post(f"/webhooks/smsto/{forged}", json={"status": "DELIVERED"})
        assert r.status_code == 404
