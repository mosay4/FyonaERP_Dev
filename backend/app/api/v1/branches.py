"""Branch management, membership, invitations and branch transfers."""
from typing import Any, Dict, List, Optional
from uuid import UUID

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile, Request
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ...api.deps import (get_branch_context, get_branch_scope, get_current_org_id_optional,
                         get_current_org_id, get_current_session_id, get_current_user_uuid)
from ...api.responses import ok, ok_paginated
from ...core import qa_business_ledger
from ...core.database import get_db
from ...domain.entities.auth_entities import Organization, User
from ...domain.entities.sale_entities import Branch
from ...domain.services import branch_access_service as access
from ...domain.services import branch_lifecycle_service as lifecycle
from ...domain.services import branch_service as svc
from ...domain.services import branch_transfer_service as transfers

async def _employee_transfer_access(request: Request,
    org_id: Optional[str] = Depends(get_current_org_id_optional), user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db)):
    if '/branches/transfers' not in request.url.path:
        return
    if org_id is None:
        raise HTTPException(403, detail='لا تملك صلاحية الدخول لهذا المتجر')
    from ...domain.services.employee_access_policy import member_policy, allowed, uuid_argument
    from ...domain.entities.branch_entities import BranchTransfer
    from ...domain.entities.business_entities import Product
    policy = await member_policy(db, request, user_id)
    if policy is None:
        await _guard_transfer_selection(request, db, org_id, user_id)
        return
    kinds = [kind for kind, key in (('financial', 'banks.transfer'), ('inventory', 'inventory.transfer'))
             if allowed(policy, key)]
    if not allowed(policy, 'branches.transfer') or not kinds:
        raise HTTPException(403, detail='لا تملك صلاحية التحويل بين الفروع')
    request.state.employee_transfer_kinds = kinds
    values = dict(request.query_params)
    if request.headers.get('content-type', '').startswith('application/json'):
        body = await request.json()
        if not isinstance(body, dict): raise HTTPException(422, detail='بيانات الطلب غير صالحة')
        values.update(body)
    kind = values.get('kind')
    if request.url.path.endswith('/financial'): kind = 'financial'
    if request.url.path.endswith(('/inventory', '/unit-conversion', '/product-match')): kind = 'inventory'
    transfer_id = request.path_params.get('transfer_id')
    if transfer_id:
        row = await db.get(BranchTransfer, uuid_argument(transfer_id))
        if row is None or str(row.organization_id) != org_id:
            raise HTTPException(404, detail='التحويل غير موجود')
        values.update(from_branch_id=row.from_branch_id, to_branch_id=row.to_branch_id)
        kind = row.kind
    if kind is not None and kind not in kinds:
        raise HTTPException(403, detail='لا تملك صلاحية هذا النوع من التحويلات')
    for key in ('branch_id', 'from_branch_id', 'to_branch_id'):
        if values.get(key) and not await access.can_access_branch(db, UUID(org_id), user_id, uuid_argument(values[key])):
            raise HTTPException(403, detail='الفرع خارج نطاق وصولك')
    for key in ('from_product_id', 'to_product_id'):
        if not values.get(key): continue
        row = await db.get(Product, uuid_argument(values[key]))
        if row is None or str(row.organization_id) != org_id or not await access.can_access_branch(
                db, UUID(org_id), user_id, row.branch_id):
            raise HTTPException(404, detail='المنتج غير موجود في الفروع المسموحة')
    await _guard_transfer_selection(request, db, org_id, user_id)


async def _guard_transfer_selection(request, db, org_id, user_id):
    if not qa_business_ledger.INVITES:
        return
    token = request.headers.get("X-Branch-Token")
    if not token:
        return  # Explicit resource branches are still checked by the service.
    scope = await get_branch_scope(org_id, user_id, token, db)
    try:
        await transfers.require_connected_transfer_scope(db, scope.branch_ids)
    except transfers.TransferNeedsArbitration as error:
        raise _transfer_device_conflict(error) from error


router = APIRouter(prefix="/branches", tags=["Branches"], dependencies=[Depends(_employee_transfer_access)])


