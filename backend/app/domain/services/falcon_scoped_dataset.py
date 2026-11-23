"""Branch-bound inventory evidence for Falcon; no main-branch stock reuse."""
from collections import defaultdict
from decimal import Decimal
from uuid import UUID
from fastapi import HTTPException
from sqlalchemy import select, func, or_
from ..entities.business_entities import Product, ProductCategory
from ..entities.invoice_entities import Invoice, InvoiceItem
from ..entities.sale_entities import Branch, BranchStock
from .fx_snapshot import convert_invoice_amount


async def scoped_dataset(db, org_id, scope, ref_id, currency, branch_ids):
    from . import falcon_service as falcon
    rep = (currency or 'USD').upper()
    ids = list(dict.fromkeys(UUID(str(b)) for b in branch_ids if b is not None))
    branches = (await db.execute(select(Branch).where(Branch.organization_id == org_id,
        Branch.id.in_(ids), Branch.is_active.is_(True), Branch.is_archived.is_(False))
        .order_by(Branch.is_default.desc(), Branch.name))).scalars().all()
    if len(branches) != len(ids): raise HTTPException(403, detail='الفروع المحددة غير متاحة للتحليل')
    main = (await db.execute(select(Branch.id).where(Branch.organization_id == org_id,
        Branch.is_default.is_(True)))).scalars().first()
    include_legacy = main in ids
    invoice_scope = or_(Invoice.branch_id.in_(ids), Invoice.branch_id.is_(None)) if include_legacy else Invoice.branch_id.in_(ids)
    product_scope = or_(Product.branch_id.in_(ids),
        Product.id.in_(select(BranchStock.product_id).where(BranchStock.organization_id == org_id, BranchStock.branch_id.in_(ids))),
        Product.id.in_(select(InvoiceItem.product_id).join(Invoice, Invoice.id == InvoiceItem.invoice_id).where(
            Invoice.organization_id == org_id, invoice_scope, Invoice.is_deleted.is_(False))))
    if include_legacy: product_scope = or_(product_scope, Product.branch_id.is_(None))
    query = select(Product).where(Product.organization_id == org_id, Product.is_deleted.is_(False), product_scope)
    category_name = None
    if scope == 'category' and ref_id:
        category = await db.get(ProductCategory, UUID(ref_id))
        if not category or category.organization_id != org_id or category.is_deleted:
            raise HTTPException(404, detail='التصنيف غير موجود')
        query = query.where(Product.category_id == category.id)
        category_name = category.name
    if scope == 'product' and ref_id: query = query.where(Product.id == UUID(ref_id))
    products = (await db.execute(query)).scalars().all()
    if scope == 'product' and not products: raise HTTPException(404, detail='المنتج غير موجود في الفروع المسموحة')
    product_ids = [p.id for p in products]
    stocks = (await db.execute(select(BranchStock).where(BranchStock.organization_id == org_id,
        BranchStock.branch_id.in_(ids), BranchStock.product_id.in_(product_ids)))).scalars().all()
    stock_map = {(r.branch_id, r.product_id): r for r in stocks}
    grouped = (await db.execute(select(Invoice.branch_id, InvoiceItem.product_id,
        Invoice.invoice_type, Invoice.currency, InvoiceItem.price_currency, InvoiceItem.exchange_rate_used,
        func.sum(InvoiceItem.total), func.sum(InvoiceItem.base_quantity),
        func.sum(InvoiceItem.cost_total), func.sum(InvoiceItem.profit))
        .join(Invoice, Invoice.id == InvoiceItem.invoice_id).where(Invoice.organization_id == org_id,
            invoice_scope, Invoice.is_deleted.is_(False), Invoice.status.notin_(['draft', 'cancelled']),
            InvoiceItem.product_id.in_(product_ids))
        .group_by(Invoice.branch_id, InvoiceItem.product_id, Invoice.invoice_type, Invoice.currency,
                  InvoiceItem.price_currency, InvoiceItem.exchange_rate_used))).all()
    stats = defaultdict(lambda: defaultdict(float))
    currencies = set()
    unverified = False
    for branch, product, kind, ccy, pcy, frozen, total, quantity, cogs, profit in grouped:
        branch = branch or main
        data = stats[branch, product]
        currencies.add(ccy or rep)
        async def converted(value):
            nonlocal unverified
            result = await convert_invoice_amount(value, ccy or rep, rep, pcy, frozen)
            if result is None:
                unverified = True
                return 0.0
            return float(result)
        if kind == 'sale':
            data['sales'] += await converted(total); data['qty_sold'] += float(quantity or 0)
            data['cogs'] += await converted(cogs); data['profit'] += await converted(profit)
        elif kind == 'purchase':
            data['purchases'] += await converted(total); data['qty_purchased'] += float(quantity or 0)
    rates = {}
    summaries = []
    totals = {}
    for branch in branches:
        items = []
        for product in products:
            row = stock_map.get((branch.id, product.id))
            recorded = stats.get((branch.id, product.id), {})
            belongs = product.branch_id == branch.id or (branch.id == main and product.branch_id is None)
            if row is None and not recorded and not belongs: continue
            quantity = float(row.quantity or 0) if row is not None else float(product.stock or 0) if belongs and branch.id == main else 0.0
            source = (product.cost_currency or rep).upper()
            if source not in rates: rates[source] = await falcon._rate_or_none(source, rep)
            rate = rates[source]
            if rate is None: unverified = True
            # Never invent a 1:1 monetary valuation if FX is missing.
            cost = float(row.avg_cost or 0) if row is not None else float(product.cost_price or 0)
            item = {'id': str(product.id), 'name': product.name, 'branch_id': str(branch.id),
                'branch_name': branch.name, 'unit': product.unit, 'stock': quantity,
                'min_stock': float(product.min_stock or 0), 'currency': rep,
                'sell_price': float(product.price or 0) * (rate or 0), 'cost_price': cost * (rate or 0),
                'inventory_value': quantity * cost * (rate or 0), 'expiry_date': product.expiry_date.isoformat() if product.expiry_date else None,
                **{key: float(recorded.get(key, 0)) for key in ('sales', 'qty_sold', 'cogs', 'profit', 'purchases', 'qty_purchased')}}
            items.append(item)
            aggregate = totals.setdefault(product.id, {**item, 'stock': 0.0, 'sales': 0.0, 'qty_sold': 0.0,
                'cogs': 0.0, 'profit': 0.0, 'purchases': 0.0, 'qty_purchased': 0.0, 'inventory_value': 0.0})
            for key in ('stock', 'sales', 'qty_sold', 'cogs', 'profit', 'purchases', 'qty_purchased', 'inventory_value'):
                aggregate[key] += item[key]
        summaries.append({'branch_id': str(branch.id), 'branch_name': branch.name,
            'products_count': len(items), 'stock': sum(i['stock'] for i in items),
            'total_sales': sum(i['sales'] for i in items), 'total_profit': sum(i['profit'] for i in items),
            'total_cogs': sum(i['cogs'] for i in items), 'total_purchases': sum(i['purchases'] for i in items),
            'inventory_value': sum(i['inventory_value'] for i in items),
            'low_stock': [i['name'] for i in items if 0 < i['stock'] <= i['min_stock']][:10],
            'out_of_stock': [i['name'] for i in items if i['stock'] <= 0][:10],
            'top_sellers': sorted(items, key=lambda i: i['qty_sold'], reverse=True)[:5]})
    items = list(totals.values())
    data = {'report_currency': rep, 'unified': len(currencies) > 1, 'unverified_fx': unverified,
        'branch_ids': [str(b.id) for b in branches], 'branch_summaries': summaries,
        'category_name': category_name,
        'products_count': len(items), 'inventory_value': sum(i['inventory_value'] for i in items),
        'total_sales': sum(i['sales'] for i in items), 'total_profit': sum(i['profit'] for i in items),
        'total_cogs': sum(i['cogs'] for i in items), 'total_purchases': sum(i['purchases'] for i in items),
        'low_stock': [i['name'] for i in items if 0 < i['stock'] <= i['min_stock']][:20],
        'out_of_stock': [i['name'] for i in items if i['stock'] <= 0][:20],
        'top_sellers': sorted(items, key=lambda i: i['qty_sold'], reverse=True)[:10],
        'top_profit': sorted(items, key=lambda i: i['profit'], reverse=True)[:10],
        'bottom_sellers': sorted(items, key=lambda i: i['qty_sold'])[:10],
        'slow_moving': [i for i in items if i['qty_sold'] <= 0 and i['stock'] > 0][:15],
        'weak_margin': [i for i in items if i['sales'] > 0 and i['profit']/i['sales'] < .1][:15]}
    if scope == 'product':
        product = items[0]
        data.update({**product, 'branch_id': None, 'branch_name': None,
            'sales_total': product['sales'], 'purchases_total': product['purchases'],
            'sales_quantity': product['qty_sold'], 'suggested_order_qty': max(0, product['min_stock'] * 2 - product['stock'])})
        data['batches'] = await falcon._product_batches(db, org_id, UUID(ref_id), rep, branch_ids=ids, main_id=main)
    return data, ('المنتج' if scope == 'product' else 'التصنيف' if scope == 'category' else 'المخزون')
