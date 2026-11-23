from typing import Optional, Callable
import hmac
import time
from typing import Optional
from fastapi import Depends, Header, HTTPException, Query, Request, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.ext.asyncio import AsyncSession
from uuid import UUID
from ..core.config import settings
from ..core.database import get_db
from ..core.security import decode_token
from ..infrastructure.repositories.sql_alchemy_auth_repository import (
    SQLAlchemyRoleRepository,
    SQLAlchemyUserRepository,
)

security_scheme = HTTPBearer(auto_error=False)

# ═══════════════════════════════════════════════════════════════════
#  MAINTENANCE (server-side enforcement)
#
#  The mobile app already blocks UI navigation, but the backend is the
#  authority: when a section (application/personal/business) or one of the
#  canonical personal features is under maintenance, non-admin requests to
#  its API surface are rejected with 503. The controls snapshot is cached
#  for ~5s so this adds near-zero overhead to hot paths.
# ═══════════════════════════════════════════════════════════════════
_CONTROLS_CACHE: dict = {"at": 0.0, "data": None}

# API path prefix → canonical personal feature key (kept in sync with the app).
_PERSONAL_FEATURE_PATHS = {
    "/personal/finance/accounts": "personal/banks",
    "/personal/finance/transactions": "personal/transactions",
    "/personal/finance/goals": "personal/savings",
    "/personal/finance/debts": "personal/debts",
    "/personal/finance/budgets": "personal/budget",
    "/personal/ai": "personal/ai",
    "/suggestions": "personal/suggestions",
}


async def _maintenance_snapshot(db) -> dict:
    now = time.monotonic()
    cached = _CONTROLS_CACHE.get("data")
    if cached is not None and now - _CONTROLS_CACHE["at"] < 5.0:
        return cached
    from ..domain.services.admin_settings_service import AdminSettingsService
    try:
        ctrl = await AdminSettingsService(db).get_controls()
    except Exception:
        return cached or {}
    _CONTROLS_CACHE.update(at=now, data=ctrl)
    return ctrl

# ═══════════════════════════════════════════════════════════════════
#  MASTER ADMIN API KEY — single key with FULL admin access.
#
#  Security layers:
#   * The key is read ONLY from the server `.env` (settings.ADMIN_MASTER_KEY).
#   * It is sent over HTTPS in the `X-Admin-Master-Key` header, NEVER in a URL,
#     body or browser storage of the mobile app.
#   * Comparison is CONSTANT-TIME (hmac.compare_digest) to resist timing attacks.
#   * A valid master key resolves to a designated platform-admin DB user
#     (settings.ADMIN_MASTER_EMAIL) so audit columns (reviewed_by, …) stay real.
#   * It grants platform-admin access ONLY to endpoints whose auth dependency
#     opts in (require_admin_perm / the identity deps). Regular user endpoints
#     are unaffected.
# ═══════════════════════════════════════════════════════════════════
_MASTER_HEADER = "X-Admin-Master-Key"


def _master_key_valid(request: Request) -> bool:
    configured = settings.ADMIN_MASTER_KEY or ""
    if not configured:
        return False
    supplied = request.headers.get(_MASTER_HEADER) or ""
    if not supplied:
        return False
    return hmac.compare_digest(supplied.encode("utf-8"), configured.encode("utf-8"))


async def _master_admin_identity(request: Request, db: AsyncSession) -> Optional[UUID]:
    """Resolve the designated platform-admin user behind the master key."""
    if not _master_key_valid(request):
        return None
    from sqlalchemy import select
    from ..domain.entities.auth_entities import User

    email = (settings.ADMIN_MASTER_EMAIL or "").strip().lower()
    if not email:
        return None
    row = await db.execute(select(User).where(User.email.ilike(email)))
    user = row.scalar_one_or_none()
    if not user or not user.is_platform_admin:
        return None
    return user.id


def _parse_token(credentials: Optional[HTTPAuthorizationCredentials]) -> dict:
    if credentials is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated"
        )
    payload = decode_token(credentials.credentials)
    if payload is None or payload.get("type") != "access":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token"
        )
    return payload


