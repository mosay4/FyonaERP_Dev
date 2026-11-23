"""All-branches view is read-only, including older signed write hints.

Permissions and explicit write targets remain validated by route dependencies.
An unsigned header never grants write access.
"""
from typing import Tuple

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

from starlette.requests import Request

MESSAGE = ("لا يمكنك تنفيذ العمليات أثناء عرض جميع الفروع. "
           "يرجى الانتقال إلى الفرع المطلوب لتنفيذ العملية.")

# Auth/session/plan/push/upload endpoints are not branch data mutations.
ALLOWED_PREFIXES: Tuple[str, ...] = (
    "/health", "/version",
    "/api/v1/auth", "/api/v1/subscription", "/api/v1/admin",
    "/api/v1/push", "/api/v1/files", "/api/v1/exchange-rates",
)


def token_is_all(token: str | None) -> bool:
    if not token:
        return False
    try:
        from jose import jwt
        from app.core.config import settings
        payload = jwt.decode(token, settings.JWT_SECRET_KEY,
                             algorithms=[settings.JWT_ALGORITHM])
        return payload.get("typ") == "branch_scope" and payload.get("mode") == "all"
    except Exception:
        return False


def all_branches_blocked(method: str, path: str, scope_header: str | None,
                          scope_token: str | None = None) -> bool:
    if (scope_header or "").strip().lower() != "all" and not token_is_all(scope_token):
        return False
    if method.upper() in ("GET", "HEAD", "OPTIONS"):
        return False
    if path.rstrip('/') in ('/api/v1/inventory/falcon/analyze', '/api/v1/inventory/falcon/chat'):
        return False  # Analysis/chat read the signed scope; neither mutates inventory.
    if path.rstrip('/') in ('/api/v1/business-sara/query', '/api/v1/business-sara/query-attachment'):
        return False  # Tool preparation and execution enforce read-only separately.
    if not path.startswith("/api/v1"):
        return False
    # Leaving «all branches» must always be possible: selecting a concrete
    # branch is a context switch, not a business-data mutation.
    if path.rstrip("/") == "/api/v1/branches/select":
        return False
    # BLOCK ONLY BUSINESS DATA. Personal sync/chat/notifications/banners and
    # other app infrastructure must keep working while viewing all branches;
    # treating every /api/v1 write as business caused constant 409s and the
    # read-only dialog to appear on refresh.
    from app.core.business_context import is_business_path
    return is_business_path(path)


class AllBranchesReadOnlyMiddleware:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        headers = {k.lower(): v for k, v in scope.get("headers", [])}
        raw = headers.get(b"x-branch-scope")
        value = raw.decode("utf-8", "ignore") if raw else None
        raw_token = headers.get(b"x-branch-token")
        token = raw_token.decode("utf-8", "ignore") if raw_token else None
        path = scope.get("path", "")
        if all_branches_blocked(scope.get("method", "GET"), path, value, token):
            await Request(scope, receive).body()
            response = JSONResponse(
                status_code=409,
                content={"success": False, "message": MESSAGE},
            )
            await response(scope, receive, send)
            return
        await self.app(scope, receive, send)
