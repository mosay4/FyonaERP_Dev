part of 'directory_database.dart';

enum BusinessStockAdjustment { add, remove, set }

/// Inventory adjustment rehearsal: preserve imported lot identities and move
/// the branch quantity, lot quantities, audit entry and replay receipt together.
extension BusinessCommerceStock on BusinessLedger {
  Future<Map<String, Object?>> adjustCommerceStock(
    BusinessLedgerAccess access, {
    required String productId,
    required String commandId,
    required BusinessStockAdjustment mode,
    required int amountMilli,
    required int expectedMilli,
    String? reason,
    String? notes,
  }) {
    final branch = _branch(access, BusinessLedgerAction.adjustStock);
    const maxMilli = 99999999999999; // PostgreSQL NUMERIC(14, 3).
    if (amountMilli < 0 || amountMilli > maxMilli) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
    }
    return _commit(
      branch,
      commandId,
      [
        'stock_adjust',
        productId,
        mode.name,
        amountMilli,
        expectedMilli,
        reason,
        notes,
      ],
      (txn, now) async {
        final product = (await txn.query(
          _commerceProducts,
          columns: ['cost_minor', 'cost_currency', 'is_service'],
          where: 'branch_id = ? AND id = ? AND deleted_us IS NULL',
          whereArgs: [branch, productId],
        )).singleOrNull;
        if (product == null || product['is_service'] == 1) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
        }
        final current = (await _commerceRows(
          txn,
          _commerceStock,
          branch,
          'product_id',
          productId,
        )).singleOrNull;
        final old = current?['quantity_milli'] as int? ?? 0;
        if (old != expectedMilli) {
          throw const BusinessLedgerError(BusinessLedgerProblem.stockChanged);
        }
        final next = switch (mode) {
          BusinessStockAdjustment.add => old + amountMilli,
          BusinessStockAdjustment.remove => old - amountMilli,
          BusinessStockAdjustment.set => amountMilli,
        };
        if (next < 0) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.insufficientStock,
          );
        }
        if (next > maxMilli) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
        }
        final delta = (next - old) * 1000;
        final when = now.toUtc().microsecondsSinceEpoch;
        if (current == null) {
          await txn.insert(_commerceStock, {
            'branch_id': branch,
            'id': const Uuid().v5(commandId, 'stock'),
            'product_id': productId,
            'quantity_milli': next,
            'avg_cost_4': 0,
          });
        } else {
          await txn.update(
            _commerceStock,
            {'quantity_milli': next},
            where: 'branch_id = ? AND id = ?',
            whereArgs: [branch, current['id']],
          );
        }

        if (delta > 0) {
          final cost = product['cost_minor'] as int?;
          await _receiveInventoryBatch(
            txn,
            branch: branch,
            id: const Uuid().v5(commandId, 'lot'),
            product: productId,
            quantity: delta,
            source: 'adjustment',
            now: now,
            cost4: cost == null ? null : cost * 100,
            currency: product['cost_currency'] as String?,
          );
        } else if (delta < 0) {
          await _consumeCommerceLots(
            txn, branch, commandId, productId, -delta, now,
          );
        }
        await txn.insert(_commerceMovements, {
          'branch_id': branch,
          'id': commandId,
          'product_id': productId,
          'movement_type': 'adjust_${mode.name}',
          'quantity_micro': delta,
          'unit_minor': 0,
          'total_minor': 0,
          'old_micro': old * 1000,
          'new_micro': next * 1000,
          'difference_micro': delta,
          'reason': reason,
          'notes': notes,
          'reference_type': 'adjustment',
          'created_by': access.directory.workspace.accountId,
          'created_us': when,
        });
        return {
          'id': commandId,
          'old_milli': old,
          'new_milli': next,
          'delta_milli': next - old,
        };
      },
    );
  }
}