async def get_current_session_id(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security_scheme),
) -> Optional[UUID]:
    """The caller's own session id (JWT `sid` claim), or None for legacy
    tokens without one. Used to scope session management (self vs others)."""
    try:
        payload = _parse_token(credentials)
    except HTTPException:
        return None
    sid = payload.get("sid")
    if not sid:
        return None
    try:
        return UUID(str(sid))
    except ValueError:
        return None


async def get_current_user_id(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security_scheme),
    request: Request = None,
    db: AsyncSession = Depends(get_db),
) -> str:
    if request is not None:
        admin_id = await _master_admin_identity(request, db)
        if admin_id is not None:
            return str(admin_id)
    payload = _parse_token(credentials)
    uid = payload.get("sub")
    if not uid:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token claims"
        )
    return uid


async def get_current_org_id(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security_scheme),
    request: Request = None,
    db: AsyncSession = Depends(get_db),
) -> str:
    if request is not None:
        admin_id = await _master_admin_identity(request, db)
        if admin_id is not None:
            # Master-key org: the master admin's own org (identity from DB).
            from sqlalchemy import select
            from ..domain.entities.auth_entities import User
            row = await db.execute(select(User.organization_id).where(User.id == admin_id))
            oid = row.scalar_one_or_none()
            if oid is not None:
                return str(oid)
    payload = _parse_token(credentials)
    oid = payload.get("org")
    # A signed branch-scope token may target a company the user was invited
    # to. It is honoured ONLY on Business APIs and only for the same user;
    # membership and permissions are still verified live per request.
    try:
        from ..core.business_context import (
            is_business_path, set_active_business_org)
        from ..domain.services.branch_service import decode_scope_token
        scope_token = request.headers.get("X-Branch-Token") if request else None
        scope = decode_scope_token(scope_token)
        # Selecting a new company is a control-plane operation. Its endpoint
        # checks the requested target membership; a revoked previous scope must
        # not prevent selecting an unrelated company the caller still owns.
        if request is not None and request.url.path.rstrip('/') == f'{settings.API_PREFIX}/branches/select' and oid:
            set_active_business_org(oid)
            return str(oid)
        if request is not None and is_business_path(request.url.path):
            if scope_token and scope is None:
                from ..domain.services.branch_service import scope_token_state
                expired = scope_token_state(scope_token) == 'expired'
                raise HTTPException(401, detail={
                    'code': 'branch_scope_expired' if expired else 'branch_scope_invalid',
                    'message': 'رمز سياق الفرع منتهي أو غير صالح؛ أعد اختيار الفرع',
                })
            from ..domain.services.branch_access_service import has_company_access
            if scope and str(scope.get('sub')) != str(payload.get('sub')):
                raise HTTPException(403, detail={'code': 'branch_scope_denied',
                    'message': 'رمز سياق الفرع لا يطابق الحساب'})
            target_org = scope.get('org') if scope else oid
            if target_org and not await has_company_access(
                    db, UUID(str(target_org)), UUID(str(payload['sub'])), scope):
                set_active_business_org(None)
                raise HTTPException(403, detail={'code': 'employee_workspace_revoked',
                    'message': 'تم إلغاء ارتباطك بالمتجر ولم يعد لديك صلاحية الدخول'})
            set_active_business_org(target_org)
            if target_org:
                from ..domain.entities.auth_entities import Organization
                from ..domain.services.merchant_subscription_service import require_merchant_subscription
                # Selection/discovery remain available to explain renewal, but
                # every data-plane request uses the merchant's live entitlement.
                if request.url.path.rstrip('/') != f'{settings.API_PREFIX}/branches/access':
                    require_merchant_subscription(await db.get(Organization, UUID(str(target_org))))
                return str(target_org)
        # Personal/other APIs never inherit the Business target org.
        set_active_business_org(oid)
    except HTTPException:
        raise
    except Exception:
        pass
    if not oid:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token claims"
        )
    return oid


async def get_current_role(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security_scheme),
    request: Request = None,
    db: AsyncSession = Depends(get_db),
) -> str:
    if request is not None:
        admin_id = await _master_admin_identity(request, db)
        if admin_id is not None:
            return "admin"
    payload = _parse_token(credentials)
    role = payload.get("role")
    if not role:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token claims"
        )
    return role


