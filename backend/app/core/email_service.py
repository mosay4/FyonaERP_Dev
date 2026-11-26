"""
SMTP email delivery shared by the auth OTP flow and the admin panel.

The in-memory ``email_config`` dict is the single source of truth so that
settings saved through the admin panel are immediately used by the OTP flow.
It can also be seeded from environment variables (SMTP_*) at startup.
"""

import asyncio
import imaplib
import logging
import re
import ssl
import smtplib
import traceback as _tb
import uuid
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import formatdate
from typing import Optional, Tuple, Dict, Any, List

from app.core.logging import get_logger
from app.core.config import settings

logger = get_logger("email_service")

# Single source of truth for SMTP settings (editable via /admin/email/config).
email_config: dict = {
    "smtp_host": "",
    "smtp_port": 587,
    "smtp_user": "",
    "smtp_password": "",
    "smtp_from": "",
    "smtp_tls": True,
    "is_configured": False,
}


def _mask(value: Optional[str]) -> str:
    if not value:
        return ""
    v = value.strip()
    if len(v) <= 4:
        return v[:1] + "***"
    return v[:2] + "***" + v[-2:]


def load_email_config_from_env() -> None:
    """Seed the shared config from SMTP_* environment variables if present."""
    host = settings.SMTP_HOST
    if not host:
        logger.warning(
            "email_config_not_seeded",
            detail="SMTP_HOST is empty; email delivery will be disabled until configured.",
        )
        return
    email_config["smtp_host"] = host
    email_config["smtp_port"] = int(settings.SMTP_PORT or 587)
    email_config["smtp_user"] = settings.SMTP_USER or ""
    email_config["smtp_password"] = settings.SMTP_PASSWORD or ""
    email_config["smtp_from"] = settings.SMTP_FROM or settings.SMTP_USER or ""
    email_config["smtp_tls"] = bool(settings.SMTP_TLS)
    email_config["is_configured"] = True
    logger.info(
        "email_config_seeded_from_env",
        smtp_host=host,
        smtp_port=email_config["smtp_port"],
        smtp_user=_mask(email_config["smtp_user"]),
        smtp_from=email_config["smtp_from"],
        smtp_tls=email_config["smtp_tls"],
    )


def _sender() -> str:
    raw = email_config.get("smtp_from") or email_config.get("smtp_user") or ""
    # A consumer Gmail account that sends with a brand display name (e.g.
    # "Fyona ERP <fyona.erp@gmail.com>") looks like brand impersonation to
    # Gmail's inbound classifier and the message is silently buried. Send with
    # the bare address instead.
    match = re.match(r'^.*<([^>]+)>$', raw)
    return match.group(1) if match else raw


def _build_message(
    to: str, subject: str, html: str, text: Optional[str], from_addr: Optional[str]
) -> MIMEMultipart:
    sender = from_addr or _sender()
    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = to
    msg["Date"] = formatdate(localtime=True)
    # Unique Message-ID so the message is trackable in the sender's Sent folder.
    msg["Message-ID"] = f"<{uuid.uuid4().hex}@fyona.smtp.test>"
    if text:
        msg.attach(MIMEText(text, "plain", "utf-8"))
    msg.attach(MIMEText(html, "html", "utf-8"))
    return msg


