part of 'directory_database.dart';

const _openingProjectionReceipts = 'business_opening_projection_receipts';
const _importedOpeningPayments = 'business_imported_opening_payments';

/// A fixture-only transaction for the banking and opening-debt slice. Ordinary
/// invoices, returns, inventory and linked parties are not authorized by it.
extension BusinessCutoverFixtureOpeningLedger on DirectoryDatabase {
  Future<BusinessCutoverReceipt> projectFixtureOpeningLedger(
    DirectoryAccess access,
    BusinessCutoverReceipt expected,
  ) {
    BusinessCutoverFixtureArchive(this)._checkFixture(access);
    return _transaction(
      (txn) => _projectOpeningLedger(txn, access, expected),
      exclusive: true,
    );
  }

  static Future<BusinessCutoverReceipt> _projectOpeningLedger(
    Transaction txn,
    DirectoryAccess access,
    BusinessCutoverReceipt expected,
  ) async {
    final branch = access.branchId;
    _requireFixture(
      await BusinessCutoverFixtureArchive._receipt(txn, branch) == expected,
    );
    final prior = await _projectionReceipt(
      txn,
      _openingProjectionReceipts,
      branch,
    );
    if (prior != null) {
      _requireFixture(prior == expected);
      return expected;
    }
    // No merging with an already projected banking branch or on-device directory.
    for (final table in [
      _bankProjections,
      DirectoryDatabase._table,
      DirectoryDatabase._groupTable,
      BusinessLedger._debts,
    ]) {
      _requireFixture(
        (await txn.query(
          table,
          columns: ['branch_id'],
          where: 'branch_id = ?',
          whereArgs: [branch],
          limit: 1,
        )).isEmpty,
      );
    }
    await BusinessCutoverFixtureBanking._projectBanking(txn, branch, expected);
    await _writeOpeningProjection(txn, access, expected);
    await _saveProjectionReceipt(
      txn,
      _openingProjectionReceipts,
      branch,
      expected,
    );
    return expected;
  }
}