async def get_current_org_id_optional(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security_scheme),
    request: Request = None,
    db: AsyncSession = Depends(get_db),
) -> Optional[str]:
    """Like get_current_org_id but returns None when the user has no org claim
    (e.g. personal-mode users)."""
    try:
        return await get_current_org_id(credentials, request, db)
    except HTTPException:
        return None


async def get_current_user_uuid(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security_scheme),
    request: Request = None,
    db: AsyncSession = Depends(get_db),
) -> UUID:
    if request is not None:
        admin_id = await _master_admin_identity(request, db)
        if admin_id is not None:
            return admin_id
    payload = _parse_token(credentials)
    uid_str = payload.get("sub")
    if not uid_str:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token claims"
        )
    try:
        uid = UUID(uid_str)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid user ID format"
        )
    # Instant revocation: reject access tokens issued before a global kick.
    iat = payload.get("iat")
    if iat is not None:
        try:
            from datetime import datetime, timezone

            from sqlalchemy import select

            from ..domain.entities.auth_entities import User

            row = await db.execute(
                select(User.tokens_valid_after).where(User.id == uid)
            )
            tokens_valid_after = row.scalar_one_or_none()
            if isinstance(tokens_valid_after, datetime):
                issued_at = datetime.fromtimestamp(int(iat), tz=timezone.utc)
                if issued_at < tokens_valid_after:
                    raise HTTPException(
                        status_code=status.HTTP_401_UNAUTHORIZED,
                        detail="انتهت صلاحية الجلسة، يرجى تسجيل الدخول مرة أخرى",
                    )
        except HTTPException:
            raise
        except Exception:
            pass  # revocation gate is best-effort; never break auth on it

    # Per-session revocation: if the JWT carries a session_id (sid), verify
    # that the session is still active.  This catches single-session logout
    # where tokens_valid_after is NOT updated.
    session_id = payload.get("sid")
    if session_id:
        try:
            from uuid import UUID as _UUID
            from sqlalchemy import select
            from ..domain.entities.auth_entities import UserSession

            sid = _UUID(session_id)
            row = await db.execute(
                select(UserSession.is_active).where(UserSession.id == sid)
            )
            is_active = row.scalar_one_or_none()
            if is_active is False or is_active is None:
                raise HTTPException(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    detail="تم إنهاء هذه الجلسة، يرجى تسجيل الدخول مرة أخرى",
                )
        except HTTPException:
            raise
        except Exception:
            pass  # best-effort; never break auth on DB errors
    else:
        # Legacy token without session_id: if user has zero active sessions,
        # all sessions were revoked → reject.
        try:
            from sqlalchemy import select, func
            from ..domain.entities.auth_entities import UserSession

            row = await db.execute(
                select(func.count()).select_from(UserSession).where(
                    UserSession.user_id == uid, UserSession.is_active.is_(True)
                )
            )
            active_count = row.scalar() or 0
            if active_count == 0:
                raise HTTPException(
                    status_code=status.HTTP_401_UNAUTHORIZED,
                    detail="جميع الجلسات تم إلغاؤها، يرجى تسجيل الدخول مرة أخرى",
                )
        except HTTPException:
            raise
        except Exception:
            pass

    return uid


async def get_current_user_uuid_optional(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security_scheme),
    request: Request = None,
    db: AsyncSession = Depends(get_db),
) -> Optional[UUID]:
    """Like ``get_current_user_uuid`` but returns ``None`` when the caller has
    no valid credentials (used by routes that are partly public, e.g. serving
    promotional banner media to the unauthenticated mobile home screen)."""
    try:
        return await get_current_user_uuid(credentials, request, db)
    except HTTPException:
        return None


def has_permission(resource: str, action: str) -> Callable:
    """Non-throwing sibling of [require_permission]: returns True/False so an
    endpoint can adapt its payload (e.g. hide cost/profit) instead of 403."""

    async def _checker(
        user_id: UUID = Depends(get_current_user_uuid),
        db: AsyncSession = Depends(get_db),
    ) -> bool:
        try:
            role_repo = SQLAlchemyRoleRepository(db)
            return await role_repo.user_has_permission(user_id, resource, action)
        except Exception:
            return False

    return _checker


