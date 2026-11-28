"""Smart import — Sara suggests which column of the user's file is which
FYONA field. Only four things are ever imported: final balances of banks and
cash, products with their stock, customers and suppliers. That is ALL the AI does: the device reads the file, checks
every row, shows the preview and imports it with its own deterministic
rules. Only the column titles and at most 30 sample rows (each value cut to
60 characters) are sent; nothing is stored or logged here."""

from __future__ import annotations

import asyncio
import json
import re
from typing import List, Literal, Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..deps import get_current_user_uuid

router = APIRouter(tags=["Import"])

FIELDS = {
    "parties": {
        "name": "اسم العميل أو المورد",
        "kind": "نوعه: عميل أو مورد (إن وُجد عمود لذلك)",
        "phone": "رقم الهاتف",
        "balance": "الرصيد أو الدين المستحق حاليًا (رقم)",
        "debit": "مدين (رقم، إن كان الرصيد في عمودين)",
        "credit": "دائن (رقم، إن كان الرصيد في عمودين)",
        "currency": "العملة",
    },
    "products": {
        "name": "اسم المنتج",
        "barcode": "الباركود",
        "unit": "الوحدة",
        "sale_price": "سعر البيع",
        "cost_price": "سعر الشراء أو التكلفة",
        "stock": "الكمية في المخزون",
        "category": "التصنيف",
        "image": "الصورة",
        "min_stock": "الحد الأدنى",
        "expiry": "تاريخ الانتهاء",
        "currency": "عملة أسعار المنتج (إن كانت مكتوبة)",
    },
    "accounts": {
        "name": "اسم الحساب أو الصندوق",
        "bank": "اسم البنك",
        "number": "رقم الحساب",
        "iban": "الآيبان",
        "balance": "الرصيد الحالي",
        "currency": "العملة",
    },
    "units": {"name": "اسم الوحدة", "factor": "كم وحدة أساسية فيها", "barcode": "باركود الوحدة",
              "sale_price": "سعر بيع الوحدة", "cost_price": "سعر شراء الوحدة"},
    "barcodes": {"barcode": "باركود إضافي للمنتج"},
    "images": {"image": "صورة المنتج"},
    "categories": {"name": "اسم التصنيف"},
    "prices": {"price": "السعر", "kind": "نوع السعر (بيع/تجزئة/جملة/تكلفة)", "cost": "سعر الشراء",
               "currency": "العملة"},
    "stock": {"quantity": "الكمية المتوفرة", "branch": "الفرع أو المستودع"},
    "balances": {"amount": "المبلغ المستحق على العميل أو للمورد", "paid": "المدفوع منه", "currency": "العملة"},
    "branches": {"name": "اسم الفرع"},
    "currencies": {"code": "رمز العملة (SAR, USD…)"},
}

ROLES = {
    "customers": "عملاء", "suppliers": "موردون", "products": "منتجات", "accounts": "حسابات بنكية أو صناديق",
    "units": "وحدات المنتجات (مرتبطة بالمنتجات)", "barcodes": "باركودات إضافية للمنتجات",
    "images": "صور المنتجات", "categories": "تصنيفات المنتجات",
    "prices": "أسعار المنتجات (جدول مرتبط بالمنتجات: سعر لكل منتج/عملة/نوع)",
    "stock": "كميات المخزون لكل منتج (وقد يكون لكل فرع)",
    "balances": "أرصدة العملاء أو الموردين الحالية: ذمم مدينة/دائنة، مستحقات، أرصدة افتتاحية (مرتبطة بالعملاء/الموردين)",
    "branches": "قائمة الفروع أو المستودعات (لا تُستورد أبدًا؛ تُستخدم فقط لمعرفة أي صفوف تخص أي فرع)",
    "currencies": "قائمة العملات (للمعرفة فقط)",
    "history": "سجلات سابقة: فواتير، سندات، حركات، مدفوعات، مصروفات، إيرادات (لا تُستورد)",
    "unsupported": "بيانات لا تُستورد: موظفون، رواتب، أصول، مستخدمون، إعدادات، ضرائب…",
    "unknown": "غير واضح",
}

