part of 'directory_database.dart';

// Lots measure physical stock. `opening`/`legacy_cover` are internal
// allocations of stock whose receipt wasn't recorded, not new receipts.
Future<void> _upgradeInventoryBatches(DatabaseExecutor db) async {
  await db.execute('''
    ALTER TABLE $_commerceConsumptions ADD COLUMN restored_micro INTEGER
    NOT NULL DEFAULT 0 CHECK (restored_micro BETWEEN 0 AND quantity_micro)
  ''');
  await db.execute('ALTER TABLE $_commerceLots ADD COLUMN receipt_lot_id TEXT');
  await db.execute('''
    CREATE INDEX ${_commerceLots}_receipt ON $_commerceLots
      (branch_id, product_id, receipt_lot_id)
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS ${_commerceLines}_by_product
      ON $_commerceLines (branch_id, product_id, invoice_id)
  ''');
  // Local v7 purchase returns reduced branch stock but didn't debit any
  // batch. Apply just the proven, stocked return to the remaining reports,
  // preferring its purchase. Imported/ambiguous movement IDs are left alone.
  final supplierReturns = await db.rawQuery('''
    SELECT m.branch_id, m.id, m.product_id, m.reference_id, m.quantity_micro, m.created_us,
      r.item_id
    FROM $_commerceMovements m
    JOIN $_commerceReturnLines r ON r.branch_id = m.branch_id
      AND r.return_id = m.reference_id AND r.product_id = m.product_id
    JOIN $_commerceReturns h ON h.branch_id = r.branch_id AND h.id = r.return_id
    WHERE m.movement_type = 'purchase_return' AND m.reference_type = 'purchase_return'
      AND m.quantity_micro < 0 AND h.status = 'confirmed'
    ORDER BY m.created_us, m.id
  ''');
  for (final row in supplierReturns) {
    final item = row['item_id'] as String;
    final branch = row['branch_id'] as String;
    if (row['id'] !=
        const Uuid().v5(
          row['reference_id'] as String,
          'fyona.commerce.return.movement.v1:$item',
        ))
      continue;
    final lots = await _availableInventoryLots(
      db,
      branch,
      row['product_id'] as String,
      preferredPurchaseItem: item,
      receivedBeforeUs: row['created_us'] as int,
    );
    var pending = -(row['quantity_micro'] as int);
    for (final lot in lots) {
      if (pending == 0) break;
      final left = lot['remaining_micro'] as int;
      final take = min(left, pending);
      await db.update(
        _commerceLots,
        {'remaining_micro': left - take},
        where: 'branch_id = ? AND id = ?',
        whereArgs: [branch, lot['id']],
      );
      pending -= take;
    }
  }

  // v7 recorded initial stock without a lot. For proven device-created
  // products only, combine its still-unallocated stock with the old opening
  // allocations. Their IDs, quantities, and costs remain intact. We don't
  // invent an opening receipt for imported stock with no source history.
  final receipts = await db.rawQuery('''
    SELECT branch_id, id, json_extract(result, '\$.id') AS record_id
    FROM ${BusinessLedger._commands}
    WHERE json_type(result, '\$.id') = 'text'
  ''');
  for (final command in receipts) {
    final branch = command['branch_id'] as String;
    final product = command['record_id'] as String;
    if (const Uuid().v5(command['id'] as String, 'fyona.commerce.product.v1') !=
        product) {
      continue;
    }
    final row = (await db.rawQuery(
      '''
      SELECT p.created_us, s.quantity_milli, SUM(l.remaining_micro) AS represented,
        SUM(CASE WHEN l.source = 'opening' THEN l.received_micro ELSE 0 END) AS covered
      FROM $_commerceProducts p
      JOIN $_commerceStock s ON s.branch_id = p.branch_id AND s.product_id = p.id
      LEFT JOIN $_commerceLots l ON l.branch_id = p.branch_id AND l.product_id = p.id
      WHERE p.branch_id = ? AND p.id = ? AND p.is_service = 0
      GROUP BY p.branch_id, p.id
    ''',
      [branch, product],
    )).singleOrNull;
    if (row == null) continue;
    final gap = max(
      0,
      (row['quantity_milli'] as int) * 1000 - (row['represented'] as int? ?? 0),
    );
    if (gap == 0 && row['covered'] == 0) continue;
    final created = row['created_us'] as int;
    final receipt = const Uuid().v5(product, 'fyona.commerce.initial-batch.v1');
    await db.insert(_commerceLots, {
      'branch_id': branch,
      'id': receipt,
      'product_id': product,
      'received_micro': gap,
      'remaining_micro': gap,
      // The v7 form didn't record opening costs independently of the product
      // card (which can have been edited). Do not use today's price.
      'unit_cost_4': 0,
      'purchase_date': _commerceDate(created)!.split('T').first,
      'source': 'initial',
      'created_us': created,
    });
    await db.update(
      _commerceLots,
      {'receipt_lot_id': receipt},
      where: "branch_id = ? AND product_id = ? AND source = 'opening'",
      whereArgs: [branch, product],
    );
  }

  // Mark the consumed slices already restored by the old writer. v7 local
  // return movements identify the exact line; imported rows without that
  // identity are only attributable when this was the sole line for the
  // product. Ambiguous rows are not distributed by a guess.
  final restored = await db.rawQuery('''
    SELECT m.branch_id, m.id, m.reference_id, m.quantity_micro, m.created_us,
      r.item_id, COUNT(*) OVER (PARTITION BY m.branch_id, m.id) AS candidates
    FROM $_commerceMovements m
    JOIN $_commerceReturnLines r ON r.branch_id = m.branch_id
      AND r.return_id = m.reference_id AND r.product_id = m.product_id
    JOIN $_commerceReturns h ON h.branch_id = r.branch_id AND h.id = r.return_id
    WHERE m.movement_type = 'sale_return' AND m.reference_type = 'invoice_return'
      AND m.quantity_micro > 0 AND h.status = 'confirmed'
    ORDER BY m.created_us, m.id
  ''');
  for (final row in restored) {
    final item = row['item_id'] as String;
    if (row['candidates'] != 1 &&
        row['id'] !=
            const Uuid().v5(
              row['reference_id'] as String,
              'fyona.commerce.return.movement.v1:$item',
            )) {
      continue;
    }
    await _markRestoredSlices(
      db,
      row['branch_id'] as String,
      item,
      row['quantity_micro'] as int,
      before: row['created_us'] as int,
    );
  }
}

