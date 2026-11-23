part of 'directory_database.dart';

Future<void> _createBusinessCutoverArchive(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE business_cutover_archives (
      branch_id TEXT PRIMARY KEY,
      snapshot_id TEXT NOT NULL,
      digest TEXT NOT NULL CHECK (length(digest) = 64),
      imported_us INTEGER NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE business_cutover_rows (
      branch_id TEXT NOT NULL,
      table_name TEXT NOT NULL,
      id TEXT NOT NULL,
      payload TEXT NOT NULL,
      PRIMARY KEY (branch_id, table_name, id),
      FOREIGN KEY (branch_id) REFERENCES business_cutover_archives (branch_id)
    )
  ''');
}

final class BusinessCutoverImportRejected implements Exception {
  const BusinessCutoverImportRejected();
}

typedef BusinessCutoverReceipt = ({String snapshotId, String digest});

String _fixtureId(Object? value) => BusinessCutoverFixtureArchive._id(value);
String? _fixtureOptionalId(Object? value) =>
    value == null ? null : _fixtureId(value);

bool _fixtureBool(Object? value) =>
    value is bool ? value : throw const BusinessCutoverImportRejected();

String _fixtureText(Object? value) =>
    value is String ? value : throw const BusinessCutoverImportRejected();

String? _fixtureOptionalText(Object? value) =>
    value == null ? null : _fixtureText(value);

String _fixtureCurrency(Object? value) {
  final raw = _fixtureText(value);
  final code = businessCurrency(raw);
  if (raw != code) throw const BusinessCutoverImportRejected();
  return code;
}

int _fixtureMinor(Object? value) =>
    BusinessMoney.checked(BusinessCutoverFixtureArchive._scaled(value, 2));
int? _optionalMinor(Object? value) =>
    value == null ? null : _fixtureMinor(value);

String? _optionalExactRate(Object? value) {
  if (value == null) return null;
  final rate = value is int ? '$value' : _fixtureText(value);
  _requireFixture(
    RegExp(r'^\d{1,10}(?:\.\d{1,8})?$').hasMatch(rate) &&
        RegExp(r'[1-9]').hasMatch(rate),
  );
  return rate;
}

int _fixtureTime(Object? value) {
  final date = value is String ? DateTime.tryParse(value) : null;
  if (date == null || !date.isUtc) throw const BusinessCutoverImportRejected();
  return date.microsecondsSinceEpoch;
}

void _requireFixture(bool valid) {
  if (!valid) throw const BusinessCutoverImportRejected();
}

const _fixtureImageBundleMax = 16 * 1024 * 1024;

/// The outer receipt binds both the scoped row and the independently supplied
/// asset digest. A source URL (even a string starting with our image prefix)
/// is never itself an offline image.
(String?, int) _fixtureInventoryImage(Map<String, Object?> row) {
  final data = _fixtureOptionalText(row['device_image']);
  final digest = row['device_image_sha256'];
  if (data == null) {
    _requireFixture(digest == null);
    return (null, 0);
  }
  _requireFixture(
    _fixtureOptionalText(row['image'])?.trim().isNotEmpty == true,
  );
  try {
    final bytes = _checkInventoryImage(data);
    _requireFixture(sha256.convert(bytes).toString() == digest);
    return (data, bytes.length);
  } on FormatException {
    throw const BusinessCutoverImportRejected();
  }
}

String _fixtureDate(Object? value) {
  final raw = _fixtureText(value);
  final parsed = DateTime.tryParse('${raw}T00:00:00Z');
  _requireFixture(
    parsed != null && parsed.toIso8601String().split('T').first == raw,
  );
  return raw;
}

Future<void> _verifyCutoverRows(
  Transaction txn,
  String branch,
  String table,
  List<String> keys,
  List<Map<String, Object?>> expected,
) async {
  Object? key(Map<String, Object?> row) => switch (keys) {
    [final field] => row[field],
    [final first, final second] => (row[first], row[second]),
    _ => throw ArgumentError.value(keys),
  };
  final byId = {for (final row in expected) key(row): row};
  final actual = await txn.query(
    table,
    columns: expected.isEmpty ? ['branch_id'] : expected.first.keys.toList(),
    where: 'branch_id = ?',
    whereArgs: [branch],
  );
  _requireFixture(
    byId.length == expected.length && actual.length == expected.length,
  );
  for (final row in actual) {
    final match = byId.remove(key(row));
    _requireFixture(
      match != null && match.entries.every((v) => row[v.key] == v.value),
    );
  }
}

Future<BusinessCutoverReceipt?> _projectionReceipt(
  DatabaseExecutor db,
  String table,
  String branch,
) async {
  final row = (await db.query(
    table,
    columns: ['snapshot_id', 'digest'],
    where: 'branch_id = ?',
    whereArgs: [branch],
  )).singleOrNull;
  return row == null
      ? null
      : (
          snapshotId: row['snapshot_id'] as String,
          digest: row['digest'] as String,
        );
}

Future<void> _saveProjectionReceipt(
  Transaction txn,
  String table,
  String branch,
  BusinessCutoverReceipt receipt,
) async {
  await txn.insert(table, {
    'branch_id': branch,
    'snapshot_id': receipt.snapshotId,
    'digest': receipt.digest,
  });
}

/// One-time transfer rehearsal from the legacy Business database. Files and
/// receipts here are synthetic; readiness to use the live ledger is a
/// separate decision. Projection into operational tables is explicit.
extension BusinessCutoverFixtureArchive on DirectoryDatabase {
  static const _fixtureServer = 'https://cutover.example.test/api/v1';
  static const _receipts = 'business_cutover_archives';
  static const _rows = 'business_cutover_rows';
  static const _tables = {
    'branches',
    'customers',
    'suppliers',
    'bank_accounts',
    'bank_transactions',
    'expenses',
    'debt_groups',
    'invoices',
    'invoice_items',
    'invoice_item_changes',
    'payments',
    'customer_receivables',
    'supplier_payables',
    'invoice_returns',
    'invoice_return_items',
    'purchase_returns',
    'purchase_return_items',
    'products',
    'product_units',
    'product_barcodes',
    'product_prices',
    'branch_stock',
    'inventory_lots',
    'inventory_lot_consumptions',
    'inventory_movements',
  };
  static const _catalogue = {'product_categories', 'warehouse_settings'};

  /// [live]: the one-time move of a branch's legacy server data to the
  /// owner's device (business_local_migration on the server). Otherwise only
  /// the synthetic cutover rehearsal server is accepted.
  void _checkFixture(DirectoryAccess access, {bool live = false}) {
    if ((!live && workspace.server != _fixtureServer) ||
        (live && access.member) ||
        access.workspace.storageId != workspace.storageId) {
      throw const DirectoryAccessDenied();
    }
    for (final kind in DirectoryPartyKind.values) {
      _check(access, kind, write: true);
    }
  }

  /// Run only after freezing and an independently supplied digest. Neither
  /// existing on-device parties nor active ledger records are overwritten.
  /// The receipt cannot become visible without every row and its controls.
  Future<BusinessCutoverReceipt> importCutoverFixture(
    DirectoryAccess access, {
    required List<int> payload,
    required String expectedDigest,
    bool live = false,
  }) async {
    _checkFixture(access, live: live);
    if (sha256.convert(payload).toString() != expectedDigest) {
      throw const BusinessCutoverImportRejected();
    }
    final root = _object(jsonDecode(utf8.decode(payload)));
    final version = root['version'];
    if (version is! int ||
        !const {1, 2, 3}.contains(version) ||
        root['server'] != workspace.server ||
        root['organization_id'] != workspace.organizationId ||
        root['account_id'] != workspace.accountId ||
        root['branch_id'] != access.branchId) {
      throw const DirectoryAccessDenied();
    }
    final receipt = (
      snapshotId: _id(root['snapshot_id']),
      digest: expectedDigest,
    );
    final tables = _object(root['tables']);
    final controls = _object(root['controls']);
    final bankPolicy = root['allow_negative'];
    if (version != 1 && bankPolicy is! bool) {
      throw const BusinessCutoverImportRejected();
    }
    final hasCatalogue = version == 3;
    final expected = {..._tables, if (hasCatalogue) ..._catalogue};
    if (tables.length != expected.length ||
        !tables.keys.every(expected.contains)) {
      throw const BusinessCutoverImportRejected();
    }
    final branch = access.branchId;
    return _transaction((txn) async {
      final prior = await _receipt(txn, branch);
      if (prior != null) {
        if (prior != receipt) throw const BusinessCutoverImportRejected();
        return prior;
      }
      await txn.insert(_receipts, {
        'branch_id': branch,
        'snapshot_id': receipt.snapshotId,
        'digest': receipt.digest,
        'imported_us': DateTime.now().toUtc().microsecondsSinceEpoch,
        if (version != 1) 'bank_policy': bankPolicy == true ? 1 : 0,
      });
      final categoryIds = <String>{}, usedCategories = <String>{};
      var imageBytes = 0;
      for (final table in expected) {
        final records = tables[table];
        if (records is! List ||
            (table == 'branches' && records.length != 1) ||
            (table == 'warehouse_settings' && records.length > 1)) {
          throw const BusinessCutoverImportRejected();
        }
        final ids = <String>{};
        final batch = txn.batch();
        for (final raw in records) {
          final row = _object(raw);
          final id = _id(row['id']);
          if (!ids.add(id) ||
              (table == 'branches' && id != branch) ||
              (row['branch_id'] != null && row['branch_id'] != branch) ||
              (hasCatalogue &&
                  (table == 'products' || _catalogue.contains(table)) &&
                  row['organization_id'] != workspace.organizationId) ||
              (row.containsKey('organization_id') &&
                  row['organization_id'] != workspace.organizationId)) {
            throw const BusinessCutoverImportRejected();
          }
          if (table == 'branches') {
            _requireFixture(
              hasCatalogue
                  ? row['device_catalogue'] == true
                  : !row.containsKey('device_catalogue'),
            );
          }
          if (table == 'product_categories') {
            _requireFixture(_fixtureText(row['name']).trim().isNotEmpty);
            _fixtureBool(row['is_active']);
            categoryIds.add(id);
          }
          if (table == 'warehouse_settings') {
            final days = row['expiry_warn_days'];
            _requireFixture(days is int && days >= 1 && days <= 365);
            _fixtureBool(row['expiry_enabled']);
          }
          if (table == 'products') {
            _requireFixture(row['branch_id'] == branch);
            final category = _fixtureOptionalId(row['category_id']);
            if (category != null) usedCategories.add(category);
          }
          if (table == 'products' || table == 'product_categories') {
            if (hasCatalogue) {
              imageBytes += _fixtureInventoryImage(row).$2;
              _requireFixture(imageBytes <= _fixtureImageBundleMax);
            } else {
              _requireFixture(
                !row.containsKey('device_image') &&
                    !row.containsKey('device_image_sha256'),
              );
            }
          }
          batch.insert(_rows, {
            'branch_id': branch,
            'table_name': table,
            'id': id,
            'payload': jsonEncode(row),
          });
        }
        await batch.commit(noResult: true);
      }
      _requireFixture(
        categoryIds.length == usedCategories.length &&
            categoryIds.containsAll(usedCategories),
      );
      final actual = await _cutoverControls(txn, branch);
      if (actual.length != controls.length ||
          actual.entries.any(
            (e) => jsonEncode(e.value) != jsonEncode(controls[e.key]),
          )) {
        throw const BusinessCutoverImportRejected();
      }
      return receipt;
    }, exclusive: true);
  }

  Future<BusinessCutoverReceipt?> cutoverFixtureReceipt(
    DirectoryAccess access, {
    bool live = false,
  }) {
    _checkFixture(access, live: live);
    return _read((db) => _receipt(db, access.branchId));
  }

  Future<Map<String, List<List<Object?>>>> cutoverFixtureControls(
    DirectoryAccess access,
  ) {
    _checkFixture(access);
    return _transaction((txn) async {
      if (await _receipt(txn, access.branchId) == null) {
        throw const BusinessCutoverImportRejected();
      }
      return _cutoverControls(txn, access.branchId);
    });
  }

  static Future<BusinessCutoverReceipt?> _receipt(
    DatabaseExecutor db,
    String branch,
  ) async {
    final rows = await db.query(
      _receipts,
      where: 'branch_id = ?',
      whereArgs: [branch],
    );
    final row = rows.singleOrNull;
    return row == null
        ? null
        : (
            snapshotId: row['snapshot_id'] as String,
            digest: row['digest'] as String,
          );
  }

  static Future<Map<String, List<List<Object?>>>> _cutoverControls(
    DatabaseExecutor db,
    String branch,
  ) async {
    Future<List<List<Object?>>> project(
      String table,
      List<Object?> Function(String, Map<String, Object?>) convert,
    ) async {
      return [
        for (final row in await _sourceRows(db, branch, table))
          convert(row['id'] as String, row),
      ];
    }

    final stock = await project(
      'branch_stock',
      (_, row) => [
        _id(row['product_id']),
        _scaled(row['quantity'], 3),
        _scaled(row['avg_cost'], 4),
      ],
    );
    stock.sort((a, b) => (a.first as String).compareTo(b.first as String));
    return {
      'accounts': await project(
        'bank_accounts',
        (id, row) => [
          id,
          businessCurrency('${row['currency']}'),
          _scaled(row['balance'], 2),
        ],
      ),
      'invoices': await project(
        'invoices',
        (id, row) => [
          id,
          businessCurrency('${row['currency']}'),
          _scaled(row['total'], 2),
          _scaled(row['paid_amount'], 2),
          _scaled(row['balance'], 2),
        ],
      ),
      'stock': stock,
    };
  }

  static Future<List<Map<String, Object?>>> _sourceRows(
    DatabaseExecutor db,
    String branch,
    String table,
  ) async {
    final rows = await db.query(
      _rows,
      columns: ['id', 'payload'],
      where: 'branch_id = ? AND table_name = ?',
      whereArgs: [branch, table],
      orderBy: 'id',
    );
    return rows.map((row) {
      final record = _object(jsonDecode(row['payload'] as String));
      _requireFixture(_id(record['id']) == row['id']);
      return record;
    }).toList();
  }

  static Map<String, Object?> _object(Object? value) {
    if (value is! Map<String, dynamic>)
      throw const BusinessCutoverImportRejected();
    return value;
  }

  static String _id(Object? value) {
    if (value is! String ||
        !isDirectoryId(value) ||
        value != value.toLowerCase()) {
      throw const BusinessCutoverImportRejected();
    }
    return value;
  }

  static int _scaled(Object? value, int places) {
    if (value is! String && value is! int)
      throw const BusinessCutoverImportRejected();
    final match = RegExp(r'^(-?)(\d+)(?:\.(\d+))?$').firstMatch('$value');
    final fraction = (match?[3] ?? '').replaceFirst(RegExp(r'0+$'), '');
    if (match == null || fraction.length > places || match[2]!.length > 15) {
      throw const BusinessCutoverImportRejected();
    }
    final units = BigInt.parse(
      '${match[1]}${match[2]}${fraction.padRight(places, '0')}',
    );
    if (units.abs() > BigInt.from(999999999999999))
      throw const BusinessCutoverImportRejected();
    return units.toInt();
  }
}
