part of 'directory_database.dart';

/// Device stocktake (جرد المخزون) on the same local reconciliation record
/// the bank flow uses. The count never writes stock: start snapshots the
/// system quantities, save stores counted quantities (uncounted lines stay
/// unknown, never zero), check compares against the CURRENT quantity and
/// flags products that moved since the count began, and approve settles
/// every requested line in one commit — verified against both the expected
/// quantity and a movement stamp taken at check, so a movement that returns
/// the balance to the same number still forces a new check. History,
/// invoices and captured costs are never rewritten.
typedef BusinessInventoryCountPart = ({
  int qtyMilli,
  String? unitId,
  String? unitName,
});

typedef BusinessInventoryCount = ({
  String productId,
  int qtyMilli,
  String? unitId,
  List<BusinessInventoryCountPart>? parts,
});

typedef BusinessInventorySettlement = ({
  String productId,
  int expectedMilli,
  int newMilli,
});

final class BusinessInventoryCategoryEmpty implements Exception {
  const BusinessInventoryCategoryEmpty();
}

final class BusinessInventoryCategoryChanged implements Exception {
  const BusinessInventoryCategoryChanged();
}

extension BusinessInventoryReconciliation on BusinessLedger {
  Future<Map<String, dynamic>> inventoryReconciliationStart(
    BusinessLedgerAccess access, {
    required String id,
    required String scope,
    String? productId,
    String? categoryId,
    String? notes,
    required bool Function() allowed,
  }) {
    final branch = _branch(
      access,
      BusinessLedgerAction.checkInventoryReconciliation,
    );
    if (!isDirectoryId(id)) throw const BusinessReconciliationInvalid();
    if (!const {'full', 'product', 'category'}.contains(scope) ||
        (scope == 'category' ? categoryId == null : categoryId != null) ||
        (scope != 'product' && productId != null)) {
      throw const BusinessReconciliationInvalid();
    }
    if (scope == 'product' &&
        (productId == null || !isDirectoryId(productId))) {
      throw const BusinessReconciliationInvalid();
    }
    final note = _reconNotes(notes);
    final digest = _reconDigest([
      'inventory',
      scope,
      productId,
      note,
      ?categoryId,
    ]);
    return _directory._transaction((txn) async {
      _requireReconciliation(access, allowed);
      final existing = await _storedReconciliation(
        txn,
        branch,
        id,
        'inventory',
      );
      if (existing != null) {
        if (existing['request_digest'] != digest) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.commandConflict,
          );
        }
        _requireReconciliation(access, allowed);
        return _reconciliationPayload(existing);
      }
      final category = categoryId == null
          ? null
          : await _commerceCategory(txn, branch, categoryId);
      final rows = await txn.rawQuery(
        '''
        SELECT p.id, p.name, p.unit, p.barcode,
               COALESCE(s.quantity_milli, 0) AS quantity_milli
        FROM $_commerceProducts p
        LEFT JOIN $_commerceStock s
          ON s.branch_id = p.branch_id AND s.product_id = p.id
        ${categoryId == null ? '' : '''
        JOIN $_commerceCategoryLinks c ON c.branch_id = p.branch_id AND c.id = p.id
        '''}
        WHERE p.branch_id = ? AND p.deleted_us IS NULL
          AND p.is_active = 1 AND p.is_service = 0
          ${scope == 'product' ? 'AND p.id = ?' : ''}
          ${categoryId == null ? '' : 'AND c.category_id = ?'}
        ORDER BY p.name ASC, p.id
        LIMIT 2001
        ''',
        [branch, ?productId, ?categoryId],
      );
      if (rows.length > 2000 || (scope == 'product' && rows.isEmpty)) {
        throw const BusinessReconciliationInvalid();
      }
      if (scope == 'category' && rows.isEmpty)
        throw const BusinessInventoryCategoryEmpty();
      final productIds = {for (final row in rows) row['id'] as String};
      final unitsByProduct = <String, List<Map<String, Object?>>>{};
      if (productIds.isNotEmpty) {
        final unitRows = await txn.query(
          _commerceUnits,
          where:
              'branch_id = ? AND is_active = 1 AND product_id IN (${List.filled(productIds.length, '?').join(',')})',
          whereArgs: [branch, ...productIds],
          orderBy: 'product_id, is_base DESC, name',
        );
        for (final row in unitRows) {
          (unitsByProduct[row['product_id'] as String] ??= []).add({
            'unit_id': row['id'],
            'name': row['name'],
            'factor': _inventoryDecimal(row['factor_4'] as int?, 10000),
          });
        }
      }
      final now = DateTime.now().toUtc();
      final lines = [
        for (final row in rows)
          {
            'product_id': row['id'],
            'name': row['name'],
            'unit': row['unit'] ?? 'قطعة',
            'system_qty': _inventoryDecimal(
              row['quantity_milli'] as int?,
              1000,
            ),
            'counted_qty': null, // never treated as zero until counted
            'unit_id': null,
            'base_qty': null,
            'barcode': row['barcode'],
          },
      ];
      final refCode =
          'RCN-${BusinessLedger._date(now).replaceAll('-', '')}'
          '-${id.substring(0, 8).toUpperCase()}';
      final record = <String, dynamic>{
        'id': id,
        'ref_code': refCode,
        'rtype': 'inventory',
        'scope': scope,
        'scope_json': {
          'product_id': productId,
          'category_id': categoryId,
          'category_name': category?['name'],
        },
        'branch_id': branch,
        'status': 'draft',
        'period_start': null,
        'period_end': null,
        'measured_at': now.toIso8601String(),
        'notes': note,
        'lines': lines,
        'units': unitsByProduct,
        'has_diff': false,
        'lines_count': lines.length,
        'settlements': [],
        'result': {},
        'created_at': now.toIso8601String(),
        'created_by': access.directory.workspace.accountId,
      };
      await txn.insert(_reconciliationRecords, {
        'branch_id': branch,
        'id': id,
        'rtype': 'inventory',
        'status': 'draft',
        'created_us': now.microsecondsSinceEpoch,
        'ref_code': refCode,
        'request_digest': digest,
        'snapshot': jsonEncode(<String, Object?>{}),
        'payload': jsonEncode(record),
      });
      _requireReconciliation(access, allowed);
      return record;
    }, exclusive: true);
  }

  Future<Map<String, dynamic>> inventoryReconciliationSave(
    BusinessLedgerAccess access, {
    required String id,
    required List<BusinessInventoryCount> counts,
    required bool Function() allowed,
  }) {
    final branch = _branch(
      access,
      BusinessLedgerAction.checkInventoryReconciliation,
    );
    if (counts.isEmpty || counts.length > 2000) {
      throw const BusinessReconciliationInvalid();
    }
    final ordered = _inventoryCounts(counts);
    return _directory._transaction((txn) async {
      _requireReconciliation(access, allowed);
      final row = await _storedReconciliation(txn, branch, id, 'inventory');
      if (row == null) throw const BusinessReconciliationInvalid();
      final record = _reconciliationPayload(row);
      if (row['status'] == 'approved') {
        throw const BusinessReconciliationInvalid();
      }
      final lines = (record['lines'] as List).cast<Map<String, dynamic>>();
      await _requireCountCategory(txn, branch, record, lines);
      final byId = {
        for (final line in lines) line['product_id'] as String: line,
      };
      final factors = await _inventoryUnitFactors(txn, branch);
      for (final count in ordered) {
        final line = byId[count.productId];
        if (line == null) {
          // A product outside this count's scope is never folded in.
          throw const BusinessReconciliationInvalid();
        }
        final parts = count.parts;
        if (parts != null && parts.isNotEmpty) {
          var baseMilli = 0;
          final storedParts = <Map<String, Object?>>[];
          for (final part in parts) {
            if (part.qtyMilli < 0) {
              throw const BusinessLedgerError(
                BusinessLedgerProblem.invalidAmount,
              );
            }
            final factor = _inventoryFactor(
              factors,
              count.productId,
              part.unitId,
            );
            baseMilli += _inventoryBase(part.qtyMilli, factor);
            if (baseMilli > _inventoryMaxMilli) {
              throw const BusinessReconciliationInvalid();
            }
            storedParts.add({
              'unit_id': part.unitId,
              'unit_name': part.unitName,
              'qty': part.qtyMilli / 1000,
              'factor': factor / 10000,
            });
          }
          line['parts'] = storedParts;
          line['counted_qty'] = baseMilli / 1000;
          line['unit_id'] = null;
          line['base_qty'] = baseMilli / 1000;
          continue;
        }
        if (count.qtyMilli < 0) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
        }
        final factor = _inventoryFactor(factors, count.productId, count.unitId);
        final baseMilli = _inventoryBase(count.qtyMilli, factor);
        line['parts'] = [
          {
            'unit_id': count.unitId,
            'unit_name': null,
            'qty': count.qtyMilli / 1000,
            'factor': factor / 10000,
          },
        ];
        line['counted_qty'] = count.qtyMilli / 1000;
        line['unit_id'] = count.unitId;
        line['base_qty'] = baseMilli / 1000;
      }
      record['status'] = 'draft';
      record['lines'] = lines;
      await txn.update(
        _reconciliationRecords,
        {'status': 'draft', 'payload': jsonEncode(record)},
        where: 'branch_id = ? AND id = ?',
        whereArgs: [branch, id],
      );
      _requireReconciliation(access, allowed);
      return record;
    }, exclusive: true);
  }

  Future<Map<String, dynamic>> inventoryReconciliationCheck(
    BusinessLedgerAccess access, {
    required String id,
    required bool Function() allowed,
  }) {
    final branch = _branch(
      access,
      BusinessLedgerAction.checkInventoryReconciliation,
    );
    return _directory._transaction((txn) async {
      _requireReconciliation(access, allowed);
      final row = await _storedReconciliation(txn, branch, id, 'inventory');
      if (row == null) throw const BusinessReconciliationInvalid();
      final record = _reconciliationPayload(row);
      if (row['status'] == 'approved') {
        throw const BusinessReconciliationInvalid();
      }
      final lines = (record['lines'] as List).cast<Map<String, dynamic>>();
      await _requireCountCategory(txn, branch, record, lines);
      final counted = [
        for (final line in lines)
          if (line['base_qty'] != null) line,
      ];
      if (counted.isEmpty) {
        throw const BusinessReconciliationInvalid();
      }
      final measuredUs = DateTime.parse(
        record['measured_at'] as String,
      ).microsecondsSinceEpoch;
      final countedIds = [
        for (final line in counted) line['product_id'] as String,
      ];
      final stockRows = await txn.query(
        _commerceStock,
        where:
            'branch_id = ? AND product_id IN (${List.filled(countedIds.length, '?').join(',')})',
        whereArgs: [branch, ...countedIds],
      );
      final stockByProduct = {
        for (final row in stockRows)
          row['product_id'] as String: row['quantity_milli'] as int,
      };
      // The stamp counts every movement ever written for the product: the
      // count is monotonic, so a later movement can never look unchanged.
      final movementRows = await txn.rawQuery(
        '''
        SELECT product_id, COUNT(*) AS total,
               SUM(CASE WHEN created_us > ? THEN 1 ELSE 0 END) AS since
        FROM $_commerceMovements
        WHERE branch_id = ? AND product_id IN (${List.filled(countedIds.length, '?').join(',')})
        GROUP BY product_id
        ''',
        [measuredUs, branch, ...countedIds],
      );
      final moved = {
        for (final row in movementRows)
          row['product_id'] as String: (
            total: row['total'] as int,
            since: (row['since'] as int?) ?? 0,
          ),
      };
      final unitRows = await txn.query(
        _commerceUnits,
        where:
            'branch_id = ? AND is_active = 1 AND product_id IN (${List.filled(countedIds.length, '?').join(',')})',
        whereArgs: [branch, ...countedIds],
        orderBy: 'product_id, is_base DESC, name',
      );
      final unitsByProduct = <String, List<Map<String, Object?>>>{};
      for (final row in unitRows) {
        (unitsByProduct[row['product_id'] as String] ??= []).add(row);
      }
      var matched = 0, short = 0, surplus = 0, staleCount = 0;
      final stamps = <String, Object?>{};
      for (final line in lines) {
        if (line['base_qty'] == null) continue;
        final productId = line['product_id'] as String;
        final currentMilli = stockByProduct[productId] ?? 0;
        final baseMilli = _inventoryMilli(line['base_qty']);
        final diffMilli = baseMilli - currentMilli;
        line['system_qty'] = currentMilli / 1000;
        line['diff'] = diffMilli / 1000;
        line['unit_rows'] = [
          for (final unit in unitsByProduct[productId] ?? const [])
            if ((_inventoryFactorValue(unit) ?? 0) > 0)
              {
                'unit_name': unit['name'],
                'factor': _inventoryFactorValue(unit),
                'system': currentMilli / 1000 / _inventoryFactorValue(unit)!,
                'actual': baseMilli / 1000 / _inventoryFactorValue(unit)!,
                'diff': diffMilli / 1000 / _inventoryFactorValue(unit)!,
              },
        ];
        line['status'] = diffMilli == 0
            ? 'match'
            : diffMilli < 0
            ? 'short'
            : 'surplus';
        line['movements_since'] = moved[productId]?.since ?? 0;
        line['stale'] = line['movements_since'] != 0;
        if (line['stale'] == true) staleCount++;
        if (line['status'] == 'match') {
          matched++;
        } else if (line['status'] == 'short') {
          short++;
        } else {
          surplus++;
        }
        stamps[productId] = _inventoryStamp(
          currentMilli,
          moved[productId]?.total ?? 0,
        );
      }
      record['status'] = 'checked';
      record['lines'] = lines;
      record['has_diff'] = short + surplus > 0;
      record['result'] = {
        'counted': counted.length,
        'matched': matched,
        'short': short,
        'surplus': surplus,
        'stale': staleCount,
        'uncounted': lines.length - counted.length,
      };
      await txn.update(
        _reconciliationRecords,
        {
          'status': 'checked',
          'payload': jsonEncode(record),
          'snapshot': jsonEncode(stamps),
        },
        where: 'branch_id = ? AND id = ?',
        whereArgs: [branch, id],
      );
      _requireReconciliation(access, allowed);
      return record;
    }, exclusive: true);
  }

  /// Every settlement, its stock adjustment, movement audit and the approval
  /// receipt are one commit. Repeated identical approvals return the record;
  /// a repetition carrying different numbers is refused.
  Future<Map<String, dynamic>> inventoryReconciliationApprove(
    BusinessLedgerAccess access, {
    required String id,
    required List<BusinessInventorySettlement> settlements,
    String? notes,
    required bool Function() allowed,
  }) {
    final branch = _branch(
      access,
      BusinessLedgerAction.approveInventoryReconciliation,
    );
    final ordered = _inventorySettlements(settlements);
    final note = _reconNotes(notes);
    final digest = _reconDigest([
      note,
      for (final s in ordered) [s.productId, s.expectedMilli, s.newMilli],
    ]);
    return _directory._transaction((txn) async {
      _requireReconciliation(access, allowed);
      final row = await _storedReconciliation(txn, branch, id, 'inventory');
      if (row == null) throw const BusinessReconciliationInvalid();
      final record = _reconciliationPayload(row);
      if (row['status'] == 'approved') {
        if (row['approval_digest'] != digest) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.commandConflict,
          );
        }
        _requireReconciliation(access, allowed);
        return record;
      }
      if (row['status'] != 'checked') {
        throw const BusinessReconciliationInvalid();
      }
      final lines = {
        for (final line in (record['lines'] as List).cast<Map>())
          line['product_id']: line,
      };
      await _requireCountCategory(txn, branch, record, lines.values);
      final snapshots = jsonDecode(row['snapshot'] as String) as Map;
      final now = DateTime.now().toUtc();
      final settledIds = [for (final s in ordered) s.productId];
      final movementTotals = {
        for (final row in await txn.rawQuery(
          '''
          SELECT product_id, COUNT(*) AS total
          FROM $_commerceMovements
          WHERE branch_id = ? AND product_id IN (${List.filled(settledIds.length, '?').join(',')})
          GROUP BY product_id
          ''',
          [branch, ...settledIds],
        ))
          row['product_id'] as String: row['total'] as int,
      };
      final settlementsOut = <Map<String, Object?>>[];
      var posted = 0;
      for (final settlement in ordered) {
        final line = lines[settlement.productId];
        if (line == null ||
            _inventoryMilli(line['system_qty']) != settlement.expectedMilli ||
            _inventoryMilli(line['base_qty']) != settlement.newMilli) {
          throw const BusinessReconciliationInvalid();
        }
        final product = (await txn.query(
          _commerceProducts,
          columns: [
            'name',
            'unit',
            'is_service',
            'cost_minor',
            'cost_currency',
          ],
          where:
              'branch_id = ? AND id = ? AND deleted_us IS NULL AND is_active = 1',
          whereArgs: [branch, settlement.productId],
        )).singleOrNull;
        if (product == null || product['is_service'] == 1) {
          throw const BusinessReconciliationInvalid();
        }
        final current = (await txn.query(
          _commerceStock,
          columns: ['quantity_milli'],
          where: 'branch_id = ? AND product_id = ?',
          whereArgs: [branch, settlement.productId],
        )).singleOrNull;
        final beforeMilli = current?['quantity_milli'] as int? ?? 0;
        if (settlement.expectedMilli != beforeMilli) {
          throw const BusinessReconciliationChanged();
        }
        final stamp = _inventoryStamp(
          beforeMilli,
          movementTotals[settlement.productId] ?? 0,
        );
        if (snapshots[settlement.productId] != stamp) {
          // A movement happened after the check — even one that returned the
          // balance to the same number — and forces a fresh check.
          throw const BusinessReconciliationChanged();
        }
        final diffMilli = settlement.newMilli - beforeMilli;
        if (diffMilli != 0 && line['stale'] == true) {
          throw const BusinessReconciliationChanged();
        }
        final command = const Uuid().v5(
          id,
          'fyona.reconciliation.inventory.approve.v1:${settlement.productId}',
        );
        if (diffMilli != 0) {
          if (current == null) {
            await txn.insert(_commerceStock, {
              'branch_id': branch,
              'id': const Uuid().v5(command, 'stock'),
              'product_id': settlement.productId,
              'quantity_milli': settlement.newMilli,
              'avg_cost_4': 0,
            });
          } else {
            await txn.update(
              _commerceStock,
              {'quantity_milli': settlement.newMilli},
              where: 'branch_id = ? AND product_id = ?',
              whereArgs: [branch, settlement.productId],
            );
          }
          if (diffMilli > 0) {
            final cost = product['cost_minor'] as int?;
            await _receiveInventoryBatch(
              txn,
              branch: branch,
              id: command,
              product: settlement.productId,
              quantity: diffMilli * 1000,
              source: 'adjustment',
              now: now,
              cost4: cost == null ? null : cost * 100,
              currency: product['cost_currency'] as String?,
            );
          } else {
            await _consumeCommerceLots(
              txn,
              branch,
              command,
              settlement.productId,
              -diffMilli * 1000,
              now,
            );
          }
          await txn.insert(_commerceMovements, {
            'branch_id': branch,
            'id': command,
            'product_id': settlement.productId,
            'movement_type': 'adjust_set',
            'quantity_micro': diffMilli * 1000,
            'unit_minor': 0,
            'total_minor': 0,
            'currency': product['cost_currency'],
            'reason': 'مطابقة المخزون',
            'old_micro': beforeMilli * 1000,
            'new_micro': settlement.newMilli * 1000,
            'difference_micro': diffMilli * 1000,
            'reference_type': 'reconciliation',
            'reference_id': record['ref_code'],
            'notes': 'تسوية جرد ${record['ref_code']}',
            'created_by': access.directory.workspace.accountId,
            'created_us': now.microsecondsSinceEpoch,
          });
          await txn.insert(BusinessLedger._commands, {
            'branch_id': branch,
            'id': command,
            'fingerprint': digest,
            'result': jsonEncode({'reconciliation_id': id}),
          });
          posted++;
        }
        settlementsOut.add({
          'product_id': settlement.productId,
          'name': product['name'],
          'unit': product['unit'] ?? 'قطعة',
          'before': beforeMilli / 1000,
          'after': settlement.newMilli / 1000,
          'diff': diffMilli / 1000,
          'movement_id': diffMilli == 0 ? null : command,
          'applied': diffMilli != 0,
          'parts': line['parts'] ?? const [],
          'unit_rows': line['unit_rows'] ?? const [],
        });
      }
      record.addAll({
        'status': 'approved',
        'approved_at': now.toIso8601String(),
        'approved_by': access.directory.workspace.accountId,
        if (note != null) 'notes': note,
        'settlements': settlementsOut,
        'result': {
          'settled': posted,
          'untouched': settlementsOut.length - posted,
          'ref_code': record['ref_code'],
        },
      });
      await txn.update(
        _reconciliationRecords,
        {
          'status': 'approved',
          'payload': jsonEncode(record),
          'approval_digest': digest,
        },
        where: 'branch_id = ? AND id = ?',
        whereArgs: [branch, id],
      );
      _requireReconciliation(access, allowed);
      return record;
    }, exclusive: true);
  }

  Future<Map<String, dynamic>> inventoryReconciliationDetail(
    BusinessLedgerAccess access,
    String id,
  ) {
    final branch = _branch(
      access,
      BusinessLedgerAction.readInventoryReconciliation,
    );
    return _directory._read((db) async {
      final row = await _storedReconciliation(db, branch, id, 'inventory');
      if (row == null) throw const BusinessReconciliationInvalid();
      return _reconciliationPayload(row);
    });
  }

  /// Resolve a visible count row's photo without duplicating every image in
  /// the count, its check, its approval or their backup history.
  Future<String?> inventoryReconciliationPhoto(
    BusinessLedgerAccess access, {
    required String id,
    required String productId,
  }) {
    final branch = _branch(
      access,
      BusinessLedgerAction.readInventoryReconciliation,
    );
    if (!isDirectoryId(id) || !isDirectoryId(productId)) {
      throw const BusinessReconciliationInvalid();
    }
    return _directory._read((db) async {
      final rows = await db.rawQuery(
        '''
        SELECT p.image FROM $_commerceProducts p
        JOIN $_reconciliationRecords r ON r.branch_id = p.branch_id
        WHERE p.branch_id = ? AND p.id = ? AND r.id = ? AND r.rtype = 'inventory'
          AND EXISTS (
            SELECT 1 FROM json_each(r.payload, '\$.lines') l
            WHERE json_extract(l.value, '\$.product_id') = p.id
          )
      ''',
        [branch, productId, id],
      );
      return _deviceInventoryImage(rows.singleOrNull?['image']);
    });
  }
}

