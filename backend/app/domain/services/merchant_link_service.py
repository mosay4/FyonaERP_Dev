"""Merchant ↔ Personal accounts service («حساباتي مع التجار»).

The SINGLE source of truth stays the business debt engine: a linked personal
user only ever READS the merchant's own customer/supplier rows for that party.
Nothing is duplicated, and approving a settlement proof goes through the same
`_settle_party` engine used by the business, exactly once.
"""

import json
import hashlib
import os
import secrets
from datetime import date, datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
import re
from typing import Any, Dict, List, Optional
from uuid import UUID, uuid4

from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.entities.auth_entities import Organization, User
from app.domain.entities.business_entities import Customer, Supplier
from app.domain.entities.invoice_entities import (
    Invoice, InvoiceItem, InvoiceItemChange, OrgInvoiceDesign, Payment,
)
from app.domain.entities.notification_entities import AppNotification
from app.domain.entities.purchase_entities import PurchaseOrder
from app.domain.entities.sale_entities import (
    Branch, CustomerReceivable, SupplierPayable,
)
from app.domain.entities.sales_entities import SalesOrder
from app.domain.entities.merchant_entities import (
    DebtGroup, MerchantLink, SettlementRequest, SharedAuditLog, UserCodeSeq,
)
from app.domain.services import sale_service
from app.domain.services import debt_notification_service as debt_notifications
from app.core.phone_lookup import ascii_digits, phone_lookup_keys

_TAU = Decimal("0.005")
_A = 387420489  # bijective permutation multiplier on 0..999_999


def _clean_shop_name(org_name, owner_name=None) -> str:
    """Never show the raw «X's Organization» / «Organization» label."""
    n = (org_name or "").strip()
    n = re.sub(r"\s*'s\s+organization\s*$", "", n, flags=re.I).strip()
    if not n or n.lower() == "organization":
        n = (owner_name or "").strip() or "متجر"
    return n


def _now():
    return datetime.now(timezone.utc)


def _code(n: int) -> str:
    return f"{((n * _A) % 1000000):06d}"


# ── unique 6-digit codes ─────────────────────────────────────────────
async def allocate_public_code(db: AsyncSession) -> str:
    """Atomically take the next code. `FOR UPDATE` serialises concurrent
    callers; the UNIQUE constraint is the final guard."""
    row = (
        await db.execute(
            select(UserCodeSeq).where(UserCodeSeq.id == 1).with_for_update()
        )
    ).scalar_one_or_none()
    if row is None:
        row = UserCodeSeq(id=1, next_val=0)
        db.add(row)
        await db.flush()
        row = (
            await db.execute(
                select(UserCodeSeq).where(UserCodeSeq.id == 1).with_for_update()
            )
        ).scalar_one()
    n = int(row.next_val or 0)
    row.next_val = n + 1
    await db.flush()
    code = _code(n)
    if n >= 1000000:  # capacity exhausted → widen (documented), never reuse
        code = f"1{n:07d}"
    return code


async def ensure_user_code(db: AsyncSession, user: User) -> str:
    if user.public_code:
        return user.public_code
    # Retry a few times in the vanishing case of a unique clash.
    for _ in range(8):
        user.public_code = await allocate_public_code(db)
        try:
            await db.flush()
            return user.public_code
        except Exception:  # noqa: BLE001 (unique violation) → try again
            await db.rollback()
    raise RuntimeError("تعذر إنشاء الرقم المميز")


async def lookup_user(
    db: AsyncSession, phone: Optional[str], code: Optional[str], country: Optional[str] = None
) -> Optional[User]:
    phone = (phone or "").strip()
    code = (code or "").strip()
    if phone and code:
        raise ValueError("اختر رقم الهاتف أو الرقم المميز، وليس الاثنين")
    if code:
        normalized = ascii_digits(code)
        if len(normalized) != len(code) or not normalized:
            return None
        u = (
            await db.execute(select(User).where(User.public_code == normalized,
                                                User.status == "active"))
        ).scalar_one_or_none()
        if u:
            return u
    if phone:
        if country:
            import phonenumbers
            country = country.upper()
            if country not in phonenumbers.SUPPORTED_REGIONS:
                raise ValueError('اختر دولة صحيحة لرقم الهاتف')
            try:
                parsed = phonenumbers.parse(phone, country)
            except phonenumbers.NumberParseException:
                raise ValueError('اكتب رقم الهاتف المحلي بدون رمز الدولة')
            if not phonenumbers.is_possible_number(parsed) or parsed.country_code != phonenumbers.country_code_for_region(country):
                raise ValueError('الرقم لا يطابق الدولة المختارة')
            phone = phonenumbers.format_number(parsed, phonenumbers.PhoneNumberFormat.E164)
        full, national = phone_lookup_keys(phone, country)
        if full is None:
            return None
        matches = (await db.execute(select(User).where(
            User.phone_lookup_digits == full, User.status == "active"
        ).limit(2))).scalars().all()
        if len(matches) > 1:
            raise ValueError("رقم الهاتف مربوط بأكثر من حساب، استخدم الرقم المميز")
        if matches:
            return matches[0]
        digits = ascii_digits(phone)
        if phone.startswith('+') or digits.startswith('00') or len(digits) > 10:
            return None
        matches = (await db.execute(select(User).where(
            User.phone_national_digits == national, User.status == "active"
        ).limit(2))).scalars().all()
        if len(matches) > 1:
            raise ValueError("يوجد أكثر من حساب بهذا الرقم المحلي؛ اكتب رمز الدولة أو الرقم المميز")
        return matches[0] if matches else None
    return None


async def audit(
    db: AsyncSession, org_id: UUID, entity_type: str, entity_id: str,
    action: str, actor: Optional[UUID] = None, before: Any = None,
    after: Any = None, reason: Optional[str] = None,
) -> None:
    db.add(SharedAuditLog(
        organization_id=org_id, entity_type=entity_type, entity_id=str(entity_id),
        action=action, actor_user_id=actor,
        before_json=json.dumps(before, ensure_ascii=False) if before is not None else None,
        after_json=json.dumps(after, ensure_ascii=False) if after is not None else None,
        reason=reason,
    ))


async def _notify(
    db: AsyncSession, org_id: UUID, user_id: Optional[UUID], type_: str,
    title: str, message: str, payload: Optional[dict] = None,
) -> None:
    db.add(AppNotification(
        organization_id=org_id, user_id=user_id, type=type_, title=title,
        message=message, action_payload=json.dumps(payload or {}, ensure_ascii=False),
    ))


# ── invitations ──────────────────────────────────────────────────────
def _party_label(kind: str) -> str:
    return "عميل" if kind == "customer" else "مورد"


async def invite(
    db: AsyncSession, org_id: UUID, actor: UUID, party_kind: str,
    party_id: UUID, phone: Optional[str] = None, code: Optional[str] = None, country: Optional[str] = None,
) -> Dict[str, Any]:
    kind = party_kind
    if kind not in ("customer", "supplier"):
        raise ValueError("نوع الطرف غير صحيح")
    from . import qa_business_party_sharing as sharing
    if sharing.qa_directory.INVITES:
        await sharing.lock_organization(db, org_id)
    # Serialize invitation creation even when no MerchantLink exists yet.
    model = Customer if kind == "customer" else Supplier
    party = (await db.execute(select(model).where(
        model.id == party_id, model.organization_id == org_id,
    ).with_for_update())).scalar_one_or_none()
    if party is None:
        raise ValueError("الطرف غير موجود")
    return await _invite_authorized_party(db, org_id, actor, kind, party_id,
                                          phone, code, country)