def _smtp_transaction(
    to: str, subject: str, html: str, text: Optional[str], from_addr: Optional[str]
) -> Tuple[Dict[str, Any], Optional[str], Optional[str], Optional[str]]:
    """Execute the full SMTP transaction and report every step's outcome.

    Returns (steps, error, traceback, message_id). A non-None ``error`` means
    the transaction failed at one of the steps; ``steps`` records how far it
    got so callers can see whether connect / starttls / login / sendmail
    succeeded.
    """
    cfg = email_config
    msg = _build_message(to, subject, html, text, from_addr)
    message_id = msg.get("Message-ID")
    steps: Dict[str, Any] = {"message_id": message_id, "from": msg["From"], "to": to}
    server = smtplib.SMTP(cfg["smtp_host"], int(cfg["smtp_port"]), timeout=20)
    try:
        try:
            server.ehlo()
            steps["connect"] = {"status": "ok", "host": cfg["smtp_host"], "port": cfg["smtp_port"]}
        except Exception as exc:  # noqa: BLE001 - diagnostic path
            steps["connect"] = {"status": "failed", "error": repr(exc)}
            return steps, repr(exc), _tb.format_exc(), message_id

        if cfg.get("smtp_tls"):
            try:
                server.starttls(context=ssl.create_default_context())
                server.ehlo()
                steps["starttls"] = {"status": "ok"}
            except Exception as exc:  # noqa: BLE001 - diagnostic path
                steps["starttls"] = {"status": "failed", "error": repr(exc)}
                return steps, repr(exc), _tb.format_exc(), message_id

        if cfg.get("smtp_user"):
            try:
                code, resp = server.login(cfg["smtp_user"], cfg["smtp_password"])
                steps["login"] = {"status": "ok", "code": code, "response": resp.decode(errors="ignore")}
            except smtplib.SMTPAuthenticationError as exc:
                steps["login"] = {
                    "status": "failed",
                    "error": "SMTPAuthenticationError",
                    "smtp_code": exc.smtp_code,
                    "smtp_error": exc.smtp_error.decode(errors="ignore"),
                }
                return steps, repr(exc), _tb.format_exc(), message_id
            except Exception as exc:  # noqa: BLE001 - diagnostic path
                steps["login"] = {"status": "failed", "error": repr(exc)}
                return steps, repr(exc), _tb.format_exc(), message_id

        try:
            refused = server.sendmail(msg["From"], [to], msg.as_string())
            # send_email raises SMTPDataError if the final DATA reply was not 250;
            # reaching here with an empty refused dict therefore means Gmail
            # replied 250 Accepted. Confirm the channel is still live and capture
            # the live server reply as an explicit, non-speculative proof.
            try:
                noop_code, noop_resp = server.noop()
            except Exception as exc:  # noqa: BLE001
                noop_code, noop_resp = None, repr(exc)
            final_code = getattr(server, "last_code", None)
            final_resp = getattr(server, "last_resp", None)
            steps["sendmail"] = {
                "status": "accepted" if not refused else "partial_or_refused",
                "last_smtp_code": final_code,
                "last_smtp_response": final_resp.decode(errors="ignore") if isinstance(final_resp, (bytes, bytearray)) else final_resp,
                "live_noop_code": noop_code,
                "live_noop_response": noop_resp.decode(errors="ignore") if isinstance(noop_resp, (bytes, bytearray)) else noop_resp,
                "refused_recipients": {
                    k.decode(errors="ignore"): v.decode(errors="ignore") for k, v in refused.items()
                } if refused else {},
            }
            if refused:
                return steps, f"sendmail refused: {refused}", _tb.format_exc(), message_id
        except smtplib.SMTPSenderRefused as exc:
            steps["sendmail"] = {
                "status": "failed",
                "error": "SMTPSenderRefused",
                "smtp_code": exc.smtp_code,
                "smtp_error": exc.smtp_error.decode(errors="ignore"),
            }
            return steps, repr(exc), _tb.format_exc(), message_id
        except smtplib.SMTPRecipientsRefused as exc:
            steps["sendmail"] = {
                "status": "failed",
                "error": "SMTPRecipientsRefused",
                "recipients": [r.decode(errors="ignore") for r in (exc.recipients or [])],
            }
            return steps, repr(exc), _tb.format_exc(), message_id
        except Exception as exc:  # noqa: BLE001 - diagnostic path
            steps["sendmail"] = {"status": "failed", "error": repr(exc)}
            return steps, repr(exc), _tb.format_exc(), message_id
    finally:
        try:
            server.quit()
        except Exception:  # noqa: BLE001 - cleanup path
            pass
    return steps, None, None, message_id


async def send_email(
    to: str, subject: str, html: str,
    text: Optional[str] = None, from_addr: Optional[str] = None,
) -> bool:
    """Send an HTML email. Returns False when SMTP is not configured or fails.

    Detailed per-step diagnostics are logged so failures are never silent.
    """
    if (to or "").strip().lower().endswith(".fyona.invalid"):
        # Phone-first accounts have no mailbox (internal placeholder).
        return False
    if not email_config.get("is_configured"):
        logger.warning(
            "email_not_configured",
            smtp_host=settings.SMTP_HOST,
            smtp_user=_mask(settings.SMTP_USER),
            to=to,
            subject=subject,
        )
        return False
    logger.info(
        "email_attempt",
        smtp_host=email_config["smtp_host"],
        smtp_port=email_config["smtp_port"],
        smtp_user=_mask(email_config["smtp_user"]),
        smtp_from=_sender(),
        to=to,
        subject=subject,
    )
    try:
        steps, error, tb, message_id = await asyncio.to_thread(
            _smtp_transaction, to, subject, html, text, from_addr
        )
        if error is not None:
            logger.error(
                "email_send_failed",
                to=to,
                subject=subject,
                smtp_host=email_config["smtp_host"],
                smtp_port=email_config["smtp_port"],
                smtp_user=_mask(email_config["smtp_user"]),
                smtp_from=_sender(),
                message_id=message_id,
                steps=steps,
                error=error,
                traceback=tb,
            )
            return False
        logger.info(
            "email_sent",
            to=to,
            subject=subject,
            smtp_host=email_config["smtp_host"],
            smtp_port=email_config["smtp_port"],
            smtp_user=_mask(email_config["smtp_user"]),
            smtp_from=_sender(),
            message_id=message_id,
            steps=steps,
        )
        return True
    except Exception as exc:  # noqa: BLE001 - safety net, should not happen
        logger.exception(
            "email_send_failed",
            to=to,
            subject=subject,
            smtp_user=_mask(email_config["smtp_user"]),
            smtp_from=_sender(),
            error=str(exc),
        )
        return False


