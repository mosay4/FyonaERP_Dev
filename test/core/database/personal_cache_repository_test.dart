import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
    await db.delete('personal_entity_cache');
    await db.delete('sync_queue');
    await db.close();
  });

  tearDown(() async {
    try {
      await DatabaseHelper.close();
    } catch (_) {}
  });

  const userId = 7;
  final cache = PersonalCacheRepository();

  group('offline cache', () {
    test('replaceCollection then getCollection roundtrip per user', () async {
      await cache.replaceCollection(userId, 'personal_transaction', [
        {'id': 'a', 'amount': 10.0},
        {'id': 'b', 'amount': 20.0},
      ]);
      final other = await cache.getCollection(8, 'personal_transaction');
      expect(other, isEmpty);

      final mine = await cache.getCollection(userId, 'personal_transaction');
      expect(mine.length, 2);
      expect(mine.first['amount'], 10.0);
    });

    test('upsertItem updates in place and isOfflineCached reflects it', () async {
      await cache.upsertItem(userId, 'personal_savings_goal', 'g1', {'id': 'g1', 'progress_pct': 33});
      await cache.upsertItem(userId, 'personal_savings_goal', 'g1', {'id': 'g1', 'progress_pct': 50});
      final rows = await cache.getCollection(userId, 'personal_savings_goal');
      expect(rows.length, 1);
      expect(rows.first['progress_pct'], 50);
      expect(await cache.isOfflineCached(userId, 'personal_savings_goal'), isTrue);
      expect(await cache.isOfflineCached(userId, 'personal_budget'), isFalse);
    });

    test('removeItem deletes only the target row', () async {
      await cache.upsertItem(userId, 'personal_debt', 'd1', {'id': 'd1'});
      await cache.upsertItem(userId, 'personal_debt', 'd2', {'id': 'd2'});
      await cache.removeItem(userId, 'personal_debt', 'd1');
      final rows = await cache.getCollection(userId, 'personal_debt');
      expect(rows.map((e) => e['id']), ['d2']);
    });
  });

  group('sync queue enqueue', () {
    test('enqueue writes a pending sync_queue row carrying remote_id in data', () async {
      await cache.enqueue(userId, 'personal_transaction', 'tx-1', 'UPDATE', data: {'amount': 99.0});
      final rows = await DatabaseHelper.rawQuery("SELECT * FROM sync_queue WHERE status = 'pending'");
      expect(rows.length, 1);
      expect(rows.first['table_name'], 'personal_transaction');
      expect(rows.first['operation'], 'UPDATE');
      expect(rows.first['record_id'], isNull);
      final data = jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
      expect(data['remote_id'], 'tx-1');
      expect(data['amount'], 99.0);
    });

    test('enqueue supports all three operations', () async {
      await cache.enqueue(userId, 'personal_bank_account', 'b1', 'INSERT');
      await cache.enqueue(userId, 'personal_bank_account', 'b1', 'UPDATE');
      await cache.enqueue(userId, 'personal_bank_account', 'b1', 'DELETE');
      final ops = await DatabaseHelper.rawQuery('SELECT operation FROM sync_queue ORDER BY id');
      expect(ops.map((r) => r['operation']), ['INSERT', 'UPDATE', 'DELETE']);
    });
  });
}