Future<void> _writeOpeningProjection(
  Transaction txn,
  DirectoryAccess access,
  BusinessCutoverReceipt receipt,
) async {
  final branch = access.branchId;
  Future<List<Map<String, Object?>>> source(String name) =>
      BusinessCutoverFixtureArchive._sourceRows(txn, branch, name);
  final people = <Map<String, Object?>>[];
  final deleted = <Map<String, Object?>>[];
  final partyScopes = <(String, String)>{};
  for (final kind in DirectoryPartyKind.values) {
    for (final party in await source('${kind.name}s')) {
      final id = _fixtureId(party['id']);
      final name = _fixtureText(party['name']);
      final email = _fixtureOptionalText(party['email']);
      _openingRequire(party['branch_id'] == branch && name.trim().isNotEmpty);
      partyScopes.add((kind.name, id));
      people.add({
        'branch_id': branch,
        'id': id,
        'kind': kind.name,
        'name': name,
        'folded_name': name.toLowerCase(),
        'phone': _fixtureOptionalText(party['phone']),
        'email': email,
        'folded_email': email?.toLowerCase(),
        'created_us': _fixtureTime(party['created_at']),
        'origin': 'fixture',
      });
      if (_fixtureBool(party['is_deleted'])) {
        deleted.add({
          'branch_id': branch,
          'kind': kind.name,
          'party_id': id,
          'deleted_us': _fixtureTime(party['deleted_at']),
        });
      }
    }
  }
  final folders = <Map<String, Object?>>[];
  final folderScopes = <String, (String, String)>{};
  for (final row in await source('debt_groups')) {
    final id = _fixtureId(row['id']);
    final key = (_fixtureText(row['party_kind']), _fixtureId(row['party_id']));
    final groupKind = _fixtureText(row['kind']);
    final name = _fixtureText(row['name']);
    _openingRequire(
      partyScopes.contains(key) &&
          const {'auto', 'manual'}.contains(groupKind) &&
          name.trim().isNotEmpty,
    );
    folderScopes[id] = key;
    folders.add({
      'branch_id': branch,
      'id': id,
      'kind': key.$1,
      'party_id': key.$2,
      'name': name,
      'group_kind': groupKind,
      'period': _fixtureOptionalText(row['period']),
      'created_us': _fixtureTime(row['created_at']),
    });
  }

  final debts = <Map<String, Object?>>[];
  final payments = <Map<String, Object?>>[];
  final edits = <Map<String, Object?>>[];
  final numbers = <String>{};
  final opened = [
    for (final row in await source('invoices'))
      if (_fixtureText(row['invoice_number']).startsWith('OPEN-')) row,
  ];
  final ids = opened.map((row) => _fixtureId(row['id'])).toSet();
  final items = _byOpening(await source('invoice_items'), ids);
  final parts = _byOpening(await source('payments'), ids);
  final history = _byOpening(await source('invoice_item_changes'), ids);
  final receivables = _byOpening(await source('customer_receivables'), ids);
  final payables = _byOpening(await source('supplier_payables'), ids);
  // Returns on a service opening are not representable in this slice.
  for (final table in ['invoice_returns', 'purchase_returns']) {
    _openingRequire(_byOpening(await source(table), ids).isEmpty);
  }
  final accountCurrencies = {
    for (final row in await txn.query(
      BusinessLedger._accounts,
      columns: ['id', 'currency'],
      where: 'branch_id = ?',
      whereArgs: [branch],
    ))
      row['id'] as String: row['currency'] as String,
  };
  for (final invoice in opened) {
    final id = _fixtureId(invoice['id']);
    final number = _fixtureText(invoice['invoice_number']);
    final supplier = invoice['invoice_type'] == 'purchase';
    final kind = supplier ? 'supplier' : 'customer';
    final party = _fixtureId(invoice['${kind}_id']);
    final key = (kind, party);
    final folder = _fixtureOptionalId(invoice['debt_group_id']);
    final currency = _fixtureCurrency(invoice['currency']);
    final total = _fixtureMinor(invoice['total']);
    final paid = _fixtureMinor(invoice['paid_amount']);
    final remaining = _fixtureMinor(invoice['balance']);
    final cancelled = _fixtureBool(invoice['is_deleted']);
    final status = invoice['status'];
    _openingRequire(
      numbers.add(number) &&
          partyScopes.contains(key) &&
          invoice['invoice_type'] == (supplier ? 'purchase' : 'sale') &&
          invoice[supplier ? 'customer_id' : 'supplier_id'] == null &&
          (folder == null || folderScopes[folder] == key) &&
          invoice['notes'] == BusinessOpeningDebts._openingLabel &&
          total >= 0 &&
          paid >= 0 &&
          remaining == max(0, total - paid) &&
          _fixtureMinor(invoice['subtotal']) == total &&
          _fixtureMinor(invoice['tax_amount']) == 0 &&
          _fixtureMinor(invoice['discount_amount']) == 0,
    );
    _openingRequire(
      status ==
          (cancelled
              ? 'cancelled'
              : remaining == 0
              ? 'paid'
              : paid == 0
              ? 'confirmed'
              : 'partially_paid'),
    );

    final line = items[id]?.singleOrNull;
    _openingRequire(line != null);
    final item = line!;
    final itemId = _fixtureId(item['id']);
    final price = _fixtureMinor(item['unit_price']);
    final quantity = _openingQuantity(item['quantity']);
    _openingRequire(
      item['is_service'] == true &&
          item['description'] == BusinessOpeningDebts._openingLabel &&
          item['product_id'] == null &&
          item['unit_id'] == null &&
          _fixtureMinor(item['discount']) == 0 &&
          _fixtureMinor(item['tax_rate']) == 0 &&
          _fixtureMinor(item['total']) == total &&
          BusinessOpeningDebtLine(
                quantity,
                BusinessMoney.display(price),
              ).totalMinor ==
              total,
    );

    final wrongPartyLedger = supplier ? receivables[id] : payables[id];
    final matching = supplier ? payables[id] : receivables[id];
    final legacyDebt = matching?.singleOrNull;
    _openingRequire(
      wrongPartyLedger == null &&
          (cancelled ? matching == null : legacyDebt != null),
    );
    String? receivableId;
    if (legacyDebt != null) {
      receivableId = _fixtureId(legacyDebt['id']);
      final legacyPaid = _fixtureMinor(legacyDebt['paid']);
      _openingRequire(
        legacyDebt['${kind}_id'] == party &&
            legacyPaid == paid &&
            _fixtureMinor(legacyDebt['amount']) - legacyPaid == remaining &&
            legacyDebt['status'] ==
                (remaining == 0
                    ? 'paid'
                    : paid == 0
                    ? 'open'
                    : 'partial'),
      );
    }
    var applied = 0;
    for (final part in parts[id] ?? const []) {
      _openingRequire(!cancelled);
      final payment = _cutoverPayment(
        part,
        branch,
        id,
        currency,
        accountCurrencies,
        requireCurrentCurrency: true,
      );
      applied = BusinessMoney.checked(
        applied + (payment['applied_minor'] as int),
      );
      payments.add(payment);
    }
    _openingRequire(cancelled || applied == paid);

    var revision = 0;
    String? lastQuantity;
    int? lastPrice;
    final changes =
        [
          for (final change in history[id] ?? const [])
            (
              changeId: _fixtureId(change['id']),
              changedUs: _fixtureTime(change['changed_at']),
              data: change,
            ),
        ]..sort((a, b) {
          final order = a.changedUs.compareTo(b.changedUs);
          return order == 0 ? a.changeId.compareTo(b.changeId) : order;
        });
    for (final change in changes) {
      final row = change.data;
      // This fixture represents the owner only; do not falsely attribute an
      // unknown/staff revision to the owner on the original operation screen.
      _openingRequire(
        row['item_id'] == itemId &&
            row['changed_by'] == access.workspace.accountId &&
            row['description'] == item['description'],
      );
      final oldQuantity = _optionalQuantity(row['old_quantity']);
      final newQuantity = _optionalQuantity(row['new_quantity']);
      final oldPrice = _optionalMinor(row['old_unit_price']);
      final newPrice = _optionalMinor(row['new_unit_price']);
      _openingRequire(
        (oldQuantity == null) == (newQuantity == null) &&
            (oldPrice == null) == (newPrice == null) &&
            (newQuantity != null || newPrice != null),
      );
      if (oldQuantity != null) {
        _openingRequire(lastQuantity == null || oldQuantity == lastQuantity);
        lastQuantity = newQuantity;
      }
      if (oldPrice != null) {
        _openingRequire(
          (lastPrice == null || oldPrice == lastPrice) &&
              oldPrice >= 0 &&
              newPrice! >= 0,
        );
        lastPrice = newPrice;
      }
      edits.add({
        'branch_id': branch,
        'command_id': change.changeId,
        'invoice_id': id,
        'revision': ++revision,
        'account_id': access.workspace.accountId,
        'old_quantity': oldQuantity,
        'new_quantity': newQuantity,
        'old_unit_minor': oldPrice,
        'new_unit_minor': newPrice,
        'created_us': change.changedUs,
      });
    }
    _openingRequire(
      (lastQuantity == null || lastQuantity == quantity) &&
          (lastPrice == null || lastPrice == price),
    );
    debts.add({
      'branch_id': branch,
      'id': id,
      'kind': kind,
      'party_id': party,
      'group_id': folder,
      'invoice_date': _fixtureDate(invoice['invoice_date']),
      'number': number,
      'currency': currency,
      'total_minor': total,
      'paid_minor': paid,
      'created_us': _fixtureTime(invoice['created_at']),
      'opening_quantity': quantity,
      'opening_unit_minor': price,
      'opening_item_id': itemId,
      'legacy_receivable_id': receivableId,
      'revision': revision,
      'cancelled_us': cancelled
          ? _fixtureTime(invoice['cancelled_at'] ?? invoice['deleted_at'])
          : null,
    });
  }

  final projections = [
    (DirectoryDatabase._table, ['kind', 'id'], people),
    (DirectoryDatabase._deleted, ['kind', 'party_id'], deleted),
    (DirectoryDatabase._groupTable, ['id'], folders),
    (BusinessLedger._debts, ['id'], debts),
    (_importedOpeningPayments, ['id'], payments),
    (BusinessOpeningDebts._edits, ['command_id'], edits),
  ];
  final batch = txn.batch();
  for (final id in [
    for (final edit in edits) edit['command_id'],
    for (final payment in payments) payment['id'],
  ]) {
    batch.insert(BusinessLedger._commands, {
      'branch_id': branch,
      'id': id,
      // Reserve source IDs without treating the old payment as a new post.
      'fingerprint': 'cutover:${receipt.digest}',
      'result': jsonEncode({'id': id}),
    });
  }
  for (final (table, _, rows) in projections) {
    for (final row in rows) {
      batch.insert(table, row);
    }
  }
  await batch.commit(noResult: true);
  for (final (table, keys, rows) in projections) {
    await _verifyCutoverRows(txn, branch, table, keys, rows);
  }
}