_TIMEOUT = 40.0
# FYONA currency codes: ISO (SAR, USD…) or ISO with a variant (YER_NEW, YER_OLD).
_CURRENCY = r"^[A-Za-z]{3}(?:_[A-Za-z]{3})?$"


def _currency_code(value) -> Optional[str]:
    code = str(value or "").strip().upper()
    return code if re.match(_CURRENCY, code) else None
_SCHEMA_GROUP = 6
_SCHEMA_TOKENS = 8000
_SCHEMA_TIMEOUT = 75.0


class MappingIn(BaseModel):
    target: Literal["parties", "products", "accounts"]
    columns: List[str] = Field(min_length=1, max_length=200)
    sample: List[List[Optional[str]]] = Field(default_factory=list, max_length=30)


def _clean(columns: List[str], sample: List[List[Optional[str]]]):
    cols = [str(c)[:80] for c in columns]
    rows = [[("" if v is None else str(v))[:60] for v in r[: len(cols)]] for r in sample[:30]]
    return cols, rows


def validate(target: str, raw: object, columns: List[str]) -> dict:
    """Keep only known fields mapped to columns that exist (exact titles)."""
    if not isinstance(raw, dict):
        return {}
    m = raw.get("mapping", raw)
    if not isinstance(m, dict):
        return {}
    out = {}
    used = set()
    for field in FIELDS[target]:
        col = m.get(field)
        if isinstance(col, str) and col in columns and col not in used:
            out[field] = col
            used.add(col)
    return out


async def _ask(target: str, cols: List[str], rows: List[List[str]]) -> Optional[str]:
    from app.domain.services.ai_router import build_client, route

    fields = "\n".join(f"- {k}: {v}" for k, v in FIELDS[target].items())
    system = (
        "You match the columns of a spreadsheet to FYONA import fields. "
        "Answer with JSON only: {\"mapping\": {\"<field>\": \"<exact column title>\" or null}}. "
        "Use each column at most once. Never invent a column title. Fields:\n" + fields
    )
    user = json.dumps({"columns": cols, "sample_rows": rows}, ensure_ascii=False)
    r = route("map columns", tools=False, base_tokens=600)
    if not r.api_key:
        return None
    client = build_client(r)
    try:
        client = client.with_options(timeout=_TIMEOUT, max_retries=0)
    except Exception:  # noqa: BLE001
        pass
    resp = await asyncio.wait_for(client.chat.completions.create(
        model=r.model,
        messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
        temperature=0,
        max_tokens=3000,
        response_format={"type": "json_object"},
    ), _TIMEOUT)
    return (resp.choices[0].message.content or "").strip()


@router.post("/ai/import-mapping", summary="سارة تقترح مطابقة أعمدة ملف الاستيراد")
async def import_mapping(body: MappingIn, user_id: UUID = Depends(get_current_user_uuid)):
    cols, rows = _clean(body.columns, body.sample)
    try:
        text = await _ask(body.target, cols, rows)
    except Exception:  # noqa: BLE001 — never echo provider errors (may quote data)
        text = None
    if not text:
        raise HTTPException(503, detail={"code": "sara_unavailable",
                                         "message": "سارة غير متاحة الآن؛ طابِق الأعمدة يدويًا"})
    try:
        mapping = validate(body.target, json.loads(text), cols)
    except ValueError:
        mapping = {}
    return {"success": True, "data": {"mapping": mapping, "source": "sara"}}


class TableIn(BaseModel):
    name: str = Field(max_length=120)
    columns: List[str] = Field(min_length=1, max_length=200)
    sample: List[List[Optional[str]]] = Field(default_factory=list, max_length=5)


class SchemaIn(BaseModel):
    tables: List[TableIn] = Field(min_length=1, max_length=40)


