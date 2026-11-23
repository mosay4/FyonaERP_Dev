"""Merchant ↔ Personal («حساباتي مع التجار») API.

Personal side: my code, my merchants, incoming invites, partner debts/invoices,
and settlement-proof requests.
Business side: look a user up, invite, link status, review/decide proofs,
and debt groups. Permissions are enforced HERE (server), never only in Flutter.
"""

from decimal import Decimal
from typing import List, Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ...core.database import get_db
from ...api.deps import get_current_org_id, get_current_org_id_optional, get_current_user_uuid, get_branch_scope, require_permission
from ...api.responses import ok
from ...domain.entities.auth_entities import User
from ...domain.entities.merchant_entities import MerchantLink
from ...domain.services import merchant_link_service as svc
from ...infrastructure.repositories.sql_alchemy_auth_repository import (
    SQLAlchemyRoleRepository,
)

async def _employee_business_access(request: Request,
    org_id: Optional[str] = Depends(get_current_org_id_optional), user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db)):
    db.info.pop('merchant_employee_authorized', None)
    if not request.url.path.startswith('/api/v1/merchant-links/'):
        return
    if org_id is None:
        raise HTTPException(403, detail='لا تملك صلاحية الدخول لهذا المتجر')
    from ...domain.services.employee_access_policy import member_policy, allowed, uuid_argument
    policy = await member_policy(db, request, user_id)
    if policy is None:
        return
    path = request.url.path
    body = {}
    if request.method not in ('GET', 'HEAD') and request.headers.get('content-type', '').startswith('application/json'):
        raw = await request.body()
        if raw:
            import json
            try: body = json.loads(raw)
            except (ValueError, UnicodeDecodeError):
                raise HTTPException(422, detail='بيانات الطلب ليست JSON صحيحاً')
    if not isinstance(body, dict): raise HTTPException(422, detail='بيانات الطلب غير صالحة')
    values = {**dict(request.query_params), **body, **request.path_params}
    kind, party_id = values.get('party_kind'), values.get('party_id')
    from ...domain.entities.merchant_entities import DebtGroup, SettlementRequest
    for name, model in (('group_id', DebtGroup), ('request_id', SettlementRequest)):
        if not values.get(name): continue
        row = await db.get(model, uuid_argument(values[name]))
        if row is None or str(row.organization_id) != org_id:
            raise HTTPException(404, detail='السجل غير موجود')
        kind, party_id = row.party_kind, row.party_id
    if path.endswith('/lookup'):
        keys = ['customers.edit', 'suppliers.edit']
        permitted = any(allowed(policy, key) for key in keys)
    else:
        key = ('debts.settle' if path.endswith('/decide') else
               'debts.details' if request.method == 'GET' else 'debts.add')
        if path.endswith('/party/delete'):
            key = 'suppliers.delete' if kind == 'supplier' else 'customers.delete'
        elif path.endswith('/invite'):
            key = 'suppliers.edit' if kind == 'supplier' else 'customers.edit'
        elif path.endswith('/status'):
            key = 'suppliers.details' if kind == 'supplier' else 'customers.details'
        permitted = allowed(policy, key)
    if not permitted:
        raise HTTPException(403, detail='لا تملك صلاحية تنفيذ هذه العملية')
    scope = await get_branch_scope(org_id, user_id, request.headers.get('X-Branch-Token'), db)
    ids = scope.branch_ids if scope.all_mode else [scope.branch_id]
    from ...domain.entities.business_entities import Customer, Supplier
    from ...domain.entities.invoice_entities import Invoice
    from ...domain.entities.finance_entities import BankAccount
    from ...domain.services.branch_service import main_branch
    main = None
    async def check(row):
        nonlocal main
        if row is None or str(row.organization_id) != org_id:
            raise HTTPException(404, detail='السجل غير موجود')
        branch = row.branch_id
        if branch is None:
            main = main or await main_branch(db, UUID(org_id))
            branch = main.id
        if branch not in ids:
            raise HTTPException(404, detail='السجل غير موجود في هذا الفرع')
    if party_id:
        if kind not in ('customer', 'supplier'):
            raise HTTPException(400, detail='نوع الطرف غير صحيح')
        await check(await db.get(Supplier if kind == 'supplier' else Customer, uuid_argument(party_id)))
    for name, model in (('invoice_id', Invoice), ('bank_account_id', BankAccount)):
        if values.get(name): await check(await db.get(model, uuid_argument(values[name])))
    db.info['merchant_employee_authorized'] = True


router = APIRouter(tags=["Merchant Accounts"], dependencies=[Depends(_employee_business_access)])