Future<void> _requireCountCategory(
  DatabaseExecutor db,
  String branch,
  Map<String, dynamic> record,
  Iterable<Map> lines,
) async {
  if (record['scope'] != 'category') return;
  final category = (record['scope_json'] as Map?)?['category_id'];
  if (category is! String) throw const BusinessInventoryCategoryChanged();
  final captured = {for (final line in lines) line['product_id']};
  final current = await db.rawQuery(
    '''
    SELECT p.id FROM $_commerceCategoryLinks c
    JOIN $_commerceProducts p ON p.branch_id = c.branch_id AND p.id = c.id
    WHERE c.branch_id = ? AND c.category_id = ?
      AND p.deleted_us IS NULL AND p.is_active = 1 AND p.is_service = 0
    LIMIT 2001
  ''',
    [branch, category],
  );
  if (current.length != captured.length ||
      current.any((row) => !captured.contains(row['id']))) {
    throw const BusinessInventoryCategoryChanged();
  }
}

List<BusinessInventoryCount> _inventoryCounts(
  List<BusinessInventoryCount> counts,
) {
  final ids = <String>{};
  for (final count in counts) {
    if (!isDirectoryId(count.productId) || !ids.add(count.productId)) {
      throw const BusinessReconciliationInvalid();
    }
  }
  return counts;
}

