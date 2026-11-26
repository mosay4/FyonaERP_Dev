"""Message providers for OTP delivery.

``MessageProvider`` is the abstraction; ``WhatsAppCloudProvider`` and
``SmsToProvider`` are the implementations; ``registry`` maps a channel to its
provider (tests or future providers call :func:`register`).

Providers never log codes, tokens or full phone numbers.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Protocol

from app.core import outbound_http
from app.core.config import settings
from app.core.logging import get_logger

from .secrets_box import mask_e164

logger = get_logger("otp_providers")


@dataclass
class SendResult:
    ok: bool
    message_id: Optional[str] = None
    error_code: Optional[str] = None
    error_title: Optional[str] = None
    permanent: bool = False
    cost_usd: Optional[float] = None


class MessageProvider(Protocol):
    name: str
    channel: str

    def configured(self) -> bool: ...

    async def send_code(self, *, to_e164: str, code: str, locale: str,
                        callback_url: Optional[str] = None) -> SendResult: ...


# ── Meta error classification ──
# Permanent for THIS recipient/message: retrying WhatsApp is pointless; the
# SMS fallback rules decide what happens next.
META_PERMANENT = frozenset({
    100,      # invalid parameter (e.g. malformed number)
    131008,   # required parameter missing
    131009,   # parameter value invalid
    131021,   # recipient cannot be sender
    131026,   # message undeliverable (not on WhatsApp / old app / ToS)
    131030,   # recipient not in allowed list (test number)
    131031,   # business account locked
    131037,   # display name not approved
    131042,   # payment issue
    131045,   # certificate / registration issue
    131047,   # re-engagement window
    131049,   # not delivered to maintain ecosystem engagement
    131050,   # user stopped messages
    131051,   # unsupported message type
    131053,   # media upload error
    132000,   # template param count mismatch
    132001,   # template does not exist (or not approved for language)
    132005,   # translated text too long
    132007,   # template format policy
    132012,   # template parameter format mismatch
    132015,   # template paused
    132016,   # template disabled
    133010,   # sender phone number not registered
    130497,   # country restricted
    190,      # access token expired / invalid
    10, 200,  # permission errors
    368,      # temporarily blocked for policy violations
    470,
})
# Transient: retried on WhatsApp within the delivery window.
META_TEMPORARY = frozenset({
    1, 2, 4, 17, 341, 80007,
    130429,   # rate limit hit
    131000,   # something went wrong
    131016,   # service unavailable
    131048,   # spam rate limit
    131056,   # pair rate limit
    133004,   # server temporarily unavailable
})

# The ONLY permanent failures that justify an SMS: about this recipient (not
# on WhatsApp / not reachable there). Everything else permanent is our setup
# (template not approved, token, permissions, account, number, budget...):
# an SMS would just burn credit on a Meta misconfiguration.
META_RECIPIENT = frozenset({
    131026,   # undeliverable: not on WhatsApp / old app
    131049,   # not delivered (ecosystem engagement)
    131050,   # user stopped messages from this business
    130497,   # business may not message users in this country
})


def sms_fallback_allowed(error_code: Optional[str]) -> bool:
    """May a WhatsApp failure with [error_code] lead to an SMS?

    None (silent timeout, receipts proven), recipient errors and transient
    outages (Meta down / rate limited, retries exhausted) -> yes. Setup and
    configuration errors -> never."""
    if error_code is None:
        return True
    raw = str(error_code)
    if raw.startswith("transport_") or raw == "no_message_id":
        return True
    if raw.startswith("http_"):
        try:
            status = int(raw[5:])
        except ValueError:
            return False
        return status >= 500 or status == 429
    try:
        num = int(raw)
    except ValueError:
        return False  # not_configured, budget_exceeded, ...
    return num in META_RECIPIENT or num in META_TEMPORARY


def classify_meta_error(code: Optional[int], http_status: Optional[int] = None) -> bool:
    """True when the Meta error is permanent for this message."""
    if code is not None:
        if code in META_PERMANENT:
            return True
        if code in META_TEMPORARY:
            return False
    if http_status is not None:
        if http_status >= 500 or http_status == 429:
            return False
        if 400 <= http_status < 500:
            return True
    return False


def wa_language(locale: str) -> str:
    return (settings.WHATSAPP_TEMPLATE_LANG_EN if (locale or "").lower().startswith("en")
            else settings.WHATSAPP_TEMPLATE_LANG_AR)


class WhatsAppCloudProvider:
    name = "whatsapp_cloud"
    channel = "whatsapp"

    def configured(self) -> bool:
        return bool(settings.WHATSAPP_ACCESS_TOKEN and settings.WHATSAPP_PHONE_NUMBER_ID)

    @staticmethod
    def build_payload(to_e164: str, code: str, locale: str) -> dict:
        """Authentication template: code as body param + COPY_CODE button
        param (Meta models the copy-code button as sub_type 'url')."""
        return {
            "messaging_product": "whatsapp",
            "recipient_type": "individual",
            "to": to_e164.lstrip("+"),
            "type": "template",
            "template": {
                "name": settings.WHATSAPP_TEMPLATE_NAME,
                "language": {"code": wa_language(locale)},
                "components": [
                    {"type": "body", "parameters": [{"type": "text", "text": code}]},
                    {"type": "button", "sub_type": "url", "index": "0",
                     "parameters": [{"type": "text", "text": code}]},
                ],
            },
        }

    def _url(self) -> str:
        base = settings.WHATSAPP_GRAPH_BASE_URL.rstrip("/")
        return f"{base}/{settings.WHATSAPP_GRAPH_VERSION}/{settings.WHATSAPP_PHONE_NUMBER_ID}/messages"

    async def send_code(self, *, to_e164: str, code: str, locale: str,
                        callback_url: Optional[str] = None) -> SendResult:
        if not self.configured():
            return SendResult(ok=False, error_code="not_configured", permanent=True)
        try:
            resp = await outbound_http.request(
                "POST", self._url(), idempotent=False, label="whatsapp",
                headers={"Authorization": f"Bearer {settings.WHATSAPP_ACCESS_TOKEN}"},
                json=self.build_payload(to_e164, code, locale),
            )
        except outbound_http.OutboundError as exc:
            # "unconfirmed" (read timeout) may have been sent: never retried
            # on WhatsApp; the deadline/fallback rules take over.
            return SendResult(ok=False, error_code=f"transport_{exc.kind}",
                              permanent=exc.kind == "unconfirmed")
        try:
            data = resp.json()
        except ValueError:
            data = {}
        if resp.status_code == 200:
            messages = (data or {}).get("messages") or []
            wamid = messages[0].get("id") if messages and isinstance(messages[0], dict) else None
            if wamid:
                logger.info("whatsapp_accepted", to=mask_e164(to_e164))
                return SendResult(ok=True, message_id=str(wamid))
            return SendResult(ok=False, error_code="no_message_id", permanent=False)
        err = (data or {}).get("error") or {}
        code_num = err.get("code")
        try:
            code_num = int(code_num) if code_num is not None else None
        except (TypeError, ValueError):
            code_num = None
        permanent = classify_meta_error(code_num, resp.status_code)
        logger.warning("whatsapp_send_failed", to=mask_e164(to_e164),
                       http=resp.status_code, error_code=code_num, permanent=permanent)
        return SendResult(ok=False, error_code=str(code_num or f"http_{resp.status_code}"),
                          error_title=str(err.get("title") or err.get("message") or "")[:200],
                          permanent=permanent)


def sms_text(code: str, locale: str) -> str:
    # Short single-part texts (Arabic is UCS-2: 70 chars per part).
    if (locale or "").lower().startswith("en"):
        text = f"FYONA code: {code}. Do not share it. Valid 5 min."
    else:
        text = f"FYONA: رمز التحقق {code}. لا تشاركه مع أحد."
    if settings.SMS_ANDROID_APP_HASH:
        text = f"{text}\n{settings.SMS_ANDROID_APP_HASH}"
    return text


class SmsToProvider:
    name = "smsto"
    channel = "sms"

    def configured(self) -> bool:
        return bool(settings.SMS_TO_API_KEY)

    @staticmethod
    def build_payload(to_e164: str, code: str, locale: str,
                      callback_url: Optional[str] = None) -> dict:
        payload = {"message": sms_text(code, locale), "to": to_e164}
        if settings.SMS_SENDER_ID:
            payload["sender_id"] = settings.SMS_SENDER_ID
        if callback_url:
            payload["callback_url"] = callback_url
        return payload

    async def send_code(self, *, to_e164: str, code: str, locale: str,
                        callback_url: Optional[str] = None) -> SendResult:
        if not self.configured():
            return SendResult(ok=False, error_code="not_configured", permanent=True)
        try:
            resp = await outbound_http.request(
                "POST", f"{settings.SMS_TO_BASE_URL.rstrip('/')}/sms/send",
                idempotent=False, label="smsto",
                headers={"Authorization": f"Bearer {settings.SMS_TO_API_KEY}",
                         "Accept": "application/json"},
                json=self.build_payload(to_e164, code, locale, callback_url),
            )
        except outbound_http.OutboundError as exc:
            return SendResult(ok=False, error_code=f"transport_{exc.kind}", permanent=True)
        try:
            data = resp.json()
        except ValueError:
            data = {}
        data = data if isinstance(data, dict) else {}
        nested = data.get("data") if isinstance(data.get("data"), dict) else {}
        message_id = (data.get("message_id") or data.get("messageId")
                      or nested.get("message_id") or nested.get("messageId"))
        if 200 <= resp.status_code < 300 and data.get("success", True) is not False and message_id:
            cost = data.get("cost") or data.get("price") or data.get("estimated_cost")
            try:
                cost_f = float(cost) if cost is not None else None
            except (TypeError, ValueError):
                cost_f = None
            logger.info("sms_accepted", to=mask_e164(to_e164))
            return SendResult(ok=True, message_id=str(message_id), cost_usd=cost_f)
        logger.warning("sms_send_failed", to=mask_e164(to_e164), http=resp.status_code)
        return SendResult(ok=False, error_code=f"http_{resp.status_code}",
                          error_title=str(data.get("message") or "")[:200], permanent=True)


# ── Registry ──
_REGISTRY: dict[str, MessageProvider] = {}


def register(provider: MessageProvider) -> None:
    _REGISTRY[provider.channel] = provider


def get(channel: str) -> Optional[MessageProvider]:
    return _REGISTRY.get(channel)


def reset_defaults() -> None:
    _REGISTRY.clear()
    register(WhatsAppCloudProvider())
    register(SmsToProvider())


reset_defaults()
