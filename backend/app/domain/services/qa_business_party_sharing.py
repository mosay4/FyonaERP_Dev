"""QA-only, read-only publication of a linked party's Business debt.

The server assigns a sharing identity, not a Customer or Supplier record.
MerchantLink remains the consent record. Neither accepting nor publishing
can post an invoice, bank entry, payment, or Personal transaction.
"""
import json
from collections import defaultdict
from datetime import date
from decimal import Decimal
from uuid import UUID, uuid4

from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select, text

from app.core import qa_directory
from app.domain.entities.auth_entities import Organization
from app.domain.entities.merchant_entities import MerchantLink

_SHARES = "public.fyona_qa_business_party_shares"
_CURRENCY = r"^[A-Z]{3}(_[A-Z]{3})?$"


async def install(conn):
    await conn.execute(text(f"""
        CREATE TABLE IF NOT EXISTS {_SHARES} (
            id UUID PRIMARY KEY,
            organization_id UUID NOT NULL,
            branch_id UUID NOT NULL
              REFERENCES public.fyona_qa_business_ledger_scope (branch_id),
            kind VARCHAR(10) NOT NULL CHECK (kind IN ('customer', 'supplier')),
            party_key UUID NOT NULL,
            publisher_session_id UUID,
            revision BIGINT NOT NULL DEFAULT 0,
            snapshot JSONB,
            published_at TIMESTAMPTZ,
            UNIQUE (branch_id, kind, party_key)
        )
    """))
    # Historical QA rows may still be read/revoked but cannot silently adopt
    # an arbitrary session as publisher, even after a new consent.
    await conn.execute(text(f"""
        ALTER TABLE {_SHARES} ADD COLUMN IF NOT EXISTS publisher_session_id UUID
    """))


async def _installed(db):
    # Installing source and installing the optional QA schema are independent.
    # Existing merchant links must keep working before the share table exists.
    return await db.scalar(
        text("SELECT to_regclass(:table) IS NOT NULL"), {"table": _SHARES}
    ) is True


async def available(db):
    return bool(qa_directory.INVITES) and await _installed(db)