def require_permission(resource: str, action: str) -> Callable:
    resource_map = {
        'products': 'inventory', 'sales': 'sales', 'purchases': 'purchases',
        'finance': 'banks', 'banking': 'banks', 'accounting': 'banks', 'customers': 'customers',
        'suppliers': 'suppliers', 'debts': 'debts', 'branches': 'branches',
        'hr': 'employees', 'reports': 'reports',
        'reconciliation': 'reconciliation', 'expenses': 'reports',
        'invoices': 'invoices', 'returns': 'returns',
    }

    async def _checker(
        request: Request,
        user_id: UUID = Depends(get_current_user_uuid),
        db: AsyncSession = Depends(get_db),
    ) -> bool:
        from ..domain.services.employee_access_policy import member_policy, allowed, required_key
        from ..domain.services.branch_service import decode_scope_token
        from ..core.business_context import is_business_path
        scope = decode_scope_token(request.headers.get('X-Branch-Token'))
        if (scope and scope.get('mode') == 'all' and action != 'read'
                and is_business_path(request.url.path)
                and not request.url.path.endswith('/branches/select')):
            raise HTTPException(403, detail={'code': 'branch_read_only',
                'message': 'أنت في وضع عرض جميع الفروع. انتقل إلى فرع محدد لتنفيذ العملية.'})
        policy = await member_policy(db, request, user_id)
        if policy is not None:
            if request.url.path.endswith(('/invoices/issue-sale', '/invoices/issue-purchase')):
                body = await request.json()
                if any(bool(item['new_product'].get('save_to_inventory', True))
                       for item in body.get('items', []) if isinstance(item.get('new_product'), dict)) and not allowed(policy, 'inventory.add'):
                    raise HTTPException(403, detail='لا تملك صلاحية إضافة منتجات للمخزون')
                for name, permission in (('customer_id', 'customers'), ('supplier_id', 'suppliers')):
                    if body.get(name) and not allowed(policy, permission):
                        raise HTTPException(403, detail='لا تملك صلاحية اختيار هذا الطرف')
                if any(item.get('product_id') for item in body.get('items', [])) and not allowed(policy, 'inventory'):
                    raise HTTPException(403, detail='لا تملك صلاحية اختيار منتجات المخزون')
            if resource == 'reports':
                from ..domain.services.employee_access_policy import report_allowed
                if not report_allowed(policy, request.url.path):
                    raise HTTPException(403, detail='لا تملك صلاحية عرض أو تصدير هذا التقرير')
            if resource in ('banking', 'finance', 'accounting') and any(
                    word in request.url.path for word in ('statement', 'export')):
                if not all(allowed(policy, key) for key in (
                        'banks.details', 'banks.balances', 'reports.view', 'reports.export')):
                    raise HTTPException(403, detail='لا تملك صلاحية تصدير كشف الحساب')
            key = required_key(resource, action, request.url.path)
            if resource == 'invoices' and ('/invoices' in request.url.path or '/returns' in request.url.path) and '/designs/' not in request.url.path and '/issue-' not in request.url.path:
                for_return = request.query_params.get('returnable_only', '').lower() in ('true', '1')
                child = 'returns' if '/returns' in request.url.path or for_return else {
                    'read': 'view', 'create': 'create', 'update': 'create', 'delete': 'delete'}[action]
                types = [kind for kind, parent in (('sale', 'sales'), ('purchase', 'purchases'))
                         if allowed(policy, f'{parent}.{child}')]
                kind = request.query_params.get('invoice_type') or request.query_params.get('kind') or request.path_params.get('kind')
                invoice_id = request.path_params.get('invoice_id')
                if invoice_id:
                    from ..domain.entities.invoice_entities import Invoice
                    invoice = await db.get(Invoice, UUID(str(invoice_id)))
                    if invoice is not None:
                        from ..domain.services.branch_service import decode_scope_token
                        from ..domain.entities.auth_entities import User
                        scope = decode_scope_token(request.headers.get('X-Branch-Token'))
                        org = UUID(str(scope['org'])) if scope else (await db.get(User, user_id)).organization_id
                        if invoice.organization_id != org:
                            raise HTTPException(404, detail='الفاتورة غير موجودة')
                        kind = invoice.invoice_type
                elif action == 'create' and request.url.path.rstrip('/').endswith('/invoices'):
                    kind = (await request.json()).get('invoice_type', 'sale')
                if kind in ('sale_return', 'purchase_return'):
                    kind = kind.removesuffix('_return')
                if not types or kind is not None and kind not in types:
                    raise HTTPException(403, detail='لا تملك صلاحية هذه الفواتير')
                request.state.employee_invoice_types = types
                if '/returns' in request.url.path or for_return:
                    if not allowed(policy, 'returns'):
                        raise HTTPException(403, detail='لا تملك صلاحية المرتجعات')
                    key = 'returns'
                elif kind is not None:
                    key = f'{"sales" if kind == "sale" else "purchases"}.{child}'
                else:
                    # The listing endpoint applies this live type filter before
                    # pagination, so a granted type does not disclose another.
                    key = f'{"sales" if types[0] == "sale" else "purchases"}.{child}'
            if resource == 'reconciliation':
                types = [kind for kind in ('bank', 'inventory')
                    if allowed(policy, f'reconciliation.{kind}') and
                    (kind != 'inventory' or allowed(policy, 'inventory.count')) and
                    (kind != 'bank' or allowed(policy, 'banks.balances'))]
                request.state.employee_recon_types = types
                kind = 'bank' if '/bank/' in request.url.path or request.url.path.endswith('/accounts') else (
                    'inventory' if '/inventory/' in request.url.path else request.query_params.get('rtype'))
                record_id = request.path_params.get('recon_id')
                if record_id:
                    from ..domain.entities.reconciliation_entities import Reconciliation
                    from ..domain.entities.auth_entities import User
                    from ..domain.services.branch_service import decode_scope_token
                    from ..domain.services.branch_access_service import can_access_branch
                    record = await db.get(Reconciliation, UUID(str(record_id)))
                    scope = decode_scope_token(request.headers.get('X-Branch-Token'))
                    if record is not None:
                        org = UUID(str(scope['org'])) if scope else (await db.get(User, user_id)).organization_id
                        if record.organization_id != org or (record.branch_id is not None and (
                                not await can_access_branch(db, org, user_id, record.branch_id) or
                                scope and scope.get('mode') != 'all' and
                                str(record.branch_id) != str(scope.get('branch')))):
                            raise HTTPException(404, detail='سجل المطابقة غير موجود')
                        kind = record.rtype
                if not types or kind is not None and kind not in types:
                    raise HTTPException(403, detail='لا تملك صلاحية عرض هذه المطابقة')
            if request.url.path == '/api/v1/business/transactions' and request.query_params.get('kind') in (
                    'income', 'expense', 'income_expense', 'inout'):
                kind = request.query_params['kind']
                keys = ['income', 'expenses'] if kind in ('income_expense', 'inout') else ['expenses' if kind == 'expense' else 'income']
                if any(allowed(policy, key) for key in keys): return True
            if allowed(policy, key):
                return True
            raise HTTPException(403, detail={'code': 'employee_permission_denied',
                'message': 'لا تملك صلاحية تنفيذ هذه العملية'})
        # Validate revocation before owner/RBAC shortcuts, including a merchant
        # using their own owner session to access another merchant's workspace.
        from ..domain.services.branch_service import decode_scope_token
        from ..domain.services.branch_access_service import has_company_access
        scope = decode_scope_token(request.headers.get('X-Branch-Token'))
        if scope and str(scope.get('sub')) == str(user_id) and scope.get('org'):
            if not await has_company_access(db, UUID(str(scope['org'])), user_id, scope):
                raise HTTPException(403, detail={'code': 'employee_workspace_revoked',
                    'message': 'تم إلغاء ارتباطك بالمتجر ولم يعد لديك صلاحية الدخول'})
        role_repo = SQLAlchemyRoleRepository(db)
        if await role_repo.user_has_permission(user_id, resource, action):
            return True
        # An accepted employee membership uses the merchant-defined permission
        # map from the active X-Branch-Token. A disabled parent button denies
        # the request server-side; the UI also removes it.
        try:
            from sqlalchemy import select
            import json
            from ..domain.services.branch_service import decode_scope_token
            from ..domain.entities.branch_entities import BranchMember
            scope = decode_scope_token(request.headers.get('X-Branch-Token'))
            if scope and str(scope.get('sub')) == str(user_id) and scope.get('org'):
                member = (await db.execute(select(BranchMember).where(
                    BranchMember.organization_id == UUID(str(scope['org'])),
                    BranchMember.user_id == user_id,
                    BranchMember.status == 'active',
                ))).scalar_one_or_none()
                if member is not None:
                    perms = json.loads(member.permissions or '{}')
                    parent = resource_map.get(resource, resource)
                    if isinstance(perms, dict) and perms.get(parent) is True:
                        return True
        except Exception:
            pass
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="لا تملك صلاحية تنفيذ هذه العملية",
        )

    return _checker


