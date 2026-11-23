"""Diagnostic endpoints for email deliverability troubleshooting.

These endpoints are intentionally lightweight dev tooling: they exercise the
real SMTP path and return the precise outcome (per-step SMTP results, server
response codes, and any exception traceback) so that an "email_sent" log line
can be trusted to mean a genuine SMTP acceptance.
"""

from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, EmailStr
from fastapi.responses import JSONResponse

from app.core.config import settings
from app.core.email_service import diagnose_smtp
from app.core.logging import get_logger

logger = get_logger("debug")

router = APIRouter(tags=["Debug"])


async def _debug_only() -> None:
    """Forbid access to diagnostic endpoints unless running in DEBUG mode.

    These endpoints execute a live SMTP send and return per-step internals
    (tracebacks included), so they must never be reachable in production.
    Returning 404 (not 403) keeps the route indistinguishable from missing.
    """
    if not settings.DEBUG:
        raise HTTPException(status_code=404, detail="Not Found")


class TestEmailRequest(BaseModel):
    to: EmailStr
    subject: Optional[str] = "اختبار SMTP — Fyona ERP"
    text: Optional[str] = "SMTP connectivity test for Fyona ERP."
    html: Optional[str] = "<p>SMTP connectivity test — Fyona ERP</p>"


@router.post("/test-email", response_class=JSONResponse, dependencies=[Depends(_debug_only)])
async def test_email(payload: TestEmailRequest) -> JSONResponse:
    """Perform a live SMTP send to ``payload.to`` and report every step.

    Returns HTTP 200 when the SMTP gateway accepted the message, 502 when any
    step (connect / starttls / login / sendmail) failed. The body always
    contains the masked SMTP configuration and the per-step results, plus the
    exact exception/traceback if one occurred.
    """
    logger.info("debug_test_email_requested", to=payload.to)
    report = await diagnose_smtp(
        payload.to,
        subject=payload.subject,
        html=payload.html,
        text=payload.text,
    )
    status = 200 if report.get("ok") else 502
    return JSONResponse(content=report, status_code=status)
