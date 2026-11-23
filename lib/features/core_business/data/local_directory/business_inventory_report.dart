part of 'directory_database.dart';

/// The device «المخزون» report. Remaining lots keep their recorded cost;
/// the last approved publication values today's balance without a network
/// read. The period selects movements and approved counts, not current stock.
extension BusinessInventoryReport on BusinessLedger {
  Future<Set<String>> inventoryReportCurrencies(BusinessLedgerAccess access) {
    final branch = _branch(access, BusinessLedgerAction.readInventoryCost);
    return _directory._read((db) async {
      final rows = await db.rawQuery(
        '''
        SELECT DISTINCT currency FROM $_commerceLots
        WHERE branch_id = ? AND remaining_micro > 0 AND currency IS NOT NULL
        ''',
        [branch],
      );
      return {
        for (final row in rows) businessCurrency(row['currency'] as String),
      };
    });
  }

  Future<Map<String, dynamic>> inventoryReport(
    BusinessLedgerAccess access, {
    required String currency,
    String? from,
    String? to,
    int expiryWarnDays = 60,
    DateTime? today,
    BusinessReportFx fx = const BusinessReportFx.empty(),
  }) {
    final branch = _branch(access, BusinessLedgerAction.readInventory);
    final showCost = access._actions.contains(
      BusinessLedgerAction.readInventoryCost,
    );
    final target = businessCurrency(currency);
    final window = _SalesReportWindow(from, to);
    final todayStr = BusinessLedger._date(today ?? DateTime.now());
    final day = DateTime.parse('${todayStr}T00:00:00Z');
    return _directory._transaction((txn) async {
      final warehouse = await _warehouseExpiry(txn, branch);
      final warn = (warehouse?.warnDays ?? expiryWarnDays).clamp(0, 365);
      // Current stock facts: active, non-service products only — the same
      // set the connected report counts and lists.
      final rows = await txn.rawQuery(
        '''
        SELECT p.id, p.name, p.unit, p.min_stock_4, p.expiry_date
        FROM $_commerceProducts p
        WHERE p.branch_id = ? AND p.deleted_us IS NULL
          AND p.is_active = 1 AND p.is_service = 0
        ORDER BY p.created_us DESC, p.id
        ''',
        [branch],
      );
      final low = <Map<String, dynamic>>[],
          out = <Map<String, dynamic>>[],
          expiring = <Map<String, dynamic>>[];
      final stock = await _reportStockValuation(
        txn,
        branch,
        target,
        showCost,
        fx,
      );
      for (final row in rows) {
        final quantity = stock.quantities[row['id']] ?? BigInt.zero;
        final minimum = _reportMinStock(row);
        final item = <String, dynamic>{
          'id': row['id'],
          'name': row['name'],
          'unit': row['unit'],
          'stock': _reportQuantity(quantity),
          'min_stock': _reportQuantity(minimum),
        };
        if (quantity <= BigInt.zero) {
          out.add(item);
        } else {
          if (quantity <= minimum) low.add(item);
        }
        final expiry = row['expiry_date'] as String?;
        final expiryDay = expiry == null
            ? null
            : DateTime.tryParse('${expiry}T00:00:00Z');
        if (expiryDay != null) {
          final days = expiryDay.difference(day).inDays;
          if (days >= 0 && days <= warn) {
            expiring.add({...item, 'expiry_date': expiry, 'days': days});
          }
        }
      }
      expiring.sort((a, b) => (a['days'] as int).compareTo(b['days'] as int));
      final units = await txn.rawQuery(
        'SELECT COUNT(*) AS n FROM $_commerceUnits WHERE branch_id = ? AND is_active = 1',
        [branch],
      );

      final movements = await txn.rawQuery(
        '''
        SELECT p.id, p.name, p.unit, m.quantity_micro
        FROM $_commerceMovements m
        JOIN $_commerceProducts p
          ON p.branch_id = m.branch_id AND p.id = m.product_id
        WHERE m.branch_id = ?
          AND m.movement_type NOT IN ('sale_return_no_stock', 'purchase_return_no_stock')
          AND m.quantity_micro != 0
          AND $_reportMovementPosted
          ${window.where('m.created_us')}
        ''',
        [branch, ...window.args],
      );
      final movedByProduct =
          <String, ({Object? name, Object? unit, BigInt moved, BigInt net})>{};
      for (final row in movements) {
        final id = row['id'] as String;
        final quantity = BigInt.from(row['quantity_micro'] as int);
        final previous = movedByProduct[id];
        movedByProduct[id] = (
          name: row['name'],
          unit: row['unit'],
          moved: (previous?.moved ?? BigInt.zero) + quantity.abs(),
          net: (previous?.net ?? BigInt.zero) + quantity,
        );
      }
      final moved = movedByProduct.entries.toList()
        ..sort((a, b) {
          final order = b.value.moved.compareTo(a.value.moved);
          return order != 0 ? order : a.key.compareTo(b.key);
        });

      // Approved inventory counts of the period (the stocktake archive).
      final recs = await txn.rawQuery(
        '''
        SELECT payload FROM $_reconciliationRecords
        WHERE branch_id = ? AND rtype = 'inventory' AND status = 'approved'
        ORDER BY json_extract(payload, '\$.approved_at') DESC, id DESC
        ''',
        [branch],
      );
      final counting = <Map<String, dynamic>>[];
      for (final row in recs) {
        final record = _reconciliationPayload(row);
        if (!_reportApprovalInWindow(record['approved_at'], window)) continue;
        final lines = [
          for (final line in (record['settlements'] as List).cast<Map>())
            if (line['applied'] == true) line,
        ];
        if (lines.isEmpty) continue;
        counting.add({
          'id': record['id'],
          'ref_code': record['ref_code'],
          'approved_at': record['approved_at'],
          'settlements': lines,
        });
      }

      return {
        'report': 'inventory',
        'currency': target,
        'branch_ids': [branch],
        'local_valuation': 'as_recorded',
        'fx_basis': _reportFxBasis,
        'totals_complete': stock.complete,
        'products': rows.length,
        'categories': await _reportCategoryCount(txn, branch),
        'units': units.first['n'] as int,
        ...stock.payload,
        'stock_value_basis': 'actual_lot_cost',
        'low_stock': low.take(30).toList(),
        'low_count': low.length,
        'out_of_stock': out.take(30).toList(),
        'out_count': out.length,
        'expiring_soon': expiring.take(30).toList(),
        'expiring_count': expiring.length,
        'warn_days': warn,
        'most_moved': [
          for (final row in moved.take(8).map((e) => e.value))
            {
              'name': row.name,
              'unit': row.unit,
              'moved': _reportQuantity(row.moved),
              'net': _reportQuantity(row.net),
            },
        ],
        'counting': {'count': counting.length, 'items': counting},
      };
    });
  }
}

