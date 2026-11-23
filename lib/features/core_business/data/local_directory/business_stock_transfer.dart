part of 'directory_database.dart';

// Stock transfers between two branches of this store. The issue leaves the
// source batches (FIFO, oldest receipt first, exactly like a sale) and the
// receipt mirrors each taken slice at the destination with the same cost,
// currency and dates. A reversal returns the very same slices and nothing
// else. Both sides share one command: they commit together or not at all.
Future<void> _createBusinessStockTransfer(DatabaseExecutor db) async {}

extension BusinessStockTransfer on BusinessLedger {
  static const _maxMilli = 99999999999999; // PostgreSQL NUMERIC(14, 3).

  int _exactProduct(int quantity, int factor4, int scale) {
    final value = BigInt.from(quantity) * BigInt.from(factor4);
    final (result, rest) = (
      value ~/ BigInt.from(scale),
      value.remainder(BigInt.from(scale)),
    );
    if (rest != BigInt.zero || result <= BigInt.zero) {
      // Rounding here would move a quantity that never existed.
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
    }
    if (result > BigInt.from(_maxMilli) * BigInt.from(1000)) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
    }
    return result.toInt();
  }

  Future<Map<String, Object?>> _transferProduct(
    DatabaseExecutor db,
    String branch,
    String productId,
  ) async {
    final row = (await db.query(
      _commerceProducts,
      where: 'branch_id = ? AND id = ? AND deleted_us IS NULL',
      whereArgs: [branch, productId],
    )).singleOrNull;
    if (row == null || row['is_service'] == 1 || row['is_active'] != 1) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
    }
    return row;
  }

  Future<int> _transferUnitFactor(
    DatabaseExecutor db,
    String branch,
    String product,
    String? unitId,
  ) async {
    if (unitId == null) return 10000;
    final row = (await db.query(
      _commerceUnits,
      columns: ['factor_4'],
      where: 'branch_id = ? AND product_id = ? AND id = ? AND is_active = 1',
      whereArgs: [branch, product, unitId],
    )).singleOrNull;
    if (row == null) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
    }
    return row['factor_4'] as int;
  }

  /// Moves stock between two branches of this store in one transaction.
  /// Every slice keeps its batch identity: cost, currency, purchase date,
  /// expiry and batch number travel with the goods.
  Future<Map<String, Object?>> transferStockBetweenBranches(
    BusinessLedgerAccess access, {
    required String commandId,
    required String fromBranch,
    required String toBranch,
    required List<BusinessStockTransferLine> items,
    String? notes,
    bool Function()? allowed,
  }) async {
    final acting = _branch(access, BusinessLedgerAction.transfer);
    if (!_validBranchPair(acting, fromBranch, toBranch)) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidTransfer);
    }
    if (items.isEmpty || items.length > 50) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidTransfer);
    }
    final note = DirectoryDatabase._optional(notes);
    final seen = <String>{};
    for (final item in items) {
      if (!isDirectoryId(item.fromProduct) || !seen.add(item.fromProduct)) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidTransfer);
      }
    }
    return _commit(
      acting,
      commandId,
      [
        'branch_stock_transfer',
        fromBranch,
        toBranch,
        note,
        [
          for (final item in items)
            [
              item.fromProduct,
              item.toProduct,
              item.fromUnit,
              item.toUnit,
              item.quantityMicro,
              item.conversionFactor4,
            ],
        ],
      ],
      (txn, now) async {
        await _requirePeerPresence(txn, fromBranch, toBranch, access.directory);
        final lines = <Map<String, Object?>>[];
        final targets = <String>{};
        var index = 0;
        for (final item in items) {
          final source = await _transferProduct(
            txn,
            fromBranch,
            item.fromProduct,
          );
          final match = await _transferMatch(txn, toBranch, source);
          final targetId =
              item.toProduct ?? match?['id'] as String? ?? item.fromProduct;
          if (!targets.add(targetId)) {
            throw const BusinessLedgerError(
              BusinessLedgerProblem.invalidTransfer,
            );
          }
          if (item.toProduct == null && match == null) {
            // The existing form asks before creating a missing target. Copy
            // only the product definition, never a quantity or a balance.
            await _copyTransferProduct(txn, source, toBranch, now);
          }
          await _transferProduct(txn, toBranch, targetId);
          final fromFactor = await _transferUnitFactor(
            txn,
            fromBranch,
            item.fromProduct,
            item.fromUnit,
          );
          final toFactor = await _transferUnitFactor(
            txn,
            toBranch,
            targetId,
            item.toUnit,
          );
          final factor4 = item.conversionFactor4;
          if ((factor4 != null && factor4 <= 0) ||
              (factor4 == null && targetId != item.fromProduct)) {
            throw const BusinessLedgerError(
              BusinessLedgerProblem.invalidTransfer,
            );
          }
          // Everything multiplies exactly, or nothing moves.
          final issueMicro = _exactProduct(
            item.quantityMicro,
            fromFactor,
            10000,
          );
          // The UI's factor is expressed in target *base* units, so a
          // destination unit displayed on the form must not multiply it again.
          final receiptMicro = factor4 == null
              ? issueMicro
              : _exactProduct(item.quantityMicro, factor4, 10000);
          if (factor4 == null &&
              item.toUnit != null &&
              toFactor != fromFactor &&
              toFactor != 10000) {
            throw const BusinessLedgerError(
              BusinessLedgerProblem.invalidTransfer,
            );
          }
          for (final base in [issueMicro, receiptMicro]) {
            if (base % 1000 != 0) {
              throw const BusinessLedgerError(
                BusinessLedgerProblem.invalidAmount,
              );
            }
          }
          final allocations = await _transferSlices(
            txn,
            commandId,
            index,
            actor: access.directory.workspace.accountId,
            fromBranch: fromBranch,
            toBranch: toBranch,
            item: item,
            targetProduct: targetId,
            issueMicro: issueMicro,
            receiptMicro: receiptMicro,
            now: now,
          );
          lines.add({
            'item_index': index,
            'from_product': item.fromProduct,
            'to_product': targetId,
            'from_unit': item.fromUnit,
            'to_unit': item.toUnit,
            'quantity_micro': item.quantityMicro,
            'issue_micro': issueMicro,
            'receipt_micro': receiptMicro,
            'allocations': allocations,
          });
          index += 1;
        }
        for (final (branch, side, peer) in [
          (fromBranch, 'out', toBranch),
          (toBranch, 'in', fromBranch),
        ]) {
          await txn.insert(_branchTransfers, {
            'branch_id': branch,
            'id': commandId,
            'side': side,
            'kind': 'inventory',
            'peer_branch': peer,
            'status': 'done',
            'reversal_of': null,
            'account_id': null,
            'amount_minor': null,
            'currency': null,
            'notes': note,
            'created_us': now.microsecondsSinceEpoch,
          });
        }
        for (final line in lines) {
          final allocations = line['allocations'] as List;
          for (final (branch, side, product, micro) in [
            (fromBranch, 'issue', line['from_product'], line['issue_micro']),
            (toBranch, 'receipt', line['to_product'], line['receipt_micro']),
          ]) {
            await txn.insert(_branchTransferLines, {
              'branch_id': branch,
              'transfer_id': commandId,
              'item_index': line['item_index'],
              'product_id': product,
              'unit_id': side == 'issue' ? line['from_unit'] : line['to_unit'],
              'quantity_micro': micro,
              'kind': side,
              'allocations': jsonEncode(allocations),
            });
          }
        }
        return {
          'id': commandId,
          'kind': 'inventory',
          'from_branch': fromBranch,
          'to_branch': toBranch,
          'notes': note,
          'lines': lines,
        };
      },
      allowed: allowed,
      mirrorBranches: [fromBranch, toBranch],
    );
  }

  /// Takes the issue quantity from the source batches and mirrors every slice
  /// at the destination. Returns the slice list used for the reversal.
  Future<List<Map<String, Object?>>> _transferSlices(
    Transaction txn,
    String commandId,
    int index, {
    required String actor,
    required String fromBranch,
    required String toBranch,
    required BusinessStockTransferLine item,
    required String targetProduct,
    required int issueMicro,
    required int receiptMicro,
    required DateTime now,
  }) async {
    final stock = await _commerceRows(
      txn,
      _commerceStock,
      fromBranch,
      'product_id',
      item.fromProduct,
    );
    final oldMilli = stock.singleOrNull?['quantity_milli'] as int? ?? 0;
    if (oldMilli * 1000 < issueMicro || oldMilli * 1000 - issueMicro < 0) {
      throw const BusinessLedgerError(BusinessLedgerProblem.insufficientStock);
    }
    final lots = await _availableInventoryLots(
      txn,
      fromBranch,
      item.fromProduct,
    );
    final slices = <Map<String, Object?>>[];
    var pending = issueMicro;
    var pendingReceipt = receiptMicro;
    if (lots.fold<int>(
          0,
          (sum, lot) => sum + (lot['remaining_micro'] as int),
        ) !=
        oldMilli * 1000) {
      throw const BusinessLedgerError(BusinessLedgerProblem.stockChanged);
    }
    for (final lot in lots) {
      if (pending == 0) break;
      final take = min(lot['remaining_micro'] as int, pending);
      if (take <= 0) continue;
      final full = (await txn.query(
        _commerceLots,
        where: 'branch_id = ? AND id = ?',
        whereArgs: [fromBranch, lot['id']],
      )).single;
      await txn.update(
        _commerceLots,
        {'remaining_micro': (lot['remaining_micro'] as int) - take},
        where: 'branch_id = ? AND id = ?',
        whereArgs: [fromBranch, lot['id']],
      );
      await txn.insert(_commerceConsumptions, {
        'branch_id': fromBranch,
        'id': const Uuid().v5(
          commandId,
          'fyona.transfer.consume.v1:$index:${lot['id']}',
        ),
        'lot_id': lot['id'],
        'item_id': null,
        'quantity_micro': take,
        'unit_cost_4': lot['unit_cost_4'],
        'currency': lot['currency'],
        'created_us': now.microsecondsSinceEpoch,
      });
      final give = _exactProduct(take, receiptMicro, issueMicro);
      final cost = lot['unit_cost_4'] as int?;
      final currency = lot['currency'] as String?;
      if (cost == null ||
          currency == null ||
          businessCurrency(currency) != currency) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidTransfer);
      }
      final value = BigInt.from(take) * BigInt.from(cost);
      final quantity = BigInt.from(give);
      final converted = value ~/ quantity;
      if (value % quantity != BigInt.zero ||
          converted > BigInt.from(999999999999999999)) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
      }
      final arrivalId = const Uuid().v5(
        commandId,
        'fyona.transfer.lot.v1:$index:${lot['id']}',
      );
      if (give > 0) {
        await _receiveInventoryBatch(
          txn,
          branch: toBranch,
          id: arrivalId,
          product: targetProduct,
          quantity: give,
          source: 'transfer',
          now: now,
          cost4: converted.toInt(),
          currency: currency,
          unitId: item.toUnit,
          expiryDate: full['expiry_date'] as String?,
          lotNumber: full['lot_number'] as String?,
        );
        // The goods keep the purchase date they travelled with.
        await txn.update(
          _commerceLots,
          {'purchase_date': full['purchase_date']},
          where: 'branch_id = ? AND id = ?',
          whereArgs: [toBranch, arrivalId],
        );
      }
      slices.add({
        'source_lot': lot['id'],
        'arrival_lot': give > 0 ? arrivalId : null,
        'issue_micro': take,
        'receipt_micro': give,
        'unit_cost_4': lot['unit_cost_4'],
        'currency': lot['currency'],
      });
      pending -= take;
      pendingReceipt -= give;
    }
    if (pending > 0 || pendingReceipt != 0) {
      // Stock was checked above; this is unattributed legacy stock without a
      // batch to travel with. Never invent one for a transfer.
      throw const BusinessLedgerError(BusinessLedgerProblem.insufficientStock);
    }
    await _transferStockDelta(txn, fromBranch, item.fromProduct, -issueMicro);
    await _transferStockDelta(txn, toBranch, targetProduct, receiptMicro);
    final newTarget =
        (await _commerceRows(
              txn,
              _commerceStock,
              toBranch,
              'product_id',
              targetProduct,
            )).single['quantity_milli']
            as int;
    await txn.insert(_commerceMovements, {
      'branch_id': fromBranch,
      'id': const Uuid().v5(commandId, 'fyona.transfer.out.v1:$index'),
      'product_id': item.fromProduct,
      'movement_type': 'transfer_out',
      'quantity_micro': -issueMicro,
      'unit_minor': 0,
      'total_minor': 0,
      'old_micro': oldMilli * 1000,
      'new_micro': oldMilli * 1000 - issueMicro,
      'difference_micro': -issueMicro,
      'reference_type': 'branch_transfer',
      'reference_id': commandId,
      'notes': item.toProduct,
      'created_by': actor,
      'created_us': now.microsecondsSinceEpoch,
    });
    await txn.insert(_commerceMovements, {
      'branch_id': toBranch,
      'id': const Uuid().v5(commandId, 'fyona.transfer.in.v1:$index'),
      'product_id': targetProduct,
      'movement_type': 'transfer_in',
      'quantity_micro': receiptMicro,
      'unit_minor': 0,
      'total_minor': 0,
      'old_micro': newTarget * 1000 - receiptMicro,
      'new_micro': newTarget * 1000,
      'difference_micro': receiptMicro,
      'reference_type': 'branch_transfer',
      'reference_id': commandId,
      'created_by': actor,
      'created_us': now.microsecondsSinceEpoch,
    });
    return slices;
  }

  /// The products of one locally kept branch, in the shape the transfer form
  /// picks from.
  Future<List<Map<String, Object?>>> transferProductOptions(
    BusinessLedgerAccess access,
    String branch, {
    String? search,
    bool includeZero = true,
    bool canReadCost = true,
  }) async {
    _branch(access, BusinessLedgerAction.transfer);
    return _directory._read((db) async {
      await _requireLocalBranch(db, branch, authorized: access.directory);
      final products = await db.query(
        _commerceProducts,
        where:
            'branch_id = ? AND deleted_us IS NULL AND is_active = 1 AND is_service = 0',
        whereArgs: [branch],
        orderBy: 'name',
      );
      final query = search?.trim().toLowerCase() ?? '';
      final result = <Map<String, Object?>>[];
      for (final row in products) {
        if (query.isNotEmpty &&
            ![
              'name',
              'name_ar',
              'barcode',
              'sku',
            ].any((key) => '${row[key] ?? ''}'.toLowerCase().contains(query)))
          continue;
        final card = await _transferProductCard(
          db,
          branch,
          row,
          canReadCost: canReadCost,
        );
        if (includeZero || (card['available'] as num) > 0) result.add(card);
      }
      return result;
    });
  }

  Future<Map<String, Object?>> _transferProductCard(
    DatabaseExecutor db,
    String branch,
    Map<String, Object?> row, {
    bool canReadCost = true,
  }) async {
    final units = await db.query(
      _commerceUnits,
      where: 'branch_id = ? AND product_id = ? AND is_active = 1',
      whereArgs: [branch, row['id']],
      orderBy: 'is_base DESC, name',
    );
    final stock = await db.query(
      _commerceStock,
      columns: ['quantity_milli'],
      where: 'branch_id = ? AND product_id = ?',
      whereArgs: [branch, row['id']],
    );
    return {
      'id': row['id'],
      'name': row['name'],
      'name_ar': row['name_ar'],
      'barcode': row['barcode'],
      'sku': row['sku'],
      'image': _deviceInventoryImage(row['image']),
      'unit': row['unit'],
      'available':
          (stock.singleOrNull?['quantity_milli'] as int? ?? 0) / 1000.0,
      'sale_price': ((row['price_minor'] as int?) ?? 0) / 100.0,
      'cost_currency': canReadCost ? row['cost_currency'] : null,
      'cost_price': !canReadCost || row['cost_minor'] == null
          ? null
          : (row['cost_minor'] as int) / 100.0,
      'units': [
        for (final unit in units)
          {
            'id': unit['id'],
            'name': unit['name'],
            'factor': (unit['factor_4'] as int) / 10000.0,
            'is_base': unit['is_base'] == 1,
          },
      ],
    };
  }

  /// Which product at the destination receives these goods.
  Future<Map<String, Object?>> transferProductMatch(
    BusinessLedgerAccess access, {
    required String fromProduct,
    required String targetBranch,
    String? sourceBranch,
    bool canReadCost = true,
  }) async {
    _branch(access, BusinessLedgerAction.transfer);
    return _directory._read((db) async {
      await _requireLocalBranch(db, targetBranch, authorized: access.directory);
      final source = await _transferProduct(
        db,
        sourceBranch ?? access.directory.branchId,
        fromProduct,
      );
      final match = await _transferMatch(db, targetBranch, source);
      return {
        'exists': match != null,
        'source_name': source['name'],
        'product': match == null
            ? null
            : await _transferProductCard(
                db,
                targetBranch,
                match,
                canReadCost: canReadCost,
              ),
      };
    });
  }

  /// How the source unit relates to the destination's base unit. The form
  /// asks for the factor only when the two are not the same measure.
  Future<Map<String, Object?>> transferUnitInfo(
    BusinessLedgerAccess access, {
    required String fromProduct,
    required String toProduct,
    String? fromUnitId,
    required String targetBranch,
    String? sourceBranch,
  }) async {
    final acting =
        sourceBranch ?? _branch(access, BusinessLedgerAction.transfer);
    _branch(access, BusinessLedgerAction.transfer);
    return _directory._read((db) async {
      await _requireLocalBranch(db, targetBranch);
      final source = await _transferProduct(db, acting, fromProduct);
      final target = await _transferProduct(db, targetBranch, toProduct);
      final fromUnit = fromUnitId == null
          ? (await db.query(
              _commerceUnits,
              where:
                  'branch_id = ? AND product_id = ? AND is_base = 1 '
                  'AND is_active = 1',
              whereArgs: [acting, fromProduct],
              limit: 1,
            )).singleOrNull
          : (await db.query(
              _commerceUnits,
              where: 'branch_id = ? AND product_id = ? AND id = ?',
              whereArgs: [acting, fromProduct, fromUnitId],
              limit: 1,
            )).singleOrNull;
      final targetBase = (await db.query(
        _commerceUnits,
        where:
            'branch_id = ? AND product_id = ? AND is_base = 1 AND is_active = 1',
        whereArgs: [targetBranch, toProduct],
        limit: 1,
      )).singleOrNull;
      final fromFactor = fromUnit?['factor_4'] as int? ?? 10000;
      final same = fromProduct == toProduct;
      return {
        'required': !same,
        'conversion_factor': same ? fromFactor / 10000 : null,
        'source_unit_name': fromUnit?['name'] ?? source['unit'],
        'target_base_unit': targetBase?['name'] ?? target['unit'],
      };
    });
  }

  Future<Map<String, Object?>?> _transferMatch(
    DatabaseExecutor db,
    String targetBranch,
    Map<String, Object?> source,
  ) async {
    final rows = await db.query(
      _commerceProducts,
      where:
          'branch_id=? AND deleted_us IS NULL AND is_service=0 AND is_active=1 '
          'AND (id=? OR (sku IS NOT NULL AND sku <> \'\' AND sku=?) '
          'OR (barcode IS NOT NULL AND barcode <> \'\' AND barcode=?))',
      whereArgs: [
        targetBranch,
        source['id'],
        source['sku'] ?? '',
        source['barcode'] ?? '',
      ],
      limit: 2,
    );
    if (rows.length > 1)
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
    return rows.singleOrNull;
  }

  Future<void> _copyTransferProduct(
    Transaction txn,
    Map<String, Object?> source,
    String target,
    DateTime now,
  ) async {
    final home = source['branch_id'], product = source['id'];
    await txn.insert(_commerceProducts, {
      ...source,
      'branch_id': target,
      'created_us': now.microsecondsSinceEpoch,
    });
    for (final table in [_commerceUnits, _commerceBarcodes, _commercePrices]) {
      for (final row in await txn.query(
        table,
        where: 'branch_id=? AND product_id=?',
        whereArgs: [home, product],
      )) {
        await txn.insert(table, {...row, 'branch_id': target});
      }
    }
  }

  Future<void> _transferStockDelta(
    Transaction txn,
    String branch,
    String product,
    int deltaMicro,
  ) async {
    final stock = await _commerceRows(
      txn,
      _commerceStock,
      branch,
      'product_id',
      product,
    );
    final current = stock.singleOrNull;
    final oldMilli = current?['quantity_milli'] as int? ?? 0;
    final next = oldMilli + deltaMicro ~/ 1000;
    if (next < 0 || next > _maxMilli) {
      throw const BusinessLedgerError(BusinessLedgerProblem.insufficientStock);
    }
    final currency =
        (await _transferProduct(txn, branch, product))['cost_currency']
            as String?;
    final average = await _transferLotAverage(
      txn,
      branch,
      product,
      next,
      currency,
    );
    if (current == null) {
      await txn.insert(_commerceStock, {
        'branch_id': branch,
        'id': const Uuid().v5(product, 'fyona.transfer.stock.v1'),
        'product_id': product,
        'quantity_milli': next,
        'avg_cost_4': average ?? 0,
      });
    } else {
      await txn.update(
        _commerceStock,
        {'quantity_milli': next, 'avg_cost_4': average ?? 0},
        where: 'branch_id = ? AND id = ?',
        whereArgs: [branch, current['id']],
      );
    }
  }

  /// Returns a stock transfer's own slices. A mirrored batch already used by
  /// a sale cannot be recalled, so the whole reversal is refused instead of
  /// leaving the two branches disagreeing.
  Future<void> reverseStockSlices(
    Transaction txn,
    String commandId,
    String transferId, {
    required String fromBranch,
    required String toBranch,
    required String actor,
    required DateTime now,
  }) async {
    final rows = await txn.query(
      _branchTransferLines,
      where: "branch_id = ? AND transfer_id = ? AND kind = 'receipt'",
      whereArgs: [toBranch, transferId],
      orderBy: 'item_index',
    );
    if (rows.isEmpty) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidTransfer);
    }
    for (final row in rows) {
      final slices = (jsonDecode(row['allocations'] as String) as List)
          .whereType<Map>()
          .toList();
      final targetProduct = row['product_id'] as String;
      final sourceProduct =
          (await txn.query(
                _branchTransferLines,
                columns: ['product_id'],
                where:
                    "branch_id = ? AND transfer_id = ? AND kind = 'issue' AND item_index = ?",
                whereArgs: [fromBranch, transferId, row['item_index']],
              )).single['product_id']
              as String;
      var issueTotal = 0, receiptTotal = 0;
      for (final slice in slices) {
        final give = slice['receipt_micro'] as int;
        final Map<Object?, Object?>? lot;
        if (give == 0) {
          lot = null;
        } else {
          final arrival = await _commerceRows(
            txn,
            _commerceLots,
            toBranch,
            'id',
            slice['arrival_lot'],
          );
          lot = arrival.singleOrNull;
          if (lot == null || lot['remaining_micro'] != give) {
            // Already used at the destination: refuse the whole reversal.
            throw const BusinessLedgerError(
              BusinessLedgerProblem.invalidTransfer,
            );
          }
        }
        final source = await _commerceRows(
          txn,
          _commerceLots,
          fromBranch,
          'id',
          slice['source_lot'],
        );
        final original = source.singleOrNull;
        final take = slice['issue_micro'] as int;
        if (original == null ||
            (original['remaining_micro'] as int) + take >
                (original['received_micro'] as int)) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.invalidTransfer,
          );
        }
        if (lot != null) {
          await txn.update(
            _commerceLots,
            {'remaining_micro': 0},
            where: 'branch_id = ? AND id = ?',
            whereArgs: [toBranch, lot['id']],
          );
        }
        await txn.update(
          _commerceLots,
          {'remaining_micro': (original['remaining_micro'] as int) + take},
          where: 'branch_id = ? AND id = ?',
          whereArgs: [fromBranch, original['id']],
        );
        issueTotal += take;
        receiptTotal += give;
      }
      await _transferStockDelta(txn, fromBranch, sourceProduct, issueTotal);
      await _transferStockDelta(txn, toBranch, targetProduct, -receiptTotal);
      await txn.insert(_commerceMovements, {
        'branch_id': toBranch,
        'id': const Uuid().v5(
          commandId,
          'fyona.transfer.reversal.in.v1:${row['item_index']}',
        ),
        'product_id': targetProduct,
        'movement_type': 'transfer_reversal_in',
        'quantity_micro': -receiptTotal,
        'unit_minor': 0,
        'total_minor': 0,
        'difference_micro': -receiptTotal,
        'reference_type': 'branch_transfer',
        'reference_id': transferId,
        'created_by': actor,
        'created_us': now.microsecondsSinceEpoch,
      });
      await txn.insert(_commerceMovements, {
        'branch_id': fromBranch,
        'id': const Uuid().v5(
          commandId,
          'fyona.transfer.reversal.out.v1:${row['item_index']}',
        ),
        'product_id': sourceProduct,
        'movement_type': 'transfer_reversal_out',
        'quantity_micro': issueTotal,
        'unit_minor': 0,
        'total_minor': 0,
        'difference_micro': issueTotal,
        'reference_type': 'branch_transfer',
        'reference_id': transferId,
        'created_by': actor,
        'created_us': now.microsecondsSinceEpoch,
      });
    }
  }
}