class SharedOperation(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: UUID
    number: str = Field(min_length=1, max_length=120)
    date: date
    currency: str = Field(pattern=_CURRENCY)
    total_minor: int = Field(ge=0, le=999999999999, strict=True)
    paid_minor: int = Field(ge=0, le=999999999999, strict=True)
    remaining_minor: int = Field(ge=0, le=999999999999, strict=True)


class SharedDebt(BaseModel):
    model_config = ConfigDict(extra="forbid")
    currency: str = Field(pattern=_CURRENCY)
    remaining_minor: int = Field(ge=0, le=9999999999999999, strict=True)
    paid_minor: int = Field(ge=0, le=9999999999999999, strict=True)


class ShareSnapshot(BaseModel):
    model_config = ConfigDict(extra="forbid")
    revision: int = Field(ge=0, strict=True)
    link_id: UUID
    generation: str = Field(min_length=1, max_length=40)
    debts: list[SharedDebt] = Field(max_length=100)
    operations: list[SharedOperation] = Field(max_length=200)


async def lock_organization(db, org):
    # Shared with the connected invitation transaction in QA so two concurrent
    # invitations cannot link the same recipient to different parties.
    await db.scalar(select(Organization.id).where(
        Organization.id == org).with_for_update())


async def _party(db, org, branch, kind, key, *, lock=False):
    return (await db.execute(text(f"""
        SELECT * FROM {_SHARES}
        WHERE organization_id = :org AND branch_id = :branch
          AND kind = :kind AND party_key = :key
        {'FOR UPDATE' if lock else ''}
    """), dict(org=org, branch=branch, kind=kind, key=key))).mappings().one_or_none()


async def _link(db, share, *, lock=False):
    q = select(MerchantLink).where(
        MerchantLink.party_id == share["id"],
        MerchantLink.merchant_org_id == share["organization_id"],
        MerchantLink.party_kind == share["kind"],
    )
    return await db.scalar(q.with_for_update().execution_options(populate_existing=True) if lock else q)


async def _locked_party(db, org, branch, kind, key):
    share = await _party(db, org, branch, kind, key)
    if share is None:
        return None, None
    # Link before projection everywhere. Recipient unlink takes the same
    # lock order so a publication cannot race consent or deadlock on it.
    link = await _link(db, share, lock=True)
    return await _party(db, org, branch, kind, key, lock=True), link


class PublisherChanged(ValueError):
    pass


def _require_publisher(share, session_id):
    if session_id is None or share["publisher_session_id"] != session_id:
        raise PublisherChanged("نشر الدين يتطلب الجهاز الذي بدأ المشاركة")


def _generation(link):
    return link.created_at.isoformat() if link and link.created_at else None


def _info(share, link):
    if not link:
        return {"status": "none", "revision": 0}
    contact = {}
    if link.linked_via == "phone":
        contact["phone"] = link.phone
    elif link.linked_via == "code":
        contact["public_code"] = link.public_code
    return {
        "id": str(link.id), "status": link.status, "generation": _generation(link),
        "revision": share["revision"], "linked_via": link.linked_via, **contact,
    }


async def invite(db, org, branch, actor, session_id, kind, key, phone, code, country):
    from . import merchant_link_service as links

    await lock_organization(db, org)
    share, previous = await _locked_party(db, org, branch, kind, key)
    if share is None:
        await db.execute(text(f"""
            INSERT INTO {_SHARES} (id, organization_id, branch_id, kind, party_key, publisher_session_id)
            VALUES (:share, :org, :branch, :kind, :key, :session)
        """), dict(share=uuid4(), org=org, branch=branch, kind=kind, key=key, session=session_id))
        share = await _party(db, org, branch, kind, key, lock=True)
    _require_publisher(share, session_id)
    target = await links.lookup_user(db, phone, code, country)
    if target is None or target.status != "active":
        raise ValueError("لا يوجد حساب نشط بهذا الرقم")
    if target.id == actor:
        raise ValueError("لا يمكنك دعوة حسابك")
    if previous and previous.status in ("pending", "accepted"):
        if previous.external_user_id == target.id:
            return _info(share, previous)  # Lost response / repeated tap.
        raise ValueError("توجد دعوة أو علاقة نشطة لهذا الطرف")
    result = await links._invite_authorized_party(
        db, org, actor, kind, share["id"], phone, code, country, target=target,
        rotate_consent_id=True,
    )
    # A new invitation must never expose a previous recipient's snapshot.
    await db.execute(text(f"""
        UPDATE {_SHARES} SET snapshot = NULL, published_at = NULL,
          revision = revision + 1 WHERE id = :id
    """), {"id": share["id"]})
    current = await _party(db, org, branch, kind, key)
    return {**_info(current, await _link(db, current)), "_push": result.get("_push")}


async def status(db, org, branch, kind, key):
    share = await _party(db, org, branch, kind, key)
    return _info(share, await _link(db, share) if share else None)


async def revoke(db, org, branch, kind, key):
    share, link = await _locked_party(db, org, branch, kind, key)
    if share is None:
        return {"status": "revoked"}
    if link is not None and link.status in ("pending", "accepted"):
        from .merchant_link_service import audit, _now
        link.status = "revoked"
        link.responded_at = _now()
        await audit(db, org, "merchant_link", link.id, "unlink_merchant", link.invited_by)
    if link is not None:
        await clear_publication(db, link)
    return {"status": "revoked"}


async def clear_publication(db, link):
    """Caller holds this link lock; retire only the projection for consent."""
    await db.execute(text(f"""
        UPDATE {_SHARES} SET snapshot = NULL, published_at = NULL, revision = revision + 1
        WHERE id = :id AND organization_id = :org AND kind = :kind AND snapshot IS NOT NULL
    """), {"id": link.party_id, "org": link.merchant_org_id, "kind": link.party_kind})


class StalePublication(ValueError):
    pass


async def publish(db, org, branch, session_id, kind, key, data):
    share, link = await _locked_party(db, org, branch, kind, key)
    if not link or link.status != "accepted" or link.id != data.link_id \
            or _generation(link) != data.generation:
        raise StalePublication("الربط غير صالح أو لم يُقبل بعد")
    _require_publisher(share, session_id)
    if len({op.id for op in data.operations}) != len(data.operations) or \
            len({row.currency for row in data.debts}) != len(data.debts):
        raise ValueError("بيانات المشاركة مكررة")
    snapshot = data.model_dump(mode="json", include={"operations", "debts"})
    if snapshot == share["snapshot"]:
        return _info(share, link)
    if data.revision != share["revision"]:
        raise StalePublication("تغيّرت بيانات المشاركة؛ أعد المحاولة")
    await db.execute(text(f"""
        UPDATE {_SHARES} SET snapshot = CAST(:snapshot AS jsonb), published_at = now(),
          revision = revision + 1 WHERE id = :id
    """), {"id": share["id"], "snapshot": json.dumps(snapshot)})
    return _info(await _party(db, org, branch, kind, key), link)


async def is_share(db, link):
    # A disabled QA share must not be mistaken for a write-capable legacy link.
    if not await _installed(db):
        return False
    return bool(await db.scalar(text(f"""
        SELECT 1 FROM {_SHARES}
        WHERE id = :id AND organization_id = :org AND kind = :kind
    """), {"id": link.party_id, "org": link.merchant_org_id, "kind": link.party_kind}))


async def authorized_recipient_read(db, link, *, require_accepted=True):
    # Recheck recipient, active branch and current grant in the SAME read as
    # the snapshot: a revoked or replaced invitation must not disclose data.
    # The share exists only if the merchant's device-ledger branch created it
    # (fenced at /business/party-sharing). Here: the same link, an active
    # branch and owner, the addressed recipient, the expected state.
    row = (await db.execute(text(f"""
        SELECT s.snapshot, s.published_at, owner_user.id AS owner_id,
          owner_user.email AS owner_email, owner_user.organization_id AS owner_org,
          owner_user.role AS owner_role, owner_user.status AS owner_status
        FROM {_SHARES} s
        JOIN public.branches b ON b.id = s.branch_id AND b.organization_id = s.organization_id
        JOIN public.merchant_links l ON l.party_id = s.id
           AND l.merchant_org_id = s.organization_id AND l.party_kind = s.kind
        JOIN public.users owner_user ON owner_user.id = l.invited_by
          AND owner_user.organization_id = s.organization_id
          AND owner_user.role = 'owner' AND owner_user.status = 'active'
        JOIN public.users recipient ON recipient.id = l.external_user_id AND recipient.status = 'active'
        WHERE l.id = :link AND l.external_user_id = :user
           AND b.is_active IS TRUE AND b.is_archived IS FALSE
          AND l.status = :status
    """), {"link": link.id, "user": link.external_user_id,
           "status": "accepted" if require_accepted else "pending"})).mappings().one_or_none()
    from types import SimpleNamespace
    from app.core import business_local_mode
    # Still only for invited (QA) merchants: losing the allowlist discloses
    # nothing, even for an already accepted share.
    if row is None or not business_local_mode.enabled_for(SimpleNamespace(
            id=row["owner_id"], email=row["owner_email"],
            organization_id=row["owner_org"], role=row["owner_role"],
            status=row["owner_status"])):
        raise ValueError("الربط غير متاح")
    return row


def _money(minor):
    return str(Decimal(minor).scaleb(-2))


def debt_rows(snapshot):
    return [{"currency": d["currency"], "debt": _money(d["remaining_minor"])}
            for d in (snapshot or {}).get("debts", []) if d["remaining_minor"]]


def operations(snapshot, kind, date_from=None, date_to=None):
    rows = []
    for op in (snapshot or {}).get("operations", []):
        if (date_from and op["date"] < date_from) or (date_to and op["date"] > date_to):
            continue
        rows.append({
            **{k: op[k] for k in ("id", "number", "date", "currency")},
            "type": "sale" if kind == "customer" else "purchase",
            "total": _money(op["total_minor"]), "paid": _money(op["paid_minor"]),
            "remaining": _money(op["remaining_minor"]),
            "status": ("paid" if not op["remaining_minor"] else
                       "partial" if op["paid_minor"] else "open"),
            "group_id": None,
        })
    return rows


def overview(row, link, display_currency, date_from=None, date_to=None):
    published = row["snapshot"]
    individual = operations(published, link.party_kind, date_from, date_to)
    remaining = defaultdict(Decimal)
    paid = defaultdict(Decimal)
    if date_from or date_to:
        for op in individual:
            remaining[op["currency"]] += Decimal(op["remaining"])
            paid[op["currency"]] += Decimal(op["paid"])
    else:
        for op in (published or {}).get("debts", []):
            remaining[op["currency"]] += Decimal(_money(op["remaining_minor"]))
            paid[op["currency"]] += Decimal(_money(op["paid_minor"]))
    display = (display_currency or next(iter(remaining), "SAR")).upper()
    gaps = sorted(c for c in remaining.keys() | paid.keys()
                  if c != display and (remaining[c] or paid[c]))
    ready = published is not None and not gaps
    return {
        "link_id": str(link.id), "kind": link.party_kind,
        "display_currency": display, "published_at": row["published_at"],
        "display_total": str(remaining[display]) if ready else None,
        "paid_total": str(paid[display]) if ready else None,
        "remaining_total": str(remaining[display]) if ready else None,
        "grand_total": str(remaining[display] + paid[display]) if ready else None,
        "fx_missing": gaps, "rates": [], "groups": [],
        "per_currency": [{"currency": c, "total": str(v)}
                         for c, v in sorted(remaining.items()) if v],
        "individual": individual, "operations": individual,
    }