Map<String, Object?> _cutoverPayment(
  Map<String, Object?> row,
  String branch,
  String invoice,
  String debtCurrency,
  Map<String, String> accountCurrencies, {
  bool requireCurrentCurrency = false,
}) {
  final method = _fixtureText(row['payment_method']);
  final account = _fixtureOptionalId(row['bank_account_id']);
  final applied = _fixtureMinor(row['amount']);
  final cur = _fixtureCurrency(row['payment_currency'] ?? debtCurrency);
  final rate = BusinessRate(
    cur,
    debtCurrency,
    _optionalExactRate(row['exchange_rate']) ?? '1',
  );
  final original = _fixtureMinor(row['original_amount'] ?? row['amount']);
  _openingRequire(
    const {'cash', 'bank', 'card', 'transfer', 'cheque'}.contains(method) &&
        applied > 0 &&
        original >= 0 &&
        (row['invoice_currency'] == null ||
            row['invoice_currency'] == debtCurrency) &&
        (row['equivalent_amount'] == null ||
            _fixtureMinor(row['equivalent_amount']) == applied) &&
        (account == null ||
            (accountCurrencies.containsKey(account) &&
                (!requireCurrentCurrency ||
                    accountCurrencies[account] == cur))) &&
        (cur != debtCurrency || original == applied) &&
        (cur == debtCurrency ||
            (row['exchange_rate'] != null && row['original_amount'] != null)),
  );
  return {
    'branch_id': branch,
    'id': _fixtureId(row['id']),
    'invoice_id': invoice,
    'account_id': account,
    'method': method,
    'date': _fixtureDate(row['payment_date']),
    'payment_currency': cur,
    'debt_currency': debtCurrency,
    'exchange_rate': rate.decimal,
    'original_minor': original,
    'applied_minor': applied,
    'created_us': _fixtureTime(row['created_at']),
  };
}

Map<String, List<Map<String, Object?>>> _byOpening(
  List<Map<String, Object?>> rows,
  Set<String> ids,
) {
  final indexed = <String, List<Map<String, Object?>>>{};
  for (final row in rows) {
    final id = _fixtureOptionalId(row['invoice_id']);
    if (id != null && ids.contains(id)) {
      (indexed[id] ??= []).add(row);
    }
  }
  return indexed;
}

void _openingRequire(bool valid) => _requireFixture(valid);

String _openingQuantity(Object? raw) {
  _openingRequire(raw is int || raw is String);
  return BusinessOpeningDebtLine('$raw', '0').quantity;
}

String? _optionalQuantity(Object? value) =>
    value == null ? null : _openingQuantity(value);