const _inventoryMaxMilli = 99999999999999; // PostgreSQL NUMERIC(14, 3).

List<BusinessInventorySettlement> _inventorySettlements(
  List<BusinessInventorySettlement> settlements,
) {
  if (settlements.isEmpty || settlements.length > 2000) {
    throw const BusinessReconciliationInvalid();
  }
  final ids = <String>{};
  for (final settlement in settlements) {
    if (!isDirectoryId(settlement.productId) ||
        !ids.add(settlement.productId) ||
        settlement.newMilli < 0 ||
        settlement.newMilli > _inventoryMaxMilli ||
        settlement.expectedMilli < 0 ||
        settlement.expectedMilli > _inventoryMaxMilli) {
      throw const BusinessReconciliationInvalid();
    }
  }
  return settlements;
}

Future<Map<String, Map<String, int>>> _inventoryUnitFactors(
  DatabaseExecutor db,
  String branch,
) async {
  final rows = await db.query(
    _commerceUnits,
    columns: ['product_id', 'id', 'factor_4'],
    where: 'branch_id = ?',
    whereArgs: [branch],
  );
  final factors = <String, Map<String, int>>{};
  for (final row in rows) {
    factors.putIfAbsent(
      row['product_id'] as String,
      () => {},
    )[row['id'] as String] = row['factor_4'] as int;
  }
  return factors;
}

