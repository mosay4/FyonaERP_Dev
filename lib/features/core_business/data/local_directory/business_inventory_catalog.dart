part of 'directory_database.dart';

const _commerceCategories = 'business_commerce_categories';
const _commerceCategoryLinks = 'business_commerce_category_links';
const _commerceCatalogue = 'business_commerce_catalogue';
const _inventoryCatalogTables = [
  _commerceCatalogue,
  _commerceCategories,
  _commerceCategoryLinks,
];

Future<void> _createBusinessInventoryCatalog(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_commerceCatalogue (
      branch_id TEXT PRIMARY KEY,
      expiry_enabled INTEGER,
      expiry_warn_days INTEGER,
      CHECK ((expiry_enabled IS NULL AND expiry_warn_days IS NULL) OR
             (expiry_enabled IS NOT NULL AND expiry_enabled IN (0,1) AND
              expiry_warn_days IS NOT NULL AND expiry_warn_days BETWEEN 1 AND 365))
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_commerceCategories (
      branch_id TEXT NOT NULL, id TEXT NOT NULL,
      name TEXT NOT NULL, image TEXT,
      active INTEGER NOT NULL CHECK (active IN (0,1)),
      PRIMARY KEY (branch_id, id),
      FOREIGN KEY (branch_id) REFERENCES $_commerceCatalogue (branch_id)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_commerceCategoryLinks (
      branch_id TEXT NOT NULL, id TEXT NOT NULL, category_id TEXT NOT NULL,
      PRIMARY KEY (branch_id, id),
      FOREIGN KEY (branch_id, id) REFERENCES $_commerceProducts (branch_id, id),
      FOREIGN KEY (branch_id, category_id) REFERENCES $_commerceCategories (branch_id, id)
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS business_commerce_category_products
    ON $_commerceCategoryLinks (branch_id, category_id, id)
  ''');
}

final class SharedCatalogReadOnly implements Exception {
  const SharedCatalogReadOnly();
}

typedef BusinessWarehouseExpiry = ({bool enabled, int warnDays});

extension BusinessInventoryCatalog on BusinessLedger {
  Future<List<Map<String, dynamic>>> commerceCategories(
    BusinessLedgerAccess access,
  ) {
    final branch = _branch(access, BusinessLedgerAction.readInventory);
    return _directory._read(
      (db) async => [
        for (final row in await db.rawQuery(
          '''
        SELECT c.id, c.name, c.image, c.active, COUNT(p.id) AS products_count
        FROM $_commerceCategories c LEFT JOIN $_commerceCategoryLinks x
          ON x.branch_id = c.branch_id AND x.category_id = c.id
        LEFT JOIN $_commerceProducts p ON p.branch_id = x.branch_id AND p.id = x.id
          AND p.deleted_us IS NULL
        WHERE c.branch_id = ?
        GROUP BY c.id ORDER BY c.name, c.id
        ''',
          [branch],
        ))
          {
            'id': row['id'],
            'name': row['name'],
            'image': _deviceInventoryImage(row['image']),
            'is_active': row['active'] == 1,
            'products_count': row['products_count'],
          },
      ],
    );
  }

  Future<bool> hasInventoryCatalogue(BusinessLedgerAccess access) {
    final branch = _branch(access, BusinessLedgerAction.readInventory);
    return _directory._read((db) => _hasInventoryCatalogue(db, branch));
  }

  Future<void> classifyCommerceProducts(
    BusinessLedgerAccess access, {
    required String commandId,
    required List<String> productIds,
    required String? categoryId,
    required String? expectedCategory,
    required bool requireExpected,
    bool Function()? allowed,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageProducts);
    final ids = productIds.toSet().toList()..sort();
    if (ids.isEmpty || ids.length > 500 || ids.length != productIds.length) {
      throw const DirectoryAccessDenied();
    }
    return _commit(
      branch,
      commandId,
      [
        'branch_product_classification',
        ids,
        categoryId,
        expectedCategory,
        requireExpected,
      ],
      (txn, _) async {
        for (final id in ids) {
          await _commerceProductRow(txn, branch, id);
          if (requireExpected &&
              await _productCategoryId(txn, branch, id) != expectedCategory) {
            throw const DirectoryAccessDenied();
          }
          await _setProductCategory(txn, branch, id, categoryId);
        }
        return {'count': ids.length};
      },
      allowed: allowed,
    );
  }

  /// Categories belong to this branch's own inventory, like its products.
  Future<Map<String, Object?>> createCommerceCategory(
    BusinessLedgerAccess access, {
    required String commandId,
    required String name,
    bool Function()? allowed,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageProducts);
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 120) throw const DirectoryAccessDenied();
    return _commit(branch, commandId, ['branch_category_create', clean], (txn, _) async {
      await _ensureCatalogue(txn, branch);
      await txn.insert(_commerceCategories, {
        'branch_id': branch, 'id': commandId, 'name': clean, 'image': null, 'active': 1,
      });
      return {'id': commandId, 'name': clean, 'is_active': true, 'products_count': 0};
    }, allowed: allowed);
  }

  Future<Map<String, Object?>> renameCommerceCategory(
    BusinessLedgerAccess access, {
    required String commandId,
    required String id,
    required String name,
    bool Function()? allowed,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageProducts);
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 120) throw const DirectoryAccessDenied();
    return _commit(branch, commandId, ['branch_category_rename', id, clean], (txn, _) async {
      await _commerceCategory(txn, branch, id);
      await txn.update(_commerceCategories, {'name': clean},
          where: 'branch_id = ? AND id = ?', whereArgs: [branch, id]);
      return {'id': id, 'name': clean};
    }, allowed: allowed);
  }

  /// The products stay; they just become uncategorized.
  Future<Map<String, Object?>> deleteCommerceCategory(
    BusinessLedgerAccess access, {
    required String commandId,
    required String id,
    bool Function()? allowed,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageProducts);
    return _commit(branch, commandId, ['branch_category_delete', id], (txn, _) async {
      await _commerceCategory(txn, branch, id);
      await txn.delete(_commerceCategoryLinks,
          where: 'branch_id = ? AND category_id = ?', whereArgs: [branch, id]);
      await txn.delete(_commerceCategories,
          where: 'branch_id = ? AND id = ?', whereArgs: [branch, id]);
      return {'id': id, 'deleted': true};
    }, allowed: allowed);
  }

  /// This branch's own expiry setting (never another branch's).
  Future<Map<String, Object?>> setWarehouseExpiry(
    BusinessLedgerAccess access, {
    required String commandId,
    required bool enabled,
    required int warnDays,
    bool Function()? allowed,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageProducts);
    if (warnDays < 1 || warnDays > 365) throw const DirectoryAccessDenied();
    return _commit(branch, commandId, ['branch_expiry', enabled, warnDays], (txn, _) async {
      await _ensureCatalogue(txn, branch);
      await txn.update(_commerceCatalogue,
          {'expiry_enabled': enabled ? 1 : 0, 'expiry_warn_days': warnDays},
          where: 'branch_id = ?', whereArgs: [branch]);
      return {'enabled': enabled, 'warn_days': warnDays};
    }, allowed: allowed);
  }

  Future<BusinessWarehouseExpiry?> warehouseExpiry(
    BusinessLedgerAccess access,
  ) {
    final branch = _branch(access, BusinessLedgerAction.readInventory);
    return _directory._read((db) => _warehouseExpiry(db, branch));
  }
}

Future<BusinessWarehouseExpiry?> _warehouseExpiry(
  DatabaseExecutor db,
  String branch,
) async {
  final row = (await db.query(
    _commerceCatalogue,
    where: 'branch_id = ?',
    whereArgs: [branch],
  )).singleOrNull;
  return row == null || row['expiry_warn_days'] == null
      ? null
      : (
          enabled: row['expiry_enabled'] == 1,
          warnDays: row['expiry_warn_days'] as int,
        );
}

Future<void> _ensureCatalogue(DatabaseExecutor db, String branch) => db.insert(
  _commerceCatalogue,
  {'branch_id': branch, 'expiry_enabled': null, 'expiry_warn_days': null},
  conflictAlgorithm: ConflictAlgorithm.ignore,
);

Future<bool> _hasInventoryCatalogue(DatabaseExecutor db, String branch) async =>
    (await db.query(
      _commerceCatalogue,
      columns: ['branch_id'],
      where: 'branch_id = ?',
      whereArgs: [branch],
    )).isNotEmpty;

Future<int?> _reportCategoryCount(DatabaseExecutor db, String branch) async {
  if (!await _hasInventoryCatalogue(db, branch)) return null;
  return (await db.rawQuery(
        'SELECT COUNT(*) AS n FROM $_commerceCategories WHERE branch_id = ?',
        [branch],
      )).single['n']
      as int;
}

Future<_CommerceRow> _commerceCategory(
  DatabaseExecutor db,
  String branch,
  String id,
) async {
  if (!isDirectoryId(id)) throw const DirectoryAccessDenied();
  return (await db.query(
        _commerceCategories,
        where: 'branch_id = ? AND id = ?',
        whereArgs: [branch, id],
      )).singleOrNull ??
      (throw const DirectoryAccessDenied());
}

Future<String?> _productCategoryId(
  DatabaseExecutor db,
  String branch,
  String id,
) async =>
    (await db.query(
          _commerceCategoryLinks,
          columns: ['category_id'],
          where: 'branch_id = ? AND id = ?',
          whereArgs: [branch, id],
        )).singleOrNull?['category_id']
        as String?;

Future<void> _setProductCategory(
  DatabaseExecutor db,
  String branch,
  String product,
  String? category,
) async {
  if (category == null) {
    await db.delete(
      _commerceCategoryLinks,
      where: 'branch_id = ? AND id = ?',
      whereArgs: [branch, product],
    );
    return;
  }
  await _commerceCategory(db, branch, category);
  await db.rawInsert(
    '''
    INSERT INTO $_commerceCategoryLinks (branch_id, id, category_id) VALUES (?, ?, ?)
    ON CONFLICT (branch_id, id) DO UPDATE SET category_id = excluded.category_id
    ''',
    [branch, product, category],
  );
}

const businessInventoryImagePrefix = 'fyona-product-image:';
// Keep reading previously picked photos, but cap new bytes before base64
// expansion so each persisted row fits a standard Android CursorWindow.
const businessInventoryImageMaxBytes = 2 * 1024 * 1024;
const businessInventoryImageWriteMaxBytes = 1024 * 1024;

// Do not turn a legacy URL, filesystem path or another tenant's image cache
// into a local read. The encrypted rows keep the original snapshot as evidence.
String? _deviceInventoryImage(Object? value) =>
    value is String &&
        value.startsWith(businessInventoryImagePrefix) &&
        value.length <=
            businessInventoryImagePrefix.length +
                ((businessInventoryImageMaxBytes + 2) ~/ 3) * 4
    ? value
    : null;

List<int> _checkInventoryImage(String value) {
  if (_deviceInventoryImage(value) == null) {
    throw const FormatException('Invalid inventory image');
  }
  final encoded = value.substring(businessInventoryImagePrefix.length);
  final bytes = base64Decode(encoded);
  _checkInventoryImageBytes(bytes);
  if (base64Encode(bytes) != encoded)
    throw const FormatException('Invalid inventory image');
  return bytes;
}

String encodeBusinessInventoryImage(List<int> bytes) {
  _checkInventoryImageBytes(bytes);
  return '$businessInventoryImagePrefix${base64Encode(bytes)}';
}

void _checkInventoryImageBytes(List<int> bytes) {
  bool starts(List<int> signature) {
    if (bytes.length < signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }

  final valid =
      (starts([255, 216, 255]) &&
          bytes.length >= 5 &&
          bytes[bytes.length - 2] == 255 &&
          bytes.last == 217) ||
      starts([137, 80, 78, 71, 13, 10, 26, 10]) ||
      (starts([82, 73, 70, 70]) &&
          bytes.length > 12 &&
          ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP');
  if (!valid || bytes.length > businessInventoryImageWriteMaxBytes) {
    throw const FormatException('Invalid inventory image');
  }
}