const _reportMovementPosted =
    '''
  (m.reference_type IS NOT 'invoice' OR EXISTS (
    SELECT 1 FROM $_commerceInvoices i WHERE i.branch_id = m.branch_id
      AND i.id = m.reference_id AND $_reportInvoicePosted
  )) AND (m.reference_type IS NULL OR m.reference_type NOT IN ('invoice_return','purchase_return')
    OR EXISTS (
      SELECT 1 FROM $_commerceReturns r JOIN $_commerceInvoices i
        ON i.branch_id = r.branch_id AND i.id = r.invoice_id
      WHERE r.branch_id = m.branch_id AND r.id = m.reference_id
        AND r.status = 'confirmed' AND $_reportInvoicePosted
    ))
''';

bool _reportApprovalInWindow(Object? at, _SalesReportWindow window) {
  final date = DateTime.tryParse('$at');
  return date != null && window.includes(BusinessLedger._date(date.toLocal()));
}

BigInt _reportMinStock(_CommerceRow row) =>
    BigInt.from(row['min_stock_4'] as int? ?? 0) * BigInt.from(100);

String _reportQuantity(BigInt quantity) {
  final scale = BigInt.from(1000000);
  final abs = quantity.abs();
  final fraction = (abs % scale)
      .toString()
      .padLeft(6, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '${quantity.isNegative ? '-' : ''}${abs ~/ scale}'
      '${fraction.isEmpty ? '' : '.$fraction'}';
}

Future<
  ({
    bool complete,
    Map<String, dynamic> payload,
    Map<String, BigInt> quantities,
  })
>
_reportStockValuation(
  DatabaseExecutor db,
  String branch,
  String target,
  bool showCost,
  BusinessReportFx fx,
) async {
  final value = _ReportAmounts(target, fx);
  final gapLots = <String, int>{};
  final represented = <String, BigInt>{};
  final quantities = <String, BigInt>{};
  var uncosted = 0;
  // Multiplication and accumulation in Dart: SQLite may silently promote
  // large products to REAL before summation. Value only the recorded lots.
  const pageSize = 512;
  var after = '';
  while (true) {
    final lots = await db.rawQuery(
      '''
      SELECT id, product_id, remaining_micro${showCost ? ', currency, unit_cost_4, source' : ''}
      FROM $_commerceLots WHERE branch_id = ? AND id > ? AND remaining_micro > 0
      ORDER BY id LIMIT $pageSize
      ''',
      [branch, after],
    );
    for (final lot in lots) {
      final product = lot['product_id'] as String;
      final qty = BigInt.from(lot['remaining_micro'] as int);
      represented.update(product, (total) => total + qty, ifAbsent: () => qty);
      if (!showCost) continue;
      final code = lot['currency'] as String?;
      final cost = lot['unit_cost_4'] as int;
      if (!_reportDocumentedLotCost(code, cost, lot['source'])) {
        uncosted++;
        continue;
      }
      final precise = qty * BigInt.from(cost);
      final currency = businessCurrency(code!);
      value.addPrecise(currency, precise);
      if (value.missing.contains(currency) && precise != BigInt.zero) {
        gapLots.update(currency, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    if (lots.length < pageSize) break;
    after = lots.last['id'] as String;
  }
  final scale = BigInt.from(1000);
  for (final stock in await db.query(
    _commerceStock,
    columns: ['product_id', 'quantity_milli'],
    where: 'branch_id = ?',
    whereArgs: [branch],
  )) {
    quantities[stock['product_id'] as String] =
        BigInt.from(stock['quantity_milli'] as int) * scale;
  }
  final unequal = {
    for (final id in {...quantities.keys, ...represented.keys})
      if ((quantities[id] ?? BigInt.zero) != (represented[id] ?? BigInt.zero))
        id,
  };
  if (unequal.isNotEmpty) {
    final drift = await _reportStockPrecisionDrift(db, branch, unequal);
    for (final id in unequal) {
      final physical = represented[id] ?? BigInt.zero;
      if (quantities.containsKey(id) &&
          quantities[id]! - physical == drift[id]) {
        quantities[id] = physical;
      } else {
        uncosted++;
      }
    }
  }
  if (!showCost) {
    return (
      complete: true,
      quantities: quantities,
      payload: {
        'stock_value': null,
        'stock_value_per_currency': null,
        'uncosted_stock': 0,
        'gaps': [],
      },
    );
  }
  final complete = gapLots.isEmpty && uncosted == 0;
  return (
    complete: complete,
    quantities: quantities,
    payload: {
      'stock_value': complete ? value.totalValue : null,
      'stock_value_per_currency': uncosted == 0 ? value.originalAmounts : [],
      'uncosted_stock': uncosted,
      'gaps': [
        for (final code in gapLots.keys.toList()..sort())
          {'currency': code, 'count': gapLots[code]},
      ],
    },
  );
}

/// Stock stores thousandths; lots and physical movements keep millionths.
/// Explain a discrepancy only from exact, identified writes of this ledger,
/// not by applying a tolerance to the remaining stock or rounding its value.
Future<Map<String, BigInt>> _reportStockPrecisionDrift(
  DatabaseExecutor db,
  String branch,
  Set<String> products,
) async {
  final drift = <String, BigInt>{};
  final unresolved = <String>{};
  final scale = BigInt.from(1000);
  void record(String product, BigInt delta) {
    final writeDelta = BusinessMoney.roundRatio(delta, scale) * scale;
    drift.update(
      product,
      (sum) => sum + writeDelta - delta,
      ifAbsent: () => writeDelta - delta,
    );
  }

  final movementIds = <String, List<_CommerceRow>>{};
  for (final row in await db.rawQuery(
    '''
    SELECT m.id, m.product_id, m.quantity_micro, m.reference_type, m.reference_id,
      l.id AS item_id, i.idempotency_key
    FROM $_commerceMovements m JOIN $_commerceInvoices i
      ON i.branch_id = m.branch_id AND i.id = m.reference_id
    JOIN $_commerceLines l ON l.branch_id = i.branch_id AND l.invoice_id = i.id
      AND l.product_id = m.product_id
    WHERE m.branch_id = ? AND m.reference_type = 'invoice' AND $_reportInvoicePosted
      AND m.quantity_micro % 1000 != 0
    UNION ALL
    SELECT m.id, m.product_id, m.quantity_micro, m.reference_type, m.reference_id,
      l.item_id, NULL
    FROM $_commerceMovements m JOIN $_commerceReturns r
      ON r.branch_id = m.branch_id AND r.id = m.reference_id
    JOIN $_commerceInvoices i ON i.branch_id = r.branch_id AND i.id = r.invoice_id
    JOIN $_commerceReturnLines l ON l.branch_id = r.branch_id AND l.return_id = r.id
      AND l.product_id = m.product_id
    WHERE m.branch_id = ? AND m.reference_type IN ('invoice_return','purchase_return')
      AND m.movement_type IN ('sale_return','purchase_return') AND r.status = 'confirmed'
      AND $_reportInvoicePosted AND m.quantity_micro % 1000 != 0
  ''',
    [branch, branch],
  )) {
    if (products.contains(row['product_id'])) {
      (movementIds[row['id'] as String] ??= []).add(row);
    }
  }
  for (final group in movementIds.values) {
    final row = group.first;
    final product = row['product_id'] as String;
    final proven = group.any((row) {
      final item = row['item_id'];
      final ref = row['reference_id'] as String;
      final command = row['idempotency_key'];
      if (row['reference_type'] != 'invoice') {
        return const Uuid().v5(
              ref,
              'fyona.commerce.return.movement.v1:$item',
            ) ==
            row['id'];
      }
      return _reportLocalInvoice(command, ref) &&
          const Uuid().v5(
                command as String,
                'fyona.commerce.movement.v1:$item',
              ) ==
              row['id'];
    });
    if (proven) {
      record(product, BigInt.from(row['quantity_micro'] as int));
    } else {
      unresolved.add(product);
    }
  }
  for (final row in await db.rawQuery(
    '''
    SELECT l.product_id, l.factor_4, i.id, i.idempotency_key, i.invoice_type,
      e.old_quantity_micro, e.new_quantity_micro
    FROM $_commerceEdits e JOIN $_commerceLines l
      ON l.branch_id = e.branch_id AND l.id = e.item_id
    JOIN $_commerceInvoices i ON i.branch_id = e.branch_id AND i.id = e.invoice_id
    WHERE e.branch_id = ? AND $_reportInvoicePosted AND l.is_service = 0
      AND e.old_quantity_micro IS NOT NULL AND e.new_quantity_micro IS NOT NULL
  ''',
    [branch],
  )) {
    final product = row['product_id'];
    if (product is! String || !products.contains(product)) continue;
    if (!_reportLocalInvoice(row['idempotency_key'], row['id']) ||
        row['factor_4'] == null) {
      unresolved.add(product);
      continue;
    }
    final factor = BigInt.from(row['factor_4'] as int);
    BigInt base(String field) => BusinessMoney.roundRatio(
      BigInt.from(row[field] as int) * factor,
      BigInt.from(10000),
    );
    final delta = base('new_quantity_micro') - base('old_quantity_micro');
    record(product, row['invoice_type'] == 'purchase' ? delta : -delta);
  }
  drift.removeWhere((id, _) => unresolved.contains(id));
  return drift;
}