async def _invite_authorized_party(
    db, org_id, actor, kind, party_id, phone, code, country, *, target=None,
    rotate_consent_id=False,
):
    """Consent only. Caller must authorize and lock the exact party identity."""
    link = (
        await db.execute(
            select(MerchantLink).where(
                MerchantLink.merchant_org_id == org_id,
                MerchantLink.party_kind == kind,
                MerchantLink.party_id == party_id,
            ).with_for_update()
        )
    ).scalar_one_or_none()
    if link and link.status == "accepted":
        raise ValueError("هذا الطرف مرتبط بالفعل")
    target = target or await lookup_user(db, phone, code, country)
    if target is None:
        raise ValueError("لا يوجد مستخدم بهذا الرقم")
    if link and link.status == "pending" and link.external_user_id == target.id:
        raise ValueError("أُرسلت دعوة بالفعل — بانتظار الموافقة")
    # ONE personal account can be linked to this merchant only ONCE, even if
    # the merchant creates another party with the same phone/public code.
    dup = (await db.execute(
        select(MerchantLink).where(
            MerchantLink.merchant_org_id == org_id,
            MerchantLink.external_user_id == target.id,
            MerchantLink.status.in_(("accepted", "pending")),
            ~((MerchantLink.party_kind == kind)
              & (MerchantLink.party_id == party_id)),
        )
    )).scalars().first()
    if dup is not None:
        label = "الموردين" if dup.party_kind == "supplier" else "العملاء"
        raise ValueError(
            f"هذا الحساب مرتبط لديك مسبقًا في قائمة {label} — "
            "لا يمكن ربطه في الديون أكثر من مرة")
    if not link:
        link = MerchantLink(
            merchant_org_id=org_id, party_kind=kind, party_id=party_id,
            invited_by=actor,
        )
        db.add(link)
    elif rotate_consent_id:
        # A delayed acceptance or unlink for a previous QA invitation must
        # never act on the current consent. The share's party identity stays
        # stable; only the recipient-facing consent handle changes.
        link.id = uuid4()
    link.external_user_id = target.id
    link.phone = target.phone
    link.public_code = target.public_code
    link.linked_via = "phone" if (phone or "").strip() else "code"
    link.display_name = target.full_name
    link.status = "pending"
    link.created_at = _now()
    link.responded_at = None
    await db.flush()
    # AppNotification.event_id is VARCHAR(80); include a compact generation.
    event_id = f"merchant_invite:{link.id}:{link.created_at.strftime('%Y%m%d%H%M%S%f')}"
    # Debt-domain invite (isolated center). Router pushes AFTER commit.
    invite_route = "/personal/merchant-accounts"
    _org_raw = (await db.execute(
        select(Organization.name).where(Organization.id == org_id)
    )).scalar_one_or_none()
    _owner = (await db.execute(
        select(User).where(User.id == actor)
    )).scalar_one_or_none() if actor else None
    _shop = _clean_shop_name(_org_raw, _owner.full_name if _owner else None)
    _title = "طلب ربط جديد"
    # Phone-tray body must stay ONE short line; full details live on the
    # request card the tap opens.
    _msg = f"التاجر {_shop} – يريد ربط دينك لمتابعته بشكل مباشر"
    created = await debt_notifications.emit(
        db, org_id, event_id, [target.id],
        title=_title, message=_msg, route=invite_route,
        payload={"link_id": str(link.id), "to_side": "personal",
                 "actor_user_id": str(actor) if actor else None},
    )
    await audit(db, org_id, "merchant_link", link.id, "invite", actor,
                after={"status": "pending", "user": str(target.id)})
    return {"id": str(link.id), "status": link.status,
            "name": target.full_name, "matched_by": link.linked_via,
            link.linked_via: (phone if link.linked_via == "phone" else code).strip(),
            "kind": kind,
            "_push": {"recipients": [target.id], "title": _title,
                      "message": _msg, "route": invite_route,
                       "event_id": event_id} if created else None}


async def merchant_link_status(
    db: AsyncSession, org_id: UUID, party_kind: str, party_id: UUID
) -> Dict[str, Any]:
    link = (
        await db.execute(
            select(MerchantLink).where(
                MerchantLink.merchant_org_id == org_id,
                MerchantLink.party_kind == party_kind,
                MerchantLink.party_id == party_id,
            )
        )
    ).scalar_one_or_none()
    if not link:
        return {"linked": False, "status": "none",
                "phone": None, "public_code": None, "avatar": None,
                "linked_via": None,
                "contact": {"via": "phone", "value": None}}
    via = link.linked_via or ("phone" if link.phone else "code")
    linked_avatar = None
    if link.external_user_id:
        linked_avatar = (
            await db.execute(
                select(User.avatar).where(User.id == link.external_user_id)
            )
        ).scalar_one_or_none()
    # Both raw identifiers are returned so the detail card can render the
    # «رقم الهاتف / الرقم المميز» footer exactly like the reference; the UI
    # still hides whichever does not exist (never a fake value).
    return {"id": str(link.id), "linked": link.status == "accepted",
            "status": link.status,
            "name": link.display_name,
            "phone": link.phone,
            "public_code": link.public_code,
            "avatar": linked_avatar,
            "linked_via": via,
            "contact": {"via": via,
                        "value": link.phone if via == "phone" else link.public_code}}


async def user_links(db: AsyncSession, user_id: UUID) -> List[Dict[str, Any]]:
    rows = (
        await db.execute(
            select(MerchantLink).where(
                MerchantLink.external_user_id == user_id,
                MerchantLink.status == "accepted",
            ).order_by(MerchantLink.responded_at.desc())
        )
    ).scalars().all()
    out = []
    for l in rows:
        owner = (
            await db.execute(
                select(User).where(
                    User.organization_id == l.merchant_org_id,
                    User.role == "owner",
                ).limit(1)
            )
        ).scalar_one_or_none()
        org = (
            await db.execute(
                select(Organization).where(
                    Organization.id == l.merchant_org_id)
            )
        ).scalar_one_or_none()
        out.append({
            "link_id": str(l.id), "kind": l.party_kind,
            "merchant_name": _clean_shop_name(
                org.name if org else None,
                owner.full_name if owner else None) or "تاجر",
            "merchant_avatar": (org.avatar if org and org.avatar else
                                (owner.avatar if owner else None)),
            "party_name": l.display_name,
            "status": l.status,
        })
    return out


async def user_invites(db: AsyncSession, user_id: UUID) -> List[Dict[str, Any]]:
    rows = (
        await db.execute(
            select(MerchantLink).where(
                MerchantLink.external_user_id == user_id,
                MerchantLink.status == "pending",
            ).order_by(MerchantLink.created_at.desc())
        )
    ).scalars().all()
    out = []
    for l in rows:
        owner = (
            await db.execute(
                select(User).where(
                    User.organization_id == l.merchant_org_id,
                    User.role == "owner",
                ).limit(1)
            )
        ).scalar_one_or_none()
        org = (
            await db.execute(
                select(Organization).where(
                    Organization.id == l.merchant_org_id)
            )
        ).scalar_one_or_none()
        out.append({
            "link_id": str(l.id), "kind": l.party_kind,
            "merchant_name": (owner.full_name if owner else None) or "تاجر",
            "shop_name": _clean_shop_name(
                org.name if org else None,
                owner.full_name if owner else None),
            "merchant_phone": owner.phone if owner else None,
            "merchant_code": owner.public_code if owner else None,
            "merchant_avatar": (org.avatar if org and org.avatar else
                                (owner.avatar if owner else None)),
            "my_name": l.display_name,
            "created_at": l.created_at.isoformat() if l.created_at else None,
        })
    return out


async def _party_display_name(db, link) -> str:
    model = Customer if link.party_kind == "customer" else Supplier
    name = (await db.execute(
        select(model.name).where(model.id == link.party_id)
    )).scalar_one_or_none()
    return (name or "").strip()


