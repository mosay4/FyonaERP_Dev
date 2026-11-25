"""«تحليل الصقر» — Business inventory analyst.

Reuses the SAME AI provider/secret as Sara (settings.OPENAI_API_KEY /
OPENAI_MODEL) and NEVER exposes the key to the client. All numbers are
computed in the backend first; the model only explains them.

Report philosophy (v2): the backend computes the dataset, the status verdict
and the dynamic suggested questions deterministically; the model only writes
the short merchant-language narrative. No invented numbers, no filler.
"""
from decimal import Decimal
import re
from typing import Optional
from uuid import UUID

from sqlalchemy import select, func, or_
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import settings
from app.domain.entities.business_entities import Product, ProductCategory
from app.domain.entities.invoice_entities import Invoice, InvoiceItem
from app.domain.services.fx_snapshot import convert_invoice_amount

MONEY_ITEM_KEYS = ("sales", "cogs", "profit", "purchases", "sell_price", "cost_price")


def _f(v) -> float:
    return float(v or 0)


async def _rate(from_ccy: str, to_ccy: str) -> float:
    """Live FX rate via CentralFXEngine (exchangerate-api.com for global
    currencies, 2dec.net for YER_OLD/YER_NEW). Report-only: never mutates
    stored product prices."""
    from_ccy = (from_ccy or "").strip().upper()
    to_ccy = (to_ccy or "").strip().upper()
    if not from_ccy or not to_ccy or from_ccy == to_ccy:
        return 1.0
    try:
        from app.domain.services.currency_service import CentralFXEngine

        res = await CentralFXEngine.get_instance().get_rate(from_ccy, to_ccy)
        r = (res or {}).get("rate")
        return float(r) if r and float(r) > 0 else 1.0
    except Exception:
        return 1.0


async def _rate_or_none(from_ccy: str, to_ccy: str):
    """Like [_rate] but returns None when no valid rate exists (so callers can
    flag the figure instead of silently assuming 1:1)."""
    from_ccy = (from_ccy or "").strip().upper()
    to_ccy = (to_ccy or "").strip().upper()
    if not from_ccy or not to_ccy:
        return None
    if from_ccy == to_ccy:
        return 1.0
    try:
        from app.domain.services.currency_service import CentralFXEngine

        res = await CentralFXEngine.get_instance().get_rate(from_ccy, to_ccy)
        r = (res or {}).get("rate")
        return float(r) if r and float(r) > 0 else None
    except Exception:
        return None


async def _convert_item(item: dict, rep: str) -> None:
    """Convert one aggregated product row's money figures to [rep] in place."""
    src = (item.get("currency") or rep or "").strip().upper()
    if not rep or src == rep:
        return
    r = await _rate(src, rep)
    if r == 1.0:
        return
    for k in MONEY_ITEM_KEYS:
        if isinstance(item.get(k), (int, float)):
            item[k] = round(item[k] * r, 4)


async def _aggregate(
    db: AsyncSession,
    org_id: UUID,
    category_id: Optional[UUID] = None,
    report_currency: Optional[str] = None,
) -> dict:
    rep = (report_currency or "").strip().upper() or "USD"
    prod_q = select(Product).where(
        Product.organization_id == org_id, Product.is_deleted.is_(False)
    )
    if category_id:
        prod_q = prod_q.where(Product.category_id == category_id)
    products = (await db.execute(prod_q)).scalars().all()
    by_id = {str(p.id): p for p in products}

    rows = (
        await db.execute(
            select(
                InvoiceItem.product_id,
                Invoice.invoice_type,
                Invoice.currency,
                InvoiceItem.price_currency,
                InvoiceItem.exchange_rate_used,
                func.sum(InvoiceItem.total),
                func.sum(InvoiceItem.base_quantity),
                func.sum(InvoiceItem.cost_total),
                func.sum(InvoiceItem.profit),
            )
            .join(Invoice, Invoice.id == InvoiceItem.invoice_id)
            .where(
                Invoice.organization_id == org_id,
                Invoice.is_deleted.is_(False),
                InvoiceItem.product_id.isnot(None),
            )
            .group_by(
                InvoiceItem.product_id,
                Invoice.invoice_type,
                Invoice.currency,
                InvoiceItem.price_currency,
                InvoiceItem.exchange_rate_used,
            )
        )
    ).all()

    # Convert each REAL line (grouped by its frozen snapshot) to the report
    # currency using the SAVED rate, so historical figures never shift with
    # today's live FX. Falls back to a live rate only for the leg the snapshot
    # cannot cover (e.g. the product's original currency -> an unrelated rep).
    source_ccys: set = set()
    unverified = False
    agg: dict = {}
    for pid, typ, inv_ccy, pcy, rused, total, qty, cogs, profit in rows:
        pid = str(pid)
        if pid not in by_id:
            continue
        ccy = (inv_ccy or "").strip().upper()
        if ccy:
            source_ccys.add(ccy)
        a = agg.setdefault(pid, {
            "sales": 0.0, "qty": 0.0, "cogs": 0.0, "profit": 0.0,
            "purchases": 0.0, "pqty": 0.0,
        })
        t = (typ or "").lower()
        base_ccy = ccy or rep

        async def _conv(amount):
            # None => impossible conversion (no rate). NEVER assume 1:1; skip
            # the amount and flag the dataset as having unverified FX.
            nonlocal unverified
            cv = await convert_invoice_amount(amount, base_ccy, rep, pcy, rused)
            if cv is None:
                unverified = True
                return 0.0
            return float(cv)

        if t == "sale":
            a["sales"] += await _conv(total)
            a["qty"] += _f(qty)
            a["cogs"] += await _conv(cogs)
            a["profit"] += await _conv(profit)
        elif t == "purchase":
            a["purchases"] += await _conv(total)
            a["pqty"] += _f(qty)

    items = []
    for pid, p in by_id.items():
        a = agg.get(pid, {})
        src = (p.cost_currency or "").strip().upper() or None
        if not src:
            src = next(iter(source_ccys), None) or rep
        pr = await _rate_or_none(src, rep)
        if pr is None:
            unverified = True
            pr = 1.0
        items.append({
            "id": pid,
            "name": p.name,
            "unit": p.unit,
            "stock": _f(p.stock),
            "min_stock": _f(p.min_stock),
            "sell_price": round(_f(p.price) * pr, 4),
            "cost_price": round(_f(p.cost_price) * pr, 4),
            "currency": rep,
            "sales": round(a.get("sales", 0.0), 4),
            "qty_sold": a.get("qty", 0.0),
            "cogs": round(a.get("cogs", 0.0), 4),
            "profit": round(a.get("profit", 0.0), 4),
            "purchases": round(a.get("purchases", 0.0), 4),
            "qty_purchased": a.get("pqty", 0.0),
            "expiry_date": p.expiry_date.isoformat() if p.expiry_date else None,
        })

    return _summary(items, rep, len(source_ccys) > 1, unverified)


_DEVICE_FIELDS = ("stock", "min_stock", "sell_price", "cost_price", "sales", "qty_sold",
                  "cogs", "profit", "purchases", "qty_purchased")


def _summary(items: list, rep: str, unified: bool, unverified: bool) -> dict:
    """The inventory/category figures from per-product rows (one shape for
    the server's own data and a device ledger's)."""
    active = [i for i in items if i["qty_sold"] > 0 or i["stock"] > 0]
    return {
        "report_currency": rep,
        "unified": unified,
        "unverified_fx": unverified,
        "inventory_value": round(sum(i["cost_price"] * i["stock"] for i in active), 4),
        "total_sales": round(sum(i["sales"] for i in active), 4),
        "total_profit": round(sum(i["profit"] for i in active), 4),
        "total_cogs": round(sum(i["cogs"] for i in active), 4),
        "products_count": len(active),
        "low_stock": [i["name"] for i in active if 0 < i["stock"] <= i["min_stock"]][:20],
        "out_of_stock": [i["name"] for i in active if i["stock"] <= 0][:20],
        "top_sellers": sorted(active, key=lambda x: x["qty_sold"], reverse=True)[:10],
        "top_profit": sorted(active, key=lambda x: x["profit"], reverse=True)[:10],
        "bottom_sellers": sorted(active, key=lambda x: x["qty_sold"])[:10],
        "slow_moving": [
            i for i in active if i["qty_sold"] <= 0 and i["stock"] > 0
        ][:15],
        "weak_margin": [
            i for i in active
            if i["sales"] > 0 and i["profit"] / i["sales"] < 0.1
        ][:15],
        # One order quantity everywhere (report, chat, product page): refill to
        # twice the alert level or ~1.5 months of the observed sales.
        "reorder": sorted([
            {"name": i["name"], "stock": i["stock"], "min_stock": i["min_stock"],
             "qty_sold": i["qty_sold"], "order_qty": q,
             "order_cost": round(q * i["cost_price"], 4)}
            for i in active
            if i["qty_sold"] > 0 and i["stock"] <= i["min_stock"]
            for q in [max(0, round(max(i["min_stock"] * 2, i["qty_sold"] / 6.0) - i["stock"]))]
            if q > 0
        ], key=lambda r: r["qty_sold"], reverse=True)[:15],
        "stagnant_value_share": round(
            sum(i["cost_price"] * i["stock"] for i in active if i["qty_sold"] <= 0 and i["stock"] > 0)
            / max(sum(i["cost_price"] * i["stock"] for i in active), 1e-9), 4)
            if any(i["stock"] > 0 for i in active) else 0.0,
    }