# ═══════════════════════════════════════════════════════════════════
#  MAINTENANCE — server-side enforcement dependency.
#  Defined AFTER get_current_user_uuid_optional so its Depends() resolves.
# ═══════════════════════════════════════════════════════════════════

async def require_maintenance_allowed(
    section: str,
    request: Request,
    db: AsyncSession = Depends(get_db),
    user_id: Optional[UUID] = Depends(get_current_user_uuid_optional),
):
    """Guard a section/feature API surface against maintenance.

    Platform admins are always allowed. Non-admins are rejected (503) when:
      - the whole application is under maintenance, or
      - the section (personal/business) is under maintenance, or
      - the request path maps to a disabled personal feature.
    """
    if user_id is None:
        return
    try:
        from sqlalchemy import select
        uid = UUID(str(user_id))
        from ..domain.entities.auth_entities import User as _User
        u = (await db.execute(select(_User).where(_User.id == uid))).scalar_one_or_none()
        if u is not None and u.is_platform_admin:
            return
    except Exception:
        return

    ctrl = await _maintenance_snapshot(db)
    if section in ("personal", "business") and u is not None:
        from sqlalchemy import select as _select
        from ..domain.entities.auth_entities import Organization
        from ..domain.services.section_entitlements import access_snapshot
        effective_org_id = u.organization_id
        if section == "business":
            try:
                from ..domain.services.branch_service import decode_scope_token
                from ..domain.entities.branch_entities import BranchMember
                scope_token = request.headers.get("X-Branch-Token")
                scope = decode_scope_token(scope_token)
                if scope_token and scope is None:
                    from ..domain.services.branch_service import scope_token_state
                    expired = scope_token_state(scope_token) == 'expired'
                    raise HTTPException(401, detail={
                        'code': 'branch_scope_expired' if expired else 'branch_scope_invalid',
                        'message': 'رمز سياق الفرع منتهي أو غير صالح؛ أعد اختيار الفرع',
                    })
                if scope and str(scope.get("sub")) == str(u.id) and scope.get("org"):
                    member = (await db.execute(_select(BranchMember).where(
                        BranchMember.organization_id == UUID(str(scope["org"])),
                        BranchMember.user_id == u.id,
                        BranchMember.status == "active",
                    ))).scalar_one_or_none()
                    if member is not None or str(scope['org']) == str(u.organization_id):
                        effective_org_id = UUID(str(scope["org"]))
            except HTTPException:
                raise
            except Exception:
                pass
        org = (await db.execute(_select(Organization).where(Organization.id == effective_org_id))).scalar_one_or_none()
        trial_cfg = ctrl.get("trial") or {}
        trial_allowed = trial_cfg.get("enabled", True) and not ctrl.get("force_paid_subscription")
        access = access_snapshot(org, trial_allowed=trial_allowed) if org else None
        if not access or not access["sections"][section]["active"]:
            if section == 'business':
                from ..domain.services.merchant_subscription_service import require_merchant_subscription
                require_merchant_subscription(org, trial_allowed=trial_allowed)
            detail = "اشتراك قسم الأعمال مطلوب" if section == "business" else "اشتراك القسم الشخصي مطلوب"
            raise HTTPException(status_code=403, detail=detail)
    if not ctrl:
        return
    maint = ctrl.get("maintenance") or {}
    if maint.get("all"):
        raise HTTPException(status_code=503, detail="التطبيق تحت الصيانة حالياً — حاول لاحقاً")
    if section == "personal" and maint.get("personal"):
        raise HTTPException(status_code=503, detail="القسم الشخصي تحت الصيانة حالياً")
    if section == "business" and maint.get("business"):
        raise HTTPException(status_code=503, detail="قسم الأعمال تحت الصيانة حالياً")
    if section != "personal":
        return
    path = request.url.path
    feature = None
    for prefix, fkey in _PERSONAL_FEATURE_PATHS.items():
        if path.startswith(f"{settings.API_PREFIX}{prefix}"):
            feature = fkey
            break
    if feature is None:
        return
    disabled = ctrl.get("disabled_buttons") or {}
    blocked = []
    for lst in (disabled.get("personal"), disabled.get("all")):
        if isinstance(lst, list):
            blocked.extend(str(x).lstrip("/") for x in lst)
    if feature in blocked:
        raise HTTPException(status_code=503, detail="هذا القسم تحت الصيانة حالياً")