async def respond(
    db: AsyncSession, user_id: UUID, link_id: UUID, accept: bool
) -> Dict[str, Any]:
    link = (
        await db.execute(
            select(MerchantLink).where(
                MerchantLink.id == link_id,
                MerchantLink.external_user_id == user_id,
            ).with_for_update()
        )
    ).scalar_one_or_none()
    if not link:
        raise ValueError("الدعوة غير موجودة")
    if link.status != "pending":
        return {"status": link.status}
    from . import qa_business_party_sharing as sharing
    local_share = await sharing.is_share(db, link)
    party = None
    if local_share:
        await sharing.authorized_recipient_read(db, link, require_accepted=False)
    else:
        pmodel = Customer if link.party_kind == "customer" else Supplier
        party = (await db.execute(select(pmodel).where(
            pmodel.id == link.party_id,
            pmodel.organization_id == link.merchant_org_id))).scalar_one_or_none()
        if party is None:
            raise ValueError("الطرف غير موجود")
    link.status = "accepted" if accept else "rejected"
    link.responded_at = _now()
    if accept and party is not None:
        # A previously removed (hidden) party becomes visible again.
        if party.is_deleted:
            party.is_deleted = False
            party.deleted_at = None
            party.is_active = True
    await db.flush()
    # Emit-only here (transactional outbox). The router pushes AFTER commit.
    party_route = ("/customers/detail" if link.party_kind == "customer"
                   else "/suppliers/detail") + f"?id={link.party_id}"
    if local_share:
        party_route = "/suppliers" if link.party_kind == "supplier" else "/customers"
    _who = ((party.name if party is not None else None) or link.display_name or "العميل")
    from app.domain.services.invitation_response_service import emit
    push = await emit(db, org_id=link.merchant_org_id,
        inviter_id=link.invited_by,
        event_id=f"link_{'accepted' if accept else 'rejected'}:{link.id}:{link.created_at.strftime('%Y%m%d%H%M%S%f')}",
        message=f"{_who} {'وافق على دعوتك' if accept else 'رفض دعوتك'}",
        route=party_route)
    try:
        await debt_notifications.mark_event_read(
            db, user_id, f"merchant_invite:{link.id}")
        await debt_notifications.mark_event_read(
            db, user_id, f"merchant_invite:{link.id}:{link.created_at.strftime('%Y%m%d%H%M%S%f')}")
    except Exception:  # noqa: BLE001
        pass
    await audit(db, link.merchant_org_id, "merchant_link", link.id,
                "accept" if accept else "reject", user_id,
                after={"status": link.status})
    return {"status": link.status, "_push": push}


# ── opening balance debt ─────────────────────────────────────────────
async def create_opening_debt(
    db: AsyncSession, org_id: UUID, actor: UUID, kind: str, party_id: UUID,
    amount: Decimal, currency: str,
) -> Dict[str, Any]:
    """Create the initial «رصيد افتتاحي» debt for a newly added party: one
    confirmed invoice + one explicit receivable/payable, so the party behaves
    exactly like any other debt from that moment on."""
    if kind not in ("customer", "supplier"):
        raise ValueError("نوع الطرف غير صحيح")
    if amount is None or Decimal(str(amount)) <= 0:
        raise ValueError("المبلغ يجب أن يكون أكبر من صفر")
    cur = (currency or "SAR").strip().upper() or "SAR"
    model = Customer if kind == "customer" else Supplier
    party = (await db.execute(select(model).where(
        model.id == party_id, model.organization_id == org_id,
        model.is_deleted.is_(False)))).scalar_one_or_none()
    if party is None:
        raise ValueError("الطرف غير موجود")
    amt = Decimal(str(amount)).quantize(Decimal("0.01"))
    number = (f"OPEN-{date.today().strftime('%Y%m%d')}-"
              f"{secrets.token_hex(3).upper()}")
    inv = Invoice(
        organization_id=org_id, invoice_number=number,
        invoice_type="sale" if kind == "customer" else "purchase",
        customer_id=party_id if kind == "customer" else None,
        supplier_id=party_id if kind == "supplier" else None,
        invoice_date=date.today(), status="confirmed",
        subtotal=amt, total=amt, paid_amount=Decimal("0"), balance=amt,
        currency=cur, notes="رصيد افتتاحي", confirmed_at=_now(),
        created_by=actor,
    )
    db.add(inv)
    await db.flush()
    db.add(InvoiceItem(invoice_id=inv.id, description="رصيد افتتاحي",
                       quantity=1, unit_price=amt, total=amt,
                       is_service=True))
    if kind == "customer":
        db.add(CustomerReceivable(
            organization_id=org_id, customer_id=party_id, invoice_id=inv.id,
            amount=amt, paid=Decimal("0"), status="open"))
    else:
        db.add(SupplierPayable(
            organization_id=org_id, supplier_id=party_id, invoice_id=inv.id,
            amount=amt, paid=Decimal("0"), status="open"))
    await audit(db, org_id, "invoice", inv.id, "opening_debt", actor,
                after={"party_kind": kind, "party_id": str(party_id),
                       "amount": str(amt), "currency": cur})
    return {"invoice_id": str(inv.id), "number": number,
            "amount": float(amt), "currency": cur}


# ── unlinking ────────────────────────────────────────────────────────
async def user_unlink(
    db: AsyncSession, user_id: UUID, link_id: UUID
) -> Dict[str, Any]:
    """The PERSONAL user cancels the link. The merchant's party row and its
    debts stay untouched — only the binding is revoked (re-linking needs a
    fresh invitation from the merchant)."""
    link = (
        await db.execute(
            select(MerchantLink).where(
                MerchantLink.id == link_id,
                MerchantLink.external_user_id == user_id,
            ).with_for_update()
        )
    ).scalar_one_or_none()
    if not link:
        raise ValueError("الربط غير موجود")
    if link.status != "accepted":
        raise ValueError("لا يوجد ربط فعّال")
    before = {"status": link.status}
    link.status = "revoked"
    link.responded_at = _now()
    await db.flush()
    from . import qa_business_party_sharing as sharing
    if await sharing.is_share(db, link):
        await sharing.clear_publication(db, link)
        party_route = "/suppliers" if link.party_kind == "supplier" else "/customers"
        who = link.display_name or "العميل"
    else:
        party_route = ("/customers/detail" if link.party_kind == "customer"
                       else "/suppliers/detail") + f"?id={link.party_id}"
        who = (await _party_display_name(db, link)) or link.display_name or "العميل"
    push_route = "/debts/notifications?tab=alerts"
    title = "إلغاء الربط"
    message = f"{who} ألغى الربط"
    event_id = f"link_revoked:{link.id}"
    await debt_notifications.emit(
        db, link.merchant_org_id, event_id,
        [link.invited_by] if link.invited_by else [],
        title=title, message=message, route=party_route,
        payload={"link_id": str(link.id), "revoked_by": "user",
                 "to_side": "merchant", "actor_user_id": str(user_id)})
    await audit(db, link.merchant_org_id, "merchant_link", link.id,
                "unlink_user", user_id, before=before,
                after={"status": "revoked"})
    push = None
    if link.invited_by:
        push = {"recipients": [link.invited_by], "title": title,
                "message": message, "route": push_route,
                "event_id": event_id}
    return {"status": "revoked", "_push": push}


def _backup_dir() -> str:
    base = os.environ.get("FYONA_BACKUP_DIR") or os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.dirname(os.path.abspath(__file__))))), "backups")
    path = os.path.join(base, "party_deletions")
    os.makedirs(path, exist_ok=True)
    return path


def _iso(v):
    if isinstance(v, UUID):
        return str(v)
    if isinstance(v, Decimal):
        return str(v)
    return v.isoformat() if hasattr(v, "isoformat") else v