/// When [before] is supplied during v7 upgrade, the physical restoration
/// already happened. Mark the old allocations only; never post the stock again.
Future<void> _markRestoredSlices(
  DatabaseExecutor db,
  String branch,
  String item,
  int pending, {
  int? before,
}) async {
  final rows = await db.rawQuery(
    '''
    SELECT c.id, c.lot_id, c.quantity_micro - c.restored_micro AS available,
      l.remaining_micro, l.received_micro
    FROM $_commerceConsumptions c JOIN $_commerceLots l
      ON l.branch_id = c.branch_id AND l.id = c.lot_id
    WHERE c.branch_id = ? AND c.item_id = ? AND c.quantity_micro > c.restored_micro
      ${before == null ? '' : 'AND c.created_us <= ?'}
    ORDER BY c.created_us DESC, c.rowid DESC
  ''',
    [branch, item, ?before],
  );
  final capacity = <String, int>{};
  for (final row in rows) {
    if (pending <= 0) break;
    final lot = row['lot_id'] as String;
    var credit = min(row['available'] as int, pending);
    if (before == null) {
      final room = capacity.putIfAbsent(
        lot,
        () => (row['received_micro'] as int) - (row['remaining_micro'] as int),
      );
      credit = min(credit, room);
      if (credit == 0) continue;
      await db.rawUpdate(
        '''
        UPDATE $_commerceLots SET remaining_micro = remaining_micro + ?
        WHERE branch_id = ? AND id = ?
      ''',
        [credit, branch, lot],
      );
      capacity[lot] = room - credit;
    }
    await db.rawUpdate(
      '''
      UPDATE $_commerceConsumptions SET restored_micro = restored_micro + ?
      WHERE branch_id = ? AND id = ?
    ''',
      [credit, branch, row['id']],
    );
    pending -= credit;
  }
}

