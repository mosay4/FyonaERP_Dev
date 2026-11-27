import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/backup/backup_bridges.dart';
import 'package:fyona_flutter/core/backup/backup_crypto.dart';
import 'package:fyona_flutter/core/backup/backup_engine.dart';
import 'package:fyona_flutter/core/backup/backup_worker.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/core_business/data/local_commerce/local_commerce_api.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../support/directory_test_keys.dart';

String _id() => const Uuid().v4();

/// Every app table, row by row (the backup log itself excluded).
Future<Map<String, List<Map<String, Object?>>>> dumpAll(Database db) async {
  final out = <String, List<Map<String, Object?>>>{};
  final tables = await db.rawQuery(
      "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name <> '_bk_changes' ORDER BY name");
  for (final t in tables) {
    final n = '${t['name']}';
    out[n] = await db.rawQuery('SELECT * FROM "$n" ORDER BY 1, 2');
  }
  return out;
}

void main() {
  if (!DirectoryPilotBuild.signupEnabled) return;
  final workspace = DirectoryWorkspace(server: DirectoryPilotBuild.baseUrl, accountId: _id(), organizationId: _id());
  final access = DirectoryAccess(workspace: workspace, branchId: _id(),
      readable: DirectoryPartyKind.values.toSet(), writable: DirectoryPartyKind.values.toSet(), financialCutover: true);
  late Directory root;
  late FixtureDirectoryKeys keys;
  late DirectoryPilotStore store;
  final client = ApiClient(dio: Dio());

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fyona-bk-real-');
    keys = FixtureDirectoryKeys();
    store = DirectoryPilotStore(root: () async => root, keys: keys);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  test('business ledger: real app operations with live capture, encrypted restore is identical', () async {
    await store.remember(access, {
      'status': 'active', 'business_setup_completed': true,
      'sections': {'business': {'active': true, 'end_date': DateTime.now().add(const Duration(days: 1)).toIso8601String()}},
    });
    final grant = BusinessLedgerAccess(access, BusinessLedgerAction.values.toSet());
    await store.withLedger(grant, () => access, (l) => l.createAccount(grant, commandId: _id(),
        bankName: 'Cash', accountName: 'Till', accountNumber: '1', currency: 'SAR', openingMinor: 150000));
    await store.add(access, DirectoryPartyKind.customer, name: 'عميل أول');
    final customer = (await store.search(access, DirectoryPartyKind.customer, 'عميل أول')).single;
    final inventory = LocalInventoryApi(client, LocalCommerceBridge(store, () => access, (_) => true));
    final sales = LocalSalesApi(client, LocalCommerceBridge(store, () => access, (_) => true));
    final products = <Map>[];
    for (var i = 0; i < 40; i++) {
      products.add(await inventory.createProduct({'name': 'منتج $i', 'unit': 'قطعة', 'price': 10.0 + i, 'stock': 50}));
    }
    Future<void> sell(int i, int qty) => sales.issueSale({
          'currency': 'SAR', 'customer_id': customer.id, 'idempotency_key': _id(),
          'items': [{'product_id': products[i]['id'], 'description': 'x', 'quantity': qty, 'unit_price': 10.0 + i, 'discount': 0}],
        });
    await sell(1, 2);

    final path = DirectoryDatabase.filePath(root, workspace);
    final dbKey = keys.memory[workspace.storageId]!;
    final key = await BackupKeys.newKey();
    final keyBytes = await BackupKeys.keyBytes(key);
    final local = '${root.path}/backups';
    var state = <String, dynamic>{};
    Future<void> backup() async {
      final r = await runBackupJob(BackupJob(dbPath: path, dbKeyHex: dbKey, backupKey: keyBytes, wrappedKey: const {},
          scope: 'business:test', localRoot: local, state: state));
      expect(r.error, isNull);
      state = r.state;
    }

    await backup(); // installs live capture into the real ledger
    // The app keeps working normally with capture in place.
    await sell(2, 3);
    await sell(3, 1);
    await inventory.updateProduct('${products[4]['id']}', {'name': 'منتج معدل', 'price': 99.5});
    await store.add(access, DirectoryPartyKind.supplier, name: 'مورد');
    // The old (v1) per-branch backup still works next to the new capture.
    await store.withLedger(grant, () => access, (l) => l.captureBackup(grant,
        id: _id(), destination: File('${root.path}/v1.fybackup'), code: BusinessBackupCode.generate(), allowed: () => true));
    await backup();

    final restored = '${root.path}/restored.sqlite';
    final outcome = await runRestoreJob(setRoot: local, backupId: state['id'] as String, backupKey: keyBytes,
        targetPath: restored, dbKeyHex: dbKey);
    expect(outcome.problems, isEmpty);

    final live = await openLedgerFile(path, dbKey);
    final back = await openLedgerFile(restored, dbKey);
    final a = await dumpAll(live), b = await dumpAll(back);
    expect(b.keys, a.keys);
    for (final t in a.keys) {
      expect(b[t], a[t], reason: 'table $t');
    }
    // Restored file is encrypted: unreadable without the key.
    final plain = await databaseFactoryFfi.openDatabase(restored, options: OpenDatabaseOptions(singleInstance: false));
    await expectLater(plain.rawQuery('SELECT count(*) FROM sqlite_master'), throwsA(anything));
    await plain.close();
    // ignore: avoid_print
    print('REAL_LEDGER tables=${a.length} rows=${a.values.fold<int>(0, (s, r) => s + r.length)}');
    await live.close();
    await back.close();
    expect(BackupEngine.changes, '_bk_changes');

    // New device: an empty ledger for the same branch gets the verified copy
    // through the app's own branch restore (v1 safety rules apply).
    final root2 = await Directory.systemTemp.createTemp('fyona-bk-newdevice-');
    final store2 = DirectoryPilotStore(root: () async => root2, keys: FixtureDirectoryKeys());
    try {
      await store2.remember(access, {
        'status': 'active', 'business_setup_completed': true,
        'sections': {'business': {'active': true, 'end_date': DateTime.now().add(const Duration(days: 1)).toIso8601String()}},
      });
      final copy2 = '${root.path}/copy-for-new-device.sqlite';
      expect((await runRestoreJob(setRoot: local, backupId: state['id'] as String, backupKey: keyBytes,
          targetPath: copy2, dbKeyHex: dbKey)).problems, isEmpty);
      final applied = await BackupBridges.applyBusiness(
          copyPath: copy2, dbKeyHex: dbKey, access: access, live: store2, allowed: () => true);
      expect(applied.alreadyRestored, isFalse);
      final inv2 = LocalInventoryApi(client, LocalCommerceBridge(store2, () => access, (_) => true));
      final sales2 = LocalSalesApi(client, LocalCommerceBridge(store2, () => access, (_) => true));
      final listed = await inv2.listProducts();
      expect(listed.length, 40);
      expect(listed.any((p) => p['name'] == 'منتج معدل'), isTrue);
      expect((await sales2.saleInvoices()).length, (await sales.saleInvoices()).length);
      final stock = {for (final p in await inventory.listProducts()) p['id']: p['stock']};
      for (final p in listed) {
        expect(p['stock'], stock[p['id']], reason: 'stock of ${p['name']}');
      }
      // A second restore into a branch that now has data is refused.
      final copy3 = '${root.path}/copy-again.sqlite';
      await runRestoreJob(setRoot: local, backupId: state['id'] as String, backupKey: keyBytes,
          targetPath: copy3, dbKeyHex: dbKey);
      await expectLater(BackupBridges.applyBusiness(
          copyPath: copy3, dbKeyHex: dbKey, access: access, live: store2, allowed: () => true), throwsA(anything));
    } finally {
      await store2.close();
      await root2.delete(recursive: true);
    }
  });
}
