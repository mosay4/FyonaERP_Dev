import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/startup/retired_business_storage.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'upgrade removes former Business mirror and outbox, not Personal',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final directory = await Directory.systemTemp.createTemp(
        'fyona-db-upgrade-',
      );
      DatabaseHelper.debugDatabasePath = path.join(directory.path, 'test.db');
      addTearDown(() async {
        await DatabaseHelper.close();
        DatabaseHelper.debugDatabasePath = null;
        await directory.delete(recursive: true);
      });

      final db = await DatabaseHelper.database;
      await db.execute('CREATE TABLE customers (id INTEGER PRIMARY KEY)');
      await db.insert('customers', {'id': 1});
      // Rows an older build left in the plain database (Personal now lives
      // in the encrypted ledger, so seed the old tables directly).
      for (final kind in ['customer', 'personal_transaction']) {
        await db.insert('personal_entity_cache', {
          'user_id': 42,
          'entity_type': kind,
          'remote_id': kind,
          'data_json': '{"id":"$kind"}',
        });
        await db.insert('sync_queue', {
          'operation_id': 'op-$kind',
          'table_name': kind,
          'entity_type': kind,
          'entity_id': kind,
          'user_id': 42,
          'operation': 'INSERT',
          'status': 'pending',
        });
      }
      await db.execute('PRAGMA user_version = 15');
      await DatabaseHelper.close();

      final upgraded = await DatabaseHelper.database;
      expect(
        await upgraded.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='customers'",
        ),
        isEmpty,
      );
      for (final table in ['personal_entity_cache', 'sync_queue']) {
        final rows = await upgraded.query(table, columns: ['entity_type']);
        expect(rows.map((row) => row['entity_type']), ['personal_transaction']);
      }
    },
  );

  test(
    'device cleanup only removes known experimental files and keys',
    () async {
      final support = await Directory.systemTemp.createTemp('fyona-retired-');
      final previousPathProvider = PathProviderPlatform.instance;
      final previousTarget = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      PathProviderPlatform.instance = _TestPathProvider(support.path);
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({
        'business_db_key_v1_example': 'old-key',
        'business_device_v1_example': 'old-device',
        'business_device_signing_v1_example': 'old-signer',
        'auth_token': 'keep-token',
      });
      addTearDown(() async {
        debugDefaultTargetPlatformOverride = previousTarget;
        PathProviderPlatform.instance = previousPathProvider;
        await support.delete(recursive: true);
      });

      final former = await Directory(
        path.join(support.path, 'business-offline'),
      ).create();
      final obsolete = File(path.join(former.path, 'business_v1_example.db'));
      final sidecar = File('${obsolete.path}-wal');
      final unrelated = File(path.join(former.path, 'unrelated.txt'));
      final personal = File(path.join(support.path, 'fyona_erp.db'));
      for (final file in [obsolete, sidecar, unrelated, personal]) {
        await file.writeAsString('fixture');
      }
      await removeRetiredBusinessStorage();
      expect(await obsolete.exists(), isFalse);
      expect(await sidecar.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
      expect(await personal.exists(), isTrue);
      expect(await const FlutterSecureStorage().readAll(), {
        'auth_token': 'keep-token',
      });
    },
  );
}

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}