def device_dataset(items: list, report_currency: Optional[str], scope: str,
                   ref_id: Optional[str], category_name: Optional[str] = None) -> tuple[dict, str]:
    """Falcon figures for a device-ledger branch: the phone sends its own
    per-product rows (same fields as the server's), in the report currency."""
    rep = (report_currency or "USD").strip().upper()
    clean = []
    unverified = False
    for raw in (items or [])[:3000]:
        if not isinstance(raw, dict):
            continue
        row = {"id": str(raw.get("id") or ""), "name": str(raw.get("name") or "")[:200],
               "unit": str(raw.get("unit") or "")[:40], "currency": rep,
               "expiry_date": raw.get("expiry_date") or None}
        for key in _DEVICE_FIELDS:
            try:
                value = float(raw.get(key) or 0)
            except (TypeError, ValueError):
                value = 0.0
            row[key] = round(value, 4) if value == value and abs(value) != float("inf") else 0.0
        unverified = unverified or raw.get("fx_incomplete") is True
        if isinstance(raw.get("branch_id"), str) and raw.get("branch_id"):
            row["branch_id"] = raw["branch_id"][:64]
            row["branch_name"] = str(raw.get("branch_name") or raw["branch_id"])[:120]
        clean.append(row)
    branches = _device_branches(clean)
    if branches:
        # «جميع الفروع» on the phone: one figure per product name over every
        # branch, and each branch's own figures by name.
        summaries = [_device_branch_summary(bid, name, rows) for bid, (name, rows) in branches.items()]
        clean = _device_merge_by_name(clean)
    if scope == "product":
        p = next((i for i in clean if not ref_id or i["id"] == ref_id), None) or (
            clean[0] if branches and clean else {})
        stock, qty = _f(p.get("stock")), _f(p.get("qty_sold"))
        data = {
            "report_currency": rep, "unified": False, "unverified_fx": unverified,
            "name": p.get("name") or "", "unit": p.get("unit") or "",
            "category_name": (category_name or "")[:120],
            "total_sales": p.get("sales", 0.0), "total_cogs": p.get("cogs", 0.0),
            "total_profit": p.get("profit", 0.0),
            "inventory_value": round(_f(p.get("cost_price")) * stock, 4),
            "products_count": 1 if p else 0,
            "sales_total": p.get("sales", 0.0), "purchases_total": p.get("purchases", 0.0),
            "cogs": p.get("cogs", 0.0), "profit": p.get("profit", 0.0),
            "sales_quantity": qty, "stock": stock, "min_stock": _f(p.get("min_stock")),
            "sell_price": _f(p.get("sell_price")), "cost_price": _f(p.get("cost_price")),
            "currency": rep, "batches": [],
        }
        if qty > 0:
            target = max(_f(data["min_stock"]) * 2, qty / 6.0)
            data["suggested_order_qty"] = max(0, round(target - stock))
        if branches:
            data.update(branch_ids=list(branches), branch_summaries=summaries)
        return data, "المنتج"
    data = _summary(clean, rep, False, unverified)
    if branches:
        data.update(branch_ids=list(branches), branch_summaries=summaries)
    if scope == "category":
        data["category_name"] = (category_name or "")[:120]
        return data, "التصنيف"
    return data, "المخزون"


# A phone may send its own deterministic summary (the same rules as
# device_dataset, computed on the device) instead of every product row: the
# request stays small however big the catalogue is. Everything is re-shaped
# through these whitelists; nothing else from the phone is trusted.
_SUMMARY_NUMBERS = (
    "inventory_value", "total_sales", "total_profit", "total_cogs", "products_count",
    "stagnant_value_share", "sales_total", "purchases_total", "cogs", "profit",
    "sales_quantity", "stock", "min_stock", "sell_price", "cost_price",
    "suggested_order_qty",
)
_SUMMARY_NAME_LISTS = {"low_stock": 20, "out_of_stock": 20}
_SUMMARY_ROW_LISTS = {"top_sellers": 10, "top_profit": 10, "bottom_sellers": 10,
                      "slow_moving": 15, "weak_margin": 15, "reorder": 15}
_SUMMARY_ROW_NUMBERS = _DEVICE_FIELDS + ("order_qty", "order_cost")


def _num(value) -> float:
    try:
        v = float(value or 0)
    except (TypeError, ValueError):
        return 0.0
    return round(v, 4) if v == v and abs(v) != float("inf") else 0.0


def _summary_row(raw, rep: str) -> Optional[dict]:
    if not isinstance(raw, dict):
        return None
    row = {"id": str(raw.get("id") or "")[:64], "name": str(raw.get("name") or "")[:200],
           "unit": str(raw.get("unit") or "")[:40], "currency": rep}
    for key in _SUMMARY_ROW_NUMBERS:
        if key in raw:
            row[key] = _num(raw.get(key))
    return row


def _summary_names(raw, limit: int) -> list:
    return [str(n)[:200] for n in (raw if isinstance(raw, list) else [])[:limit]
            if isinstance(n, (str, int, float))]


def device_summary_dataset(summary, report_currency: Optional[str], scope: str,
                           category_name: Optional[str] = None) -> tuple[dict, str]:
    """Falcon figures from the summary a phone computed itself."""
    rep = (report_currency or "USD").strip().upper()
    src = summary if isinstance(summary, dict) else {}
    data: dict = {"report_currency": rep, "unified": False,
                  "unverified_fx": src.get("unverified_fx") is True}
    for key in _SUMMARY_NUMBERS:
        if key in src:
            data[key] = _num(src.get(key))
    data["products_count"] = int(data.get("products_count") or 0)
    for key, limit in _SUMMARY_NAME_LISTS.items():
        if key in src:
            data[key] = _summary_names(src.get(key), limit)
    for key, limit in _SUMMARY_ROW_LISTS.items():
        if key in src:
            rows = src.get(key) if isinstance(src.get(key), list) else []
            data[key] = [r for r in (_summary_row(x, rep) for x in rows[:limit]) if r]
    branches = []
    for raw in (src.get("branch_summaries") if isinstance(src.get("branch_summaries"), list) else [])[:50]:
        if not isinstance(raw, dict) or not isinstance(raw.get("branch_id"), str):
            continue
        row = {"branch_id": raw["branch_id"][:64],
               "branch_name": str(raw.get("branch_name") or raw["branch_id"])[:120]}
        for key in ("products_count", "stock", "total_sales", "total_profit", "total_cogs",
                    "total_purchases", "inventory_value"):
            row[key] = _num(raw.get(key))
        row["products_count"] = int(row["products_count"])
        for key in ("low_stock", "out_of_stock"):
            row[key] = _summary_names(raw.get(key), 10)
        top = raw.get("top_sellers") if isinstance(raw.get("top_sellers"), list) else []
        row["top_sellers"] = [r for r in (_summary_row(x, rep) for x in top[:5]) if r]
        branches.append(row)
    if branches:
        data.update(branch_ids=[b["branch_id"] for b in branches], branch_summaries=branches)
    if scope == "product":
        data.update(name=str(src.get("name") or "")[:200], unit=str(src.get("unit") or "")[:40],
                    category_name=(category_name or str(src.get("category_name") or ""))[:120],
                    currency=rep, batches=[])
        for key in ("total_sales", "total_cogs", "total_profit", "inventory_value", "sales_total",
                    "purchases_total", "cogs", "profit", "sales_quantity", "stock", "min_stock",
                    "sell_price", "cost_price"):
            data.setdefault(key, 0.0)
        if "suggested_order_qty" in data:
            data["suggested_order_qty"] = max(0, round(data["suggested_order_qty"]))
        return data, "المنتج"
    for key in ("inventory_value", "total_sales", "total_profit", "total_cogs",
                "stagnant_value_share"):
        data.setdefault(key, 0.0)
    for key in (*_SUMMARY_NAME_LISTS, *_SUMMARY_ROW_LISTS):
        data.setdefault(key, [])
    if scope == "category":
        data["category_name"] = (category_name or "")[:120]
        return data, "التصنيف"
    return data, "المخزون"


def _device_branches(rows: list) -> dict:
    out: dict = {}
    for row in rows:
        if row.get("branch_id"):
            out.setdefault(row["branch_id"], (row["branch_name"], []))[1].append(row)
    return out


def _device_branch_summary(branch_id: str, name: str, items: list) -> dict:
    """Same shape as a server branch summary (falcon_scoped_dataset)."""
    return {
        'branch_id': branch_id, 'branch_name': name,
        'products_count': len(items), 'stock': sum(i['stock'] for i in items),
        'total_sales': sum(i['sales'] for i in items), 'total_profit': sum(i['profit'] for i in items),
        'total_cogs': sum(i['cogs'] for i in items), 'total_purchases': sum(i['purchases'] for i in items),
        'inventory_value': sum(i['cost_price'] * i['stock'] for i in items),
        'low_stock': [i['name'] for i in items if 0 < i['stock'] <= i['min_stock']][:10],
        'out_of_stock': [i['name'] for i in items if i['stock'] <= 0][:10],
        'top_sellers': sorted(items, key=lambda i: i['qty_sold'], reverse=True)[:5],
    }


