"""Per-request Business organization context.

A signed branch-scope token may point at a company the user was invited to.
While handling Business APIs, dependencies publish that target organization
here so permission checks evaluate the user's live branch membership instead
of their Personal organization's role.
"""

from contextvars import ContextVar
from typing import Optional
from uuid import UUID

_active_business_org: ContextVar[Optional[UUID]] = ContextVar(
    "active_business_org", default=None)


def set_active_business_org(org_id: Optional[UUID]) -> None:
    _active_business_org.set(UUID(str(org_id)) if org_id else None)


def get_active_business_org() -> Optional[UUID]:
    return _active_business_org.get()


BUSINESS_PATH_PREFIXES = (
    "/api/v1/business", "/api/v1/branches", "/api/v1/invoices",
    "/api/v1/finance", "/api/v1/accounting", "/api/v1/reconciliation",
    "/api/v1/business-reports", "/api/v1/sales", "/api/v1/purchases",
    "/api/v1/reports", "/api/v1/banking",
    # Business routers mounted at the API root.
    "/api/v1/customers", "/api/v1/suppliers", "/api/v1/products",
    "/api/v1/categories", "/api/v1/inventory", "/api/v1/returns",
    "/api/v1/payments", "/api/v1/cheques", "/api/v1/expenses",
    "/api/v1/merchant-links",
    "/api/v1/business-sara",
)


def is_business_path(path: str) -> bool:
    if (path or '').startswith('/api/v1/employees'):
        return not any((path or '').startswith(prefix) for prefix in (
            '/api/v1/employees/me', '/api/v1/employees/invitations')) and not (path or '').endswith('/unlink')
    return any((path or "").startswith(p) for p in BUSINESS_PATH_PREFIXES)
