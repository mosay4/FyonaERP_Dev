import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../support/personal_ledger_test_support.dart';

/// Regression test for the debt-delete resurrection bug:
///
/// Deleting a row online showed success, but the row came back — the
/// background server refresh re-inserted it because the pending-DELETE
/// protection only covered rows that still had a local mirror row.
/// A staged (unconfirmed) DELETE must keep its id out of every
/// server-snapshot merge path until the replay confirms it.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    try {
      await DatabaseHelper.close();
    } catch (_) {}
    final path = '${await getDatabasesPath()}/fyona_erp.db';
    final db = await databaseFactory.openDatabase(path);
    await resetPersonalLedger();
    await db.close();
  });

  tearDown(() async {
    try {
      await DatabaseHelper.close();
    } catch (_) {}
  });

  const userId = 11;
  const entity = 'personal_debt';
  final cache = PersonalCacheRepository();

  /// Mirror the offline delete: drop the mirror row, stage a DELETE op.
  Future<void> stageOfflineDelete(String id) async {
    await cache.removeItem(userId, entity, id);
    await cache.enqueue(userId, entity, id, 'DELETE');
  }

  Map<String, dynamic> serverRow(String id) => {'id': id, 'person_name': 'Test'};

  group('pending DELETE hides rows from server snapshots', () {
    test('replaceCollection does not re-insert a deleted row', () async {
      await cache.upsertItem(userId, entity, 'd1', serverRow('d1'));
      await stageOfflineDelete('d1');

      // Server still has the row (DELETE not replayed yet).
      await cache.replaceCollection(userId, entity, [serverRow('d1'), serverRow('d2')]);

      final rows = await cache.getCollection(userId, entity);
      expect(rows.map((e) => e['id']), ['d2']);
    });

    test('mergePendingInto drops deleted rows from the returned list', () async {
      await stageOfflineDelete('d9');

      final merged = await cache.mergePendingInto(
        userId,
        entity,
        [serverRow('d9'), serverRow('d8')],
      );
      expect(merged.map((e) => e['id']), ['d8']);
    });

    test('control: without a DELETE op the server row is kept', () async {
      await cache.replaceCollection(userId, entity, [serverRow('k1')]);
      final rows = await cache.getCollection(userId, entity);
      expect(rows.map((e) => e['id']), ['k1']);

      final merged = await cache.mergePendingInto(userId, entity, [serverRow('k1')]);
      expect(merged.map((e) => e['id']), ['k1']);
    });
  });
}