int _inventoryFactor(
  Map<String, Map<String, int>> factors,
  String productId,
  String? unitId,
) {
  if (unitId == null) return 10000; // base unit
  final factor = factors[productId]?[unitId];
  if (factor == null || factor <= 0) {
    throw const BusinessReconciliationInvalid();
  }
  return factor;
}

double? _inventoryFactorValue(Map<String, Object?> unit) {
  final factor = unit['factor_4'] as int?;
  return factor == null ? null : factor / 10000;
}

/// Base-unit milli from [qtyMilli] × [factor4]; input that would require
/// rounding beyond the ledger's 0.001 precision is refused.
int _inventoryBase(int qtyMilli, int factor4) {
  final precise = BigInt.from(qtyMilli) * BigInt.from(factor4);
  final scale = BigInt.from(10000);
  final base = precise ~/ scale;
  if (precise % scale != BigInt.zero ||
      base > BigInt.from(_inventoryMaxMilli)) {
    throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
  }
  return base.toInt();
}

double? _inventoryDecimal(int? value, int scale) =>
    value == null ? null : value / scale;

/// Exact 0.001 resolution round trip; finer quantities are refused.
int _inventoryMilli(Object? qty) {
  final value = num.tryParse('$qty');
  if (value == null || !value.isFinite) {
    throw const BusinessReconciliationInvalid();
  }
  final milli = (value * 1000).round();
  if ((milli / 1000 - value).abs() > 0.0000001) {
    throw const BusinessReconciliationInvalid();
  }
  return milli;
}

String _inventoryStamp(int quantityMilli, int movementCount) =>
    _reconDigest([quantityMilli, movementCount]);