async def _need_perm(db: AsyncSession, user_id: UUID, resource: str, action: str) -> None:
    if db.info.get('merchant_employee_authorized'):
        return
    repo = SQLAlchemyRoleRepository(db)
    if not await repo.user_has_permission(user_id, resource, action):
        from fastapi import HTTPException
        raise HTTPException(status_code=403, detail="صلاحيات الأدمن مطلوبة لهذه العملية")


async def _need_party_perm(db: AsyncSession, user_id: UUID, kind: str, action: str) -> None:
    if kind not in ("customer", "supplier"):
        from fastapi import HTTPException
        raise HTTPException(status_code=400, detail="نوع الطرف غير صحيح")
    resource = "customers" if kind == "customer" else "suppliers"
    await _need_perm(db, user_id, resource, action)


async def _push_after_commit(db: AsyncSession, org_id: UUID, push: dict | None) -> None:
    """Best-effort push AFTER the commit — never raises, never breaks the op."""
    if not push or not push.get("recipients"):
        return
    try:
        from ...domain.services import debt_notification_service as dn
        result = await dn.push_event(
            db, org_id, push["event_id"], push["recipients"],
            title=push["title"], message=push["message"], route=push["route"])
        import logging
        logging.getLogger('invitation.delivery').info('party_event_delivery sent=%s failed=%s',
            (result or {}).get('sent', 0), (result or {}).get('failed', 0))
    except Exception as exc:
        import logging
        logging.getLogger('invitation.delivery').warning('party_event_delivery_failed type=%s', type(exc).__name__)


class LookupRequest(BaseModel):
    country: Optional[str] = Field(default=None, min_length=2, max_length=2)
    phone: Optional[str] = None
    code: Optional[str] = None


class InviteRequest(BaseModel):
    country: Optional[str] = Field(default=None, min_length=2, max_length=2)
    party_kind: str
    party_id: UUID
    phone: Optional[str] = None
    code: Optional[str] = None


class SettlementRequestCreate(BaseModel):
    link_id: UUID
    amount: Decimal
    currency: str = "SAR"
    method: Optional[str] = None
    reference: Optional[str] = None
    receipt_url: Optional[str] = None
    note: Optional[str] = None
    idempotency_key: Optional[str] = None


class SettlementDecide(BaseModel):
    approve: bool
    bank_account_id: Optional[UUID] = None
    reason: Optional[str] = None


class PartyDeleteRequest(BaseModel):
    party_kind: str
    party_id: UUID


class OpeningDebtRequest(BaseModel):
    party_kind: str
    party_id: UUID
    amount: Decimal
    currency: str = "SAR"


class DebtGroupCreate(BaseModel):
    party_kind: str
    party_id: UUID
    name: str
    kind: str = "manual"
    period: Optional[str] = None


