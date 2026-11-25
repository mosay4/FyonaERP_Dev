import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/database/repositories/sync_outbox.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/account_type_store.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_ledger.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_ledger_migration.dart';
import 'package:fyona_flutter/features/personal/data/models/financial_tree_models.dart';
import 'package:fyona_flutter/features/personal/data/repositories/financial_tree_storage.dart';
import 'package:fyona_flutter/features/personal/domain/services/backup/backup_integrity.dart';
import 'package:fyona_flutter/features/personal/domain/services/backup/backup_snapshot.dart';
import 'package:fyona_flutter/features/personal/domain/services/backup_service.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/personal_ledger_test_support.dart';

const _userA = 'aaaaaaaa-0000-4000-8000-00000000000a';
const _userB = 'bbbbbbbb-0000-4000-8000-00000000000b';
const _bankId = '0b0b0b0b-1111-4111-8111-000000000001';
const _txId = '0c0c0c0c-2222-4222-8222-000000000002';
const _secret = 'رصيد-سري-encrypted-personal-9137';

Future<int> _stable(String user, int id) async {
  await DatabaseHelper.rawInsert(
    'INSERT OR REPLACE INTO stable_user_ids (real_user_id, local_user_id, created_at) VALUES (?, ?, ?)',
    [user, id, DateTime.now().toIso8601String()],
  );
  return id;
}

/// Old-version plain rows for one namespace (what a user upgrading has).
Future<void> _seedPlain(int ns, {String tag = 'a'}) async {
  for (var i = 0; i < 3; i++) {
    await DatabaseHelper.rawInsert(
      'INSERT INTO personal_entity_cache (user_id, entity_type, remote_id, data_json, updated_at) VALUES (?, ?, ?, ?, ?)',
      [
        ns,
        'personal_transaction',
        '$tag-tx-$i',
        jsonEncode({'id': '$tag-tx-$i', 'amount': 10.5 + i, 'note': _secret}),
        '2026-01-0${i + 1}T10:00:00.000',
      ],
    );
  }
  await DatabaseHelper.rawInsert(
    'INSERT INTO personal_entity_cache (user_id, entity_type, remote_id, data_json, updated_at) VALUES (?, ?, ?, ?, ?)',
    [ns, 'personal_bank_account', '$tag-bank', jsonEncode({'id': '$tag-bank', 'balance': 99.25, '_sync_version': 3}), null],
  );
  await DatabaseHelper.insert('sync_queue', {
    'operation_id': 'op-$tag-1',
    'operation_type': 'TRANSACTION_CREATE',
    'table_name': 'personal_transaction',
    'entity_type': 'personal_transaction',
    'entity_id': '$tag-tx-0',
    'user_id': ns,
    'device_id': 'dev',
    'operation': 'INSERT',
    'data': jsonEncode({'id': '$tag-tx-0', 'amount': 10.5, 'note': _secret}),
    'status': 'pending',
    'occurred_at': '2026-01-01T10:00:00.000Z',
    'created_at': '2026-01-01T10:00:00.000',
    'updated_at': '2026-01-01T10:00:00.000',
  });
  await DatabaseHelper.insert('sync_operation_log', {
    'operation_id': 'op-$tag-0',
    'entity_type': 'personal_bank_account',
    'entity_id': '$tag-bank',
    'operation': 'INSERT',
    'status': 'synced',
    'user_id': ns,
    'response_json': jsonEncode({'balance': 99.25}),
  });
  await DatabaseHelper.insert('personal_exchange_rates', {
    'user_id': ns,
    'from_currency': 'USD',
    'to_currency': 'SAR',
    'rate': 3.75,
  });
}

Future<int> _plainCount(String table, int ns) async {
  final rows = await DatabaseHelper.rawQuery(
    'SELECT COUNT(*) AS c FROM $table WHERE user_id = ?',
    [ns],
  );
  return (rows.first['c'] as num).toInt();
}

Future<int> _ledgerCount(String table, int ns) async {
  final rows = await (await PersonalLedger.active()).rawQuery(
    'SELECT COUNT(*) AS c FROM $table WHERE user_id = ?',
    [ns],
  );
  return (rows.first['c'] as num).toInt();
}

