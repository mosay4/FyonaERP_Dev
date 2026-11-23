"""Tenant/branch-bound business data backups. Never export authentication/HR."""
import hashlib
import json
from datetime import date, datetime, timezone
from decimal import Decimal
from uuid import UUID
from sqlalchemy import select, and_, or_, insert, update
from fastapi import HTTPException
from ...core.database import Base

TABLES = set('''branches customers suppliers product_categories products product_units product_barcodes
product_prices inventory_movements warehouse_settings branch_stock inventory_lots inventory_lot_consumptions
invoices invoice_items payments invoice_sequences org_invoice_designs invoice_item_changes
bank_accounts bank_transactions financial_payments expenses cheques accounts journal_entries journal_entry_lines
purchase_orders purchase_order_items purchase_receipts purchase_receipt_items purchase_returns
purchase_return_items supplier_bills customer_receivables supplier_payables invoice_returns invoice_return_items
business_project_settings reconciliations'''.split())

LEDGERS = TABLES - {'branches', 'customers', 'suppliers', 'product_categories',
    'products', 'product_units', 'product_barcodes', 'product_prices',
    'warehouse_settings', 'org_invoice_designs', 'business_project_settings'}


def _json(value):
    if isinstance(value, (UUID, Decimal)): return str(value)
    if isinstance(value, (date, datetime)): return value.isoformat()
    raise TypeError(f'Unsupported backup value: {type(value).__name__}')


def checksum(payload):
    return hashlib.sha256(payload.encode()).hexdigest()


async def capture(db, org, branch_ids):
    ids = {}
    result = {}
    total = 0
    # Sorted FK order allows child tables without an organization_id to inherit
    # ownership from their document/product. No global/private tables enter here.
    for table in Base.metadata.sorted_tables:
        if table.name not in TABLES: continue
        if 'organization_id' in table.c:
            condition = table.c.organization_id == org
            if table.name == 'branches': condition = and_(condition, table.c.id.in_(branch_ids))
            elif 'branch_id' in table.c:
                condition = and_(condition, table.c.branch_id.in_(branch_ids))
        else:
            owned = []
            priority = ['invoice_id', 'purchase_order_id', 'receipt_id', 'return_id',
                        'journal_entry_id', 'invoice_item_id', 'product_id']
            for column in table.c:
                for fk in column.foreign_keys:
                    if fk.column.table.name in ids:
                        owned.append((priority.index(column.name) if column.name in priority else 99,
                                      column, ids[fk.column.table.name]))
            if not owned: continue
            _, column, values = sorted(owned, key=lambda item: item[0])[0]
            condition = column.in_(values)
        rows = (await db.execute(select(table).where(condition).limit(100001))).mappings().all()
        total += len(rows)
        if total > 100000: raise HTTPException(413, detail='حجم بيانات النسخة يتجاوز الحد المسموح')
        result[table.name] = [dict(row) for row in rows]
        if 'id' in table.c: ids[table.name] = [row['id'] for row in rows]
    payload = json.dumps({'schema': 1, 'organization_id': str(org),
        'branch_ids': sorted(str(b) for b in branch_ids), 'created_at': datetime.now(timezone.utc).isoformat(),
        'tables': result, 'record_count': total}, ensure_ascii=False, default=_json)
    if len(payload.encode()) > 25 * 1024 * 1024: raise HTTPException(413, detail='حجم النسخة أكبر من 25 ميجا')
    return payload


def _decode(column, value):
    if value is None: return None
    try: kind = column.type.python_type
    except NotImplementedError: return value
    if kind is UUID: return UUID(value)
    if kind is Decimal: return Decimal(str(value))
    if kind is datetime: return datetime.fromisoformat(value)
    if kind is date: return date.fromisoformat(value)
    return value


async def restore(db, row, org, branch_ids):
    if checksum(row.payload) != row.checksum: raise HTTPException(400, detail='بصمة النسخة غير صحيحة')
    snapshot = json.loads(row.payload)
    if snapshot['organization_id'] != str(org) or set(snapshot['branch_ids']) != {str(b) for b in branch_ids}:
        raise HTTPException(403, detail='النسخة ليست لهذا المتجر والفروع المحددة')
    # A record may have moved to another branch since capture. Check current
    # ownership too, including child tables that inherit scope through FKs.
    current = json.loads(await capture(db, org, branch_ids))['tables']
    for name in LEDGERS:
        table = Base.metadata.tables.get(name)
        if table is None: continue
        old_keys = {tuple(str(item[c.name]) for c in table.primary_key)
                    for item in snapshot['tables'].get(name, [])}
        new_keys = {tuple(str(item[c.name]) for c in table.primary_key)
                    for item in current.get(name, [])}
        if new_keys - old_keys:
            raise HTTPException(409, detail='توجد سجلات مالية أو مخزنية أحدث من النسخة؛ لا يمكن دمج أرصدتها بأمان')
    for table in Base.metadata.sorted_tables:
        if table.name not in TABLES: continue
        current_keys = {tuple(str(item[c.name]) for c in table.primary_key)
                        for item in current.get(table.name, [])}
        for source in snapshot['tables'].get(table.name, []):
            values = {key: _decode(table.c[key], value) for key, value in source.items() if key in table.c}
            key = and_(*(c == values[c.name] for c in table.primary_key))
            existing = (await db.execute(select(table).where(key))).mappings().first()
            if existing:
                if tuple(str(source[c.name]) for c in table.primary_key) not in current_keys:
                    raise HTTPException(403, detail='تعارض ملكية سجل في النسخة')
                await db.execute(update(table).where(key).values(**values))
            else:
                await db.execute(insert(table).values(**values))
    await db.flush()
    return snapshot['record_count']