async def _party_snapshot(db: AsyncSession, org_id: UUID, kind: str,
                          party_id: UUID) -> Dict[str, Any]:
    """Everything the delete touches, captured BEFORE any change."""
    model = Customer if kind == "customer" else Supplier
    party = (await db.execute(select(model).where(
        model.id == party_id, model.organization_id == org_id))).scalar_one_or_none()
    snap: Dict[str, Any] = {
        "kind": kind,
        "party": ({c.name: _iso(getattr(party, c.name)) for c in party.__table__.columns}
                  if party is not None else None),
        "links": [], "debt_groups": [], "settlement_requests": [],
        "invoices": [], "debts": [], "orders": [],
    }
    if party is None:
        return snap
    links = (await db.execute(select(MerchantLink).where(
        MerchantLink.merchant_org_id == org_id,
        MerchantLink.party_kind == kind,
        MerchantLink.party_id == party_id))).scalars().all()
    snap["links"] = [{"id": str(l.id), "status": l.status,
                      "external_user_id": str(l.external_user_id) if l.external_user_id else None}
                     for l in links]
    groups = (await db.execute(select(DebtGroup).where(
        DebtGroup.organization_id == org_id,
        DebtGroup.party_kind == kind,
        DebtGroup.party_id == party_id))).scalars().all()
    snap["debt_groups"] = [{"id": str(g.id), "name": g.name} for g in groups]
    proofs = (await db.execute(select(SettlementRequest).where(
        SettlementRequest.organization_id == org_id,
        SettlementRequest.party_kind == kind,
        SettlementRequest.party_id == party_id))).scalars().all()
    snap["settlement_requests"] = [{"id": str(r.id), "status": r.status,
                                    "amount": str(r.amount)} for r in proofs]
    inv_col = Invoice.customer_id if kind == "customer" else Invoice.supplier_id
    invoices = (await db.execute(select(Invoice).where(
        Invoice.organization_id == org_id, inv_col == party_id))).scalars().all()
    snap["invoices"] = [{"id": str(i.id), "number": i.invoice_number,
                         "type": i.invoice_type, "total": str(i.total),
                         "paid": str(i.paid_amount), "balance": str(i.balance),
                         "status": i.status,
                         "deleted": bool(i.is_deleted)} for i in invoices]
    for entity, col in ((CustomerReceivable, CustomerReceivable.customer_id),
                        (SupplierPayable, SupplierPayable.supplier_id),
                        (SalesOrder, SalesOrder.customer_id),
                        (PurchaseOrder, PurchaseOrder.supplier_id)):
        if (entity is SalesOrder and kind != "customer") or (
                entity is PurchaseOrder and kind != "supplier"):
            continue
        try:
            rows = (await db.execute(select(entity).where(
                entity.organization_id == org_id, col == party_id))).scalars().all()
        except Exception:
            continue
        key = "debts" if entity in (CustomerReceivable, SupplierPayable) else "orders"
        snap[key].extend([{"id": str(r.id)} for r in rows])
    return snap


async def merchant_delete_party(
    db: AsyncSession, org_id: UUID, actor: UUID, kind: str, party_id: UUID,
) -> Dict[str, Any]:
    """Delete a customer/supplier from the merchant's debt section.

    • linked (accepted/pending link) → revoke the binding, notify the personal
      user, and hide the party (soft delete). Debts stay intact.
    • not linked → permanent delete with a JSON backup taken first; the FK
      rules anonymise the invoices (SET NULL) and drop the explicit debt rows
      (CASCADE), so remaining balances stay but their source becomes unknown.
    """
    if kind not in ("customer", "supplier"):
        raise ValueError("نوع الطرف غير صحيح")
    model = Customer if kind == "customer" else Supplier
    party = (await db.execute(select(model).where(
        model.id == party_id, model.organization_id == org_id,
        model.is_deleted.is_(False)))).scalar_one_or_none()
    if party is None:
        raise ValueError("الطرف غير موجود")
    snapshot = await _party_snapshot(db, org_id, kind, party_id)
    filename = f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S')}_{kind}_{party_id}.json"
    try:
        with open(os.path.join(_backup_dir(), filename), "w", encoding="utf-8") as fh:
            json.dump(snapshot, fh, ensure_ascii=False, indent=2)
    except Exception:
        pass  # the audit row below keeps a second copy of the essentials
    link = (await db.execute(select(MerchantLink).where(
        MerchantLink.merchant_org_id == org_id,
        MerchantLink.party_kind == kind,
        MerchantLink.party_id == party_id))).scalar_one_or_none()
    linked = bool(link is not None and link.external_user_id
                  and link.status in ("accepted", "pending"))
    label = "العميل" if kind == "customer" else "المورد"
    push = None
    if linked:
        before = {"status": link.status}
        link.status = "revoked"
        link.responded_at = _now()
        await db.flush()
        title = "إلغاء الربط"
        message = "ألغى التاجر الربط بينكما"
        event_id = f"link_revoked_by_merchant:{link.id}"
        await debt_notifications.emit(
            db, org_id, event_id, [link.external_user_id],
            title=title, message=message,
            route="/personal/merchant-accounts",
            payload={"link_id": str(link.id), "revoked_by": "merchant",
                     "to_side": "personal", "actor_user_id": str(actor)})
        party.is_deleted = True
        party.deleted_at = _now()
        party.is_active = False
        await audit(db, org_id, "merchant_link", link.id, "unlink_merchant",
                    actor, before=before, after={"status": "revoked"})
        push = {"recipients": [link.external_user_id], "title": title,
                "message": message, "route": "/personal/merchant-accounts",
                "event_id": event_id}
    else:
        await db.execute(delete(MerchantLink).where(
            MerchantLink.merchant_org_id == org_id,
            MerchantLink.party_kind == kind,
            MerchantLink.party_id == party_id))
        await db.execute(delete(DebtGroup).where(
            DebtGroup.organization_id == org_id,
            DebtGroup.party_kind == kind,
            DebtGroup.party_id == party_id))
        await db.execute(delete(SettlementRequest).where(
            SettlementRequest.organization_id == org_id,
            SettlementRequest.party_kind == kind,
            SettlementRequest.party_id == party_id))
        await audit(db, org_id, kind, party_id, "delete_party", actor,
                    before=snapshot, reason=f"delete unlinked {label} + debts")
        await db.flush()
        await db.delete(party)
        await db.flush()
    await audit(db, org_id, kind, party_id, "delete_party_backup", actor,
                after={"backup": filename, "linked": linked},
                reason=f"backup before deleting {label}")
    return {"deleted": True, "linked": linked, "backup": filename,
            "_push": push}


# ── partner detail (personal side) ───────────────────────────────────
async def _link_for_user(
    db: AsyncSession, user_id: UUID, link_id: UUID
) -> MerchantLink:
    link = (
        await db.execute(
            select(MerchantLink).where(
                MerchantLink.id == link_id,
                MerchantLink.external_user_id == user_id,
                MerchantLink.status == "accepted",
            )
        )
    ).scalar_one_or_none()
    if not link:
        raise ValueError("لا يوجد ربط")
    return link


async def _party_balance(db: AsyncSession, link: MerchantLink) -> Dict[str, Any]:
    from . import qa_business_party_sharing as sharing
    if await sharing.is_share(db, link):
        row = await sharing.authorized_recipient_read(db, link)
        return {"debts": sharing.debt_rows(row["snapshot"]),
                "published_at": row["published_at"]}
    if link.party_kind == "customer":
        return await sale_service.customer_balance(
            db, link.merchant_org_id, link.party_id)
    return await sale_service.supplier_balance(
        db, link.merchant_org_id, link.party_id)


async def partner_detail(
    db: AsyncSession, user_id: UUID, link_id: UUID
) -> Dict[str, Any]:
    link = await _link_for_user(db, user_id, link_id)
    bal = await _party_balance(db, link)
    merchant = (
        await db.execute(
            select(User.full_name).where(
                User.organization_id == link.merchant_org_id,
                User.role == "owner",
            ).limit(1)
        )
    ).scalar_one_or_none()
    # Identity per how the party was actually linked — phone OR public code,
    # never the email, never both.
    via = link.linked_via or ("phone" if link.phone else "code")
    contact = {"via": via,
               "value": (link.phone or "") if via == "phone"
               else (link.public_code or "")}
    return {
        "link_id": str(link.id), "kind": link.party_kind,
        "merchant_name": merchant or "تاجر",
        "party_name": link.display_name,
        "contact": contact,
        "debts": bal.get("debts", bal),
        **({"published_at": bal["published_at"]} if "published_at" in bal else {}),
    }


async def partner_invoices(
    db: AsyncSession, user_id: UUID, link_id: UUID
) -> List[Dict[str, Any]]:
    link = await _link_for_user(db, user_id, link_id)
    from . import qa_business_party_sharing as sharing
    if await sharing.is_share(db, link):
        row = await sharing.authorized_recipient_read(db, link)
        return sharing.operations(row["snapshot"], link.party_kind)
    col = Invoice.customer_id if link.party_kind == "customer" else Invoice.supplier_id
    rows = (
        await db.execute(
            select(Invoice).where(
                col == link.party_id,
                Invoice.organization_id == link.merchant_org_id,
                Invoice.is_deleted.is_(False),
            ).order_by(Invoice.invoice_date.desc(), Invoice.created_at.desc(), Invoice.id.desc()).limit(200)
        )
    ).scalars().all()
    return [
        {
            "id": str(i.id), "number": i.invoice_number, "type": i.invoice_type,
            "date": i.invoice_date.isoformat() if i.invoice_date else None,
            "total": float(i.total or 0), "paid": float(i.paid_amount or 0),
            "remaining": float(i.balance or 0), "currency": i.currency,
            "status": i.status,
        }
        for i in rows
    ]


