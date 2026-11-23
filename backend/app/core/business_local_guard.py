"""The server never stores Business data of a device-ledger business.

Business records of a local-mode organization live on its devices and travel
only through the relays (/business-relay, /peer-relay). Any REST write to the
legacy Business stores for such a business is refused, so no old screen or
older app version can put data on the server by mistake.

Still allowed: the relays, linking parties/employees (identity and consent),
branch names, employee identity/permissions, auth, subscription, chat.
"""

from __future__ import annotations

import re
from uuid import UUID

from fastapi.responses import JSONResponse

_WRITES = ("POST", "PUT", "PATCH", "DELETE")
_LEDGER_PREFIXES = (
    "/api/v1/invoices", "/api/v1/sales", "/api/v1/purchases", "/api/v1/products",
    "/api/v1/categories", "/api/v1/banking", "/api/v1/banks", "/api/v1/inventory",
    "/api/v1/returns", "/api/v1/expenses", "/api/v1/finance", "/api/v1/accounting",
    "/api/v1/reconciliation", "/api/v1/hr", "/api/v1/debts", "/api/v1/customers",
    "/api/v1/suppliers",
)
# Employee money is ledger data; the employee record itself is identity.
_EMPLOYEE_MONEY = re.compile(r"^/api/v1/employees/[^/]+/(salary|debts)$")


def _is_ledger_write(method: str, path: str) -> bool:
    if method not in _WRITES:
        return False
    path = path.rstrip("/")
    if path.startswith("/api/v1/invoices/designs"):
        return False  # the invoice's appearance, not Business data
    return path.startswith(_LEDGER_PREFIXES) or bool(_EMPLOYEE_MONEY.match(path))


async def _organization_is_local(request) -> bool:
    from app.core.database import async_session_factory
    from app.core.security import decode_token
    from app.core import business_local_mode

    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return False
    try:
        claims = decode_token(auth[7:]) or {}
        org = UUID(str(claims.get("org")))
    except Exception:
        return False
    async with async_session_factory() as db:
        return await business_local_mode.organization_enabled(db, org)


async def guard(request, call_next):
    if _is_ledger_write(request.method, request.url.path):
        from app.domain.services.branch_service import decode_scope_token

        scope = decode_scope_token(request.headers.get("X-Branch-Token")) or {}
        if scope.get("qa_business_ledger") is True or (
            not scope and await _organization_is_local(request)
        ):
            return JSONResponse(
                {"detail": "بيانات الأعمال تُحفظ على أجهزتك فقط"},
                status_code=403,
            )
    return await call_next(request)