async def require_platform_admin(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
) -> bool:
    """Gate: the authenticated caller must be a platform admin (DB flag).

    Master API key holders are accepted here (they resolve to a real platform
    admin via [_master_admin_identity]).
    """
    user = await SQLAlchemyUserRepository(db).get_by_id(user_id)
    if not user or not user.is_platform_admin:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="ليس لديك صلاحية المشرف",
        )
    return True


def require_admin_perm(resource: str, action: str) -> Callable:
    """Gate a platform-admin endpoint behind a `resource:action` permission.

    The external Admin Web App authenticates with the master API key
    (`X-Admin-Master-Key`), which has FULL access to every admin endpoint; a
    normal platform-admin JWT still goes through RBAC permission checks.
    """

    async def _checker(
        request: Request,
        user_id: UUID = Depends(get_current_user_uuid),
        db: AsyncSession = Depends(get_db),
    ) -> bool:
        if _master_key_valid(request):
            # Master key → unconditional platform-admin access.
            await require_platform_admin(user_id=user_id, db=db)
            return True
        await require_platform_admin(user_id=user_id, db=db)
        role_repo = SQLAlchemyRoleRepository(db)
        has_perm = await role_repo.user_has_admin_permission(user_id, resource, action)
        if not has_perm:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="ليس لديك صلاحية للوصول إلى هذا القسم",
            )
        return True

    return _checker

