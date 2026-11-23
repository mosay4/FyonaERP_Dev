"""Live, company-scoped employee permissions. Explicit child denials win."""
import json
from uuid import UUID
from fastapi import HTTPException
from sqlalchemy import select
from ..entities.auth_entities import User
from ..entities.branch_entities import BranchMember
from .branch_service import decode_scope_token
from .branch_access_service import is_owner, scope_is_current

GROUPS = {
    'dashboard': [], 'falcon': [], 'transactions': [],
    'income': [], 'expenses': [], 'reports': ['view', 'export'],
    'reconciliation': ['bank', 'inventory', 'equalize'],
    'banks': ['add_delete', 'transfer', 'details', 'balances'],
    'sales': ['create', 'view', 'delete', 'returns'],
    'purchases': ['create', 'view', 'delete', 'returns'], 'returns': [], 'invoices': [],
    'inventory': ['add', 'edit', 'delete', 'count', 'transfer'],
    'customers': ['add', 'edit', 'delete', 'details'],
    'suppliers': ['add', 'edit', 'delete', 'details'],
    'debts': ['add', 'settle', 'details'], 'branches': ['view', 'transfer', 'manage'],
    'suggestions': [], 'notifications': [], 'chat': [], 'transfers': [],
}
LEGACY = {'falcon': 'inventory', 'transactions': 'dashboard', 'income': 'reports', 'expenses': 'reports'}


def uuid_argument(value):
    try:
        return UUID(str(value))
    except (ValueError, TypeError, AttributeError):
        raise HTTPException(422, detail='معرّف السجل غير صالح')


def allowed(permissions, key):
    parent = key.split('.')[0]
    if parent in ('employees', 'subscription', 'ai'):
        return False
    value = permissions.get(parent, permissions.get(LEGACY.get(parent, ''), False))
    return value is True and permissions.get(key, value) is True


def full_access(permissions):
    return all(allowed(permissions, key) and all(allowed(permissions, f'{key}.{child}')
        for child in children) for key, children in GROUPS.items())


async def member_policy(db, request, user_id):
    if request.url.path.startswith('/api/v1/ai/'):
        # Personal Sara never inherits a selected merchant workspace.
        return None
    user = await db.get(User, user_id)
    scope = decode_scope_token(request.headers.get('X-Branch-Token'))
    if scope and str(scope.get('sub')) != str(user_id):
        raise HTTPException(403, detail='رمز الفرع لا يطابق الحساب')
    org = UUID(str(scope['org'])) if scope and scope.get('org') else user.organization_id
    if is_owner(user, org):
        return None
    member = (await db.execute(select(BranchMember).where(
        BranchMember.organization_id == org, BranchMember.user_id == user_id))).scalar_one_or_none()
    if member is None:
        if user.organization_id != org:
            raise HTTPException(403, detail='لا تملك صلاحية الدخول لهذا المتجر')
        return None  # Existing same-company role-based accounts.
    if member.status != 'active' or not scope_is_current(member, scope):
        raise HTTPException(403, detail={'code': 'employee_workspace_revoked', 'message': 'تم إلغاء ارتباطك بالمتجر'})
    try:
        permissions = json.loads(member.permissions or '{}')
    except (ValueError, TypeError):
        permissions = {}
    # Preserve the older branch-invitation RBAC format (resource -> actions).
    # Employee editor maps are flat booleans and never take this path.
    if isinstance(permissions, dict) and (any(isinstance(v, dict) for v in permissions.values())
            or 'read' in permissions or 'write' in permissions):
        return None
    permissions = permissions if isinstance(permissions, dict) else {}
    request.state.employee_policy = permissions
    if request.method == 'POST' and request.headers.get('content-type', '').startswith('application/json'):
        body = await request.json()
        if isinstance(body, dict) and body.get('allow_negative') is True and not full_access(permissions):
            from ..entities.business_settings_entities import BusinessProjectSettings
            row = await db.get(BusinessProjectSettings, org)
            shared = json.loads(row.settings or '{}') if row else {}
            if shared.get('allow_negative') is not True:
                raise HTTPException(403, detail='الدفع بالسالب غير مسموح في إعدادات المتجر')
    return permissions