_DEVICE_SUMMED = ("stock", "min_stock", "sales", "qty_sold", "cogs", "profit", "purchases", "qty_purchased")


def _device_merge_by_name(rows: list) -> list:
    """The same product (by name) in several branches is one product of the
    business: quantities and money add up, cost is the stock-weighted cost."""
    merged: dict = {}
    for row in rows:
        key = ' '.join(row['name'].strip().lower().split())
        entry = merged.get(key)
        if entry is None:
            merged[key] = {k: v for k, v in row.items() if k not in ('branch_id', 'branch_name')}
            merged[key]['_value'] = row['cost_price'] * row['stock']
            continue
        for field in _DEVICE_SUMMED:
            entry[field] = round(entry[field] + row[field], 4)
        entry['_value'] += row['cost_price'] * row['stock']
        entry['sell_price'] = entry['sell_price'] or row['sell_price']
    out = []
    for entry in merged.values():
        value = entry.pop('_value')
        if entry['stock'] > 0:
            entry['cost_price'] = round(value / entry['stock'], 4)
        out.append(entry)
    return out


# ════════════════════════════════════════════════════════════════════
# Product-type expertise: the Falcon detects the merchant domain of a
# product/category from names and adapts pricing, turnover, marketing and
# risk advice to that type instead of generic talk.
# ════════════════════════════════════════════════════════════════════

_TYPE_KEYWORDS = {
    "fresh": ("خضار", "خضروات", "فواكه", "فاكهة", "بناتج", "طماطم", "بطاطس", "بصل", "موز", "عنب", "vegetable", "fruit"),
    "grocery": ("غذائية", "غذائي", "بقالة", "توابل", "بهارات", "معلبات", "أرز", "سكر", "زيت", "دقيق", "مكرونة", "معجون", "عصائر", "مشروبات", "شاي", "قهوة", "grocery", "food"),
    "electronics": ("إلكترونيات", "جوال", "هاتف", "شاحن", "سماعات", "لابتوب", "كمبيوتر", "تابلت", "بطارية", "كيبل", "ساعة ذكية", "electronics", "phone"),
    "clothing": ("ملابس", "ألبسة", "ثياب", "قميص", "بنطلون", "حذاء", "أحذية", "جوارب", "عباية", "فستان", "clothing", "shirt"),
    "home": ("منزلية", "أواني", "صحون", "أطقم", "أكواب", "دلال", "قلاية", "خلاط", "مفارش", "home"),
    "hardware": ("صحية", "بناء", "دهانات", "اسمنت", "مسامير", "خراطيم", "عدد", "hardware"),
    "pharmacy": ("أدوية", "صيدلية", "مستحضرات", "فيتامينات", "مسكنات", "pharmacy"),
    "cosmetics": ("عطور", "تجميل", "كريمات", "مكياج", "شامبو", "صابون", "بخور", "cosmetics"),
    "stationery": ("قرطاسية", "دفاتر", "أقلام", "محفظات", "stationery"),
    "baby": ("أطفال", "حفاضات", "ألعاب", "رضاعة", "baby", "toys"),
}

# Merchant playbooks per type — deterministic guidance the Falcon speaks.
_TYPE_PLAYBOOKS = {
    "fresh": {
        "label": "خضروات وفواكه (سلع طازجة)",
        "pricing": "هامش 15–25% وسعر يومي يتبع السوق — لا تثبّت السعر أسبوعًا كاملًا.",
        "turnover": "سريع جدًا: يجب أن يصرف المخزون خلال 2–4 أيام.",
        "marketing": "عرض الطازج صباحًا وتسعير الوزن، وعروض ما قبل المساء لتسييل الباقي.",
        "risks": "تلف وفقد قيمة سريع — أي كمية زائدة خسارة مؤكدة.",
        "opportunity": "تعاقدات مع مطاعم ومطابخ تضمن تصريفًا يوميًا ثابتًا.",
        "order": "اطلب كميات صغيرة ومتكررة (توريد يومي أو يومين) ولا تكبّر الدفعة أبدًا.",
        "velocity": "سريع الحركة بطبيعته.",
    },
    "grocery": {
        "label": "مواد غذائية وبقالة",
        "pricing": "هامش 10–20% والربح يعتمد على الدوران السريع لا الهامش المرتفع.",
        "turnover": "مستقر ومتوقع — راقب دوران كل صنف شهريًا.",
        "marketing": "عروض «اشترِ 2 بسعر خاص» والعروض الشهرية مع السلة الأساسية.",
        "risks": "انتهاء صلاحية وتقلب أسعار التوريد — لا تكدّس أصناف بطيئة.",
        "opportunity": "الطلب بالجملة على الأصناف سريعة الدوران يخفض التكلفة.",
        "order": "اطلب شهريًا حسب الدوران الفعلي، وزد 20% للأصناف الأكثر مبيعًا فقط.",
        "velocity": "سريع الحركة إذا دورانه شهري وصاعد.",
    },
    "electronics": {
        "label": "إلكترونيات وأجهزة",
        "pricing": "هامش 8–15% على الجهاز الأساسي، وارفع الهامش من الملحقات والضمان.",
        "turnover": "متوسط: 3–8 أسابيع للصنف النشط.",
        "marketing": "تسويق بالمواصفات ومقاطع الفيديو والضمان، واربط الجوال بشاحن وحماية.",
        "risks": "قدم الموديل يهبط سعره بسرعة، وتكلفة صيانة وضمان.",
        "opportunity": "حزم (جهاز + ملحقات) ترفع هامش الفاتورة الكلي.",
        "order": "اطلب دفعة تغطي شهرًا ونصف الطلب، وقلّل قبل صدور موديل جديد.",
        "velocity": "متوسط الحركة — راقب أصناف الملحقات فهي الأسرع.",
    },
    "clothing": {
        "label": "ملابس وألبسة",
        "pricing": "هامش 30–50% مع تخفيضات نهاية الموسم مخطط لها مسبقًا.",
        "turnover": "موسمي: ذروة عند بداية كل موسم وعيدين.",
        "marketing": "صور حقيقية بالمقاسات، وتجربة داخل المحل، وحملات قبل الموسم بأسبوعين.",
        "risks": "تغير الموضة وبقاء مقاسات مكسورة — الكسر يجمّد رأس المال.",
        "opportunity": "تخفيضات نهاية الموسم تسيّل الباقي وتعيد السيولة.",
        "order": "اطلب بداية الموسم بمقاسات متوازنة (وسط أكثر)، ولا تكرر من مقاس راكد.",
        "velocity": "سريع في موسمه وراكد خارجها.",
    },
    "home": {
        "label": "أدوات ومستلزمات منزلية",
        "pricing": "هامش 20–35% مع عروض باقات (طقم كامل أرخص من القطع المفردة).",
        "turnover": "بطيء إلى متوسط — لا تربح بسرعة بل بتنوع.",
        "marketing": "عرض الاستخدام (صور المطبخ/الصالة) وعروض المناسبات والأعراس.",
        "risks": "رأس مال متجمد في أصناف بطيئة وتكلفة تخزين.",
        "opportunity": "باقات الهدايا والمناسبات ترفع قيمة السلة.",
        "order": "كميات صغيرة ومتنوعة؛ أعِد الطلب فقط لما يتحرك فعليًا.",
        "velocity": "بطيء إلى متوسط الحركة.",
    },
    "hardware": {
        "label": "أدوات ومواد بناء وصحية",
        "pricing": "هامش 20–40% وأسعار خاصة للمقاولين بالكمية.",
        "turnover": "مرتبط بالمشاريع والمواسم — قد يتركز الطلب فجأة.",
        "marketing": "استهدف الورش والمقاولين وعروض الكميات.",
        "risks": "تلف تخزيني ورداءة بعض الموردين — افحص الدفعات.",
        "opportunity": "عقود توريد ثابتة مع ورش ومقاولات.",
        "order": "اطلب حسب مواعيد مشاريع عملائك لا حسب التقويم.",
        "velocity": "متقطع الحركة — قوي خلال المشاريع.",
    },
    "pharmacy": {
        "label": "أدوية ومستحضرات",
        "pricing": "هامش 20–30% مع التزام تنظيمي بالتسعير.",
        "turnover": "ثابت للأساسي ومتغير للعلاجات الموسمية.",
        "marketing": "ثقة وخدمة استشارية وبرنامج نقاط لعملائك الدائمين.",
        "risks": "انتهاء صلاحية وتنظيم صارم — FIFO إلزامي هنا.",
        "opportunity": "البدائل المكافئة ترفع الهامش دون فقدان العميل.",
        "order": "اطلب شهريًا للأدوية الأساسية، وراقب الصلاحية الأقرب أولًا.",
        "velocity": "حركة ثابتة ومتوقعة.",
    },
    "cosmetics": {
        "label": "عطور وتجميل",
        "pricing": "هامش 40–60% وقيمة مضافة بالهدايا والتغليف.",
        "turnover": "جيد مع العروض والمناسبات (أعياد، أعراس، مواسم).",
        "marketing": "مؤثرون ومحتوى بصري وعينات مجانية مع الشراء.",
        "risks": "تقليد ومنتجات منتهية — الدفعات المكدسة تنتهي قبل تصريفها.",
        "opportunity": "مجموعات موسمية (عطر + كريم) بهامش مضاعف.",
        "order": "دفعات صغيرة متكررة تنوع العرض بدل تكديس صنف واحد.",
        "velocity": "حركة جيدة مع دفعات التسويق.",
    },
    "stationery": {
        "label": "قرطاسية",
        "pricing": "هامش 25–40% وذروة موسم الدراسة.",
        "turnover": "موسمي بقوة: أغسطس–سبتمبر ذروة، ثم هدوء.",
        "marketing": "حملات المدارس وقوائم المستلزمات الجاهزة (باكيت كاملة).",
        "risks": "تكدس بعد الموسم — لا تطلب خارج موسمك.",
        "opportunity": "عقود مدارس ومؤسسات.",
        "order": "ركّز طلبك قبل الموسم بـ6 أسابيع وقلّل بعده إلى الحد الأدنى.",
        "velocity": "موسمي الحركة.",
    },
    "baby": {
        "label": "مستلزمات أطفال وألعاب",
        "pricing": "هامش 30–45% على الألعاب و20–30% على الأساسيات (حفاضات/حليب).",
        "turnover": "أساسيات ثابتة، ألعاب موسمية (أعياد ومناسبات).",
        "marketing": "ثقة الأمهات: جودة وسلامة وتغليف هدية.",
        "risks": "معايير سلامة صارمة وتقادم الألعاب.",
        "opportunity": "اشتراك شهري (حفاضات/حليب) يضمن دخلًا متكررًا.",
        "order": "الأساسيات شهرية ثابتة، والألعاب قبل المواسم فقط.",
        "velocity": "الأساسيات سريعة والألعاب موسمية.",
    },
    "general": {
        "label": "منتجات عامة",
        "pricing": "هامش 15–30% حسب المنافس المحلي — راقب أسعار السوق.",
        "turnover": "قِس الدوران بالكمية الشهرية لكل صنف.",
        "marketing": "ابدأ بعرض واحد واضح وقِس أثره على الحركة.",
        "risks": "تكدس أصناف بطيئة دون ملاحظة — راجع الحركة شهريًا.",
        "opportunity": "ركّز رأس مالك على أفضل 20% صنف ربحًا.",
        "order": "أعِد طلب ما تحرك فعليًا، وقلّل ما لم يتحرك.",
        "velocity": "قِس الحركة من الكميات المباعة.",
    },
}


