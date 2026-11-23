# -*- coding: utf-8 -*-
"""Automatic Telegram alerting for FYONA backend system warnings & errors.

- Reads TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID from the server `.env`.
- Sends only to Telegram — nothing else.
- Auto-discovers the chat id on first use (if TELEGRAM_CHAT_ID is empty) by
  polling getUpdates once and binding the most recent chat, so it works with a
  fresh bot without extra setup.
- All failures are silent (never raise into the request path).
"""
import asyncio
import logging

import httpx

logger = logging.getLogger(__name__)

from app.core.config import settings  # noqa: E402

_BOT_TOKEN: str = ""
_CHAT_ID: str = ""
_RESOLVED = False


def _load() -> None:
    global _BOT_TOKEN, _CHAT_ID, _RESOLVED
    _BOT_TOKEN = (settings.TELEGRAM_BOT_TOKEN or "").strip()
    _CHAT_ID = (settings.TELEGRAM_CHAT_ID or "").strip()
    _RESOLVED = bool(_CHAT_ID)


async def _discover_chat_id() -> str:
    """Fetch the most recent chat id from getUpdates (binds the admin's DM)."""
    try:
        async with httpx.AsyncClient(timeout=8) as client:
            r = await client.get(
                f"https://api.telegram.org/bot{_BOT_TOKEN}/getUpdates",
                params={"limit": 5, "timeout": 2},
            )
            data = r.json()
            results = data.get("result") or []
            if not results:
                return ""
            last = results[-1].get("message") or results[-1].get("edited_message") or {}
            return str(last.get("chat", {}).get("id", ""))
    except Exception as exc:  # pragma: no cover
        logger.debug("telegram discover failed: %s", exc)
        return ""


async def send_alert(title: str, detail: str, *, component: str = "system") -> bool:
    """Send a formatted Arabic alert to the Telegram bot.

    Never raises. Returns True on success.
    """
    global _CHAT_ID, _RESOLVED
    try:
        _load()
        if not _BOT_TOKEN:
            return False
        if not _CHAT_ID:
            _CHAT_ID = await _discover_chat_id()
            if not _CHAT_ID:
                return False
            _RESOLVED = True

        text = (
            "\U0001F6A8 *FYONA — تنبيه النظام*\n"
            f"المكوّن: `{component}`\n"
            f"العنوان: {title}\n\n"
            f"التفاصيل:\n{detail}\n\n"
            f"_للحل: راجع سجلات الخادم أو أعد تشغيل الخدمة إن لزم._"
        )
        # Telegram markdown is safe here; the payload is server-generated.
        await asyncio.to_thread(
            lambda: httpx.post(
                f"https://api.telegram.org/bot{_BOT_TOKEN}/sendMessage",
                json={"chat_id": _CHAT_ID, "text": text, "parse_mode": "Markdown"},
                timeout=10,
            )
        )
        return True
    except Exception as exc:  # pragma: no cover
        logger.debug("telegram alert failed: %s", exc)
        return False


async def alert_exception(exc: Exception, *, component: str = "system") -> bool:
    """Shortcut: send an exception's message + type to Telegram."""
    return await send_alert(
        f"حدث خطأ غير متوقع ({exc.__class__.__name__})",
        _sanitize(str(exc)),
        component=component,
    )


def _sanitize(text: str) -> str:
    return (text or "")[:3000].replace("\n", " ")