# ── settlement proof (customer request → merchant decision) ──────────
async def create_settlement_request(
    db: AsyncSession, user_id: UUID, link_id: UUID, amount: Decimal,
    currency: str, method: Optional[str], reference: Optional[str],
    receipt_url: Optional[str], note: Optional[str],
    idempotency_key: Optional[str],
) -> Dict[str, Any]:
    link = await _link_for_user(db, user_id, link_id)
    from . import qa_business_party_sharing as sharing
    if await sharing.is_share(db, link):
        raise ValueError("هذه المشاركة لمتابعة الدين فقط ولا ترحّل طلبات السداد")
    if amount <= 0:
        raise ValueError("المبلغ غير صحيح")
    # Serialize retries on the relationship; never reveal another user's key.
    await db.execute(select(MerchantLink).where(MerchantLink.id == link.id).with_for_update())
    if idempotency_key:
        existing = (
            await db.execute(
                select(SettlementRequest).where(
                    SettlementRequest.idempotency_key == idempotency_key)
            )
        ).scalar_one_or_none()
        if existing:
            if existing.external_user_id != user_id or existing.link_id != link_id:
                raise ValueError("مفتاح الطلب مستخدم")
            if existing.amount != amount or existing.currency != currency.upper():
                raise ValueError("لا يمكن تغيير بيانات طلب سبق إرساله")
            return {"id": str(existing.id), "status": existing.status,
                    "duplicate": True}
    req = SettlementRequest(
        organization_id=link.merchant_org_id, party_kind=link.party_kind,
        party_id=link.party_id, link_id=link.id, external_user_id=user_id,
        amount=amount, currency=(currency or "SAR").upper(), method=method,
        reference=reference, receipt_url=receipt_url, note=note,
        idempotency_key=idempotency_key or secrets.token_hex(16),
        status="pending",
    )
    db.add(req)
    await db.flush()
    # Emit-only; the router pushes AFTER commit so no push precedes persistence.
    # The RECIPIENT here is the merchant (invited_by) → the deep link must open
    # the merchant's BUSINESS party detail, not the personal screen.
    _route = ("/customers/detail" if link.party_kind == "customer"
              else "/suppliers/detail") + f"?id={link.party_id}&req={req.id}"
    _title = "طلب إثبات سداد"
    _msg = (f"{link.display_name or 'عميل'} يسجّل سداد "
            f"{amount} {req.currency} — بانتظار اعتمادك")
    await debt_notifications.emit(
        db, link.merchant_org_id, f"settlement_request:{req.id}",
        [link.invited_by], title=_title, message=_msg, route=_route,
        payload={"request_id": str(req.id), "link_id": str(req.link_id),
                 "to_side": "merchant", "actor_user_id": str(user_id)},
    )
    await audit(db, link.merchant_org_id, "settlement_request", req.id,
                "request", user_id, after={"amount": str(amount)})
    return {"id": str(req.id), "status": "pending",
            "_push": {"recipients": [link.invited_by], "title": _title,
                      "message": _msg, "route": _route,
                      "event_id": f"settlement_request:{req.id}"}}


async def user_settlement_requests(
    db: AsyncSession, user_id: UUID, link_id: UUID
) -> List[Dict[str, Any]]:
    """The linked user's own proof requests for this merchant relation —
    so the personal side can track pending/approved/rejected states."""
    link = await _link_for_user(db, user_id, link_id)
    rows = (
        await db.execute(
            select(SettlementRequest).where(
                SettlementRequest.link_id == link.id,
                SettlementRequest.external_user_id == user_id,
            ).order_by(SettlementRequest.created_at.desc()).limit(50)
        )
    ).scalars().all()
    return [
        {"id": str(r.id), "amount": str(r.amount), "currency": r.currency,
         "method": r.method, "reference": r.reference,
         "status": r.status, "reject_reason": r.reject_reason,
         "created_at": r.created_at.isoformat() if r.created_at else None}
        for r in rows
    ]


async def list_settlement_requests(
    db: AsyncSession, org_id: UUID, party_kind: str, party_id: UUID
) -> List[Dict[str, Any]]:
    rows = (
        await db.execute(
            select(SettlementRequest).where(
                SettlementRequest.organization_id == org_id,
                SettlementRequest.party_kind == party_kind,
                SettlementRequest.party_id == party_id,
            ).order_by(SettlementRequest.created_at.desc()).limit(100)
        )
    ).scalars().all()
    return [
        {"id": str(r.id), "amount": float(r.amount), "currency": r.currency,
         "method": r.method, "reference": r.reference,
         "receipt_url": r.receipt_url, "note": r.note, "status": r.status,
         "reject_reason": r.reject_reason,
         "created_at": r.created_at.isoformat() if r.created_at else None}
        for r in rows
    ]


async def _open_balance(db, org_id, party_kind, party_id, currency) -> Decimal:
    """Sum the party's OPEN invoice balances in the settlement currency — used
    to tell the customer whether the debt is now fully settled or partial."""
    col = (Invoice.customer_id if party_kind == "customer"
           else Invoice.supplier_id)
    rows = (
        await db.execute(
            select(Invoice.balance, Invoice.currency).where(
                Invoice.organization_id == org_id,
                col == party_id,
                Invoice.is_deleted.is_(False),
                Invoice.status.notin_(["draft", "cancelled"]),
            )
        )
    ).all()
    total = Decimal(0)
    for bal, cur in rows:
        if (cur or "").upper() == (currency or "").upper():
            total += Decimal(str(bal or 0))
    return max(total, Decimal(0))


async def decide_settlement_request(
    db: AsyncSession, org_id: UUID, actor: UUID, request_id: UUID,
    approve: bool, bank_account_id: Optional[UUID] = None,
    reason: Optional[str] = None,
) -> Dict[str, Any]:
    req = (
        await db.execute(
            select(SettlementRequest).where(
                SettlementRequest.id == request_id,
                SettlementRequest.organization_id == org_id,
            ).with_for_update()
        )
    ).scalar_one_or_none()
    if not req:
        raise ValueError("الطلب غير موجود")
    if req.status != "pending":
        return {"status": req.status}  # idempotent — never applied twice
    if not approve:
        if not (reason or "").strip():
            raise ValueError("اكتب سبب الرفض")
        req.status = "rejected"
        req.reject_reason = reason.strip()
        req.decided_at = _now()
        await db.flush()
        _route = f"/personal/merchant-partner?link={req.link_id}&req={req.id}"
        _title = "رفض طلب السداد"
        _msg = f"رُفض طلبك: {reason.strip()}"
        await debt_notifications.emit(
            db, org_id, f"settlement_rejected:{req.id}", [req.external_user_id],
            title=_title, message=_msg, route=_route,
            payload={"request_id": str(req.id), "link_id": str(req.link_id),
                     "to_side": "personal", "actor_user_id": str(actor)})
        await audit(db, org_id, "settlement_request", req.id, "reject", actor,
                    reason=reason)
        return {"status": "rejected",
                "_push": {"recipients": [req.external_user_id], "title": _title,
                          "message": _msg, "route": _route,
                          "event_id": f"settlement_rejected:{req.id}"}}
    if not bank_account_id:
        raise ValueError("اختر الحساب الذي استلمت فيه")
    # Apply through the SAME engine as the business — exactly once.
    from app.domain.models.invoice_models import PartyPaymentRequest

    data = PartyPaymentRequest(
        bank_account_id=bank_account_id, amount=req.amount,
        currency=req.currency, payment_method=req.method or "cash",
        reference=req.reference, notes=req.note,
    )
    if req.party_kind == "customer":
        await sale_service.add_customer_payment(
            db, org_id, actor, req.party_id, data, notify_linked=False)
    else:
        await sale_service.add_supplier_payment(
            db, org_id, actor, req.party_id, data, notify_linked=False)
    req.status = "approved"
    req.decided_at = _now()
    await db.flush()
    remaining = await _open_balance(
        db, org_id, req.party_kind, req.party_id, req.currency)
    fully = remaining <= Decimal("0.004")
    _route = f"/personal/merchant-partner?link={req.link_id}"
    _title = "تم اعتماد السداد"
    _msg = (f"اعتمد التاجر سدادك {req.amount} {req.currency}"
            + (" — مكتمل السداد" if fully else
               f" — سداد جزئي، المتبقي {remaining} {req.currency}"))
    await debt_notifications.emit(
        db, org_id, f"settlement_approved:{req.id}", [req.external_user_id],
        title=_title, message=_msg, route=_route,
        payload={"request_id": str(req.id), "link_id": str(req.link_id),
                 "settlement_status": "full" if fully else "partial",
                 "remaining": str(remaining), "to_side": "personal",
                 "actor_user_id": str(actor)})
    await audit(db, org_id, "settlement_request", req.id, "approve", actor,
                after={"amount": str(req.amount), "currency": req.currency})
    return {"status": "approved",
            "_push": {"recipients": [req.external_user_id], "title": _title,
                      "message": _msg, "route": _route,
                      "event_id": f"settlement_approved:{req.id}"}}