def validate_schema(raw: object, tables: List[TableIn]) -> list:
    """Keep only known roles and fields mapped to real columns."""
    by_name = {t.name: t for t in tables}
    out = []
    items = raw.get("tables") if isinstance(raw, dict) else None
    for it in items if isinstance(items, list) else []:
        if not isinstance(it, dict):
            continue
        t = by_name.get(str(it.get("name")))
        role = str(it.get("role") or "")
        if t is None or role not in ROLES:
            continue
        fields = FIELDS.get("parties" if role in ("customers", "suppliers") else role, {})
        cols = [str(c)[:80] for c in t.columns]
        mapping = {}
        m = it.get("mapping") if isinstance(it.get("mapping"), dict) else {}
        used = set()
        for f in fields:
            c = m.get(f)
            if isinstance(c, str) and c in cols and c not in used:
                mapping[f] = c
                used.add(c)
        link = it.get("link") if isinstance(it.get("link"), str) and it.get("link") in cols else None
        out.append({"name": t.name, "role": role, "mapping": mapping, "link": link})
    return out


@router.post("/ai/import-schema", summary="سارة تقترح ما هو كل جدول في ملف الاستيراد")
async def import_schema(body: SchemaIn, user_id: UUID = Depends(get_current_user_uuid)):
    from app.domain.services.ai_router import build_client, route

    tables = [{"name": t.name[:120], "columns": [str(c)[:80] for c in t.columns],
               "sample_rows": [[("" if v is None else str(v))[:60] for v in r[: len(t.columns)]] for r in t.sample[:5]]}
              for t in body.tables]
    roles = "\n".join(f"- {k}: {v}" for k, v in ROLES.items())
    fields = "\n".join(f"- {'customers / suppliers' if k == 'parties' else k}: {', '.join(v)}" for k, v in FIELDS.items())
    system = (
        "You classify the tables of a business's old database for import into FYONA ERP. "
        "Answer JSON only: {\"tables\": [{\"name\": <table>, \"role\": <role>, "
        "\"mapping\": {<field>: <exact column title>}, \"link\": <column pointing at the products table or null>}]}. "
        "Never invent a column. A table of past documents (invoices, payments, orders) is history; one that only "
        "states what each customer/supplier owes today is balances. If unsure, use role unknown. "
        "\"link\" is the column pointing at the products (for product parts) or at the customers/suppliers (for balances). "
        "Roles:\n" + roles + "\nFields per role:\n" + fields
    )
    r = route("classify tables", tools=False, base_tokens=1500)
    if not r.api_key:
        raise HTTPException(503, detail={"code": "sara_unavailable", "message": "سارة غير متاحة الآن"})
    client = build_client(r)
    try:
        client = client.with_options(timeout=_SCHEMA_TIMEOUT, max_retries=0)
    except Exception:  # noqa: BLE001
        pass

    # The model thinks before it answers: a big database in one request ran
    # out of room and came back EMPTY ("Sara unavailable"). Small groups of
    # tables go out together, each with room to think and answer.
    async def one(group):
        try:
            resp = await asyncio.wait_for(client.chat.completions.create(
                model=r.model,
                messages=[{"role": "system", "content": system},
                          {"role": "user", "content": json.dumps({"tables": group}, ensure_ascii=False)}],
                temperature=0, max_tokens=_SCHEMA_TOKENS, response_format={"type": "json_object"},
            ), _SCHEMA_TIMEOUT)
            return validate_schema(json.loads((resp.choices[0].message.content or "").strip()), body.tables)
        except Exception:  # noqa: BLE001 — never echo provider errors
            return None

    groups = [tables[i:i + _SCHEMA_GROUP] for i in range(0, len(tables), _SCHEMA_GROUP)]
    answers = await asyncio.gather(*(one(g) for g in groups))
    if all(a is None for a in answers):
        raise HTTPException(503, detail={"code": "sara_unavailable", "message": "سارة غير متاحة الآن"})
    result = [x for a in answers if a for x in a]
    return {"success": True, "data": {"tables": result, "source": "sara"}}


# ── Sara inside the import window (agent) ──
# Sara reads the user's request and the file's OUTLINE (table names, column
# titles, what each table was recognised as, ≤3 sample rows cut to 60
# characters) and answers with operations. The phone applies them to its
# review with its own rules and shows the result before anything is saved;
# nothing is stored here.

AGENT_ROLES = ["customers", "suppliers", "products", "accounts", "units", "barcodes", "images", "categories",
               "prices", "stock", "balances", "branches", "currencies", "history", "unsupported", "unknown"]
