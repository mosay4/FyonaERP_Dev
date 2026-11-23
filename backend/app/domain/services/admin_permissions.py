"""Platform-admin permission catalog and helpers.

Platform admins are identified by the `is_platform_admin` flag on `users`.
Their granular access is stored as rows in `admin_permissions`
(user_id, resource, can_create, can_read, can_update, can_delete).

A platform admin with no explicit rows keeps full access (legacy admins
created before this feature). Granting any row restricts access to the
granted resources/actions; a row with resource `"*"` means full access.
"""

from typing import List, Set, Optional

ADMIN_PERMISSIONS: dict[str, list[str]] = {
    "dashboard": ["read"],
    "plans": ["create", "read", "update", "delete"],
    "subscription_requests": ["read", "update"],
    "accounting": ["create", "read", "update", "delete"],
    "api_keys": ["create", "read", "update", "delete"],
    "notifications": ["create", "read"],
    "trash": ["read", "update", "delete"],
    "export": ["read"],
    "organizations": ["create", "read", "update", "delete"],
    "settings": ["read", "update"],
    "admin_settings": ["read", "update"],
    "admin_controls": ["read", "update"],
    "currencies": ["create", "read", "update", "delete"],
    "banners": ["create", "read", "update", "delete"],
    "admin_users": ["create", "read", "update", "delete"],
    "admin_roles": ["create", "read", "update", "delete"],
    "branches": ["create", "read", "update", "delete"],
    "modules": ["read", "update"],
    "audit": ["read"],
    "email": ["read", "update"],
    "backups": ["create", "read", "update", "delete"],
    "maintenance": ["read", "update"],
    "health": ["read"],
    "system": ["read"],
    "admin_permissions": ["read", "update"],
    "exchange_rates": ["create", "read", "update", "delete"],
    "personal_finance": ["read", "update", "delete"],
    "suggestions": ["read", "update"],
}

ADMIN_ACTIONS = ("create", "read", "update", "delete")
ACTION_KEYS = {"create", "read", "update", "delete"}


def all_admin_permission_codes() -> List[str]:
    """All `resource:action` codes in the catalog (used for full access)."""
    return [
        f"{resource}:{action}"
        for resource, actions in ADMIN_PERMISSIONS.items()
        for action in actions
    ]


def admin_permission_codes(permission_rows) -> List[str]:
    """Expand AdminPermission rows into sorted `resource:action` codes.

    A row with resource `"*"` grants every catalog action.
    """
    codes: Set[str] = set()
    for perm in permission_rows:
        resource = perm.resource
        if resource == "*":
            codes.update(all_admin_permission_codes())
            continue
        for action in ADMIN_ACTIONS:
            if getattr(perm, f"can_{action}", False):
                codes.add(f"{resource}:{action}")
    return sorted(codes)


def permission_codes_to_rows(codes: List[str]) -> List[dict]:
    """Convert `resource:action` codes back into AdminPermission row dicts."""
    rows: dict[str, set[str]] = {}
    for code in codes:
        if ":" not in code:
            continue
        resource, action = code.split(":", 1)
        if action in ACTION_KEYS:
            rows.setdefault(resource, set()).add(action)
    return [
        {
            "resource": resource,
            "can_create": "create" in actions,
            "can_read": "read" in actions,
            "can_update": "update" in actions,
            "can_delete": "delete" in actions,
        }
        for resource, actions in rows.items()
    ]


def is_valid_admin_permission(resource: str, action: str) -> bool:
    return action in ACTION_KEYS and (
        resource == "*" or resource in ADMIN_PERMISSIONS
    )