def detect_type(*texts) -> tuple[str, str]:
    """(type_key, matched_text) from product/category names."""
    blob = " ".join((t or "") for t in texts if t).lower()
    for key, words in _TYPE_KEYWORDS.items():
        for w in words:
            if w.lower() in blob:
                return key, w
    return "general", ""


def _type_context(scope: str, data: dict, names: list, cat_name: str) -> dict:
    """Detect the dominant merchant type for this analysis scope."""
    if scope == "product":
        key, hit = detect_type(data.get("name"), cat_name)
    else:
        counts: dict = {}
        for n in names:
            k, _ = detect_type(n, cat_name)
            counts[k] = counts.get(k, 0) + 1
        if not counts:
            key, hit = detect_type(cat_name)
        else:
            key = max(counts, key=lambda k: counts[k])
            hit = f"{counts[key]}/{len(names)}"
    return {"key": key, "hit": hit, "playbook": _TYPE_PLAYBOOKS[key]}


# ════════════════════════════════════════════════════════════════════
# Deterministic verdict + dynamic suggested questions (computed in the
# backend so the client always has a status even when the AI is down).
# ════════════════════════════════════════════════════════════════════

def _flags_from(data: dict, scope: str) -> dict:
    if scope == "product":
        sales = _f(data.get("sales_total"))
        profit = _f(data.get("profit"))
        stock = _f(data.get("stock"))
        min_stock = _f(data.get("min_stock"))
        qty = _f(data.get("sales_quantity"))
        margin = profit / sales if sales > 0 else None
        return {
            "sales": sales,
            "profit": profit,
            "margin": margin,
            "stock": stock,
            "min_stock": min_stock,
            "qty_sold": qty,
            "out": stock <= 0,
            "stagnant": qty <= 0 and stock > 0,
            "low": 0 < stock <= min_stock,
            "loss": profit < 0,
        }
    active = data.get("products_count", 0) or 0
    return {
        "sales": _f(data.get("total_sales")),
        "profit": _f(data.get("total_profit")),
        "margin": (
            _f(data.get("total_profit")) / _f(data.get("total_sales"))
            if _f(data.get("total_sales")) > 0 else None
        ),
        "out": len(data.get("out_of_stock") or []),
        "low": len(data.get("low_stock") or []),
        "stagnant": len(data.get("slow_moving") or []),
        "weak_margin": len(data.get("weak_margin") or []),
        "products_count": active,
        "loss": _f(data.get("total_profit")) < 0,
        "frozen": _f(data.get("stagnant_value_share")),
    }


def _verdict(flags: dict, scope: str) -> str:
    if scope == "product":
        if flags["out"] or flags["loss"]:
            return "weak"
        margin = flags["margin"]
        if flags["stagnant"] or flags["low"]:
            return "watch"
        if flags["sales"] > 0 and margin is not None and margin >= 0.2:
            return "excellent"
        if flags["sales"] > 0 and margin is not None and margin >= 0.1:
            return "good"
        return "watch"
    sales, profit = flags["sales"], flags["profit"]
    margin = flags["margin"]
    stagnant, low, out = flags["stagnant"], flags["low"], flags["out"]
    if flags["loss"] or (flags["products_count"] > 0 and out >= max(3, flags["products_count"] * 0.3)):
        return "weak"
    if sales <= 0:
        return "watch"
    # Lost sales (an item that sells is out) or capital sitting in goods that
    # do not move are never «good», whatever the margin.
    if (stagnant >= 3 or low >= 3 or out > 0 or flags.get("frozen", 0) >= 0.3
            or (margin is not None and margin < 0.1)):
        return "watch"
    if margin is not None and margin >= 0.2 and stagnant == 0 and low == 0 and out == 0:
        return "excellent"
    if margin is not None and margin >= 0.1:
        return "good"
    return "watch"


def _attention_points(flags: dict, scope: str, data: dict, cur: str) -> list:
    pts: list = []
    if scope == "product":
        if flags["out"]:
            pts.append("المنتج نفد من المخزون تمامًا — تخسر أي مبيعات له الآن.")
        if flags["loss"]:
            pts.append(f"الربح على هذا المنتج سالب ({_fmt_money(flags['profit'], cur)}).")
        if flags["low"]:
            pts.append(f"الكمية الحالية ({_f(flags['stock']):g}) وصلت حد التنبيه ({_f(flags['min_stock']):g}).")
        if flags["stagnant"]:
            pts.append("لا توجد أي مبيعات لهذا المنتج مع وجود كمية في المخزون.")
        if flags["sales"] > 0 and flags["margin"] is not None and flags["margin"] < 0.1:
            pts.append(f"هامش الربح ضعيف ({flags['margin'] * 100:.0f}%).")
        # Real batch comparison (1st/2nd/3rd...) from linked lots + sales.
        batches = [
            b for b in (data.get("batches") or []) if (b.get("sold") or 0) > 0
        ]
        if len(batches) >= 2:
            by_profit = sorted(
                batches, key=lambda b: b.get("profit", 0), reverse=True
            )
            top, low = by_profit[0], by_profit[-1]
            if top.get("profit", 0) > 0:
                pts.append(
                    f"الدفعة {top['n']} الأكثر ربحًا "
                    f"({_fmt_money(top['profit'], cur)}) بتكلفة "
                    f"{_fmt_money(top.get('unit_cost', 0), top.get('currency') or cur)} للقطعة."
                )
            if low.get("profit", 0) < top.get("profit", 0):
                pts.append(
                    f"الدفعة {low['n']} الأقل ربحًا "
                    f"({_fmt_money(low['profit'], cur)}) — تكلفتها أعلى "
                    f"({_fmt_money(low.get('unit_cost', 0), low.get('currency') or cur)} للقطعة)."
                )
        return pts[:3]
    if flags["loss"]:
        pts.append(f"إجمالي الربح سالب ({_fmt_money(flags['profit'], cur)}).")
    if flags["out"]:
        pts.append(f"{flags['out']} منتج نفد من المخزون.")
    if flags["low"]:
        pts.append(f"{flags['low']} منتج وصل حد التنبيه وقربه النفاد.")
    if flags["stagnant"]:
        pts.append(f"{flags['stagnant']} منتج راكد (بدون أي مبيعات) ورأس المال متجمد فيه.")
    if flags.get("weak_margin"):
        pts.append(f"{flags['weak_margin']} منتج بهامش ربح أقل من 10%.")
    return pts[:3]