AGENT_TARGETS = {"products", "customers", "suppliers", "accounts"}
# Sara never writes amounts, prices, quantities or phone numbers: those come
# from the file only. She may name a currency, a unit, a category or a bank.
AGENT_SET_FIELDS = {
    "products": {"currency", "unit", "category"},
    "customers": {"currency"},
    "suppliers": {"currency"},
    "accounts": {"currency", "bank"},
}
AGENT_WHERE_OPS = {"empty", "not_empty", "equals", "contains", "lt", "gt"}
_MAX_OPS = 30


class AgentTableIn(BaseModel):
    name: str = Field(max_length=120)
    role: str = Field(max_length=20)
    rows: int = 0
    columns: List[str] = Field(default_factory=list, max_length=120)
    mapping: dict = Field(default_factory=dict)
    sample: List[List[Optional[str]]] = Field(default_factory=list, max_length=3)


class AgentIn(BaseModel):
    message: str = Field(min_length=1, max_length=800)
    # Empty: the user has not chosen one yet (never assumed).
    currency: Optional[str] = Field(default=None, max_length=7)
    tables: List[AgentTableIn] = Field(default_factory=list, max_length=60)
    history: List[dict] = Field(default_factory=list, max_length=8)


def validate_ops(raw: object, tables: List[AgentTableIn]) -> list:
    """Keep only operations the phone knows, on tables / columns / fields
    that exist. Anything else is dropped (never guessed into shape)."""
    names = {t.name: t for t in tables}
    ops = raw.get("ops") if isinstance(raw, dict) else None
    out = []
    for o in ops if isinstance(ops, list) else []:
        if not isinstance(o, dict) or len(out) >= _MAX_OPS:
            continue
        kind = o.get("op")
        if kind == "set_role":
            t, role = names.get(str(o.get("table"))), str(o.get("role"))
            if t is not None and role in AGENT_ROLES:
                out.append({"op": "set_role", "table": t.name, "role": role})
        elif kind == "map":
            t = names.get(str(o.get("table")))
            field, col = str(o.get("field") or ""), o.get("column")
            if t is None or not field or len(field) > 30:
                continue
            if col is not None and str(col) not in t.columns:
                continue
            out.append({"op": "map", "table": t.name, "field": field, "column": None if col is None else str(col)})
        elif kind == "set_currency":
            code = _currency_code(o.get("currency"))
            if code:
                out.append({"op": "set_currency", "currency": code})
        elif kind == "set_field":
            target, field = str(o.get("target")), str(o.get("field"))
            if target not in AGENT_SET_FIELDS or field not in AGENT_SET_FIELDS[target]:
                continue
            value = o.get("value")
            if value is None or len(str(value)) > 120:
                continue
            if field == "currency":
                value = _currency_code(value)
                if not value:
                    continue
            where = o.get("where") if isinstance(o.get("where"), dict) else None
            op = {"op": "set_field", "target": target, "field": field, "value": str(value),
                  "only_empty": bool(o.get("only_empty", False))}
            if where and str(where.get("op") or "") in AGENT_WHERE_OPS:
                op["where"] = {"field": str(where.get("field") or "")[:30], "op": str(where.get("op")),
                               "value": None if where.get("value") is None else str(where.get("value"))[:120]}
            out.append(op)
        elif kind in ("reject", "accept"):
            target = str(o.get("target"))
            where = o.get("where") if isinstance(o.get("where"), dict) else {}
            wop = str(where.get("op") or "")
            if target not in AGENT_TARGETS or wop not in AGENT_WHERE_OPS:
                continue
            out.append({"op": kind, "target": target,
                        "where": {"field": str(where.get("field") or "")[:30], "op": wop,
                                  "value": None if where.get("value") is None else str(where.get("value"))[:120]}})
    return out