async def get_branch_context(
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    x_branch_token: Optional[str] = Header(default=None, alias="X-Branch-Token"),
    x_branch_id: Optional[str] = Header(default=None, alias="X-Branch-Id"),
    branch_id: Optional[str] = Query(default=None),
    db: AsyncSession = Depends(get_db),
    request: Request = None,
):
    """Signed branch context.

    A plain `X-Branch-Id` can NEVER select a non-main branch by itself: the
    client must exchange it for `X-Branch-Token` (user+org+branch bound).
    Missing token → the org's main branch (legacy behaviour, unchanged).
    """
    from ..domain.services.branch_service import (
        decode_scope_token, main_branch, resolve_branch_for_context,
        scope_token_state)
    payload = decode_scope_token(x_branch_token)
    if x_branch_token and payload is None:
        state = scope_token_state(x_branch_token)
        raise HTTPException(status_code=401, detail={
            "code": ("branch_scope_expired" if state == "expired"
                     else "branch_scope_invalid"),
            "message": ("انتهت صلاحية رمز سياق الفرع"
                        if state == "expired"
                        else "رمز سياق الفرع غير صالح")})
    if payload is not None:
        if str(payload.get("sub")) != str(user_id) or \
                str(payload.get("org")) != str(org_id):
            raise HTTPException(status_code=403, detail={
                "code": "branch_scope_denied",
                "message": "رمز سياق الفرع لا يطابق الحساب"})
        if payload.get("mode") == "all":
            raise HTTPException(403, detail={
                'code': 'branch_read_only',
                'message': 'أنت في وضع عرض جميع الفروع. انتقل إلى فرع محدد لتنفيذ العملية.'})
        raw = payload.get("branch")
        try:
            branch = await resolve_branch_for_context(
                db, UUID(org_id), UUID(str(raw)) if raw else None)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc))
        from ..domain.services import branch_access_service as _access
        if not await _access.can_access_branch(db, UUID(org_id), user_id,
                                               branch.id):
            raise HTTPException(status_code=403, detail={
                "code": "branch_access_denied",
                "message": "لا تملك صلاحية الوصول إلى هذا الفرع"})
        return branch
    header_branch = (x_branch_id or branch_id or "").strip()
    if header_branch:
        raise HTTPException(
            status_code=403,
            detail="يلزم اختيار الفرع عبر رمز سياق موقّع من الخادم")
    branch = await main_branch(db, UUID(org_id))
    from ..domain.services.branch_access_service import can_access_branch
    if not await can_access_branch(db, UUID(org_id), user_id, branch.id):
        raise HTTPException(403, detail='لا تملك صلاحية الوصول إلى هذا الفرع')
    return branch