/// Derive the average from the available batches once a transfer has changed
/// them. Never present a mixed-currency or incompletely attributed average.
Future<int?> _transferLotAverage(
  DatabaseExecutor db,
  String branch,
  String product,
  int quantityMilli,
  String? currency,
) async {
  if (quantityMilli == 0 || currency == null) return null;
  var quantity = 0;
  var value = BigInt.zero;
  for (final lot in await _availableInventoryLots(db, branch, product)) {
    final take = lot['remaining_micro'] as int;
    final cost = lot['unit_cost_4'] as int?;
    if (lot['currency'] != currency || cost == null) return null;
    quantity += take;
    value += BigInt.from(take) * BigInt.from(cost);
  }
  if (quantity != quantityMilli * 1000) return null;
  return _commerceRatioRound(value, BigInt.from(quantity));
}

Future<num?> _visibleStockAverage(
  DatabaseExecutor db,
  String branch,
  String product,
  Map<String, Object?> row,
) async {
  final qty = row['quantity_milli'] as int?;
  if (qty == null) return null;
  final transferred = await db.query(
    _commerceMovements,
    columns: ['id'],
    where: "branch_id=? AND product_id=? AND reference_type='branch_transfer'",
    whereArgs: [branch, product],
    limit: 1,
  );
  if (transferred.isEmpty) return _commerceDecimal(row, 'avg_cost_4', 10000);
  final average = await _transferLotAverage(
    db,
    branch,
    product,
    qty,
    row['cost_currency'] as String?,
  );
  return average == null ? null : average / 10000;
}
