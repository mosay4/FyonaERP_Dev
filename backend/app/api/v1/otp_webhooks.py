"""Delivery-receipt webhooks for the OTP engine.

* GET  /webhooks/whatsapp — Meta verification (hub.challenge echo when
  hub.verify_token matches WHATSAPP_VERIFY_TOKEN, constant time).
* POST /webhooks/whatsapp — X-Hub-Signature-256 = HMAC-SHA256(app secret,
  raw body); secret = META_WEBHOOK_APP_SECRET only (the app the WABA is
  subscribed to). Status receipts are applied idempotently.
* POST /webhooks/smsto/{token} — per-message callback URL; ``token`` =
  ``<delivery_id>.<HMAC(delivery_id)>`` (SMS.to has no global secret).
  Parsing is tolerant (JSON or form; several field spellings).
"""

from __future__ import annotations

import hashlib
import hmac
import json
from typing import Optional
from urllib.parse import parse_qs

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse, PlainTextResponse
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.core.database import get_db
from app.core.logging import get_logger
from app.domain.services.otp import engine
from app.domain.services.otp.secrets_box import check_token

router = APIRouter(tags=["Webhooks"])
logger = get_logger("otp_webhooks")
MAX_BODY = 512 * 1024


def _webhook_secret() -> Optional[str]:
    return settings.META_WEBHOOK_APP_SECRET


def valid_meta_signature(raw: bytes, header: Optional[str], secret: Optional[str]) -> bool:
    if not secret or not header or not header.startswith("sha256="):
        return False
    expected = hmac.new(secret.encode("utf-8"), raw, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header[len("sha256="):].strip().lower())


@router.get("/webhooks/whatsapp")
async def whatsapp_verify(request: Request):
    q = request.query_params
    token = q.get("hub.verify_token") or ""
    configured = settings.WHATSAPP_VERIFY_TOKEN or ""
    if (q.get("hub.mode") == "subscribe" and configured
            and hmac.compare_digest(token.encode(), configured.encode())):
        return PlainTextResponse(q.get("hub.challenge") or "")
    return PlainTextResponse("forbidden", status_code=403)


def iter_whatsapp_statuses(payload: dict):
    for entry in (payload or {}).get("entry") or []:
        for change in (entry or {}).get("changes") or []:
            value = (change or {}).get("value") or {}
            for st in value.get("statuses") or []:
                if not isinstance(st, dict) or not st.get("id") or not st.get("status"):
                    continue
                errors = st.get("errors") or []
                code = None
                if errors and isinstance(errors[0], dict) and errors[0].get("code") is not None:
                    code = str(errors[0].get("code"))
                yield str(st["id"]), str(st["status"]), code, str(st.get("timestamp") or "")


@router.post("/webhooks/whatsapp")
async def whatsapp_events(request: Request, db: AsyncSession = Depends(get_db)):
    raw = await request.body()
    if len(raw) > MAX_BODY:
        return JSONResponse({"ok": False}, status_code=413)
    if not valid_meta_signature(raw, request.headers.get("X-Hub-Signature-256"),
                                _webhook_secret()):
        logger.warning("whatsapp_webhook_bad_signature")
        return JSONResponse({"ok": False}, status_code=401)
    try:
        payload = json.loads(raw.decode("utf-8") or "{}")
    except ValueError:
        return JSONResponse({"ok": False}, status_code=400)
    to_process = []
    applied = 0
    for message_id, status, code, _ts in iter_whatsapp_statuses(payload):
        cid = await engine.apply_whatsapp_status(
            db, message_id=message_id, status=status, error_code=code)
        applied += 1
        engine.note_receipt()  # a real message status from Meta: receipts flow
        if cid is not None:
            to_process.append(cid)
    await db.commit()
    for cid in to_process:
        engine.kick(cid)
    return {"ok": True, "applied": applied}


def _first(data: dict, *names) -> Optional[str]:
    for name in names:
        value = data.get(name)
        if isinstance(value, list):
            value = value[0] if value else None
        if value not in (None, ""):
            return str(value)
    return None


@router.post("/webhooks/smsto/{token}")
async def smsto_callback(token: str, request: Request, db: AsyncSession = Depends(get_db)):
    delivery_id, _, sig = token.partition(".")
    if not delivery_id or not sig or not check_token("smsto", delivery_id, sig):
        return JSONResponse({"ok": False}, status_code=404)
    raw = await request.body()
    if len(raw) > MAX_BODY:
        return JSONResponse({"ok": False}, status_code=413)
    data: dict = {}
    try:
        parsed = json.loads(raw.decode("utf-8") or "{}")
        data = parsed if isinstance(parsed, dict) else {}
        if isinstance(data.get("data"), dict):
            data = {**data["data"], **{k: v for k, v in data.items() if k != "data"}}
    except ValueError:
        data = {k: v for k, v in parse_qs(raw.decode("utf-8", "ignore")).items()}
    data.update({k: v for k, v in request.query_params.items() if k not in data})
    status = _first(data, "status", "state", "delivery_status", "deliveryStatus", "dlr_status")
    if not status:
        return {"ok": True, "applied": 0}
    error = _first(data, "error_code", "errorCode", "error", "reason")
    try:
        await engine.apply_sms_status(db, delivery_id=delivery_id, status=status,
                                      error_code=error and error[:40])
    except ValueError:
        return JSONResponse({"ok": False}, status_code=404)
    await db.commit()
    return {"ok": True, "applied": 1}