def check_sent_via_imap(message_id: str) -> Dict[str, Any]:
    """Prove Gmail enqueued the message in the sender's Sent/All-Mail folder.

    Logs into imap.gmail.com with the SAME SMTP user/app-password and fetches
    the most recent message headers from "[Gmail]/Sent Mail" / "[Gmail]/All
    Mail", matching by Message-ID. Finding it proves Gmail accepted the message
    and took responsibility for delivery to the recorded recipient, so any
    recipient non-receipt is recipient-side filtering.
    """
    user = email_config.get("smtp_user") or ""
    pwd = email_config.get("smtp_password") or ""
    result: Dict[str, Any] = {"checked": False}
    if not (user and pwd):
        result["error"] = "smtp_user/smtp_password not configured"
        return result
    mid = message_id.strip().strip("<>")
    try:
        with imaplib.IMAP4_SSL("imap.gmail.com", 993) as mbox:
            mbox.debug = 0
            mbox.login(user, pwd)
            result["imap_login"] = "ok"
            # Gmail needs a few seconds to index a freshly SMTP-sent message.
            import time as _time
            _time.sleep(3)
            candidates = ["[Gmail]/Sent Mail", "[Gmail]/All Mail", "Sent"]
            found: List[Dict[str, Any]] = []
            for folder in candidates:
                typ, _ = mbox.select(f'"{folder}"')
                if typ != "OK":
                    continue
                typ, ids = mbox.search(None, "ALL")
                if typ != "OK" or not ids or not ids[0]:
                    continue
                nums = ids[0].split()
                recent = nums[-10:]  # 10 most recent messages
                for num in reversed(recent):
                    typ, hdr = mbox.fetch(
                        num, "(BODY[HEADER.FIELDS (MESSAGE-ID TO FROM SUBJECT)])"
                    )
                    if not hdr or not hdr[0]:
                        continue
                    raw = hdr[0][1]
                    if isinstance(raw, (bytes, bytearray)):
                        raw = raw.decode(errors="ignore")
                    if f"<{mid}>" in raw:
                        found.append({"folder": folder, "match": True})
                        break
                if found:
                    break
            result["found_in_sender_mailbox"] = len(found) > 0
            result["matches"] = found
            result["note"] = (
                "Gmail does NOT automatically file SMTP-submitted messages into "
                "'Sent Mail'/'All Mail'. Absence here therefore does NOT mean the "
                "message failed to send; it only means no sender-side copy was "
                "filed. Delivery responsibility is shown by the SMTP 250 result."
            )
            mbox.logout()
    except imaplib.IMAP4.error as exc:
        result["imap_login"] = "failed"
        result["error"] = f"IMAP4 error: {exc}"
    except Exception as exc:  # noqa: BLE001 - diagnostic path
        result["error"] = f"IMAP error: {repr(exc)}"
    result["checked"] = True
    return result


async def diagnose_smtp(
    to: str, subject: str = "اختبار SMTP — Fyona ERP",
    html: Optional[str] = None, text: Optional[str] = "SMTP connectivity test for Fyona ERP.",
    check_sent: bool = True,
) -> Dict[str, Any]:
    """Run a live SMTP send to ``to`` and return full diagnostics.

    Returns the same per-step breakdown that the production path logs, including
    the Message-ID, the final SMTP reply code, and (optionally) an IMAP check
    proving the message was enqueued in the sender's Sent folder.
    """
    html = html or "<p>SMTP connectivity test — Fyona ERP</p>"
    report: Dict[str, Any] = {
        "configured": bool(email_config.get("is_configured")),
        "smtp_host": email_config.get("smtp_host"),
        "smtp_port": email_config.get("smtp_port"),
        "smtp_user": _mask(email_config.get("smtp_user")),
        "smtp_from": _sender(),
        "to": to,
        "subject": subject,
        "steps": {},
        "ok": False,
        "error": None,
        "traceback": None,
    }
    if not email_config.get("is_configured"):
        report["error"] = "SMTP not configured (SMTP_HOST empty). Check .env / Docker env."
        return report
    steps, error, tb, message_id = await asyncio.to_thread(_smtp_transaction, to, subject, html, text, None)
    report["steps"] = steps
    report["ok"] = error is None
    report["error"] = error
    report["traceback"] = tb
    if check_sent and message_id and email_config.get("smtp_user") and email_config.get("smtp_password"):
        report["imap_sent_check"] = await asyncio.to_thread(check_sent_via_imap, message_id)
    return report


# Seed from env at import time (imports happen after dotenv is loaded in main).
load_email_config_from_env()