# ── debt groups (organisation only) ──────────────────────────────────
async def business_party(db, org_id, kind, party_id):
    if kind not in ("customer", "supplier"):
        raise ValueError("نوع الطرف غير صحيح")
    model = Customer if kind == "customer" else Supplier
    party = (await db.execute(select(model).where(
        model.id == party_id, model.organization_id == org_id,
        model.is_deleted.is_(False)))).scalar_one_or_none()
    if not party:
        raise ValueError("الطرف غير موجود")
    return party


async def owned_group(db, org_id, kind, party_id, group_id):
    group = (await db.execute(select(DebtGroup).where(
        DebtGroup.id == group_id, DebtGroup.organization_id == org_id,
        DebtGroup.party_kind == kind, DebtGroup.party_id == party_id))).scalar_one_or_none()
    if not group:
        raise ValueError("القسم غير موجود")
    return group


async def manage_group(db, org_id, actor, group_id, name=None, remove=False):
    group = (await db.execute(select(DebtGroup).where(
        DebtGroup.id == group_id, DebtGroup.organization_id == org_id).with_for_update())).scalar_one_or_none()
    if not group:
        raise ValueError("القسم غير موجود")
    before = group.name
    if remove:
        # Deleting a folder ONLY unassigns its invoices. Financial rows survive.
        await db.execute(update(Invoice).where(Invoice.organization_id == org_id,
            Invoice.debt_group_id == group.id).values(debt_group_id=None))
        await db.delete(group)
    else:
        if not name or not name.strip() or len(name.strip()) > 100:
            raise ValueError("اكتب اسم قسم صالح")
        group.name = name.strip()
    await audit(db, org_id, "debt_group", group_id, "delete" if remove else "rename",
                actor, before={"name": before}, after={"name": name})
    await db.flush()
    return {"id": str(group_id)}


async def assign_group(db, org_id, actor, kind, party_id, invoice_id, group_id):
    await business_party(db, org_id, kind, party_id)
    if group_id:
        await owned_group(db, org_id, kind, party_id, group_id)
    col = Invoice.customer_id if kind == "customer" else Invoice.supplier_id
    inv = (await db.execute(select(Invoice).where(Invoice.id == invoice_id,
        Invoice.organization_id == org_id, col == party_id,
        Invoice.is_deleted.is_(False)).with_for_update())).scalar_one_or_none()
    if not inv:
        raise ValueError("العملية غير موجودة")
    if inv.debt_group_id == group_id:
        return {"id": str(inv.id)}
    before = str(inv.debt_group_id) if inv.debt_group_id else None
    inv.debt_group_id = group_id
    await audit(db, org_id, "invoice", inv.id, "assign_group", actor,
                before={"group_id": before}, after={"group_id": str(group_id) if group_id else None})
    await db.flush()
    return {"id": str(inv.id)}


async def business_overview(db, org_id, kind, party_id,
                            group_id=None, display_currency=None,
                            date_from=None, date_to=None):
    party = await business_party(db, org_id, kind, party_id)
    data = await debt_overview_for_party(
        db, org_id, kind, party_id, display_currency, group_id,
        date_from=date_from, date_to=date_to)
    link = await merchant_link_status(db, org_id, kind, party_id)
    data["party"] = {"id": str(party.id), "name": party.name,
                     "phone": party.phone,
                     "created_at": party.created_at.isoformat() if party.created_at else None}
    # Same identity rule as the personal side: phone OR code per linked_via.
    data["link"] = link
    data["contact"] = link.get("contact", {"via": "phone", "value": party.phone})
    data["requests"] = await list_settlement_requests(db, org_id, kind, party_id)
    return data


async def list_debt_groups(
    db: AsyncSession, org_id: UUID, party_kind: str, party_id: UUID
) -> List[Dict[str, Any]]:
    rows = (
        await db.execute(
            select(DebtGroup).where(
                DebtGroup.organization_id == org_id,
                DebtGroup.party_kind == party_kind,
                DebtGroup.party_id == party_id,
            ).order_by(DebtGroup.created_at.desc())
        )
    ).scalars().all()
    return [{"id": str(g.id), "name": g.name, "kind": g.kind,
             "period": g.period} for g in rows]


async def create_debt_group(
    db: AsyncSession, org_id: UUID, actor: UUID, party_kind: str,
    party_id: UUID, name: str, kind: str = "manual", period: Optional[str] = None,
) -> Dict[str, Any]:
    if not (name or "").strip():
        raise ValueError("اكتب اسم المجموعة")
    await business_party(db, org_id, party_kind, party_id)
    if len(name.strip()) > 100:
        raise ValueError("اسم القسم طويل")
    g = DebtGroup(organization_id=org_id, party_kind=party_kind,
                  party_id=party_id, name=name.strip(),
                  kind="auto" if kind == "auto" else "manual", period=period)
    db.add(g)
    await db.flush()
    await audit(db, org_id, "debt_group", g.id, "create", actor,
                after={"name": g.name})
    return {"id": str(g.id), "name": g.name}


# ── partner debt overview (grouped + multi-currency display) ─────────
async def partner_debt_overview(
    db: AsyncSession, user_id: UUID, link_id: UUID,
    display_currency: Optional[str] = None,
    group_id: Optional[UUID] = None,
    date_from: Optional[str] = None,
    date_to: Optional[str] = None,
) -> Dict[str, Any]:
    """The merchant's REAL debts for this party — one source of truth, no
    duplication: raw per-currency totals, a converted display total via the
    approved CentralFXEngine (never summing mixed currencies), the individual
    operations (no group assigned) and the groups with their counts."""
    link = await _link_for_user(db, user_id, link_id)
    from . import qa_business_party_sharing as sharing
    if await sharing.is_share(db, link):
        if group_id is not None:
            raise ValueError("المجموعة غير متاحة في هذه المشاركة")
        row = await sharing.authorized_recipient_read(db, link)
        return sharing.overview(
            row, link, display_currency, date_from=date_from, date_to=date_to)
    return await debt_overview_for_party(
        db, link.merchant_org_id, link.party_kind, link.party_id,
        display_currency, group_id, link_id=str(link.id),
        date_from=date_from, date_to=date_to)


