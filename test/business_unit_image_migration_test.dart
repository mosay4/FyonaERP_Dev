import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

void main() {
  test('v17 ledgers gain the unit photo column and keep their units', () async {
    final root = await Directory.systemTemp.createTemp('fyona-unit-image-');
    addTearDown(() => root.delete(recursive: true));
    final workspace = DirectoryWorkspace(
      server: 'https://units.fixture.test/api/v1',
      accountId: _id(),
      organizationId: _id(),
    );
    final scope = DirectoryAccess(
      workspace: workspace,
      branchId: _id(),
      readable: {},
      writable: {},
      financialCutover: true,
    );
    final access = BusinessLedgerAccess(
      scope,
      BusinessLedgerAction.values.toSet(),
    );
    final keys = FixtureDirectoryKeys();
    Future<DirectoryDatabase> open() =>
        DirectoryDatabase.open(root: root, workspace: workspace, keys: keys);

    var db = await open();
    final product = await db.ledger.createCommerceProduct(
      access,
      commandId: _id(),
      name: 'Juice',
      unit: 'قطعة',
      price: 1,
    );
    final carton = await db.ledger.createCommerceUnit(
      access,
      commandId: _id(),
      productId: '${product['id']}',
      name: 'كرتون',
      factor: 24,
      salePrice: 20,
      purchasePrice: 15,
    );
    await db.close();

    // Rebuild the v17 file: the units table without the photo column.
    final raw = await databaseFactoryFfi.openDatabase(
      DirectoryDatabase.filePath(root, workspace),
      options: OpenDatabaseOptions(
        singleInstance: false,
        onConfigure: (sql) async {
          await sql.execute(
            'PRAGMA key = "x\'${keys.memory[workspace.storageId]!}\'"',
          );
        },
      ),
    );
    try {
      await raw.execute(
        'ALTER TABLE business_commerce_units DROP COLUMN image',
      );
      await raw.execute('PRAGMA user_version = 17');
    } finally {
      await raw.close();
    }

    db = await open();
    addTearDown(() => db.close());
    final units = (await db.ledger.commerceProductUnits(
      access,
      '${product['id']}',
    ))['units'] as List;
    final row = units.cast<Map>().singleWhere((u) => u['id'] == carton['id']);
    expect(row['sale_price'], 20);
    expect(row['purchase_price'], 15);
    expect(row['image'], isNull);
    // The upgraded table accepts (and syncs) a unit photo.
    final photo = encodeBusinessInventoryImage([
      137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3,
    ]);
    await db.ledger.setCommerceUnitImage(
      access,
      commandId: _id(),
      productId: '${product['id']}',
      unitId: '${carton['id']}',
      image: photo,
    );
    final after = (await db.ledger.commerceProductUnits(
      access,
      '${product['id']}',
    ))['units'] as List;
    expect(
      after.cast<Map>().singleWhere((u) => u['id'] == carton['id'])['image'],
      photo,
    );
  });
}
