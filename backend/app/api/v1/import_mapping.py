"""Smart import — Sara suggests which column of the user's file is which
FYONA field. That is ALL the AI does: the device reads the file, checks
every row, shows the preview and imports it with its own deterministic
rules. Only the column titles and at most 30 sample rows (each value cut to
60 characters) are sent; nothing is stored or logged here."""

from __future__ import annotations

import asyncio
import json
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
        "sku": "رمز المنتج",
        "unit": "الوحدة",
        "sale_price": "سعر البيع",
        "cost_price": "سعر الشراء أو التكلفة",
        "stock": "الكمية في المخزون",
    },
}

_TIMEOUT = 25.0


class MappingIn(BaseModel):
    target: Literal["parties", "products"]
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
        max_tokens=600,
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