async def debt_overview_for_party(db, org_id, kind, party_id,
                                  display_currency=None, group_id=None, link_id=None,
                                  date_from=None, date_to=None):
    from app.domain.services.currency_service import CentralFXEngine
    from app.domain.entities.sale_entities import (
    Branch, CustomerReceivable, SupplierPayable,
)
    await business_party(db, org_id, kind, party_id)
    if group_id:
        await owned_group(db, org_id, kind, party_id, group_id)
    model = CustomerReceivable if kind == "customer" else SupplierPayable
    party_col = model.customer_id if kind == "customer" else model.supplier_id
    rows = (
        await db.execute(
            select(Invoice, model).join(model, model.invoice_id == Invoice.id).where(
                party_col == party_id,
                model.organization_id == org_id,
                Invoice.organization_id == org_id,
                Invoice.is_deleted.is_(False),
                Invoice.status.notin_(["draft", "cancelled"]),
                *([Invoice.debt_group_id == group_id] if group_id else []),
                *([Invoice.invoice_date >= date.fromisoformat(date_from)]
                  if date_from else []),
                *([Invoice.invoice_date <= date.fromisoformat(date_to)]
                  if date_to else []),
            ).order_by(Invoice.invoice_date.desc(), Invoice.created_at.desc(), Invoice.id.desc())
        )
    ).all()

    per_ccy = {}
    paid_ccy = {}
    individual: List[Dict[str, Any]] = []
    operations = []
    groups_map: Dict[str, Dict[str, Any]] = {}
    engine = CentralFXEngine.get_instance()
    rep = (display_currency or "SAR").strip().upper()
    for inv, debt in rows:
        # The invoice document is authoritative for display; the receivable row
        # stays the settlement source. Both are updated by the settlement engine.
        total_amt = Decimal(str(inv.total or 0))
        paid = Decimal(str(inv.paid_amount or 0))
        remaining = Decimal(str(inv.balance if inv.balance is not None
                                else (total_amt - paid)))
        if remaining < 0:
            remaining = Decimal(0)
        ccy = (inv.currency or "").upper()
        if not ccy:
            raise ValueError("عملة العملية غير متاحة")
        if remaining > Decimal("0.004"):
            per_ccy[ccy] = per_ccy.get(ccy, Decimal(0)) + remaining
        if paid > Decimal("0.004"):
            paid_ccy[ccy] = paid_ccy.get(ccy, Decimal(0)) + paid
        entry = {
            "id": str(inv.id), "number": inv.invoice_number,
            "date": inv.invoice_date.isoformat() if inv.invoice_date else None,
            "total": str(total_amt), "paid": str(paid),
            "remaining": str(remaining), "currency": ccy,
            "status": debt.status,
            "group_id": (str(inv.debt_group_id)
                         if inv.debt_group_id else None),
        }
        operations.append(entry)
        if inv.debt_group_id:
            groups_map.setdefault(str(inv.debt_group_id), {"count": 0})["count"] += 1
        else:
            individual.append(entry)

    # Groups the merchant created for this party (organisational only).
    g_rows = (
        await db.execute(
            select(DebtGroup).where(
                DebtGroup.organization_id == org_id,
                DebtGroup.party_kind == kind,
                DebtGroup.party_id == party_id,
            ).order_by(DebtGroup.created_at.desc())
        )
    ).scalars().all()
    groups = [
        {"id": str(g.id), "name": g.name, "kind": g.kind,
         "count": groups_map.get(str(g.id), {}).get("count", 0)}
        for g in g_rows
    ]

    async def _convert(amounts: Dict[str, Decimal]):
        total = Decimal(0)
        gaps = []
        rates = []
        if not rep:
            return None, gaps, rates
        for ccy, amount in amounts.items():
            if not amount:
                continue
            try:
                meta = await engine.get_rate(ccy, rep)
                rate = Decimal(str((meta or {}).get("rate")))
                if not rate.is_finite() or rate <= 0:
                    raise ValueError("invalid rate")
                total += amount * rate
                rates.append({"currency": ccy, "source": meta.get("source"),
                              "freshness": meta.get("freshness"),
                              "fetched_at": meta.get("fetched_at")})
            except Exception:
                import logging
                logging.getLogger(__name__).warning(
                    "debt_fx_unavailable %s -> %s", ccy, rep)
                gaps.append(ccy)
        if gaps:
            return None, gaps, rates
        return total.quantize(Decimal('0.01'), rounding=ROUND_HALF_UP), gaps, rates

    remaining_total, gaps, rates = await _convert(per_ccy)
    paid_total, _pg, _pr = await _convert(paid_ccy)
    total_display = None
    if remaining_total is not None and paid_total is not None:
        total_display = (remaining_total + paid_total).quantize(
            Decimal('0.01'), rounding=ROUND_HALF_UP)
    return {
        "link_id": link_id, "kind": kind,
        "display_currency": rep,
        "display_total": (str(remaining_total)
                          if remaining_total is not None else None),
        "paid_total": (str(paid_total) if paid_total is not None else None),
        "remaining_total": (str(remaining_total)
                            if remaining_total is not None else None),
        "grand_total": (str(total_display)
                        if total_display is not None else None),
        "fx_missing": gaps, "rates": rates,
        "per_currency": [{"currency": c, "total": str(v)}
                         for c, v in sorted(per_ccy.items())],
        "individual": individual,
        "operations": operations,
        "groups": groups,
        "group_name": next((g['name'] for g in groups if g['id'] == str(group_id)), None),
    }


async def partner_operation_detail(
    db: AsyncSession, user_id: UUID, link_id: UUID, invoice_id: UUID,
) -> Dict[str, Any]:
    link = await _link_for_user(db, user_id, link_id)
    from . import qa_business_party_sharing as sharing
    if await sharing.is_share(db, link):
        row = await sharing.authorized_recipient_read(db, link)
        operation = next((op for op in sharing.operations(row["snapshot"], link.party_kind)
                          if op["id"] == str(invoice_id)), None)
        if operation is None:
            raise ValueError("العملية غير متاحة في هذه المشاركة")
        return {"id": operation["id"], "invoice_id": operation["id"],
                "number": operation["number"], "date": operation["date"],
                "total": operation["total"], "paid": operation["paid"],
                "remaining": operation["remaining"], "currency": operation["currency"],
                "status": operation["status"], "party_name": link.display_name,
                "items": [], "payments": []}
    return await operation_detail_for_party(
        db, link.merchant_org_id, link.party_kind, link.party_id,
        invoice_id, link.display_name)


async def business_operation_detail(
    db: AsyncSession, org_id: UUID, kind: str, party_id: UUID,
    invoice_id: UUID,
) -> Dict[str, Any]:
    party = await business_party(db, org_id, kind, party_id)
    return await operation_detail_for_party(
        db, org_id, kind, party_id, invoice_id, party.name)