Future<List<_CommerceRow>> _availableInventoryLots(
  DatabaseExecutor db,
  String branch,
  String product, {
  String? preferredPurchaseItem,
  int? receivedBeforeUs,
}) => db.rawQuery(
  '''
  SELECT l.id, l.remaining_micro, l.unit_cost_4, l.currency
  FROM $_commerceLots l
  LEFT JOIN $_commerceLots receipt ON receipt.branch_id = l.branch_id
    AND receipt.id = l.receipt_lot_id
  WHERE l.branch_id = ? AND l.product_id = ? AND l.remaining_micro > 0
    ${receivedBeforeUs == null ? '' : 'AND l.created_us <= ?'}
  ORDER BY ${preferredPurchaseItem == null ? '' : 'CASE WHEN l.item_id = ? THEN 0 ELSE 1 END,'}
    COALESCE(receipt.purchase_date, l.purchase_date, date(l.created_us / 1000000, 'unixepoch')),
    COALESCE(receipt.created_us, l.created_us), l.rowid
''',
  [branch, product, ?receivedBeforeUs, ?preferredPurchaseItem],
);

Future<void> _receiveInventoryBatch(
  DatabaseExecutor db, {
  required String branch,
  required String id,
  required String product,
  required int quantity,
  required String source,
  required DateTime now,
  int? cost4,
  String? currency,
  String? invoiceId,
  String? itemId,
  String? unitId,
  String? supplierId,
  String? expiryDate,
  String? lotNumber,
}) async {
  if (quantity <= 0) return;
  await db.insert(_commerceLots, {
    'branch_id': branch,
    'id': id,
    'product_id': product,
    'supplier_id': supplierId,
    'purchase_invoice_id': invoiceId,
    'item_id': itemId,
    'unit_id': unitId,
    'received_micro': quantity,
    'remaining_micro': quantity,
    'unit_cost_4': cost4 ?? 0,
    'currency': cost4 == null ? null : currency,
    'exchange_rate': cost4 == null ? null : '1.00000000',
    'purchase_date': BusinessLedger._date(now),
    'expiry_date': expiryDate,
    'lot_number': lotNumber,
    'source': source,
    'created_us': now.microsecondsSinceEpoch,
  });
}

Future<List<_CommerceRow>> _inventoryBatches(
  DatabaseExecutor db,
  String branch,
  String product,
) => db.rawQuery(
  '''
  SELECT l.*, p.name AS product_name, p.image AS product_image,
    l.received_micro + COALESCE(a.received, 0) AS batch_received,
    l.remaining_micro + COALESCE(a.remaining, 0) AS batch_remaining
  FROM $_commerceLots l
  JOIN $_commerceProducts p ON p.branch_id = l.branch_id AND p.id = l.product_id
  LEFT JOIN $_commerceInvoices i ON i.branch_id = l.branch_id AND i.id = l.purchase_invoice_id
  LEFT JOIN (
    SELECT receipt_lot_id, SUM(received_micro) AS received, SUM(remaining_micro) AS remaining
    FROM $_commerceLots WHERE branch_id = ? AND product_id = ? AND receipt_lot_id IS NOT NULL
    GROUP BY receipt_lot_id
  ) a ON a.receipt_lot_id = l.id
  WHERE l.branch_id = ? AND l.product_id = ? AND l.receipt_lot_id IS NULL
    AND (i.id IS NULL OR (i.deleted_us IS NULL AND i.status <> 'cancelled'))
    AND COALESCE(l.source, '') NOT IN ('opening', 'legacy_cover', 'return')
    AND l.received_micro + COALESCE(a.received, 0) > 0
  ORDER BY COALESCE(l.purchase_date, date(l.created_us / 1000000, 'unixepoch')),
    l.created_us, l.id
''',
  [branch, product, branch, product],
);