class BranchScopeContext:
    def __init__(self, branch_id, all_mode: bool, branch_ids):
        self.branch_id = branch_id
        self.all_mode = all_mode
        self.branch_ids = branch_ids


async def get_branch_scope(
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    x_branch_token: Optional[str] = Header(default=None, alias="X-Branch-Token"),
    db: AsyncSession = Depends(get_db),
):
    """Read context for branch-scoped Business APIs.

    mode=branch → exactly one active branch.
    mode=all    → signed permitted IDs intersected with current active grants.
                  Write dependencies reject this mode, even with a target.
    """
    from sqlalchemy import select as _select
    from app.domain.entities.auth_entities import User
    from app.domain.entities.sale_entities import Branch
    from app.domain.services.branch_service import (
        decode_scope_token, main_branch, resolve_branch_for_context)

    payload = decode_scope_token(x_branch_token)
    if payload is None:
        if x_branch_token:
            from app.domain.services.branch_service import scope_token_state
            state = scope_token_state(x_branch_token)
            raise HTTPException(status_code=401, detail={
                "code": ("branch_scope_expired" if state == "expired"
                         else "branch_scope_invalid"),
                "message": ("انتهت صلاحية رمز سياق الفرع"
                            if state == "expired"
                            else "رمز سياق الفرع غير صالح")})
        branch = await main_branch(db, UUID(org_id))
        from ..domain.services.branch_access_service import can_access_branch
        if not await can_access_branch(db, UUID(org_id), user_id, branch.id):
            raise HTTPException(403, detail='لا تملك صلاحية الوصول إلى هذا الفرع')
        return BranchScopeContext(branch.id, False, [branch.id])
    if str(payload.get("sub")) != str(user_id) or \
            str(payload.get("org")) != str(org_id):
        raise HTTPException(status_code=403, detail={
            "code": "branch_scope_denied",
            "message": "رمز سياق الفرع لا يطابق الحساب"})
    from ..domain.services import branch_access_service as _access
    if payload.get("mode") == "all":
        if 'branch_ids' not in payload and not await _access.can_view_all(db, UUID(org_id), user_id):
            raise HTTPException(status_code=403, detail={
                "code": "branch_scope_denied",
                "message": "عرض جميع الفروع غير مصرح لحسابك"})
        ids = await _access.effective_branch_ids(db, UUID(org_id), user_id)
        ids = _access.intersect_scope_ids(payload, ids)
        if not ids:
            raise HTTPException(403, detail='لا توجد فروع مسموحة في هذا النطاق')
        return BranchScopeContext(None, True, ids)
    raw = payload.get("branch")
    try:
        branch = await resolve_branch_for_context(
            db, UUID(org_id), UUID(raw) if raw else None)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail={
            "code": "branch_scope_invalid", "message": str(exc)})
    if not await _access.can_access_branch(db, UUID(org_id), user_id,
                                           branch.id):
        raise HTTPException(status_code=403, detail={
            "code": "branch_access_denied",
            "message": "لا تملك صلاحية الوصول إلى هذا الفرع"})
    return BranchScopeContext(branch.id, False, [branch.id])