class BranchCreate(BaseModel):
    name: str
    # A branch is born on the device with its own id; the server learns the
    # id and the name only, so it can be selected and carried to other devices.
    id: UUID | None = None


class BranchUpdate(BaseModel):
    name: str


class BranchSelect(BaseModel):
    branch_id: Optional[UUID] = None
    all: bool = False
    organization_id: Optional[UUID] = None


class InviteCreate(BaseModel):
    branch_id: UUID
    phone: Optional[str] = None
    code: Optional[str] = None
    can_transfer: bool = False


class InviteRespond(BaseModel):
    accept: bool


class MemberUpdate(BaseModel):
    branch_ids: Optional[List[UUID]] = None
    all_branches: Optional[bool] = None
    can_transfer: Optional[bool] = None
    permissions: Optional[Dict[str, Any]] = None
    status: Optional[str] = None


class FinancialTransferCreate(BaseModel):
    from_branch_id: UUID
    to_branch_id: UUID
    from_account_id: UUID
    to_account_id: UUID
    amount: float
    exchange_rate: Optional[float] = None
    allow_negative: bool = False
    idempotency_key: Optional[str] = Field(default=None, max_length=120)
    notes: Optional[str] = None


class InventoryTransferLine(BaseModel):
    from_product_id: UUID
    quantity: float
    to_product_id: Optional[UUID] = None
    from_unit_id: Optional[UUID] = None
    to_unit_id: Optional[UUID] = None
    unit_cost: Optional[float] = None
    # 1 selected source unit = N target BASE units. Required only when the
    # two products have no provable/known unit relationship; saved once.
    conversion_factor: Optional[float] = None


class InventoryTransferCreate(BaseModel):
    from_branch_id: UUID
    to_branch_id: UUID
    items: List[InventoryTransferLine]
    idempotency_key: Optional[str] = Field(default=None, max_length=120)
    notes: Optional[str] = None


class BranchCurrenciesUpdate(BaseModel):
    currencies: List[str]


class ReverseRequest(BaseModel):
    allow_negative: bool = False
    items: Optional[List[Dict[str, Any]]] = None
    notes: Optional[str] = None


async def _require_owner(db: AsyncSession, user_id: UUID, org_id: str) -> User:
    return await svc.require_owner(db, user_id, org_id)