def _recommendations(flags: dict, scope: str, data: dict, cur: str) -> list:
    recs: list = []
    if scope == "product":
        if flags["out"]:
            recs.append("أعِد طلب المنتج فورًا — توفره يوقف خسارة مبيعات حقيقية.")
        if flags["stagnant"] and not flags["out"]:
            recs.append("لا تشترِ كمية جديدة الآن؛ اعْرض الموجود بعرض ترويجي لتسييله.")
        if flags["low"] and not flags["stagnant"]:
            recs.append(f"خطّط لإعادة الطلب قريبًا — المتبقي {_f(flags['stock']):g} فقط.")
        if flags["sales"] > 0 and flags["margin"] is not None and flags["margin"] < 0.1:
            recs.append("راجع سعر البيع قبل الطلب القادم — الهامش الحالي ضعيف مقارنة بالتكلفة.")
        if flags["sales"] > 0 and flags["margin"] is not None and flags["margin"] >= 0.2 and not flags["low"]:
            recs.append("الأداء ممتاز — حافظ على مستوى المخزون الحالي دون زيادة كبيرة.")
        if not recs:
            recs.append("راقب حركة البيع أسبوعيًا قبل أي قرار شراء جديد.")
        return recs[:4]
    if flags["out"]:
        recs.append("أعِد طلب المنتجات النافدة أولًا — كل يوم تأخير مبيعات مفقودة.")
    if flags["low"]:
        names = "، ".join((data.get("low_stock") or [])[:3])
        recs.append(f"أعد طلب: {names}." if names else "أعد طلب المنتجات قريبة النفاد.")
    if flags["stagnant"]:
        recs.append("المنتجات الراكدة تُجمّد رأس المال — سيّلها بعرض ترويجي ولا تكرّر شراءها.")
    if flags.get("weak_margin"):
        recs.append("راجع أسعار البيع للمنتجات بهامش أقل من 10% قبل الطلب القادم.")
    if flags["sales"] > 0 and flags["margin"] is not None and flags["margin"] >= 0.2:
        recs.append("الربحية جيدة — ركّز المشتريات على المنتجات ذات أعلى هامش.")
    if not recs:
        recs.append("ابدأ بتسجيل المبيعات والشراء بانتظام ليصبح التحليل أدق.")
    return recs[:4]


def _opportunity(flags: dict, scope: str, data: dict, cur: str) -> str:
    if scope != "product":
        top = (data.get("top_profit") or [{}])[0]
        if top and _f(top.get("profit")) > 0 and _f(top.get("qty_sold", 0)) > 0:
            m = (
                top["profit"] / top["sales"]
                if _f(top.get("sales")) > 0 else None
            )
            if m is not None and m >= 0.25:
                return (
                    f"«{top['name']}» يحقق أعلى ربح بهامش {m * 100:.0f}% "
                    f"({_fmt_money(top['profit'], cur)}) — زيادة مخزونه قد ترفع الربح."
                )
    return ""


def _fmt_money(v, cur: str) -> str:
    d = _f(v)
    s = f"{d:,.0f}" if abs(d) >= 100 or d == int(d) else f"{d:,.2f}"
    return f"{s} {cur}"


def _suggested_questions(scope: str, flags: dict, data: dict) -> list:
    """3–4 dynamic questions driven by scope + the actual detected issues."""
    qs: list = []
    if scope == "product":
        if flags["stock"] > 0 and flags["qty_sold"] > 0:
            qs.append("كم أطلب الشهر القادم؟")
            qs.append("متى ممكن يخلص المخزون؟")
        if flags["loss"] or (flags["margin"] is not None and flags["margin"] < 0.15 and flags["sales"] > 0):
            qs.append("هل أزيد سعر المنتج؟")
        if flags["stagnant"]:
            qs.append("هل المنتج راكد؟")
        if len(qs) < 3:
            qs.append("وش وضع المنتج الحالي باختصار؟")
    elif scope == "category":
        qs.append("وش أفضل منتج في التصنيف؟")
        qs.append("وش المنتج الأقل ربحًا؟")
        if flags["low"] or flags["out"]:
            qs.append("أي منتج يحتاج إعادة طلب؟")
        if flags["stagnant"]:
            qs.append("هل فيه منتجات راكدة؟")
        if len(qs) < 4:
            qs.append("وين أكبر فرصة ربح؟")
    else:
        qs.append("وش أكثر المنتجات ربحًا؟")
        if flags["stagnant"]:
            qs.append("وش المنتجات الراكدة؟")
        if flags["low"] or flags["out"]:
            qs.append("وش المنتجات اللي قربت تخلص؟")
        if flags["stagnant"]:
            qs.append("وين رأس المال متجمد؟")
        if len(qs) < 4:
            qs.append("وش أحتاج أطلب الفترة القادمة؟")
    return qs[:4]


def _rule_report(data: dict, flags: dict, scope: str, title: str, cur: str) -> dict:
    verdict = _verdict(flags, scope)
    return {
        "status": verdict,
        "status_line": f"وضع {title}: {dict(excellent='ممتاز', good='جيد', watch='يحتاج متابعة', weak='ضعيف')[verdict]}.",
        "attention": _attention_points(flags, scope, data, cur),
        "recommendations": _recommendations(flags, scope, data, cur),
        "opportunity": _opportunity(flags, scope, data, cur),
    }


_PLAIN_STYLE = (
    "اكتب بلغة عربية بسيطة قريبة من كلام التجار اليومي (مثل: بعت، باقي، خلص، "
    "اطلب، فلوسك واقفة في بضاعة ما تنباع)، بدون مصطلحات محاسبية معقدة "
    "(لا هامش ربح إجمالي ولا تكلفة البضاعة المباعة ولا رأس مال متجمد). "
    "ممنوع منعًا باتًا أي كلمة إنجليزية أو اسم حقل من البيانات مثل qty_sold أو "
    "total_profit أو total_sales أو reorder أو stock أو min_stock أو SKU؛ عبّر عنها "
    "بالعربي (الكمية المباعة، الربح، المبيعات، الطلب، المخزون، الحد الأدنى). "
    "أسماء المنتجات تُكتب كما هي. لا تذكر رقمًا صفرًا إلا إذا كان هو المشكلة نفسها. "
    "لا تكرر نفس المعلومة في أكثر من قسم. "
)

_SYSTEM = (
    "أنت الصقر، مستشار تجاري لنظام FYONA يكلّم صاحب المحل. "
    + _PLAIN_STYLE +
    "تتلقى أرقامًا حقيقية محسوبة مسبقًا — ممنوع اختراع أي رقم غير موجود، "
    "وممنوع النصائح العامة بلا رقم (مثل: حسّن التسويق). "
    "إذا كانت البيانات قليلة قل ذلك بجملة واحدة واقترح تسجيل المبيعات أولًا. "
    "أعِد ردّك في صيغة JSON فقط بالمفاتيح: "
    "status_line (جملة واحدة قصيرة لا تزيد عن 14 كلمة تلخص الوضع)، "
    "attention (من 1 إلى 3 نقاط، كل نقطة سطر واحد لا يزيد عن 12 كلمة، للمشاكل الحقيقية فقط)، "
    "recommendations (من 1 إلى 3 خطوات عملية، كل خطوة تبدأ بفعل أمر مثل اطلب/اعرض/ارفع السعر، "
    "ولا تزيد عن 14 كلمة، وفيها رقم واحد أو رقمان فقط)، "
    "opportunity (سطر واحد لا يزيد عن 14 كلمة لفرصة مدعومة برقم، أو نص فارغ). "
    "مثال للأسلوب: «أونيكس باقي منه 5 قطع بس، اطلب 10 قبل ما يخلص». "
    "كميات الطلب محسوبة مسبقًا في reorder وsuggested_order_qty: استخدم الرقم كما هو ولا تحسب غيره "
    "(لكن لا تكتب اسم الحقل). "
    "رتّب حسب الأهمية: ما خلص وهو يُباع أولًا، ثم ما قرب يخلص، ثم بضاعة ما تنباع، ثم ربح ضعيف."
)

_CHAT_SYSTEM = (
    "أنت «الصقر» مستشار تجاري وخبير مخازن ومنتجات في نظام FYONA. "
    + _PLAIN_STYLE +
    "اعتمد فقط على الأرقام الحقيقية المرسلة — لا تخترع أرقامًا. "
    "أجب مباشرة في جملة إلى ثلاث جمل قصيرة، وإن طلب المستخدم تفاصيل أكثر توسّع "
    "حينها فقط وبنقاط قصيرة. ممنوع JSON في الرد. ابقَ داخل نطاق التحليل المحدد. "
    "إذا كان السؤال خارج اختصاصك (أي شيء لا يخص التجارة أو المخزون أو "
    "التسويق أو المنتجات أو الأرباح أو الكميات)، اعتذر بلطف باختصار واشرح أنك "
    "مختص بمحله وبضاعته وأرباحه، واقترح سؤالًا مثالًا. "
    "عند سؤال الطلب والكميات استخدم كمية الطلب المحسوبة في reorder وsuggested_order_qty "
    "كما هي، واذكر تكلفتها إن وجدت (بدون ذكر أسماء الحقول)."
)

_SPECIALTY_FALLBACK = (
    "أنا الصقر، خبير التجارة والمخزون والتسويق في متجرك. اجابتي تعتمد على "
    "أرقام بضاعتك الفعلية. اسألني مثلًا عن أرباح منتج، أو سرعة تصريفه، أو "
    "الكمية المناسبة لطلبه، وسأجيبك فورًا."
)


# The report's narrative must arrive well inside the phone's request window:
# past this the deterministic report is returned (never an error).
AI_REPORT_TIMEOUT = 20.0
AI_CHAT_TIMEOUT = 25.0


def _bounded(client, timeout: float):
    """One attempt, bounded: no SDK retries stacking on a slow provider."""
    try:
        return client.with_options(timeout=timeout, max_retries=0)
    except Exception:
        return client