_AGENT_SYSTEM = (
    "You are Sara, the assistant inside FYONA ERP's smart import window. The user imports an old database "
    "into FYONA. FYONA imports ONLY four things: final balances of bank accounts and cash boxes, products with "
    "their stock, customers and suppliers (name, phone, what they owe). Branches, invoices, payments, movements, "
    "employees and anything else are never imported. You see the outline of the file: each table, what FYONA "
    "recognised it as (role), its columns, the field→column mapping and a few sample rows. Do what the user asks "
    "by returning operations; the app applies them, re-checks every row and shows the result before saving.\n"
    "You NEVER invent or change amounts, prices, quantities, balances, phone numbers or exchange rates: they "
    "come from the file only. You never convert currencies.\n"
    "Answer JSON only: {\"reply\": <short answer in the user's language and dialect, 1-3 sentences, say what "
    "you changed>, \"ops\": [...]}.\n"
    "Operations:\n"
    "- {\"op\":\"set_role\",\"table\":T,\"role\":R} put a table somewhere else. Roles: " + ", ".join(AGENT_ROLES) + ".\n"
    "- {\"op\":\"map\",\"table\":T,\"field\":F,\"column\":C or null} which column is which field.\n"
    "- {\"op\":\"set_currency\",\"currency\":\"SAR\"} currency of amounts the file does not name "
    "(FYONA codes: SAR, USD, AED, YER_NEW, YER_OLD…; only when the user names it).\n"
    "- {\"op\":\"set_field\",\"target\":\"products|customers|suppliers|accounts\",\"field\":F,\"value\":V,"
    "\"only_empty\":true|false, \"where\":{optional filter as below}} give rows one value (products: currency, "
    "unit, category; customers/suppliers: currency; accounts: currency, bank).\n"
    "- {\"op\":\"reject\"|\"accept\",\"target\":...,\"where\":{\"field\":F,\"op\":\"empty|not_empty|equals|contains|lt|gt\","
    "\"value\":V}} leave rows out / put them back.\n"
    "Never invent tables or columns. Invoices, payments and other past documents must stay history (importing "
    "them would double debts and stock) — explain that if asked. If the user asks to check or arrange the "
    "file, fix roles and mappings so each table goes to the right one of the four sections. If the request is "
    "unclear or impossible (e.g. changing prices or importing branches), return no ops and say why in one sentence."
)


@router.post("/ai/import-agent", summary="سارة داخل نافذة الاستيراد: تنفّذ طلب المستخدم على المراجعة")
async def import_agent(body: AgentIn, user_id: UUID = Depends(get_current_user_uuid)):
    from app.domain.services.ai_router import build_client, route

    outline = {
        "currency": _currency_code(body.currency) or "not chosen yet",
        "tables": [{
            "name": t.name[:120], "role": t.role[:20], "rows": t.rows,
            "columns": [str(c)[:80] for c in t.columns[:120]],
            "mapping": {str(k)[:30]: str(v)[:80] for k, v in list(t.mapping.items())[:40]},
            "sample_rows": [[("" if v is None else str(v))[:60] for v in r[:40]] for r in t.sample[:3]],
        } for t in body.tables],
    }
    history = [{"role": "assistant" if h.get("role") == "assistant" else "user", "content": str(h.get("content", ""))[:600]}
               for h in body.history[-8:] if isinstance(h, dict)]
    r = route("import agent", tools=False, base_tokens=2000)
    if not r.api_key:
        raise HTTPException(503, detail={"code": "sara_unavailable", "message": "سارة غير متاحة الآن"})
    client = build_client(r)
    try:
        client = client.with_options(timeout=75.0, max_retries=0)
    except Exception:  # noqa: BLE001
        pass
    try:
        resp = await asyncio.wait_for(client.chat.completions.create(
            model=r.model,
            messages=[{"role": "system", "content": _AGENT_SYSTEM},
                      {"role": "user", "content": "FILE OUTLINE:\n" + json.dumps(outline, ensure_ascii=False)},
                      *history,
                      {"role": "user", "content": body.message[:800]}],
            temperature=0, max_tokens=6000, response_format={"type": "json_object"},
        ), 75.0)
        data = json.loads((resp.choices[0].message.content or "").strip())
    except Exception:  # noqa: BLE001 — never echo provider errors
        raise HTTPException(503, detail={"code": "sara_unavailable", "message": "سارة غير متاحة الآن"})
    reply = str(data.get("reply") or "")[:600] if isinstance(data, dict) else ""
    return {"success": True, "data": {"reply": reply, "ops": validate_ops(data, body.tables), "source": "sara"}}