@router.get("/manage", summary="قائمة الفروع (إدارة)")
async def list_branches(
    include_archived: bool = Query(False),
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _require_owner(db, user_id, org_id)
    rows = await svc.list_branches(db, UUID(org_id), include_archived)
    return ok({"branches": [svc.branch_dict(b) for b in rows]})


@router.post("", status_code=201, summary="إنشاء فرع")
async def create_branch(
    data: BranchCreate,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    session_id: UUID | None = Depends(get_current_session_id),
):
    owner = await _require_owner(db, user_id, org_id)
    if data.id is not None:
        existing = (await db.execute(select(Branch).where(
            Branch.id == data.id))).scalar_one_or_none()
        if existing is not None:
            if existing.organization_id != UUID(org_id):
                raise HTTPException(status_code=403, detail="غير مصرح")
            return ok(svc.branch_dict(existing))  # a retry of the same branch
    try:
        branch = await svc.create_branch(db, UUID(org_id), data.name,
                                         branch_id=data.id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    from ...core import qa_business_ledger, qa_directory
    await qa_directory.bind_first_branch(db, owner, branch)
    await qa_business_ledger.bind_new_ledger_branch(db, owner, branch, session_id=session_id)
    await db.commit()
    return ok(svc.branch_dict(branch))


@router.patch("/{branch_id}", summary="تعديل اسم الفرع")
async def rename_branch(
    branch_id: UUID,
    data: BranchUpdate,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _require_owner(db, user_id, org_id)
    try:
        branch = await svc.rename_branch(db, UUID(org_id), branch_id, data.name)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    await db.commit()
    return ok(svc.branch_dict(branch))


@router.get("/access", summary="الفروع والشركات المتاحة للمستخدم")
async def branch_access(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    return ok(await access.access_summary(db, user_id))


@router.post("/select", summary="اختيار سياق الفرع (رمز موقّع)")
async def select_branch(
    data: BranchSelect,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    session_id: UUID | None = Depends(get_current_session_id),
):
    user = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=403, detail="غير مصرح")
    target_org = data.organization_id or UUID(org_id)
    allowed_ids = await access.effective_branch_ids(db, target_org, user_id)
    if not allowed_ids:
        raise HTTPException(status_code=403,
                            detail="لا تملك صلاحية الوصول إلى فروع هذه الشركة")
    from ...domain.services.merchant_subscription_service import owner_subscription_fields
    subscription = owner_subscription_fields(await db.get(Organization, target_org))
    if data.all:
        if not await access.can_view_all(db, target_org, user_id):
            raise HTTPException(status_code=403,
                                 detail="عرض جميع الفروع غير مصرح لحسابك")
        token = svc.issue_scope_token(user_id, target_org, None, True, allowed_ids)
        return ok({"token": token, "mode": "all", "branch_id": None,
                   "branch_ids": [str(b) for b in allowed_ids],
                    "organization_id": str(target_org), **subscription})
    branch_id = data.branch_id or allowed_ids[0]
    if branch_id not in allowed_ids:
        raise HTTPException(status_code=403,
                            detail="لا تملك صلاحية الوصول إلى هذا الفرع")
    branch = await svc.resolve_branch_for_context(db, target_org, branch_id)
    from ...core import qa_business_ledger, qa_directory
    from ...domain.services import qa_cash_admission, qa_employee_finance
    from ...core import business_local_mode
    if await business_local_mode.whole_organization(db, user, branch):
        # Every branch of this account lives on its devices; the server only
        # carries operations between them (see docs/BUSINESS_SYNC_ENGINE.md).
        local_directory = local_ledger = True
        employee_finance = None
        cash_link = None
        writer_branches = await business_local_mode.branch_names(db, target_org)
    else:
        local_directory = await qa_directory.for_owner(db, user, branch)
        local_ledger = await qa_business_ledger.for_owner(db, user, branch)
        pair = await qa_business_ledger.pair_writer_scope(db, user, branch, session_id) \
            if local_directory or local_ledger else None
        if pair is False:
            raise HTTPException(403, detail="لا تملك صلاحية الوصول إلى هذا الفرع")
        employee_finance = await qa_employee_finance.select_claim(db, user, branch)
        cash_link = await qa_cash_admission.scope_claim(db, branch, user_id, session_id) \
            if local_ledger and local_directory else None
        writer_branches = pair if local_ledger else None
    token = svc.issue_scope_token(
        user_id, target_org, branch.id, False, qa_directory=local_directory,
        qa_business_ledger=local_ledger, qa_employee_finance=employee_finance,
        qa_transfer_branches=writer_branches,
        qa_writer_session=session_id if writer_branches is not None else None,
        qa_cash_link=cash_link,
    )
    return ok({"token": token, "mode": "branch",
               "branch_id": str(branch.id),
               "organization_id": str(target_org),
                "branch": svc.branch_dict(branch), **subscription})


@router.post("/reset-all", summary="تصفير حساب الأعمال بالكامل")
async def reset_all_business(
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    actor = await _require_owner(db, user_id, org_id)
    if await qa_business_ledger.contains_registered_ledger(db, UUID(org_id)):
        raise HTTPException(409, detail="حساب الأعمال فيه فرع يعمل من دفتر الجهاز")
    org = (await db.execute(select(Organization).where(
        Organization.id == UUID(org_id)))).scalar_one_or_none()
    try:
        branch = await lifecycle.reset_whole_business(
            db, UUID(org_id), org.name if org else "")
    except ValueError as e:
        await db.rollback()
        raise HTTPException(status_code=400, detail=str(e))
    await db.commit()
    return ok(svc.branch_dict(branch), "تم تصفير حساب الأعمال بالكامل")


@router.post("/{branch_id}/image", summary="تحديث صورة الفرع")
async def upload_branch_image(
    branch_id: UUID,
    file: UploadFile = File(...),
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    import io
    from datetime import datetime as _dt, timezone as _tz
    from PIL import Image
    from app.core.storage import unified_upload

    await _require_owner(db, user_id, org_id)
    branch = await svc._get(db, UUID(org_id), branch_id, include_archived=True)
    raw = await file.read()
    if not raw or len(raw) > 2 * 1024 * 1024:
        raise HTTPException(status_code=400,
                            detail="الصورة غير صالحة أو تتجاوز 2 ميجابايت")
    try:
        img = Image.open(io.BytesIO(raw))
        img.verify()
        img = Image.open(io.BytesIO(raw))
        if img.mode in ("RGBA", "LA", "P"):
            bg = Image.new("RGB", img.size, (255, 255, 255))
            bg.paste(img, mask=img.split()[-1]
                     if img.mode in ("RGBA", "LA") else None)
            img = bg
        else:
            img = img.convert("RGB")
    except Exception:
        raise HTTPException(status_code=400, detail="ملف الصورة غير صالح")
    img.thumbnail((512, 512))
    out = io.BytesIO()
    img.save(out, format="JPEG", quality=85, optimize=True)
    version = int(_dt.now(_tz.utc).timestamp())
    try:
        rel = await unified_upload(
            "branch_avatars", f"{branch.id}.jpg", out.getvalue(),
            "image/jpeg")
    except Exception:
        from app.core.paths import UPLOAD_ROOT
        from app.core.storage import LocalStorage
        rel = await LocalStorage(UPLOAD_ROOT).upload(
            f"branch_avatars/{branch.id}.jpg",
            io.BytesIO(out.getvalue()), "image/jpeg")
    branch.image = f"uploads/{rel}?v={version}"
    await db.commit()
    return ok({"image": branch.image, "branch": svc.branch_dict(branch)},
              "تم تحديث صورة الفرع")


@router.post("/{branch_id}/reset", summary="تصفير بيانات الفرع")
async def reset_branch(
    branch_id: UUID,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _require_owner(db, user_id, org_id)
    if await qa_business_ledger.contains_registered_branch(db, [branch_id]):
        raise HTTPException(409, detail="دفتر هذا الفرع يعمل من الجهاز فقط")
    branch = await svc._get(db, UUID(org_id), branch_id, include_archived=True)
    try:
        await lifecycle.reset_branch_data(db, UUID(org_id), branch)
    except ValueError as e:
        await db.rollback()
        raise HTTPException(status_code=400, detail=str(e))
    await db.commit()
    return ok({"branch_id": str(branch.id)}, "تم تصفير بيانات الفرع")


@router.delete("/{branch_id}", summary="حذف الفرع نهائيًا وكل بياناته")
async def delete_branch_permanently(
    branch_id: UUID,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _require_owner(db, user_id, org_id)
    if await qa_business_ledger.contains_registered_branch(db, [branch_id]):
        raise HTTPException(409, detail="دفتر هذا الفرع يعمل من الجهاز فقط")
    branch = await svc._get(db, UUID(org_id), branch_id, include_archived=True)
    try:
        await lifecycle.delete_branch_permanently(db, UUID(org_id), branch)
    except ValueError as e:
        await db.rollback()
        raise HTTPException(status_code=400, detail=str(e))
    await db.commit()
    return ok({"branch_id": str(branch.id)}, "تم حذف الفرع نهائيًا")


@router.post("/{branch_id}/archive", summary="أرشفة فرع")
async def archive_branch(
    branch_id: UUID,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _require_owner(db, user_id, org_id)
    try:
        branch = await svc.archive_branch(db, UUID(org_id), branch_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    await db.commit()
    return ok(svc.branch_dict(branch))


@router.post("/{branch_id}/reactivate", summary="إعادة تفعيل فرع")
async def reactivate_branch(
    branch_id: UUID,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _require_owner(db, user_id, org_id)
    try:
        branch = await svc.reactivate_branch(db, UUID(org_id), branch_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    await db.commit()
    return ok(svc.branch_dict(branch))


# ── Membership & invitations ─────────────────────────────────────────
@router.post("/invitations", status_code=201, summary="إرسال دعوة فرع")
async def invite_branch(
    data: InviteCreate,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    actor = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    if actor is None:
        raise HTTPException(status_code=403, detail="غير مصرح")
    try:
        result = await access.invite(
            db, UUID(org_id), actor, data.branch_id, phone=data.phone,
            code=data.code, can_transfer=data.can_transfer)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    await db.commit()
    try:
        from ...domain.services import push_service
        await push_service.push_to_users_now(
            db, [UUID(result["target_user_id"])],
            title=result["title"], body=result["message"],
            action="open_screen", action_payload=result["route"],
            log_type="branch_invite")
    except Exception:
        pass
    return ok(result["invitation"], "تم إرسال الدعوة")


@router.get("/invitations", summary="الدعوات الواردة")
async def my_branch_invitations(
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    rows = await access.incoming_invitations(db, user_id)
    await db.commit()
    return ok({"invitations": rows})


@router.get("/invitations/manage", summary="دعوات الفروع المرسلة (المالك)")
async def manage_invitations(
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    actor = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    try:
        rows = await access.list_invitations(db, UUID(org_id), actor)
    except ValueError as e:
        raise HTTPException(status_code=403, detail=str(e))
    return ok({"invitations": rows})


@router.post("/invitations/{invitation_id}/respond", summary="قبول/رفض دعوة")
async def respond_invitation(
    invitation_id: UUID,
    data: InviteRespond,
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        result = await access.respond(
            db, user_id, invitation_id, data.accept)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    push = result.pop("_push", None)
    await db.commit()
    from ...domain.services.invitation_response_service import deliver
    await deliver(db, push)
    return ok(result)


@router.delete("/invitations/{invitation_id}", summary="سحب دعوة")
async def revoke_invitation(
    invitation_id: UUID,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    actor = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    try:
        await access.revoke_invitation(db, UUID(org_id), actor, invitation_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    await db.commit()
    return ok(None, "تم سحب الدعوة")


@router.get("/members", summary="أعضاء الفروع")
async def list_members(
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    actor = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    try:
        rows = await access.list_members(db, UUID(org_id), actor)
    except ValueError as e:
        raise HTTPException(status_code=403, detail=str(e))
    return ok({"members": rows})


@router.patch("/members/{member_id}", summary="تعديل صلاحيات عضو")
async def update_member(
    member_id: UUID,
    data: MemberUpdate,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    actor = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    try:
        result = await access.update_member(
            db, UUID(org_id), actor, member_id,
            branch_ids=data.branch_ids, all_branches=data.all_branches,
            can_transfer=data.can_transfer, permissions=data.permissions,
            status=data.status)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    await db.commit()
    return ok(result, "تم تحديث العضو")


# ── Per-branch durable preferences ───────────────────────────────────
@router.get("/currencies", summary="عملات الفرع المحفوظة في الحساب")
async def get_branch_currencies(
    org_id: str = Depends(get_current_org_id),
    scope=Depends(get_branch_scope),
    db: AsyncSession = Depends(get_db),
):
    from app.domain.services import branch_service as _bs
    branch_id = scope.branch_id
    if branch_id is None:
        branch_id = (await _bs.main_branch(db, UUID(org_id))).id
    row = (await db.execute(select(Branch).where(
        Branch.id == branch_id, Branch.organization_id == UUID(org_id),
    ))).scalar_one_or_none()
    if row is None:
        raise HTTPException(status_code=404, detail="الفرع غير موجود")
    values = (row.settings or {}).get("enabled_currencies", []) \
        if isinstance(row.settings, dict) else []
    return ok({"currencies": values, "branch_id": str(branch_id)})


@router.put("/currencies", summary="حفظ عملات الفرع في الحساب")
async def save_branch_currencies(
    data: BranchCurrenciesUpdate,
    org_id: str = Depends(get_current_org_id),
    branch=Depends(get_branch_context),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    await _require_owner(db, user_id, org_id)
    cleaned = list(dict.fromkeys(
        c.strip().upper() for c in data.currencies
        if isinstance(c, str) and c.strip()))
    if not cleaned or len(cleaned) > 50:
        raise HTTPException(status_code=400,
                            detail="قائمة العملات غير صالحة")
    branch.settings = {
        **(branch.settings if isinstance(branch.settings, dict) else {}),
        "enabled_currencies": cleaned,
    }
    await db.commit()
    return ok({"currencies": cleaned, "branch_id": str(branch.id)},
              "تم حفظ عملات الفرع")


# ── Transfers ────────────────────────────────────────────────────────
def _transfer_device_conflict(error: transfers.TransferNeedsArbitration) -> HTTPException:
    return HTTPException(409, detail={"code": "transfer_device_scope", "message": str(error)})


@router.get("/transfers/unit-conversion", summary="فحص معامل تحويل الوحدات")
async def unit_conversion(
    from_product_id: UUID,
    to_product_id: UUID,
    from_unit_id: Optional[UUID] = Query(None),
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    from ...domain.services.branch_transfer_service import (
        UnitConversionRequired, unit_conversion_info)
    try:
        result = await unit_conversion_info(
            db, UUID(org_id), from_product_id, to_product_id, from_unit_id)
    except UnitConversionRequired as e:
        return ok({"required": True, **e.info})
    except transfers.TransferNeedsArbitration as e:
        raise _transfer_device_conflict(e) from e
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return ok({"required": False, **result})


@router.get("/transfers/product-match", summary="مطابقة منتج الفرع المستلم")
async def product_match(
    from_product_id: UUID,
    to_branch_id: UUID,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    actor = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    try:
        result = await transfers.product_match(
            db, UUID(org_id), actor, from_product_id, to_branch_id)
    except transfers.TransferNeedsArbitration as e:
        raise _transfer_device_conflict(e) from e
    except ValueError as e:
        raise HTTPException(status_code=403, detail=str(e))
    return ok(result)


@router.get("/transfers/options", summary="بيانات التحويل لفرع محدد")
async def transfer_options(
    branch_id: UUID,
    search: Optional[str] = Query(None),
    include_zero: bool = Query(False),
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    request: Request = None,
):
    actor = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    try:
        result = await transfers.options(
            db, UUID(org_id), actor, branch_id, search,
            include_zero=include_zero)
        policy = getattr(request.state, 'employee_policy', None) if request else None
        if policy is not None:
            from ...domain.services.employee_access_policy import allowed
            from ...core.employee_response_guard import redact_balances
            if not allowed(policy, 'banks.transfer'): result['accounts'] = []
            if not allowed(policy, 'inventory.transfer'):
                result['products'] = []; result['categories'] = []
            if not allowed(policy, 'banks.balances'): result = redact_balances(result)
    except transfers.TransferNeedsArbitration as e:
        raise _transfer_device_conflict(e) from e
    except ValueError as e:
        raise HTTPException(status_code=403, detail=str(e))
    return ok(result)


@router.get("/transfers", summary="التحويلات بين الفروع")
async def list_transfers(
    branch_id: Optional[UUID] = Query(None),
    kind: Optional[str] = Query(None),
    page: int = Query(1, ge=1),
    per_page: int = Query(20, ge=1, le=100),
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
    request: Request = None,
):
    kinds = getattr(request.state, 'employee_transfer_kinds', None) if request else None
    if kinds is not None and len(kinds) == 1: kind = kinds[0]
    actor = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    try:
        rows, total = await transfers.list_transfers(
            db, UUID(org_id), actor, branch_id, kind, page, per_page)
    except transfers.TransferNeedsArbitration as e:
        raise _transfer_device_conflict(e) from e
    except ValueError as e:
        raise HTTPException(status_code=403, detail=str(e))
    return ok_paginated(rows, total, page, per_page)


@router.post("/transfers/financial", status_code=201,
             summary="تحويل مالي بين الفروع")
async def create_financial_transfer(
    data: FinancialTransferCreate,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    actor = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    try:
        result = await transfers.create_financial(
            db, UUID(org_id), actor,
            from_branch_id=data.from_branch_id,
            to_branch_id=data.to_branch_id,
            from_account_id=data.from_account_id,
            to_account_id=data.to_account_id,
            amount=data.amount, exchange_rate=data.exchange_rate,
            allow_negative=data.allow_negative,
            idempotency_key=data.idempotency_key, notes=data.notes)
    except transfers.TransferNeedsArbitration as e:
        raise _transfer_device_conflict(e) from e
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    await _push_transfer(db, UUID(org_id), result["id"])
    return ok(result, "تم التحويل المالي بنجاح")


@router.post("/transfers/inventory", status_code=201,
             summary="تحويل مخزوني بين الفروع")
async def create_inventory_transfer(
    data: InventoryTransferCreate,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    actor = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    try:
        result = await transfers.create_inventory(
            db, UUID(org_id), actor,
            from_branch_id=data.from_branch_id,
            to_branch_id=data.to_branch_id,
            items=[i.model_dump() for i in data.items],
            idempotency_key=data.idempotency_key, notes=data.notes)
    except transfers.UnitConversionRequired as e:
        raise HTTPException(status_code=422, detail={
            "code": "unit_conversion_required", **e.info})
    except transfers.TransferNeedsArbitration as e:
        raise _transfer_device_conflict(e) from e
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    await _push_transfer(db, UUID(org_id), result["id"])
    return ok(result, "تم التحويل المخزوني بنجاح")


@router.get("/transfers/{transfer_id}", summary="تفاصيل تحويل")
async def get_transfer(
    transfer_id: UUID,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    try:
        result = await transfers.detail(db, UUID(org_id), transfer_id)
    except transfers.TransferNeedsArbitration as e:
        raise _transfer_device_conflict(e) from e
    except ValueError as e:
        raise HTTPException(status_code=404, detail=str(e))
    return ok(result)


@router.post("/transfers/{transfer_id}/reverse", summary="عكس تحويل")
async def reverse_transfer(
    transfer_id: UUID,
    data: ReverseRequest,
    org_id: str = Depends(get_current_org_id),
    user_id: UUID = Depends(get_current_user_uuid),
    db: AsyncSession = Depends(get_db),
):
    actor = (await db.execute(select(User).where(
        User.id == user_id))).scalar_one_or_none()
    try:
        original = await transfers.detail(db, UUID(org_id), transfer_id)
        if original["kind"] == "financial":
            result = await transfers.reverse_financial(
                db, UUID(org_id), actor, transfer_id,
                allow_negative=data.allow_negative, notes=data.notes)
        else:
            result = await transfers.reverse_inventory(
                db, UUID(org_id), actor, transfer_id, items=data.items,
                notes=data.notes)
    except transfers.TransferNeedsArbitration as e:
        raise _transfer_device_conflict(e) from e
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    await _push_transfer(db, UUID(org_id), result["id"])
    return ok(result, "تم عكس التحويل بنجاح")


async def _push_transfer(db: AsyncSession, org_id: UUID,
                         transfer_id: str) -> None:
    try:
        from ...domain.services import push_service
        row = await transfers.detail(db, org_id, UUID(transfer_id))
        recipients = await access.branch_recipients(
            db, org_id, UUID(row["to_branch_id"]))
        actor = row.get("actor_user_id")
        if actor:
            recipients = [u for u in recipients if str(u) != str(actor)]
        money = (transfers.format_money_ar(
                     row.get('amount'), row.get('currency'))
                 if row.get('kind') == 'financial' else "تحويل مخزوني")
        body = (f"{row['number']}: {money} من {row['from_branch_name']} "
                f"إلى {row['to_branch_name']}")
        await push_service.push_to_users_now(
            db, recipients, title="تحويل بين الفروع", body=body,
            action="open_screen",
            action_payload=f"/branches/transfers/{transfer_id}",
            log_type="branch_transfer")
    except Exception:
        pass