async def _call_ai(system: str, user: str, max_tokens: int = 900,
                   difficulty_text: str = "",
                   timeout: Optional[float] = None) -> Optional[str]:
    # Model layer routes through the central AI router (DeepSeek-first,
    # legacy OpenAI fallback). The effort is chosen from [difficulty_text]
    # (the merchant's question), never from the figures dump: the dump is
    # long and its type playbook words («أثر», «خطة»…) always triggered the
    # 9x «max» budget, which outlasted the phone's request and ended in
    # «تعذّر تشغيل التحليل».
    import asyncio

    from app.domain.services.ai_router import build_client, route

    timeout = timeout or AI_REPORT_TIMEOUT
    r = route(difficulty_text, tools=False, base_tokens=max_tokens)
    if not r.api_key:
        return None
    try:
        client = _bounded(build_client(r), timeout)
        resp = await asyncio.wait_for(client.chat.completions.create(
            model=r.model,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            temperature=0.3,
            max_tokens=r.max_tokens,
            extra_body={"effort": r.effort},
        ), timeout)
        return (resp.choices[0].message.content or "").strip()
    except Exception:
        return None


async def _product_batches(
    db: AsyncSession, org_id: UUID, pid: UUID, rep: str, branch_ids=None, main_id=None
) -> list:
    """Per-purchase-batch performance from REAL lots + the sale consumptions
    actually linked to them — no guessing, no currency mixing. Each batch gets
    its sold qty plus the revenue/profit apportioned from the sale lines that
    consumed it (converted once to the report currency)."""
    from app.domain.entities.invoice_entities import Invoice, InvoiceItem
    from app.domain.entities.sale_entities import (
        InventoryLot,
        InventoryLotConsumption,
    )

    lots = (
        await db.execute(
            select(InventoryLot)
            .where(
                InventoryLot.organization_id == org_id,
                InventoryLot.product_id == pid,
                *([or_(InventoryLot.branch_id.in_(branch_ids), InventoryLot.branch_id.is_(None))
                   if main_id in branch_ids else InventoryLot.branch_id.in_(branch_ids)] if branch_ids is not None else []),
            )
            .order_by(
                InventoryLot.purchase_date.asc(), InventoryLot.created_at.asc()
            )
        )
    ).scalars().all()
    if not lots:
        return []
    rows = (
        await db.execute(
            select(InventoryLotConsumption, InvoiceItem, Invoice.currency)
            .join(
                InvoiceItem,
                InvoiceItem.id == InventoryLotConsumption.invoice_item_id,
            )
            .join(Invoice, Invoice.id == InvoiceItem.invoice_id)
            .where(
                InventoryLotConsumption.organization_id == org_id,
                InventoryLotConsumption.lot_id.in_([l.id for l in lots]),
                Invoice.is_deleted.is_(False),
                *([or_(Invoice.branch_id.in_(branch_ids), Invoice.branch_id.is_(None))
                   if main_id in branch_ids else Invoice.branch_id.in_(branch_ids)] if branch_ids is not None else []),
            )
        )
    ).all()

    per_lot = {
        l.id: {"sold": 0.0, "revenue": 0.0, "cogs": 0.0} for l in lots
    }
    lot_by_id = {l.id: l for l in lots}
    line_cons: dict = {}
    for cons, _item, _ccy in rows:
        line_cons[_item.id] = line_cons.get(_item.id, 0.0) + float(
            cons.quantity or 0
        )
    for cons, item, inv_ccy in rows:
        base = float(item.base_quantity or 0)
        share = (float(cons.quantity or 0) / base) if base > 0 else 0.0
        r = await _rate((inv_ccy or "").strip().upper(), rep)
        lot = lot_by_id[cons.lot_id]
        cr = await _rate((lot.currency or "").strip().upper(), rep)
        d = per_lot[cons.lot_id]
        qty = float(cons.quantity or 0)
        d["sold"] += qty
        d["revenue"] += float(item.total or 0) * share * r
        # COGS from THIS lot's own frozen unit cost (multi-cost lots differ).
        d["cogs"] += qty * float(lot.unit_cost or 0) * cr

    out = []
    for i, l in enumerate(lots, start=1):
        d = per_lot[l.id]
        profit = d["revenue"] - d["cogs"]
        out.append(
            {
                "n": i,
                "lot_number": l.lot_number,
                "received": float(l.received_quantity or 0),
                "remaining": float(l.remaining_quantity or 0),
                "sold": round(d["sold"], 4),
                "unit_cost": float(l.unit_cost or 0),
                "currency": (l.currency or "").strip().upper(),
                "revenue": round(d["revenue"], 2),
                "profit": round(profit, 2),
                "purchase_date": l.purchase_date.isoformat()
                if l.purchase_date
                else None,
            }
        )
    return out


async def _dataset(
    db: AsyncSession, org_id: UUID, scope: str, ref_id: Optional[str],
    report_currency: Optional[str] = None,
    branch_ids=None,
) -> tuple[dict, str]:
    """Compute the deterministic dataset (already converted to the report
    currency) + the scope title."""
    if branch_ids is not None:
        from .falcon_scoped_dataset import scoped_dataset
        return await scoped_dataset(db, org_id, scope, ref_id, report_currency, branch_ids)
    rep = (report_currency or "USD").strip().upper()
    if scope == "product" and ref_id:
        # Real-currency buckets for THIS product (sales may span currencies).
        rows = (
            await db.execute(
                select(
                    Invoice.invoice_type,
                    Invoice.currency,
                    InvoiceItem.price_currency,
                    InvoiceItem.exchange_rate_used,
                    func.sum(InvoiceItem.total),
                    func.sum(InvoiceItem.base_quantity),
                    func.sum(InvoiceItem.cost_total),
                    func.sum(InvoiceItem.profit),
                )
                .join(Invoice, Invoice.id == InvoiceItem.invoice_id)
                .where(
                    Invoice.organization_id == org_id,
                    Invoice.is_deleted.is_(False),
                    InvoiceItem.product_id == UUID(ref_id),
                )
                .group_by(
                    Invoice.invoice_type,
                    Invoice.currency,
                    InvoiceItem.price_currency,
                    InvoiceItem.exchange_rate_used,
                )
            )
        ).all()
        prod = (
            await db.execute(
                select(Product).where(
                    Product.id == UUID(ref_id),
                    Product.organization_id == org_id,
                )
            )
        ).scalar_one_or_none()

        sales = qty = cogs = profit = purchases = 0.0
        src_ccys = set()
        unverified = False

        async def _conv(amount):
            nonlocal unverified
            cv = await convert_invoice_amount(amount, base_ccy, rep, pcy, rused)
            if cv is None:
                unverified = True
                return 0.0
            return float(cv)

        for typ, inv_ccy, pcy, rused, total, bqty, it_cogs, it_profit in rows:
            ccy = (inv_ccy or "").strip().upper()
            src_ccys.add(ccy)
            base_ccy = ccy or rep
            t = (typ or "").lower()
            if t == "sale":
                sales += await _conv(total)
                qty += _f(bqty)
                cogs += await _conv(it_cogs)
                profit += await _conv(it_profit)
            elif t == "purchase":
                purchases += await _conv(total)

        src = ((prod.cost_currency or "") if prod else "").strip().upper() \
            or next(iter(src_ccys), None) or rep
        pr = await _rate_or_none(src, rep)
        if pr is None:
            unverified = True
            pr = 1.0
        stock = _f(prod.stock) if prod else 0
        cost_price = round(_f(prod.cost_price) * pr, 4) if prod else 0
        data = {
            "report_currency": rep,
            "unified": len({c for c in src_ccys if c}) > 1,
            "unverified_fx": unverified,
            # Unified keys (same shape as the inventory dataset) so the
            # frontend cards + AI read ONE consistent shape for every scope:
            "total_sales": round(sales, 4),
            "total_cogs": round(cogs, 4),
            "total_profit": round(profit, 4),
            "inventory_value": round(cost_price * stock, 4),
            "products_count": 1 if prod else 0,
            # Legacy aliases kept for the stats page + flags logic:
            "sales_total": round(sales, 4),
            "purchases_total": round(purchases, 4),
            "cogs": round(cogs, 4),
            "profit": round(profit, 4),
            "sales_quantity": qty,
            "stock": stock,
            "min_stock": _f(prod.min_stock) if prod else 0,
            "sell_price": round(_f(prod.price) * pr, 4) if prod else 0,
            "cost_price": cost_price,
            "currency": rep,
        }
        # Suggested reorder quantity (estimate): refill to twice the alert
        # level or ~one-and-a-half months of observed velocity.
        if qty > 0:
            target = max(_f(data["min_stock"]) * 2, qty / 6.0)
            data["suggested_order_qty"] = max(0, round(target - _f(data["stock"])))
        # Real per-batch performance (purchase lots + linked sales) so batch
        # 1st/2nd/3rd can be compared truthfully.
        try:
            data["batches"] = await _product_batches(
                db, org_id, UUID(ref_id), rep
            )
        except Exception:
            data["batches"] = []
        return data, "المنتج"
    if scope == "category" and ref_id:
        return await _aggregate(db, org_id, UUID(ref_id), rep), "التصنيف"
    return await _aggregate(db, org_id, None, rep), "المخزون"