Future<void> _wipePlain() async {
  for (final t in [
    'personal_entity_cache',
    'sync_queue',
    'sync_operation_log',
    'personal_exchange_rates',
    'stable_user_ids',
  ]) {
    await DatabaseHelper.rawDelete('DELETE FROM $t');
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PersonalLedgerMigration.debugStep = null;
    personalLedgerTestKeys.failReads = false;
    await resetPersonalLedger();
    PersonalLedger.fallbackOwner = null;
    await _wipePlain();
  });

  tearDown(() async {
    PersonalLedgerMigration.debugStep = null;
    personalLedgerTestKeys.failReads = false;
    await resetPersonalLedger();
    PersonalLedger.fallbackOwner = 'test-device';
  });

  group('encryption, fail closed', () {
    test('ledger file is SQLCipher-encrypted; no plaintext anywhere', () async {
      final ns = PersonalCacheRepository.stableIdSync(_userA);
      final cache = PersonalCacheRepository();
      await cache.commitOfflineWrite(
        userId: ns,
        entityType: 'personal_transaction',
        remoteId: 'tx-1',
        primaryRow: {'id': 'tx-1', 'note': _secret},
        operation: 'INSERT',
        data: {'id': 'tx-1', 'note': _secret},
      );
      final db = await PersonalLedger.active();
      final path = db.path;
      // Nothing reached the old plain store.
      expect(
        await DatabaseHelper.rawQuery(
          "SELECT 1 FROM personal_entity_cache WHERE data_json LIKE ?",
          ['%$_secret%'],
        ),
        isEmpty,
      );
      expect(
        await DatabaseHelper.rawQuery(
          "SELECT 1 FROM sync_queue WHERE data LIKE ?",
          ['%$_secret%'],
        ),
        isEmpty,
      );
      await PersonalLedger.deactivate();
      final bytes = await File(path).readAsBytes();
      final raw = utf8.decode(bytes, allowMalformed: true);
      expect(raw.startsWith('SQLite format 3'), isFalse);
      expect(raw, isNot(contains(_secret)));
      expect(raw, isNot(contains('tx-1')));
      expect(path, isNot(contains(_userA)), reason: 'file name is a digest');
    });

    test('missing / wrong key or locked vault: refused, file untouched, '
        'no plaintext fallback, recovers when the key is back', () async {
      final ns = PersonalCacheRepository.stableIdSync(_userA);
      final cache = PersonalCacheRepository();
      await cache.upsertItem(ns, 'personal_debt', 'd1', {'id': 'd1', 'note': _secret});
      final path = (await PersonalLedger.active()).path;
      await PersonalLedger.deactivate();
      final before = await File(path).readAsBytes();
      final storage = personalLedgerTestKeys.memory.keys.single;
      final key = personalLedgerTestKeys.memory.remove(storage)!;

      PersonalCacheRepository.stableIdSync(_userA);
      await expectLater(
        cache.getCollection(ns, 'personal_debt'),
        throwsA(isA<PersonalLedgerUnavailable>()
            .having((e) => e.reason, 'reason', 'key_missing')),
      );
      await expectLater(
        cache.upsertItem(ns, 'personal_debt', 'd2', {'id': 'd2'}),
        throwsA(isA<PersonalLedgerUnavailable>()),
      );
      expect(personalLedgerTestKeys.memory, isEmpty, reason: 'never re-keyed');
      expect(await File(path).readAsBytes(), before);
      expect(
        await DatabaseHelper.rawQuery('SELECT 1 FROM personal_entity_cache'),
        isEmpty,
      );

      personalLedgerTestKeys.memory[storage] = List.filled(64, 'a').join();
      await expectLater(
        cache.getCollection(ns, 'personal_debt'),
        throwsA(isA<PersonalLedgerUnavailable>()),
      );
      expect(await File(path).readAsBytes(), before);

      personalLedgerTestKeys.memory[storage] = key;
      personalLedgerTestKeys.failReads = true;
      await expectLater(
        cache.getCollection(ns, 'personal_debt'),
        throwsA(isA<PersonalLedgerUnavailable>()
            .having((e) => e.reason, 'reason', 'key_store')),
      );
      personalLedgerTestKeys.failReads = false;
      final rows = await cache.getCollection(ns, 'personal_debt');
      expect(rows.single['note'], _secret);
    });

    test('no signed-in user: Personal storage refuses instead of guessing',
        () async {
      await expectLater(
        PersonalCacheRepository().getCollection(5, 'personal_debt'),
        throwsA(isA<PersonalLedgerUnavailable>()
            .having((e) => e.reason, 'reason', 'no_active_user')),
      );
      await expectLater(
        FinancialTreeStorage().loadTrees(),
        throwsA(isA<PersonalLedgerUnavailable>()),
      );
    });
  });

  group('one-time migration from plain storage', () {
    Future<void> seedPrefs() async {
      SharedPreferences.setMockInitialValues({
        'financial_trees_v1': jsonEncode([
          {'id': 't1', 'name': 'خطة', 'baseAmount': 100},
        ]),
        'financial_tree_nodes_t1': '[]',
        'bank_account_types_v3': '{"a-bank":"savings"}',
        'bank_account_types_relay_pending': true,
        'enabled_currencies_x': ['SAR'], // not ledger data: stays
      });
    }

    test('copy → verify → wipe, scoped to the user; idempotent', () async {
      final stable = await _stable(_userA, 4);
      final fnv = PersonalCacheRepository.fnvNamespace(_userA);
      await _seedPlain(stable, tag: 'a');
      await _seedPlain(fnv, tag: 'af');
      final other = await _stable(_userB, 5);
      await _seedPlain(other, tag: 'b');
      await seedPrefs();

      PersonalLedger.select(_userA);
      final db = await PersonalLedger.active();

      for (final ns in [stable, fnv]) {
        expect(await _ledgerCount('personal_rows', ns), 4);
        expect(await _ledgerCount('personal_outbox', ns), 1);
        expect(await _ledgerCount('personal_outbox_log', ns), 1);
        expect(await _ledgerCount('personal_exchange_rates', ns), 1);
        for (final t in ['personal_entity_cache', 'sync_queue', 'sync_operation_log', 'personal_exchange_rates']) {
          expect(await _plainCount(t, ns), 0, reason: '$t wiped for $ns');
        }
      }
      // The other user's plain rows are not touched (moved on their open).
      expect(await _plainCount('personal_entity_cache', other), 4);
      expect(await _ledgerCount('personal_rows', other), 0);

      // Content identical (ids, money, order, version column).
      final rows = await db.rawQuery(
        'SELECT id, data_json, version FROM personal_rows WHERE user_id = ? ORDER BY seq',
        [stable],
      );
      expect(rows.map((r) => r['id']), ['a-tx-0', 'a-tx-1', 'a-tx-2', 'a-bank']);
      expect(jsonDecode(rows[1]['data_json'] as String)['amount'], 11.5);
      expect(rows.last['version'], 3);
      final op = (await db.rawQuery('SELECT * FROM personal_outbox WHERE user_id = ?', [stable])).single;
      expect(op['operation_id'], 'op-a-1');
      expect(op['status'], 'pending');

      // Preferences moved into the ledger, removed from plaintext.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('financial_trees_v1'), isNull);
      expect(prefs.getString('bank_account_types_v3'), isNull);
      expect(prefs.getStringList('enabled_currencies_x'), ['SAR']);
      expect((await FinancialTreeStorage().loadTrees()).single.id, 't1');
      expect(await PersonalAccountTypeStore.load(), {'a-bank': 'savings'});
      expect(await PersonalAccountTypeStore.takePending(), isTrue);

      final meta = jsonDecode((await db.readMeta(PersonalLedgerMigration.metaKey))!) as Map;
      expect(meta['state'], 'done');
      expect(meta['conflicts'], 0);
      expect((meta['counts'] as Map)['personal_entity_cache'], 8);
      expect((meta['checksum'] as String).length, 64);

      // Re-open: nothing to move, nothing duplicated.
      await PersonalLedger.deactivate();
      PersonalLedger.select(_userA);
      final report = await PersonalLedgerMigration.run(
        await PersonalLedger.active(),
        namespaces: await PersonalLedger.namespacesOf(_userA),
      );
      expect(report.total, 0);
      expect(await _ledgerCount('personal_rows', stable), 4);
      expect(await _ledgerCount('personal_outbox', stable), 1);

      // The old sync path replays the moved operation unchanged.
      final batch = await SyncOutbox.nextBatch(userId: stable);
      expect(batch.single.operationId, 'op-a-1');
      expect(batch.single.data['note'], _secret);
    });

    for (final step in ['copied', 'verified', 'wiped_db']) {
      test('crash after "$step": next open continues, no loss, no dups',
          () async {
        final stable = await _stable(_userA, 4);
        await _seedPlain(stable);
        await seedPrefs();
        PersonalLedgerMigration.debugStep = (s) async {
          if (s == step) throw StateError('crash at $s');
        };
        PersonalLedger.select(_userA);
        await expectLater(
          PersonalLedger.active(),
          throwsA(isA<PersonalLedgerUnavailable>()
              .having((e) => e.reason, 'reason', 'migration_failed')),
        );
        // Whatever happened, the data is in one of the two stores.
        final plainLeft = await _plainCount('personal_entity_cache', stable);
        expect(plainLeft, step == 'wiped_db' ? 0 : 4);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('financial_trees_v1'), isNotNull,
            reason: 'prefs are wiped last');

        PersonalLedgerMigration.debugStep = null;
        await PersonalLedger.active();
        expect(await _ledgerCount('personal_rows', stable), 4);
        expect(await _ledgerCount('personal_outbox', stable), 1);
        expect(await _ledgerCount('personal_outbox_log', stable), 1);
        expect(await _ledgerCount('personal_exchange_rates', stable), 1);
        expect(await _plainCount('personal_entity_cache', stable), 0);
        expect(await _plainCount('sync_queue', stable), 0);
        expect(prefs.getString('financial_trees_v1'), isNull);
        expect((await FinancialTreeStorage().loadTrees()).single.id, 't1');
      });
    }

    test('a differing row already in the ledger is kept and the plain copy '
        'is preserved encrypted (never lost)', () async {
      final stable = await _stable(_userA, 4);
      PersonalLedger.select(_userA);
      await PersonalCacheRepository().upsertItem(
          stable, 'personal_transaction', 'a-tx-0', {'id': 'a-tx-0', 'amount': 1});
      await PersonalLedger.deactivate();
      await _seedPlain(stable);
      PersonalLedger.select(_userA);
      final db = await PersonalLedger.active();
      final kept = await PersonalCacheRepository()
          .getCollection(stable, 'personal_transaction');
      expect(kept.firstWhere((r) => r['id'] == 'a-tx-0')['amount'], 1);
      final stash = await db.rawQuery('SELECT * FROM personal_migration_conflicts');
      expect(stash.single['row_key'], '$stable|personal_transaction|a-tx-0');
      expect(stash.single['row_json'] as String, contains('10.5'));
      expect(await _plainCount('personal_entity_cache', stable), 0);
    });
  });

  group('per-user isolation', () {
    test('each user has a separate encrypted file; switching never mixes',
        () async {
      final cache = PersonalCacheRepository();
      final nsA = PersonalCacheRepository.stableIdSync(_userA);
      await cache.upsertItem(nsA, 'personal_bank_account', 'bank-a', {'id': 'bank-a'});
      await FinancialTreeStorage().saveTree(FinancialTree(
        id: 'tree-a', name: 'A', baseAmount: 1, currency: 'SAR', rootNodeId: 'r',
        createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026),
      ));
      final pathA = (await PersonalLedger.active()).path;

      final nsB = PersonalCacheRepository.stableIdSync(_userB);
      expect(await cache.getCollection(nsB, 'personal_bank_account'), isEmpty);
      expect(await FinancialTreeStorage().loadTrees(), isEmpty);
      // A's namespace cannot be read or written while B is signed in.
      await expectLater(
        cache.getCollection(nsA, 'personal_bank_account'),
        throwsA(isA<PersonalLedgerUnavailable>()
            .having((e) => e.reason, 'reason', 'other_user')),
      );
      await expectLater(
        cache.upsertItem(nsA, 'personal_debt', 'x', {'id': 'x'}),
        throwsA(isA<PersonalLedgerUnavailable>()),
      );
      await cache.upsertItem(nsB, 'personal_bank_account', 'bank-b', {'id': 'bank-b'});
      final pathB = (await PersonalLedger.active()).path;
      expect(pathB, isNot(pathA));

      // Logout closes the ledger; nothing readable until a user is chosen.
      await PersonalLedger.deactivate();
      await expectLater(
        cache.getCollection(nsB, 'personal_bank_account'),
        completion(hasLength(1)),
        reason: 'B\'s own namespace re-selects B\'s ledger only',
      );
      PersonalCacheRepository.stableIdSync(_userA);
      expect(
        (await cache.getCollection(nsA, 'personal_bank_account')).single['id'],
        'bank-a',
      );
      expect((await FinancialTreeStorage().loadTrees()).single.id, 'tree-a');
    });
  });

  group('local backup / restore with the ledger', () {
    test('snapshot carries the ledger; restore brings it back into it',
        () async {
      const serverUuid = _userA;
      final ns = PersonalCacheRepository.stableIdSync(_userA);
      final svc = PersonalFinanceService(
        apiClient: ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'))),
        cache: PersonalCacheRepository(),
      );
      svc.setUserId(ns);
      final cache = PersonalCacheRepository();
      await cache.upsertItem(ns, 'personal_bank_account', _bankId,
          {'id': _bankId, 'bank_name': 'Cash', 'currency': 'SAR', 'balance': 123.45});
      await cache.upsertItem(ns, 'personal_transaction', _txId,
          {'id': _txId, 'amount': 23.45, 'bank_account_id': _bankId, 'note': _secret});
      await FinancialTreeStorage().saveTree(FinancialTree(
        id: 'tree-1', name: 'Plan', baseAmount: 5, currency: 'SAR', rootNodeId: 'r',
        createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026),
      ));
      PersonalAccountTypeStore.now = () => 42;
      await PersonalAccountTypeStore.save(_bankId, 'savings');

      final snap = await BackupSnapshotBuilder.build(
        localUserId: ns,
        serverUserUuid: serverUuid,
        appVersion: 't',
      );
      final mirror = (snap['tables'] as Map)['personal_entity_cache'] as List;
      expect(mirror.map((r) => (r as Map)['remote_id']), containsAll([_bankId, _txId]));
      final prefs = snap['preferences'] as Map;
      expect(prefs.keys, containsAll(['financial_trees_v1', 'bank_account_types_v3']));

      // Lose the device data (ledger gone), then restore the archive.
      await resetPersonalLedger();
      PersonalCacheRepository.stableIdSync(_userA);
      expect(await cache.getCollection(ns, 'personal_transaction'), isEmpty);
      final sealed = BackupIntegrity.sealSnapshot(snap);
      final issues = BackupIntegrity.validateSnapshot(sealed);
      expect(issues.errors.map((e) => '${e.code}:${e.params}'), isEmpty);
      final res = await BackupService(financeService: svc).restoreFromBackup(
        sealed,
        userId: ns,
        serverUserUuid: serverUuid,
        skipServer: true,
      );
      expect(res.success, isTrue, reason: res.message);
      final txs = await cache.getCollection(ns, 'personal_transaction');
      expect(txs.single['note'], _secret);
      expect(txs.single['amount'], 23.45);
      expect((await FinancialTreeStorage().loadTrees()).single.id, 'tree-1');
      expect(await PersonalAccountTypeStore.load(), {_bankId: 'savings'});
      // Restored into the encrypted ledger, not into plaintext.
      final p = await SharedPreferences.getInstance();
      expect(p.getString('financial_trees_v1'), isNull);
      expect(
        await DatabaseHelper.rawQuery('SELECT 1 FROM personal_entity_cache'),
        isEmpty,
      );
    });
  });
}