def required_key(resource, action, path):
    if path.endswith('/settle'):
        return 'debts.settle'
    if path.startswith('/api/v1/merchant-links/'):
        return 'debts.settle' if path.endswith('/decide') else ('debts.details' if action == 'read' else 'debts.add')
    if path.endswith('/invoices/issue-sale'):
        return 'sales.create'
    if path.endswith('/invoices/issue-purchase'):
        return 'purchases.create'
    if path.startswith('/api/v1/returns'):
        return 'returns'
    if path.startswith('/api/v1/business/transactions'):
        return 'transactions'
    if resource in ('banking', 'finance', 'accounting'):
        if any(part in path for part in ('export', 'balance', 'summary')): return 'banks.balances'
        if path.endswith('/deposit'): return 'income'
        if path.endswith('/withdraw'): return 'expenses'
        if 'transfer' in path: return 'banks.transfer'
        if action in ('create', 'delete'): return 'banks.add_delete'
        if action == 'update': return 'banks.add_delete'
        if '/accounts/' in path or '/group/' in path: return 'banks.details'
        return 'banks'
    parent = {'products': 'inventory', 'categories': 'inventory', 'falcon': 'falcon',
        'hr': 'employees', 'payments': 'transactions', 'expenses': 'expenses'}.get(resource, resource)
    if parent in ('sales', 'purchases'):
        child = 'returns' if 'return' in path else {'read':'view', 'create':'create', 'delete':'delete', 'update':'create'}.get(action)
    elif parent in ('customers', 'suppliers'):
        child = {'create':'add', 'update':'edit', 'delete':'delete'}.get(action)
        if action == 'read' and (f'/{parent}/' in path or any(s in path for s in ('balance', 'statement', 'ledger'))): child = 'details'
    elif parent == 'inventory':
        child = 'transfer' if 'transfer' in path else ('count' if ('count' in path or 'stocktake' in path) else {'create':'add','update':'edit','delete':'delete'}.get(action))
    elif parent == 'reconciliation':
        child = 'equalize' if path.endswith('/approve') else ('inventory' if '/inventory/' in path else ('bank' if '/bank/' in path or path.endswith('/accounts') else None))
    elif parent == 'reports': child = 'export' if 'export' in path else 'view'
    elif parent == 'branches': child = 'transfer' if 'transfer' in path else ('view' if action == 'read' else 'manage')
    elif parent == 'debts': child = 'settle' if 'settle' in path else ('details' if action == 'read' else 'add')
    else: child = None
    return f'{parent}.{child}' if child else parent


KIND_PERMISSIONS = {
    'sale': 'sales.view', 'purchase': 'purchases.view', 'sale_return': 'sales.returns',
    'purchase_return': 'purchases.returns', 'expense': 'expenses', 'income': 'income',
    'collection': 'customers.details', 'supplier_payment': 'suppliers.details',
    'bank_withdrawal': 'expenses', 'transfer': 'transfers',
    'transfer_reversal': 'transfers', 'reconciliation': 'reconciliation', 'opening': 'banks.balances',
}


def visible_kinds(permissions):
    return {kind for kind, key in KIND_PERMISSIONS.items() if allowed(permissions, key)}


def report_allowed(permissions, path):
    """Report queries cannot be used as a bypass around operational denials."""
    if not allowed(permissions, 'reports.view'):
        return False
    if any(word in path for word in ('export', 'statement')) and not allowed(permissions, 'reports.export'):
        return False
    # Legacy tenant-wide HR/order aggregates have no branch ownership. Members
    # use the branch-scoped business reports instead; never disclose HR counts.
    if path.endswith(('/reports/kpi', '/reports/sales')):
        return False
    if path.endswith('/inventory'):
        return allowed(permissions, 'inventory')
    if not allowed(permissions, 'banks.balances'):
        return False
    if path.endswith('/money'):
        return allowed(permissions, 'banks.details') and allowed(permissions, 'transactions')
    if path.endswith('/debts'):
        return allowed(permissions, 'debts.details')
    # Combined reports include sales, purchases, income, expenses and debt
    # totals. Do not reveal a denied source through a precomputed aggregate.
    return all(allowed(permissions, key) for key in (
        'sales.view', 'purchases.view', 'income', 'expenses', 'debts.details'))