async def analyze(
    db: AsyncSession, org_id: UUID, scope: str, ref_id: Optional[str], lang: str,
    report_currency: Optional[str] = None,
    branch_ids=None,
    device=None,
) -> dict:
    import json

    data, title = device or await _dataset(db, org_id, scope, ref_id, report_currency, branch_ids=branch_ids)
    cur = (data.get("report_currency") or "USD").strip().upper()
    flags = _flags_from(data, scope)

    has_data = bool(
        data.get("total_sales", 0) > 0
        or data.get("products_count", 0) > 0
        or data.get("movements")
        or _f(data.get("inventory_value")) > 0
    )
    if not has_data:
        return {
            "status": "watch",
            "status_line": _branch_fallback(data, lang) if data.get('branch_summaries') else (
                "There is not enough data for this analysis yet." if lang == 'en' else "لا توجد بيانات كافية لهذا التحليل بعد."),
            "attention": [], "recommendations": [], "opportunity": "",
            "suggested_questions": [
                "وش وضع المخزون الحالي؟", "وش أحتاج أطلب الفترة القادمة؟",
            ],
            "ai": False, "stats": data,
            "debug": {
                "scope": scope, "ref_id": ref_id,
                "note": "no_data_checkpoint",
            },
        }

    debug_info = {'scope': scope, 'ref_id': ref_id,
                  'branch_ids': data.get('branch_ids', []), 'display_currency': cur}

    rule = _rule_report(data, flags, scope if scope in ("product", "category") else "inventory", title, cur)
    questions = _suggested_questions(scope if scope in ("product", "category") else "inventory", flags, data)

    # Merchant-type expertise: detect the product/category domain and attach
    # its playbook so pricing/turnover/marketing advice fits THIS goods.
    if scope == "product":
        cat_name = data.get("category_name") or ""
        if ref_id and device is None:
            prod_row = (
                await db.execute(
                    select(Product).where(
                        Product.id == UUID(ref_id),
                        Product.organization_id == org_id,
                    )
                )
            ).scalar_one_or_none()
            if prod_row is not None and prod_row.category_id:
                cat_row = (
                    await db.execute(
                        select(ProductCategory).where(
                            ProductCategory.id == prod_row.category_id)
                    )
                ).scalar_one_or_none()
                cat_name = (cat_row.name if cat_row else "") or ""
        names = [data.get("name") or ""]
    else:
        cat_name = data.get("category_name") or ""
        names = [i["name"] for i in (data.get("top_sellers") or [])] + \
                [i["name"] for i in (data.get("slow_moving") or [])]
    tinfo = _type_context(scope, data, names, cat_name)
    pb = tinfo["playbook"]

    compact = _compact_scoped_data(data)
    type_brief = (
        f"نوع البضاعة المكتشف: {pb['label']} (السبب: {tinfo['hit'] or 'تحليل الأسماء'}). "
        f"إرشادات النوع — التسعير: {pb['pricing']} التصريف: {pb['turnover']} "
        f"التسويق: {pb['marketing']} المخاطر: {pb['risks']} "
        f"الفرص: {pb['opportunity']} الطلب: {pb['order']}"
    )
    text = await _call_ai(
        _SYSTEM + '\n' + _BRANCH_RESPONSE_RULE + _language_rule(lang),
        f"النطاق: {title}\nالعملة: {cur}\n{type_brief}\nالبيانات:\n{compact}",
    )
    if not text:
        report = dict(rule)
        report["ai"] = False
    else:
        parsed = _parse(text)
        report = {
            "status": rule["status"],
            "status_line": parsed.get("status_line") or rule["status_line"],
            "attention": parsed.get("attention") or rule["attention"],
            "recommendations": parsed.get("recommendations") or rule["recommendations"],
            "opportunity": parsed.get("opportunity") or "",
            "ai": True,
        }
    # Deterministic type guide rendered as its own card (type-specific
    # pricing/turnover/marketing/risks) + suggested order qty for products.
    report["product_type"] = pb["label"]
    report["type_guide"] = {
        "pricing": pb["pricing"], "turnover": pb["turnover"],
        "marketing": pb["marketing"], "risks": pb["risks"],
    }
    if scope == "product" and data.get("suggested_order_qty") is not None:
        report["suggested_order_qty"] = data["suggested_order_qty"]
    report["suggested_questions"] = questions
    report["stats"] = data
    report["debug"] = debug_info  # TEMPORARY diagnosis field (counts only)
    if lang == 'en' and not report['ai']:
        report.update(status_line=f"Sales: {_fmt_money(flags['sales'], cur)}. Profit: {_fmt_money(flags['profit'], cur)}.",
                      attention=[], recommendations=['Review stock and sales before placing a new order.'], opportunity='')
    if data.get('branch_summaries'):
        # Always show exact branch evidence, including when AI omits a branch.
        report['status_line'] = _branch_fallback(data, lang) + '\n\n' + report['status_line']
    for field in ('status_line', 'opportunity', 'product_type'):
        report[field] = normalize_ai_text(plain_arabic(report[field], lang))
    for field in ('attention', 'recommendations'):
        report[field] = [
            line for line in (
                normalize_ai_text(plain_arabic(line, lang)) for line in report[field]
            ) if line
        ][:3]
    report['type_guide'] = {key: normalize_ai_text(value) for key, value in report['type_guide'].items()}
    return report


_BRANCH_RESPONSE_RULE = (
    'بيانات الفروع الحالية هي المصدر الوحيد للأرقام. اذكر اسم الفرع مع كل توصية تخصه. '
    'إذا تعددت الفروع قارن جميع الفروع المسموحة بالاسم من branch_summaries مع مخزون ومبيعات كل فرع. '
    'إذا حدد السؤال فرعاً بالاسم فأجب عنه وحده. لا تطلب اختيار فرع. '
    'استخدم أقساماً قصيرة وفقرة من جملة إلى ثلاث جمل، وسطرًا فارغًا واحدًا بين الأقسام. '
    'لا تستخدم Markdown أو علامات اقتباس أو زخارف أو عبارات إنشائية أو ترقيمًا مفرطًا. '
    'لا تعرض JSON للمستخدم؛ في التقرير استخدم JSON للنقل فقط دون تنسيق داخل قيمه. '
    'لا تخلط أرقام الفروع ولا تقترح كمية غير موجودة في البيانات ولا تعيد بيانات محادثة سابقة.'
)


def _language_rule(lang):
    return ('\nWrite all user-facing text in plain, simple English (no field names like qty_sold).'
            if lang == 'en' else
            '\nاكتب النص الظاهر للمستخدم بعربية بسيطة يفهمها كل تاجر، بدون أي كلمة إنجليزية.')


# Data field names the model sometimes copies into the text, in plain words.
_FIELD_WORDS = {
    'qty_sold': 'الكمية المباعة', 'quantity_sold': 'الكمية المباعة',
    'total_profit': 'الربح', 'total_sales': 'المبيعات', 'total_cogs': 'تكلفة المبيعات',
    'inventory_value': 'قيمة المخزون', 'suggested_order_qty': 'كمية الطلب',
    'order_qty': 'كمية الطلب', 'order_cost': 'تكلفة الطلب', 'min_stock': 'الحد الأدنى',
    'low_stock': 'قرب يخلص', 'out_of_stock': 'خلص', 'top_profit': 'الأكثر ربحًا',
    'products_count': 'عدد المنتجات', 'unit_cost': 'تكلفة القطعة',
    'reorder': 'الطلب', 'stock': 'المخزون', 'profit': 'الربح', 'sales': 'المبيعات',
    'margin': 'الربح', 'stagnant': 'راكد', 'cogs': 'تكلفة المبيعات',
}
_FIELD_RE = re.compile(
    r'(?<![A-Za-z0-9])(' + '|'.join(sorted(map(re.escape, _FIELD_WORDS), key=len, reverse=True)) + r')(?![A-Za-z0-9])',
    re.IGNORECASE,
)


def plain_arabic(text: str, lang: str = 'ar') -> str:
    """Answers never show data field names (qty_sold, reorder…)."""
    text = str(text or '')
    if lang == 'en':
        return re.sub(r'(?<![A-Za-z0-9])([a-z]+)_([a-z0-9_]+)(?![A-Za-z0-9])',
                      lambda m: m.group(0).replace('_', ' '), text)
    text = _FIELD_RE.sub(lambda m: _FIELD_WORDS[m.group(1).lower()], text)
    # Any other snake_case identifier is a field name: drop it.
    text = re.sub(r'(?<![A-Za-z0-9])[a-z]+(?:_[a-z0-9]+)+(?![A-Za-z0-9])', '', text)
    return re.sub(r'[ \t]{2,}', ' ', text).strip()


def normalize_ai_text(text: str) -> str:
    """Remove presentation noise without touching digits, decimals or line breaks."""
    text = str(text or '').replace('\r\n', '\n').replace('\r', '\n')
    text = re.sub(r'```(?:json|text|markdown)?', '', text, flags=re.IGNORECASE)
    text = text.replace('**', '').replace('`', '')
    text = re.sub(r'[{}"“”«»]', '', text)
    text = re.sub(r"(?<!\w)['‘’]|['‘’](?!\w)", '', text)
    text = re.sub(r'(?m)^\s{0,3}(?:#{1,6}\s+|[-*•]\s+)', '', text)
    text = re.sub(r'([!?؟!،؛:.,])\1+', r'\1', text)
    text = '\n'.join(line.strip() for line in text.split('\n'))
    return re.sub(r'\n{3,}', '\n\n', text).strip()


