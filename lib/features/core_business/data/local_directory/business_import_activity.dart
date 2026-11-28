part of 'directory_database.dart';

/// Read-only check before an import batch is undone: has anything happened
/// to what the batch created? Undo then only goes ahead when nothing did —
/// a payment, an invoice, a stock move or an edit since the import keeps
/// the batch (undoing it would change real balances).
extension BusinessImportActivity on BusinessLedger {
  /// [parties]: party id → kind name; [openings]: party id → the opening
  /// debt the import made for it (if any); [products]: product ids.
  /// Returns the ids with later activity.
  Future<Set<String>> importLaterActivity(
    BusinessLedgerAccess access, {
    required Map<String, String> parties,
    required Map<String, String> openings,
    required List<String> products,
    Map<String, String> accounts = const {},
    Map<String, List<String>> extraOpenings = const {},
  }) {
    final branch = _branch(access, BusinessLedgerAction.readDebt);
    return _directory._transaction((txn) async {
      final busy = <String>{};
      Future<bool> any(String sql, List<Object?> args) async =>
          (await txn.rawQuery('$sql LIMIT 1', args)).isNotEmpty;
      for (final e in parties.entries) {
        final p = e.key, kind = e.value;
        // Anything but the untouched opening documents of this import.
        final own = [if (openings[p] != null) openings[p]!, ...?extraOpenings[p]];
        final marks = own.isEmpty ? "''" : List.filled(own.length, '?').join(',');
        if (await any(
              'SELECT 1 FROM ${BusinessLedger._debts} WHERE branch_id = ? AND kind = ? AND party_id = ? '
              'AND (id NOT IN ($marks) OR paid_minor != 0 OR revision != 0 OR cancelled_us IS NOT NULL)',
              [branch, kind, p, ...own],
            ) ||
            await any('SELECT 1 FROM $_commerceInvoices WHERE branch_id = ? AND party_id = ?', [branch, p])) {
          busy.add(p);
        }
      }
      // An account: anything but the opening movement of its import.
      for (final e in accounts.entries) {
        if (await any('SELECT 1 FROM ${BusinessLedger._legs} WHERE branch_id = ? AND account_id = ? AND command_id != ?',
            [branch, e.key, e.value])) {
          busy.add(e.key);
        }
      }
      for (final id in products) {
        if (await any('SELECT 1 FROM $_commerceLines WHERE branch_id = ? AND product_id = ?', [branch, id]) ||
            await any('SELECT 1 FROM $_commerceMovements WHERE branch_id = ? AND product_id = ?', [branch, id])) {
          busy.add(id);
        }
      }
      return busy;
    });
  }

  /// Is anything an import batch made still in the ledger? (A backup
  /// restored from before the import has none of it: the same file may then
  /// be imported again.)
  Future<bool> importAnyPresent(
    BusinessLedgerAccess access, {
    List<String> parties = const [],
    List<String> products = const [],
    List<String> accounts = const [],
  }) {
    final branch = _branch(access, BusinessLedgerAction.readDebt);
    return _directory._transaction((txn) async {
      Future<bool> any(String table, String extra, List<String> ids) async {
        for (var i = 0; i < ids.length; i += 400) {
          final chunk = ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
          final marks = List.filled(chunk.length, '?').join(',');
          if ((await txn.rawQuery('SELECT 1 FROM $table WHERE branch_id = ? AND id IN ($marks)$extra LIMIT 1',
                  [branch, ...chunk]))
              .isNotEmpty) {
            return true;
          }
        }
        return false;
      }

      return await any(DirectoryDatabase._table, '', parties) ||
          await any(_commerceProducts, ' AND deleted_us IS NULL', products) ||
          await any(BusinessLedger._accounts, '', accounts);
    });
  }

  /// Every live card name (`customer|name`, `supplier|name`) and product
  /// name/barcode (`product|…`) of the branch, as the import compares them
  /// ([fold] = the import's spelling fold).
  Future<Set<String>> importExistingKeys(BusinessLedgerAccess access, String Function(String) fold) {
    final branch = _branch(access, BusinessLedgerAction.readDebt);
    return _directory._transaction((txn) async {
      final out = <String>{};
      for (final r in await txn.rawQuery(
          'SELECT kind, name, phone FROM ${DirectoryDatabase._table} p WHERE branch_id = ? AND NOT EXISTS '
          '(SELECT 1 FROM ${DirectoryDatabase._deleted} d WHERE d.branch_id = p.branch_id AND d.kind = p.kind AND d.party_id = p.id)',
          [branch])) {
        out.add('${r['kind']}|${fold('${r['name']}')}');
        // A phone is used once per kind in a branch (FYONA's own rule).
        final phone = '${r['phone'] ?? ''}'.trim();
        if (phone.isNotEmpty) out.add('phone|${r['kind']}|$phone');
      }
      for (final r in await txn.rawQuery(
          'SELECT account_name, bank_name, currency FROM ${BusinessLedger._accounts} WHERE branch_id = ? AND closed_us IS NULL',
          [branch])) {
        out.add('account|${fold('${r['account_name']}')}|${fold('${r['bank_name']}')}');
        // FYONA keeps one account per bank and currency (the import's type).
        out.add('bank|${fold('${r['bank_name']}')}|${r['currency']}');
      }
      for (final r in await txn.rawQuery(
          'SELECT name, barcode, sku FROM $_commerceProducts WHERE branch_id = ? AND deleted_us IS NULL', [branch])) {
        out.add('product|${fold('${r['name']}')}');
        if (r['barcode'] != null && '${r['barcode']}'.isNotEmpty) {
          out
            ..add('product|${r['barcode']}')
            ..add('code|${r['barcode']}');
        }
        if (r['sku'] != null && '${r['sku']}'.isNotEmpty) out.add('sku|${r['sku']}');
      }
      // Every barcode in use (units and extra codes too): FYONA keeps one
      // barcode for one thing in a branch.
      for (final r in await txn.rawQuery(
          'SELECT barcode FROM $_commerceUnits WHERE branch_id = ? AND barcode IS NOT NULL '
          'UNION SELECT barcode FROM $_commerceBarcodes WHERE branch_id = ?',
          [branch, branch])) {
        if ('${r['barcode']}'.isNotEmpty) out.add('code|${r['barcode']}');
      }
      return out;
    });
  }
}