# ── personal ─────────────────────────────────────────────────────────
@router.get("/me/code", summary="الرقم المميز الخاص بي")
async def my_code(
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one()
    code = await svc.ensure_user_code(db, user)
    await db.commit()
    return ok({"code": code})


@router.get("/me/merchant-links", summary="تجاري المرتبطون")
async def my_merchants(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    return ok(await svc.user_links(db, user_id))


@router.get("/me/merchant-invites", summary="الدعوات الواردة")
async def my_invites(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    return ok(await svc.user_invites(db, user_id))


@router.post("/me/merchant-invites/{link_id}/accept", summary="قبول الدعوة")
async def accept_invite(
    link_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        res = await svc.respond(db, user_id, link_id, True)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    push = res.pop("_push", None)
    await db.commit()
    from ...domain.services.invitation_response_service import deliver
    await deliver(db, push)
    return ok(res)


@router.post("/me/merchant-invites/{link_id}/reject", summary="رفض الدعوة")
async def reject_invite(
    link_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        res = await svc.respond(db, user_id, link_id, False)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    push = res.pop("_push", None)
    await db.commit()
    from ...domain.services.invitation_response_service import deliver
    await deliver(db, push)
    return ok(res)


@router.post("/me/merchant-links/{link_id}/unlink", summary="إلغاء الربط من الحساب الشخصي")
async def unlink_my_merchant(
    link_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        res = await svc.user_unlink(db, user_id, link_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    push = res.pop("_push", None)
    await db.commit()
    if push:
        try:
            link = (await db.execute(
                select(MerchantLink).where(MerchantLink.id == link_id))).scalar_one_or_none()
            if link is not None:
                from ...domain.services import debt_notification_service as dn
                await dn.push_event(
                    db, link.merchant_org_id, push["event_id"], push["recipients"],
                    title=push["title"], message=push["message"], route=push["route"])
        except Exception:
            pass
    return ok(res)


@router.post("/merchant-links/party/opening-debt",
             summary="إضافة رصيد افتتاحي لعميل/مورد جديد")
async def create_opening_debt(
    data: OpeningDebtRequest,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _need_party_perm(db, user_id, data.party_kind, "create")
    try:
        res = await svc.create_opening_debt(
            db, UUID(org_id), user_id, data.party_kind, data.party_id,
            data.amount, data.currency)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    await db.commit()
    return ok(res)


@router.post("/merchant-links/party/delete", summary="حذف عميل/مورد وإلغاء الربط إن وجد")
async def delete_party(
    data: PartyDeleteRequest,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _need_party_perm(db, user_id, data.party_kind, "delete")
    try:
        res = await svc.merchant_delete_party(
            db, UUID(org_id), user_id, data.party_kind, data.party_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    push = res.pop("_push", None)
    await db.commit()
    await _push_after_commit(db, UUID(org_id), push)
    return ok(res)


@router.get("/me/merchant-links/{link_id}/debts", summary="ديوني مع التاجر")
async def partner_debts(
    link_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    return ok(await svc.partner_detail(db, user_id, link_id))


@router.get("/me/merchant-links/{link_id}/invoices", summary="فواتيري مع التاجر")
async def partner_invoices(
    link_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    return ok(await svc.partner_invoices(db, user_id, link_id))


@router.get("/me/merchant-links/{link_id}/settlement-requests",
            summary="طلبات السداد الخاصة بي لدى التاجر")
async def my_proofs(
    link_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        return ok(await svc.user_settlement_requests(db, user_id, link_id))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.post("/me/merchant-links/settlement-requests", summary="طلب إثبات سداد")
async def create_proof(
    data: SettlementRequestCreate,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        res = await svc.create_settlement_request(
            db, user_id, data.link_id, data.amount, data.currency, data.method,
            data.reference, data.receipt_url, data.note, data.idempotency_key)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    push = res.pop("_push", None)
    await db.commit()
    if push:
        try:
            from ...domain.services import debt_notification_service as dn
            from sqlalchemy import select as _sel
            link = (await db.execute(
                _sel(MerchantLink).where(MerchantLink.id == data.link_id))).scalar_one_or_none()
            if link is not None:
                await dn.push_event(
                    db, link.merchant_org_id, push["event_id"], push["recipients"],
                    title=push["title"], message=push["message"], route=push["route"])
        except Exception:
            pass
    return ok(res)


# ── business (kind-aware permissions: customers XOR suppliers) ──────
@router.post("/merchant-links/lookup", summary="ابحث عن مستخدم")
async def lookup(
    data: LookupRequest,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    # User search for linking — either party permission suffices.
    repo = SQLAlchemyRoleRepository(db)
    can_c = await repo.user_has_permission(user_id, "customers", "read")
    can_s = await repo.user_has_permission(user_id, "suppliers", "read")
    if not (can_c or can_s):
        raise HTTPException(status_code=403, detail="صلاحيات الأدمن مطلوبة لهذه العملية")
    try:
        u = await svc.lookup_user(db, data.phone, data.code, data.country)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    if not u:
        return ok({"found": False})
    via = "phone" if (data.phone or "").strip() else "code"
    identifier = (data.phone if via == "phone" else data.code).strip()
    return ok({"found": True, "name": u.full_name, "matched_by": via,
               "avatar": u.photo_url or u.avatar,
               "contact": {"via": via, "value": identifier}, via: identifier})


@router.post("/merchant-links/invite", summary="دعوة للمتابعة")
async def invite(
    data: InviteRequest,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _need_party_perm(db, user_id, data.party_kind, "update")
    try:
        res = await svc.invite(db, UUID(org_id), user_id, data.party_kind,
                               data.party_id, data.phone, data.code, data.country)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    push = res.pop("_push", None)
    await db.commit()
    await _push_after_commit(db, UUID(org_id), push)
    return ok(res)


@router.get("/merchant-links/status", summary="حالة الربط")
async def link_status(
    party_kind: str,
    party_id: UUID,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _need_party_perm(db, user_id, party_kind, "read")
    return ok(await svc.merchant_link_status(db, UUID(org_id), party_kind, party_id))


@router.get("/merchant-links/settlement-requests", summary="طلبات السداد", dependencies=[Depends(require_permission("payments", "read"))])
async def list_proofs(
    party_kind: str,
    party_id: UUID,
    org_id: str = Depends(get_current_org_id),
    db: AsyncSession = Depends(get_db),
):
    return ok(await svc.list_settlement_requests(db, UUID(org_id), party_kind, party_id))


@router.post("/merchant-links/settlement-requests/{request_id}/decide",
             summary="اعتماد/رفض طلب سداد", dependencies=[Depends(require_permission("payments", "create"))])
async def decide_proof(
    request_id: UUID,
    data: SettlementDecide,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        res = await svc.decide_settlement_request(
            db, UUID(org_id), user_id, request_id, data.approve,
            data.bank_account_id, data.reason)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    push = res.pop("_push", None)
    await db.commit()
    await _push_after_commit(db, UUID(org_id), push)
    return ok(res)


@router.get("/merchant-links/debt-groups", summary="مجموعات الديون")
async def groups(
    party_kind: str,
    party_id: UUID,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _need_party_perm(db, user_id, party_kind, "read")
    return ok(await svc.list_debt_groups(db, UUID(org_id), party_kind, party_id))


@router.post("/merchant-links/debt-groups", summary="إنشاء مجموعة ديون")
async def create_group(
    data: DebtGroupCreate,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _need_party_perm(db, user_id, data.party_kind, "update")
    try:
        res = await svc.create_debt_group(
            db, UUID(org_id), user_id, data.party_kind, data.party_id,
            data.name, data.kind, data.period)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    await db.commit()
    return ok(res)


# ── commercial-debt notification center (isolated) ────────────────────
class GroupUpdate(BaseModel):
    name: str


class GroupAssignment(BaseModel):
    party_kind: str
    party_id: UUID
    group_id: Optional[UUID] = None


@router.get("/merchant-links/overview")
async def business_overview(party_kind: str, party_id: UUID,
    group_id: Optional[UUID] = None, currency: Optional[str] = None,
    date_from: Optional[str] = None, date_to: Optional[str] = None,
    org_id: str = Depends(get_current_org_id), user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db)):
    await _need_party_perm(db, user_id, party_kind, "read")
    try:
        return ok(await svc.business_overview(
            db, UUID(org_id), party_kind, party_id,
            group_id=group_id, display_currency=currency,
            date_from=date_from, date_to=date_to))
    except ValueError as e:
        raise HTTPException(404, str(e))


class DebtItemAdjust(BaseModel):
    item_id: UUID
    quantity: float
    unit_price: float


class DebtAdjustRequest(BaseModel):
    party_kind: str
    party_id: UUID
    items: List[DebtItemAdjust]


@router.patch("/merchant-links/operation/{invoice_id}")
async def adjust_operation(
    invoice_id: UUID,
    data: DebtAdjustRequest,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _need_party_perm(db, user_id, data.party_kind, "update")
    from ...domain.services import debt_invoice_service as dis
    try:
        res = await dis.adjust_debt_invoice(
            db, UUID(org_id), user_id, data.party_kind, data.party_id,
            invoice_id, [i.model_dump() for i in data.items])
        _msg = (f"عدّل التاجر الفاتورة {res['number']}. "
                "لعرض جميع التفاصيل اضغط هنا")
        pushes = await svc.notify_party(
            db, UUID(org_id), data.party_kind, data.party_id,
            event_id=f"debt_edited:{invoice_id}",
            title="تعديل فاتورة",
            message=_msg,
            route_for=lambda link: (
                f"/personal/merchant-partner?link={link.id}&op={invoice_id}"
                f"&edits=1"),
            actor_user_id=user_id)
        await db.commit()
        for p in pushes:
            await _push_after_commit(db, UUID(org_id), p)
        return ok(res)
    except ValueError as e:
        await db.rollback()
        raise HTTPException(400, str(e))


@router.delete("/merchant-links/operation/{invoice_id}")
async def delete_operation(
    invoice_id: UUID,
    party_kind: str,
    party_id: UUID,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _need_party_perm(db, user_id, party_kind, "update")
    from ...domain.services import debt_invoice_service as dis
    try:
        res = await dis.delete_debt_invoice(
            db, UUID(org_id), user_id, party_kind, party_id, invoice_id)
        pushes = await svc.notify_party(
            db, UUID(org_id), party_kind, party_id,
            event_id=f"debt_deleted:{invoice_id}",
            title="حذف فاتورة",
            message=(f"حذف التاجر الفاتورة {res['number']} نهائيًا "
                     f"(الإجمالي {res['total']})"),
            route_for=lambda link: (
                f"/personal/merchant-partner?link={link.id}"),
            actor_user_id=user_id)
        await db.commit()
        for p in pushes:
            await _push_after_commit(db, UUID(org_id), p)
        return ok(res)
    except ValueError as e:
        await db.rollback()
        raise HTTPException(400, str(e))


@router.get("/merchant-links/operation")
async def business_operation(
    party_kind: str, party_id: UUID, invoice_id: UUID,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _need_party_perm(db, user_id, party_kind, "read")
    try:
        return ok(await svc.business_operation_detail(
            db, UUID(org_id), party_kind, party_id, invoice_id))
    except ValueError as e:
        raise HTTPException(404, str(e))


@router.put("/merchant-links/debt-groups/{group_id}")
async def rename_group(group_id: UUID, data: GroupUpdate,
    org_id: str = Depends(get_current_org_id), user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db)):
    # Group is party-scoped; resolve its kind for the permission check.
    from sqlalchemy import select as _sel
    from ...domain.entities.merchant_entities import DebtGroup
    g = (await db.execute(_sel(DebtGroup).where(
        DebtGroup.id == group_id,
        DebtGroup.organization_id == UUID(org_id)))).scalar_one_or_none()
    if g is None:
        raise HTTPException(400, "القسم غير موجود")
    await _need_party_perm(db, user_id, g.party_kind, "update")
    try:
        result = await svc.manage_group(db, UUID(org_id), user_id, group_id, data.name)
        await db.commit()
        return ok(result)
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.delete("/merchant-links/debt-groups/{group_id}")
async def remove_group(group_id: UUID,
    org_id: str = Depends(get_current_org_id), user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db)):
    from sqlalchemy import select as _sel
    from ...domain.entities.merchant_entities import DebtGroup
    g = (await db.execute(_sel(DebtGroup).where(
        DebtGroup.id == group_id,
        DebtGroup.organization_id == UUID(org_id)))).scalar_one_or_none()
    if g is None:
        raise HTTPException(400, "القسم غير موجود")
    await _need_party_perm(db, user_id, g.party_kind, "update")
    try:
        result = await svc.manage_group(db, UUID(org_id), user_id, group_id, remove=True)
        await db.commit()
        return ok(result)
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.put("/merchant-links/operations/{invoice_id}/group")
async def assign_group(invoice_id: UUID, data: GroupAssignment,
    org_id: str = Depends(get_current_org_id), user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db)):
    await _need_party_perm(db, user_id, data.party_kind, "update")
    try:
        result = await svc.assign_group(db, UUID(org_id), user_id, data.party_kind,
                                       data.party_id, invoice_id, data.group_id)
        await db.commit()
        return ok(result)
    except ValueError as e:
        raise HTTPException(400, str(e))


@router.get("/debt-notifications/unread", summary="عدد إشعارات الديون غير المقروءة")
async def debt_notifications_unread(
    side: Optional[str] = None,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    from ...domain.services import debt_notification_service as dn
    return ok({"unread": await dn.unread_count(db, user_id, side=side)})


@router.get("/debt-notifications/chat-unread", summary="الرسائل غير المقروءة لكل محادثة")
async def debt_chat_unread(
    side: Optional[str] = None,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    from ...domain.services import debt_notification_service as dn
    return ok(await dn.unread_chat_by_link(db, user_id, side=side))


@router.get("/debt-notifications", summary="مركز إشعارات الديون")
async def debt_notifications(
    link_id: Optional[UUID] = None,
    side: Optional[str] = None,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    from app.domain.services import debt_notification_service as dn
    return ok(await dn.list_notifications(db, user_id, link_id=link_id, side=side))


@router.post("/debt-notifications/read", summary="تعليم الإشعارات كمقروءة")
async def debt_notifications_read(
    data: dict,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    from app.domain.services import debt_notification_service as dn
    ids = [UUID(x) for x in (data.get("ids") or []) if x]
    n = await dn.mark_read(db, user_id, ids or None)
    await db.commit()
    return ok({"marked": n})


@router.get("/me/merchant-links/{link_id}/debt-overview",
            summary="ديوني عند التاجر (بالعملة المختارة)")
async def debt_overview(
    link_id: UUID,
    currency: Optional[str] = None,
    group_id: Optional[UUID] = None,
    date_from: Optional[str] = None,
    date_to: Optional[str] = None,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        return ok(await svc.partner_debt_overview(
            db, user_id, link_id, currency, group_id,
            date_from=date_from, date_to=date_to))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.get("/me/merchant-links/{link_id}/operations/{invoice_id}",
            summary="تفاصيل العملية")
async def operation_detail(
    link_id: UUID, invoice_id: UUID,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        return ok(await svc.partner_operation_detail(db, user_id, link_id, invoice_id))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