async def operation_detail_for_party(
    db: AsyncSession, org_id: UUID, kind: str, party_id: UUID,
    invoice_id: UUID, display_name: Optional[str] = None,
) -> Dict[str, Any]:
    """Operation detail (items, totals, payments, A4 document, edits) scoped to
    ONE party. Used by BOTH the personal (via link) and business (via party)."""
    col = Invoice.customer_id if kind == "customer" else Invoice.supplier_id
    inv = (
        await db.execute(
            select(Invoice).where(
                Invoice.id == invoice_id, col == party_id,
                Invoice.organization_id == org_id,
                Invoice.is_deleted.is_(False),
            )
        )
    ).scalar_one_or_none()
    if not inv:
        raise ValueError("العملية غير موجودة")
    items = (
        await db.execute(
            select(InvoiceItem).where(InvoiceItem.invoice_id == inv.id)
        )
    ).scalars().all()
    payments = (
        await db.execute(
            select(Payment).where(Payment.invoice_id == inv.id)
        )
    ).scalars().all()
    # Merchant identity for the invoice document header (business name +
    # owner phone) — real org/user data, never invented.
    org_name_raw = (
        await db.execute(
            select(Organization.name).where(
                Organization.id == org_id)
        )
    ).scalar_one_or_none()
    owner = (
        await db.execute(
            select(User).where(
                User.organization_id == org_id,
                User.role == "owner",
            ).limit(1)
        )
    ).scalar_one_or_none()
    org_name = _clean_shop_name(
        org_name_raw, owner.full_name if owner else None)
    owner_phone = owner.phone if owner else None
    # Branch-scoped designs are additive: the invoice's own branch wins,
    # then the main branch, then the legacy organization-wide row. Never use
    # scalar_one_or_none here — that raised MultipleResultsFound for every
    # merchant with a branch override.
    design_rows = (
        await db.execute(
            select(OrgInvoiceDesign).where(
                OrgInvoiceDesign.organization_id == org_id,
                OrgInvoiceDesign.template_id == "paper",
            ).order_by(OrgInvoiceDesign.updated_at.desc().nullslast())
        )
    ).scalars().all()
    by_branch = {row.branch_id: row for row in design_rows}
    main_branch = (
        await db.execute(
            select(Branch.id).where(
                Branch.organization_id == org_id,
                Branch.is_default.is_(True),
            ).limit(1)
        )
    ).scalar_one_or_none()
    design_row = by_branch.get(inv.branch_id)
    if design_row is None and main_branch is not None:
        design_row = by_branch.get(main_branch)
    if design_row is None:
        design_row = by_branch.get(None)
    design = None
    if design_row is not None:
        try:
            design = json.loads(design_row.payload)
        except Exception:
            design = None

    change_rows = (
        await db.execute(
            select(InvoiceItemChange).where(
                InvoiceItemChange.invoice_id == inv.id,
                InvoiceItemChange.organization_id == org_id,
            ).order_by(InvoiceItemChange.changed_at.asc())
        )
    ).scalars().all()
    _uids = {c.changed_by for c in change_rows if c.changed_by}
    _users = {}
    if _uids:
        _rows = (await db.execute(
            select(User.id, User.full_name, User.role).where(User.id.in_(_uids))
        )).all()
        _users = {r.id: (r.full_name, (r.role or "").lower()) for r in _rows}
    changes = [
        {"item_id": str(c.item_id) if c.item_id else None,
         "description": c.description,
         "old_quantity": c.old_quantity, "new_quantity": c.new_quantity,
         "old_unit_price": str(c.old_unit_price) if c.old_unit_price is not None else None,
         "new_unit_price": str(c.new_unit_price) if c.new_unit_price is not None else None,
         "changed_at": c.changed_at.isoformat() if c.changed_at else None,
         "changed_by_name": (_users.get(c.changed_by) or (None, ""))[0],
         "changed_by_is_manager": (_users.get(c.changed_by) or (None, ""))[1]
             in ("owner", "admin", "manager")}
        for c in change_rows
    ]

    is_purchase = kind == "supplier"
    doc_items = [
        {"description": it.description, "product_name": it.description,
         "quantity": float(it.quantity or 0), "unit_name": it.unit_name,
         "unit_price": float(it.unit_price or 0),
         "discount": float(it.discount or 0),
         "total": float(it.total or 0),
         "product_id": str(it.product_id) if it.product_id else None,
         "image": it.image}
        for it in items
    ]
    doc_payments = [
        {"payment_method": p.payment_method,
         "amount": float(p.original_amount if p.original_amount is not None
                         else p.amount),
         "payment_currency": p.payment_currency or inv.currency,
         "payment_date": p.payment_date.isoformat() if p.payment_date else None}
        for p in payments
    ]
    document = {
        "invoice_number": inv.invoice_number,
        "invoice_type": inv.invoice_type,
        "invoice_date": inv.invoice_date.isoformat() if inv.invoice_date else None,
        "currency": inv.currency,
        "customer_name": None if is_purchase else display_name,
        "customer_phone": None,
        "supplier_name": display_name if is_purchase else None,
        "supplier_phone": None,
        "subtotal": float(inv.subtotal or 0),
        "discount_amount": float(inv.discount_amount or 0),
        "tax_amount": float(inv.tax_amount or 0),
        "total": float(inv.total or 0),
        "paid_amount": float(inv.paid_amount or 0),
        "balance": float(inv.balance or 0),
        "notes": inv.notes,
        "status": inv.status,
        "branch_name": "",
        "cashier": "",
        "items": doc_items,
        "payments": doc_payments,
    }

    return {
        "id": str(inv.id), "number": inv.invoice_number,
        "date": inv.invoice_date.isoformat() if inv.invoice_date else None,
        "type": inv.invoice_type, "currency": inv.currency,
        "party_name": display_name,
        "perspective": kind,
        "linked": bool((await db.execute(
            select(MerchantLink.status).where(
                MerchantLink.merchant_org_id == org_id,
                MerchantLink.party_kind == kind,
                MerchantLink.party_id == party_id,
            ))).scalar_one_or_none() == "accepted"),
        "subtotal": str(inv.subtotal or 0),
        "total": float(inv.total or 0), "paid": float(inv.paid_amount or 0),
        "remaining": float(inv.balance or 0),
        "has_invoice_document": True,
        "discount": str(inv.discount_amount or 0), "tax": str(inv.tax_amount or 0),
        "merchant": {"name": org_name or "متجر", "phone": owner_phone},
        "is_modified": len(changes) > 0,
        "item_changes": changes,
        "design": design,
        "document": document,
        "items": [
            {"id": str(it.id), "name": it.description,
             "qty": float(it.quantity or 0),
             "price": float(it.unit_price or 0),
             "unit": it.unit_name, "discount": str(it.discount or 0),
             "tax_rate": str(it.tax_rate or 0),
             "image": it.image,
             "total": float(it.total or 0)}
            for it in items
        ],
        "payments": [
            {"id": str(p.id),
             "amount": str(p.original_amount if p.original_amount is not None
                            else p.amount),
             "currency": p.payment_currency or inv.currency,
             "method": p.payment_method,
             "date": p.payment_date.isoformat() if p.payment_date else None}
            for p in payments
        ],
    }


# ── event fan-out to the linked party ────────────────────────────────
async def deliver_pushes(pushes: list, org_id: UUID) -> None:
    """Background-task delivery AFTER the request transaction commits.
    Opens its own session (the request session is closed by then). Never
    raises — a push failure must never surface as an API error."""
    if not pushes:
        return
    try:
        from app.core.database import async_session_factory
        async with async_session_factory() as s:
            for p in pushes:
                try:
                    await debt_notifications.push_event(
                        s, org_id, p["event_id"], p["recipients"],
                        title=p["title"], message=p["message"], route=p["route"])
                except Exception:
                    continue
    except Exception:
        pass


async def linked_users(
    db: AsyncSession, org_id: UUID, party_kind: str, party_id: UUID
) -> List[MerchantLink]:
    """Accepted links of this party in this org (one link per party by
    constraint) — the ONLY recipients ever notified."""
    rows = (
        await db.execute(
            select(MerchantLink).where(
                MerchantLink.merchant_org_id == org_id,
                MerchantLink.party_kind == party_kind,
                MerchantLink.party_id == party_id,
                MerchantLink.status == "accepted",
            )
        )
    ).scalars().all()
    return [l for l in rows if l.external_user_id]


async def notify_party(
    db: AsyncSession, org_id: UUID, party_kind: str, party_id: UUID,
    *, event_id: str, title: str, message: str, route_for=None,
    actor_user_id: Optional[UUID] = None,
) -> list:
    """Emit-only (transactional outbox) to the linked party. Returns push
    payloads; the caller must send them AFTER commit (BackgroundTasks) so no
    push ever precedes the persisted financial operation. The route is built
    per link so the deep link always opens the right screen for THAT
    recipient."""
    links = await linked_users(db, org_id, party_kind, party_id)
    pushes = []
    _org_raw = (await db.execute(
        select(Organization.name).where(Organization.id == org_id)
    )).scalar_one_or_none()
    _shop = _clean_shop_name(_org_raw)
    _title = f"{title} — {_shop}" if _shop else title
    for link in links:
        route = route_for(link) if route_for else "/personal"
        # Two UUIDs plus the event prefix exceed app_notifications VARCHAR(80).
        # Keep the category prefix and hash the complete identity, never truncate
        # away the relationship (which would merge distinct recipients/events).
        notification_event = f"{event_id}:{link.id}"
        if len(notification_event) > 80:
            notification_event = (event_id.split(':', 1)[0][:15] + ':' +
                                  hashlib.sha256(notification_event.encode()).hexdigest())
        created = await debt_notifications.emit(
            db, org_id, notification_event, [link.external_user_id],
            title=_title, message=message, route=route,
            payload={"link_id": str(link.id), "to_side": "personal",
                     "actor_user_id": str(actor_user_id) if actor_user_id else None})
        if created:
            pushes.append({"recipients": [link.external_user_id], "title": _title,
                           "message": message, "route": route,
                           "event_id": notification_event})
    return pushes
