"""Outbound HTTPS for auth providers (Meta, SMS.to, Google, Apple).

* httpx with ``trust_env=True`` so HTTPS_PROXY / NO_PROXY (the egress proxy)
  are honoured.
* Short timeouts; retries with exponential backoff for TRANSIENT failures
  only. Non-idempotent sends (``idempotent=False``) are retried only when the
  request certainly never left (connect errors) so a message is never sent
  twice by a retry; idempotent calls (JWKS GET, Apple revoke) also retry on
  read timeouts, 429 and 5xx.
* Never logs URLs with secrets, headers or bodies.
"""

from __future__ import annotations

import asyncio
from typing import Any, Optional

import httpx

from app.core.logging import get_logger

logger = get_logger("outbound_http")

DEFAULT_TIMEOUT = httpx.Timeout(8.0, connect=4.0)
_TRANSIENT_STATUS = {429, 500, 502, 503, 504}


class OutboundError(Exception):
    """Transport-level failure after all retries (no HTTP response)."""

    def __init__(self, kind: str, message: str = ""):
        self.kind = kind
        super().__init__(message or kind)


# Tests replace this with an httpx.MockTransport.
_transport: Optional[httpx.AsyncBaseTransport] = None


def set_transport_for_tests(transport: Optional[httpx.AsyncBaseTransport]) -> None:
    global _transport
    _transport = transport


def _client(timeout) -> httpx.AsyncClient:
    if _transport is not None:
        return httpx.AsyncClient(transport=_transport, timeout=timeout)
    return httpx.AsyncClient(timeout=timeout, trust_env=True)


async def request(
    method: str,
    url: str,
    *,
    idempotent: bool,
    retries: int = 2,
    backoff: float = 0.4,
    timeout: Any = DEFAULT_TIMEOUT,
    label: str = "provider",
    **kwargs,
) -> httpx.Response:
    """Send one request with bounded, transient-only retries.

    Returns the final ``httpx.Response`` (any status). Raises
    :class:`OutboundError` when no response could be obtained.
    """
    attempt = 0
    while True:
        try:
            async with _client(timeout) as client:
                resp = await client.request(method, url, **kwargs)
            if idempotent and resp.status_code in _TRANSIENT_STATUS and attempt < retries:
                attempt += 1
                await asyncio.sleep(backoff * (2 ** (attempt - 1)))
                continue
            return resp
        except (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout) as exc:
            kind = "connect"
            err: Exception = exc
        except (httpx.ReadTimeout, httpx.WriteTimeout, httpx.RemoteProtocolError,
                httpx.ReadError, httpx.WriteError) as exc:
            if not idempotent:
                logger.warning("outbound_unconfirmed", label=label, error=type(exc).__name__)
                raise OutboundError("unconfirmed", type(exc).__name__) from exc
            kind = "read"
            err = exc
        except httpx.HTTPError as exc:
            logger.warning("outbound_failed", label=label, error=type(exc).__name__)
            raise OutboundError("http", type(exc).__name__) from exc
        if attempt >= retries:
            logger.warning("outbound_gave_up", label=label, kind=kind, error=type(err).__name__)
            raise OutboundError(kind, type(err).__name__) from err
        attempt += 1
        await asyncio.sleep(backoff * (2 ** (attempt - 1)))