def _compact_scoped_data(data):
    import json
    # Put tenant/branch identity ahead of rankings. Never cut JSON mid-object
    # or accidentally discard the last branches because a top-seller is long.
    keys = ('branch_ids', 'report_currency', 'unverified_fx', 'products_count',
            'inventory_value', 'total_sales', 'total_profit', 'total_cogs', 'total_purchases',
            'name', 'stock', 'sales_quantity', 'min_stock', 'suggested_order_qty',
            'sell_price', 'cost_price', 'low_stock', 'out_of_stock', 'reorder',
            'stagnant_value_share')
    compact = {key: data[key] for key in keys if key in data}
    summaries = data.get('branch_summaries', [])
    compact['branch_summaries'] = [{key: value for key, value in row.items() if key != 'top_sellers'} for row in summaries]
    for key in ('top_sellers', 'slow_moving', 'weak_margin', 'batches'):
        if key in data: compact[key] = data[key][:5]
    return json.dumps(compact, ensure_ascii=False, default=str)


def _branch_fallback(data, lang):
    rows = data.get('branch_summaries') or []
    if not rows:
        return normalize_ai_text(_SPECIALTY_FALLBACK if lang != 'en' else
            'There is not enough branch data to answer.\n\nRecord stock movements and sales first.')
    ar = lang != 'en'
    out = []
    for row in rows:
        out.append(f"{row['branch_name']}\n" +
            (f"المبيعات: {row['total_sales']:,.2f} {data['report_currency']}، المخزون: {row['stock']:,.2f}."
             if ar else f"Sales: {row['total_sales']:,.2f} {data['report_currency']}; stock: {row['stock']:,.2f}."))
        low = (row.get('out_of_stock', []) + row.get('low_stock', []))[:3]
        if low: out.append(('راجع التوريد لهذا الفرع: ' if ar else 'Check replenishment for this branch: ') + '، '.join(low) + '.')
    if data.get('unverified_fx'):
        out.append('بعض قيم العملات غير مكتملة لعدم توفر سعر صرف موثوق.' if ar else 'Some currency valuations are incomplete because a reliable FX rate is unavailable.')
    return normalize_ai_text('\n\n'.join(out))


def _parse(text: str) -> dict:
    import json

    t = text.strip()
    if t.startswith("```"):
        t = t.strip("`")
        t = t[t.find("{"):] if "{" in t else t
    try:
        start = t.find("{")
        end = t.rfind("}")
        data = json.loads(t[start:end + 1]) if start >= 0 and end > start else {}
    except Exception:
        data = {}
    def aslist(v):
        if isinstance(v, list):
            return [str(x).strip() for x in v if str(x).strip()]
        if isinstance(v, str) and v.strip():
            return [v.strip()]
        return []
    attention = aslist(data.get("attention"))[:3]
    seen = set(attention)
    recommendations = [
        x for x in aslist(data.get("recommendations")) if x not in seen
    ][:3]
    return {
        "status_line": str(data.get("status_line") or "").strip(),
        "attention": attention,
        "recommendations": recommendations,
        "opportunity": str(data.get("opportunity") or "").strip(),
    }


async def chat(
    db: AsyncSession, org_id: UUID, scope: str, ref_id: Optional[str],
    question: str, history: list, lang: str,
    report_currency: Optional[str] = None,
    branch_ids=None,
    device=None,
    device_rebuild=None,
) -> dict:
    import json

    data, title = device or await _dataset(db, org_id, scope, ref_id, report_currency, branch_ids=branch_ids)
    all_summaries = data.get('branch_summaries') or []
    # Resolve only against the signed permitted set, then recompute every metric
    # for the named branch. Never mix an all-branch total into a branch answer.
    named = [row for row in all_summaries if _mentions_branch(question, row['branch_name'])]
    if named and device is not None:
        # The phone's own figures: recompute from the named branches' rows.
        if device_rebuild is None:
            named = []
        else:
            data, title = device_rebuild({row['branch_id'] for row in named})
    elif named:
        data, title = await _dataset(db, org_id, scope, ref_id, report_currency,
                                    branch_ids=[row['branch_id'] for row in named])
    cur = (data.get("report_currency") or "USD").strip().upper()
    flags = _flags_from(data, scope)

    # Merchant-type brief for the chat too (same expertise as the report).
    if scope == "product":
        names = [data.get("name") or ""]
        cat_name = data.get("category_name") or ""
        if ref_id and device is None:
            prod_row = (
                await db.execute(
                    select(Product).where(
                        Product.id == UUID(ref_id),
                        Product.organization_id == org_id,
                    )
                )
            ).scalar_one_or_none()
            if prod_row is not None and prod_row.category_id:
                cat_row = (
                    await db.execute(
                        select(ProductCategory).where(
                            ProductCategory.id == prod_row.category_id)
                    )
                ).scalar_one_or_none()
                cat_name = (cat_row.name if cat_row else "") or ""
    else:
        cat_name = ""
        names = [i["name"] for i in (data.get("top_sellers") or [])] + \
                [i["name"] for i in (data.get("slow_moving") or [])]
    tinfo = _type_context(scope, data, names, cat_name)
    pb = tinfo["playbook"]

    compact = _compact_scoped_data(data)
    scope_line = {
        "product": "نطاق المحادثة: منتج واحد فقط.",
        "category": "نطاق المحادثة: منتجات هذا التصنيف فقط.",
    }.get(scope, "نطاق المحادثة: المخزون بالكامل.")
    type_line = (
        f"نوع البضاعة: {pb['label']}. إرشاد النوع — التسعير: {pb['pricing']} "
        f"التصريف: {pb['turnover']} المخاطر: {pb['risks']}"
    )
    msgs = [{
        "role": "system",
        "content": (
            f"{_CHAT_SYSTEM}\n{_BRANCH_RESPONSE_RULE}{_language_rule(lang)}\n{scope_line} العملة: {cur}. {type_line} "
            f"وضع محسوب مسبقًا: {_verdict(flags, scope if scope in ('product','category') else 'inventory')}."
        ),
    }]
    for h in ([] if named else (history or [])[-6:]):
        role = h.get("role")
        if role in ("user", "assistant"):
            msgs.append({"role": role, "content": str(h.get("content") or "")})
    msgs.append({
        "role": "user",
        "content": f"البيانات الحالية:\n{compact}\n\nالسؤال: {question}",
    })
    # Same provider as Sara (DeepSeek when its key is set, else OpenAI).
    key = settings.DEEPSEEK_API_KEY or settings.OPENAI_API_KEY
    if not key:
        return {"answer": _branch_fallback(data, lang)}
    try:
        from app.domain.services.ai_router import build_client, route

        import asyncio

        # Effort from the question itself (the figures dump is long and
        # always looked «max»); one bounded attempt.
        r = route(question or "", tools=False, base_tokens=500)
        if not r.api_key:
            return {"answer": _branch_fallback(data, lang)}
        client = _bounded(build_client(r), AI_CHAT_TIMEOUT)
        resp = await asyncio.wait_for(client.chat.completions.create(
            model=r.model, messages=msgs,
            temperature=0.4, max_tokens=r.max_tokens,
            extra_body={"effort": r.effort},
        ), AI_CHAT_TIMEOUT)
        answer = plain_arabic(_as_plain((resp.choices[0].message.content or "")), lang)
        summaries = data.get('branch_summaries') or []
        if any(row['branch_name'] not in answer for row in summaries):
            answer = _branch_fallback(data, lang)
        if named and any(row['branch_name'] in answer for row in all_summaries if row not in named):
            answer = _branch_fallback(data, lang)
        return {"answer": answer or _branch_fallback(data, lang)}
    except Exception:
        return {"answer": _branch_fallback(data, lang)}


def _mentions_branch(question: str, name: str) -> bool:
    # Word boundaries also work with Arabic; avoid matching a short name
    # inside another word. Accept both فرع الرياض and الرياض.
    name = re.sub(r'^فرع\s+', '', name.strip(), flags=re.IGNORECASE)
    return bool(name and re.search(r'(?<!\w)' + re.escape(name) + r'(?!\w)', question, re.IGNORECASE))


def _as_plain(text: str) -> str:
    """Never surface raw JSON to the user. If the model replied with a JSON
    object, flatten its human-readable fields to Arabic text."""
    import json

    t = (text or "").strip()
    if not t:
        return ""
    if t.startswith("```"):
        t = re.sub(r'^```(?:json|text|markdown)?\s*|\s*```$', '', t,
                   flags=re.IGNORECASE).strip()
    i, j = t.find("{"), t.rfind("}")
    if i >= 0 and j > i:
        try:
            data = json.loads(t[i : j + 1], strict=False)
        except Exception:
            return normalize_ai_text(t)
        if isinstance(data, dict):
            parts: list = []
            for k in ("answer", "text", "status_line"):
                v = data.get(k)
                if isinstance(v, str) and v.strip():
                    parts.append(v.strip())
            for k in ("attention", "recommendations"):
                v = data.get(k)
                if isinstance(v, list):
                    parts.extend(str(x).strip() for x in v if str(x).strip())
                elif isinstance(v, str) and v.strip():
                    parts.append(v.strip())
            if parts:
                return normalize_ai_text("\n\n".join(parts))
    return normalize_ai_text(t)
