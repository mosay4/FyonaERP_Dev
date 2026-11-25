import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/database/repositories/sync_outbox.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/network/dio_provider.dart';
import 'package:fyona_flutter/core/offline/sync_integrity.dart';
import 'package:fyona_flutter/features/personal/di/personal_providers.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/personal_providers.dart';
import 'package:fyona_flutter/features/personal/data/ledger/personal_ledger_migration.dart';
import 'support/personal_ledger_test_support.dart';

/// Pre-v15 shape of sync_queue (before the additive integrity columns), used
/// to prove the v14 -> v15 upgrade path.
const String _syncQueueLegacyV14 = '''
    CREATE TABLE IF NOT EXISTS sync_queue (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      operation_id TEXT UNIQUE,
      operation_type TEXT,
      table_name TEXT NOT NULL,
      entity_type TEXT,
      entity_id TEXT,
      record_id INTEGER,
      user_id INTEGER,
      device_id TEXT,
      operation TEXT NOT NULL,
      data TEXT,
      base_version INTEGER DEFAULT 0,
      source TEXT DEFAULT 'ui',
      status TEXT NOT NULL DEFAULT 'pending',
      error_message TEXT,
      retry_count INTEGER DEFAULT 0,
      depends_on TEXT,
      occurred_at TEXT,
      next_attempt_at TEXT,
      created_at TEXT,
      updated_at TEXT
    )
  ''';

/// Instant-open (SWR) + additive sync-integrity verification.
///
/// Part 1 proves pages open from the local mirror without awaiting the
/// network (isLoading only on empty cache; background refresh is silent).
/// Part 2 proves the v15 integrity columns + shadow verifier without
/// changing a single replay byte (the 58-test suite proves behavior).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  /// Deterministic offline Dio: rejects every request immediately with a
  /// connection error (no sockets involved — immune to the test binding's
  /// HTTP stub, which answers 400 to everything and is NOT a connectivity
  /// error). This is exactly what `isConnectivityError` classifies offline.
  Dio makeUnreachableDio() {
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'));
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          message: 'SocketException: offline (test stub)',
        ),
      ),
    ));
    return dio;
  }

  PersonalFinanceService makeService() {
    final svc = PersonalFinanceService(
      apiClient: ApiClient(dio: makeUnreachableDio()),
      cache: PersonalCacheRepository(),
    );
    svc.setUserId(7);
    return svc;
  }

  ProviderContainer makeContainer(PersonalFinanceService svc) =>
      ProviderContainer(overrides: [
        personalFinanceServiceProvider.overrideWithValue(svc),
        apiClientProvider
            .overrideWithValue(ApiClient(dio: makeUnreachableDio())),
      ]);

  Future<void> cleanDb() async {
    await (await testLedger()).rawDelete('DELETE FROM personal_entity_cache');
    await (await testLedger()).rawDelete('DELETE FROM sync_queue');
    await (await testLedger()).rawDelete('DELETE FROM sync_operation_log');
    await DatabaseHelper.rawDelete('DELETE FROM sync_cursor');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  Future<void> seedAll() async {
    final cache = PersonalCacheRepository();
    await cache.upsertItem(7, 'personal_bank_account', 'bank-i', {
      'id': 'bank-i',
      'bank_name': 'InstantBank',
      'currency': 'SAR',
      'balance': 9000.0,
      'is_active': true,
    });
    await cache.upsertItem(7, 'personal_transaction', 'tx-i', {
      'id': 'tx-i',
      'tx_type': 'expense',
      'amount': 120.0,
      'currency': 'SAR',
      'category': 'Food',
      'bank_account_id': 'bank-i',
      'budget_id': 'bud-i',
      'date': DateTime.now().toIso8601String(),
    });
    await cache.upsertItem(7, 'personal_savings_goal', 'goal-i', {
      'id': 'goal-i',
      'name': 'G',
      'target_amount': 1000.0,
      'current_amount': 100.0,
      'currency': 'SAR',
    });
    await cache.upsertItem(7, 'personal_debt', 'debt-i', {
      'id': 'debt-i',
      'debt_type': 'payable',
      'person_name': 'P',
      'amount': 500.0,
      'currency': 'SAR',
    });
    await cache.upsertItem(7, 'personal_budget', 'bud-i', {
      'id': 'bud-i',
      'name': 'Monthly',
      'amount': 2000.0,
      'spent': 0.0,
      'currency': 'SAR',
    });
    await cache.upsertItem(7, 'personal_recurring_transaction', 'rt-i', {
      'id': 'rt-i',
      'name': 'Rent',
      'tx_type': 'expense',
      'amount': 800.0,
      'currency': 'SAR',
      'category': 'Rent',
      'frequency': 'monthly',
      'interval_value': 1,
      'next_run_date':
          DateTime.now().add(const Duration(days: 30)).toIso8601String(),
      'account_type': 'fixed',
      'bank_account_id': 'bank-i',
      'execution_type': 'manual',
      'is_active': true,
    });
  }

  // ═══════════════════════════════════════════════════════════════════
  // PART 1 — Instant open: local reads never wait for the network.
  // ═══════════════════════════════════════════════════════════════════
  group('instant open (SWR)', () {
    test('all six getters return seeded mirrors with dead network', () async {
      await seedAll();
      final svc = makeService();
      final sw = Stopwatch()..start();
      final results = await Future.wait([
        svc.getBankAccounts(),
        svc.getTransactions(),
        svc.getSavingsGoals(),
        svc.getDebts(),
        svc.getAllBudgets(),
        svc.getRecurring(),
      ]);
      sw.stop();
      expect((results[0] as List).length, 1);
      expect((results[1] as List).length, 1);
      expect((results[2] as List).length, 1);
      expect((results[3] as List).length, 1);
      expect((results[4] as List).length, 1);
      expect((results[5] as List).length, 1);
      // Six sequential network timeouts would cost ~12s+; local reads finish
      // in milliseconds even with the artificial 2s Dio timeouts armed.
      expect(sw.elapsedMilliseconds, lessThan(10000),
          reason: 'reads must come from Local DB, never await the network');
    });

    test('getCategories falls back to locally derived names offline',
        () async {
      await seedAll();
      final svc = makeService();
      final cats = await svc.getCategories();
      expect(cats.map((c) => c.name), contains('Food'));
    });

    test('getLocalCategories is empty-safe with no transactions', () async {
      final svc = makeService();
      expect(await svc.getLocalCategories(), isEmpty);
    });

    test('PersonalFinanceNotifier second load: no spinner, data kept',
        () async {
      await seedAll();
      final svc = makeService();
      final container = makeContainer(svc);
      try {
        final notifier = container.read(personalFinanceProvider.notifier);
        await notifier.load(); // first: populates from mirror
        expect(notifier.state.bankAccounts, isNotEmpty);
        expect(notifier.state.transactions, isNotEmpty);
        expect(notifier.state.isLoading, isFalse);

        final fut = notifier.load(); // second open
        // Synchronous prefix already ran: no spinner, rows still on screen.
        expect(notifier.state.isLoading, isFalse,
            reason: 'cached open must not raise isLoading');
        expect(notifier.state.bankAccounts, isNotEmpty);
        await fut;
        expect(notifier.state.isLoading, isFalse);
        expect(notifier.state.bankAccounts, isNotEmpty);
        expect(notifier.state.transactions, isNotEmpty);
        expect(notifier.state.savingsGoals, isNotEmpty);
        expect(notifier.state.debts, isNotEmpty);
      } finally {
        container.dispose();
      }
    });

    test('BudgetNotifier publishes local spent instantly, no spinner',
        () async {
      await seedAll();
      final svc = makeService();
      final container = makeContainer(svc);
      try {
        final notifier = container.read(budgetProvider.notifier);
        await notifier.load(); // first: phase-1 publishes local spent
        expect(notifier.state.budgets.length, 1);
        // Local math: one 120 SAR expense linked to bud-i.
        expect(notifier.state.budgets.first.totalSpent, 120.0);
        expect(notifier.state.isLoading, isFalse);

        final fut = notifier.load();
        expect(notifier.state.isLoading, isFalse,
            reason: 'cached open must not raise isLoading');
        await fut;
        expect(notifier.state.budgets.first.totalSpent, 120.0);
        // Phase-2 (background aggregations fail offline) keeps local truth.
        await Future<void>.delayed(const Duration(seconds: 4));
        expect(notifier.state.budgets.length, 1);
        expect(notifier.state.budgets.first.totalSpent, 120.0);
      } finally {
        container.dispose();
      }
    });

    test('CategoryNotifier never raises isLoading, publishes local rows',
        () async {
      await seedAll();
      final svc = makeService();
      final container = makeContainer(svc);
      try {
        final notifier = container.read(categoryProvider.notifier);
        final fut = notifier.load();
        // Synchronous prefix must not raise the spinner (old code did).
        expect(notifier.state.isLoading, isFalse,
            reason: 'must not raise isLoading synchronously');
        await fut;
        expect(notifier.state.categories.map((c) => c.name),
            contains('Food'));
        expect(notifier.state.isLoading, isFalse);
      } finally {
        container.dispose();
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // PART 1b — No spinner ever on open; save never waits for budget net.
  // ═══════════════════════════════════════════════════════════════════
  group('instant open (no-spinner + decoupled save)', () {
    test('fresh notifiers never raise isLoading synchronously', () async {
      // Empty DB: the harshest case (old code spun here on every open).
      final svc = makeService();
      final container = makeContainer(svc);
      try {
        final f = container.read(personalFinanceProvider.notifier).load();
        expect(container.read(personalFinanceProvider).isLoading, isFalse);
        await f;

        final b = container.read(budgetProvider.notifier).load();
        expect(container.read(budgetProvider).isLoading, isFalse);
        await b;

        final r = container.read(recurringProvider.notifier).load();
        expect(container.read(recurringProvider).isLoading, isFalse);
        await r;

        final c = container.read(categoryProvider.notifier).load();
        expect(container.read(categoryProvider).isLoading, isFalse);
        await c;
      } finally {
        // Budget phase-2 is detached; let it settle before dispose.
        await Future<void>.delayed(const Duration(seconds: 1));
        container.dispose();
      }
    });

    test('save returns before slow budget aggregation network', () async {
      Dio makeSlowAggDio() {
        final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'));
        dio.interceptors.add(InterceptorsWrapper(
          onRequest: (options, handler) async {
            if (options.path.contains('aggregation')) {
              // A slow server aggregation: save must NOT wait for this.
              await Future<void>.delayed(const Duration(seconds: 3));
            }
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              message: 'SocketException: offline (test stub)',
            ));
          },
        ));
        return dio;
      }

      final slowDio = makeSlowAggDio();
      final svc = PersonalFinanceService(
        apiClient: ApiClient(dio: slowDio),
        cache: PersonalCacheRepository(),
      );
      svc.setUserId(7);
      final container = ProviderContainer(overrides: [
        personalFinanceServiceProvider.overrideWithValue(svc),
        apiClientProvider.overrideWithValue(ApiClient(dio: slowDio)),
      ]);
      try {
        final cache = PersonalCacheRepository();
        await cache.upsertItem(7, 'personal_bank_account', 'bank-s', {
          'id': 'bank-s',
          'bank_name': 'SaveBank',
          'currency': 'SAR',
          'balance': 5000.0,
          'is_active': true,
        });

        final notifier = container.read(personalFinanceProvider.notifier);
        final sw = Stopwatch()..start();
        final err = await notifier.addTransaction(
          type: 'expense',
          amount: 50,
          category: 'Food',
          date: DateTime.now(),
          accountId: 'bank-s',
          currency: 'SAR',
        );
        sw.stop();
        expect(err, isNull, reason: 'save must succeed');
        expect(sw.elapsedMilliseconds, lessThan(2500),
            reason:
                'save must return before the 3s aggregation call finishes');
        expect(
            notifier.state.transactions
                .any((t) => (t.category) == 'Food'),
            isTrue,
            reason: 'tx must land locally with the save');
        // Let the detached budget refresh settle before dispose.
        await Future<void>.delayed(const Duration(seconds: 4));
      } finally {
        container.dispose();
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // PART 2 — Additive integrity: migration + stamp + shadow verify.
  // ═══════════════════════════════════════════════════════════════════
  group('integrity migration (v15, nullable-only)', () {
    test('fresh DB carries the three nullable columns', () async {
      final cols = await (await testLedger()).rawQuery(
          "PRAGMA table_info('sync_queue')");
      final names = cols.map((c) => c['name'].toString()).toSet();
      expect(names,
          containsAll(['op_revision', 'payload_hash', 'idempotency_key']));
    });

    test('v14 -> v15 upgrade adds columns and preserves rows', () async {
      final legacyPath =
          '${await getDatabasesPath()}/fyona_legacy_v14.db';
      try {
        await DatabaseHelper.close();
      } catch (_) {}
      final legacyDb = await databaseFactory.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(
          version: 14,
          onCreate: (db, version) async {
            await db.execute(_syncQueueLegacyV14);
          },
        ),
      );
      const legacyOpId = 'op_legacy_1';
      await legacyDb.insert('sync_queue', {
        'operation_id': legacyOpId,
        'operation_type': 'ENTITY_CREATE',
        'table_name': 'personal_transaction',
        'entity_type': 'personal_transaction',
        'entity_id': 'tx-legacy',
        'user_id': 7,
        'operation': 'INSERT',
        'data': jsonEncode({'id': 'tx-legacy', 'amount': 5.0}),
        'status': 'pending',
        'occurred_at': DateTime.now().toUtc().toIso8601String(),
      });
      await legacyDb.close();

      DatabaseHelper.debugDatabasePath = legacyPath;
      try {
        // Triggers onUpgrade(14 -> 15) on the real DatabaseHelper path.
        final cols = await DatabaseHelper.rawQuery(
            "PRAGMA table_info('sync_queue')");
        final names = cols.map((c) => c['name'].toString()).toSet();
        expect(names,
            containsAll(['op_revision', 'payload_hash', 'idempotency_key']));
        final rows = await DatabaseHelper.rawQuery(
            'SELECT * FROM sync_queue WHERE operation_id = ?',
            [legacyOpId]);
        expect(rows.length, 1, reason: 'legacy row must survive upgrade');
        // The one-time move carries the legacy row into the encrypted
        // ledger unchanged (null integrity columns included).
        await PersonalLedgerMigration.run(await testLedger(), namespaces: {7});
        final ops = await SyncOutbox.nextBatch(limit: 10, userId: 7);
        final legacy =
            ops.firstWhere((o) => o.operationId == legacyOpId);
        expect(legacy.opRevision, isNull);
        expect(legacy.payloadHash, isNull);
        expect(legacy.idempotencyKey, isNull);
        // Shadow verifier passes legacy rows through untouched.
        expect(
            verifyStagedIntegrity(
                data: legacy.data, expectedHash: legacy.payloadHash),
            isTrue);
      } finally {
        DatabaseHelper.debugDatabasePath = null;
        try {
          await DatabaseHelper.close();
        } catch (_) {}
        await databaseFactory.deleteDatabase(legacyPath);
      }
    });
  });

  group('integrity stamp + shadow verify', () {
    test('fingerprint is order-stable and content-sensitive', () {
      final a = {'x': 1, 'y': [1, 2], 'z': {'m': 'a', 'n': 'b'}};
      final b = {'z': {'n': 'b', 'm': 'a'}, 'y': [1, 2], 'x': 1};
      expect(fingerprintPayload(a), fingerprintPayload(b));
      expect(fingerprintPayload(a).length, 16);
      final c = {'x': 2, 'y': [1, 2], 'z': {'m': 'a', 'n': 'b'}};
      expect(fingerprintPayload(c), isNot(fingerprintPayload(a)));
    });

    test('commitOfflineWrite stamps revision/hash/key atomically', () async {
      final cache = PersonalCacheRepository();
      await cache.commitOfflineWrite(
        userId: 7,
        entityType: 'personal_bank_account',
        remoteId: 'bank-stamp',
        primaryRow: {'id': 'bank-stamp', 'bank_name': 'S'},
        operation: 'UPDATE',
        data: {'bank_name': 'S', 'client_operation_id': 'op-key-1'},
        baseVersion: 3,
      );
      var rows = await (await testLedger()).rawQuery(
        "SELECT * FROM sync_queue WHERE entity_id = 'bank-stamp'");
      expect(rows.length, 1);
      expect(rows.first['op_revision'], 1);
      expect((rows.first['payload_hash'] as String).length, 16);
      expect(rows.first['idempotency_key'], 'op-key-1');
      expect(rows.first['base_version'], 3,
          reason: 'existing version chain untouched');

      // Second op on the same entity advances the per-entity revision.
      await cache.commitOfflineWrite(
        userId: 7,
        entityType: 'personal_bank_account',
        remoteId: 'bank-stamp',
        primaryRow: {'id': 'bank-stamp', 'bank_name': 'S2'},
        operation: 'UPDATE',
        data: {'bank_name': 'S2'},
        baseVersion: 3,
      );
      rows = await (await testLedger()).rawQuery(
        "SELECT op_revision, idempotency_key FROM sync_queue "
        "WHERE entity_id = 'bank-stamp' ORDER BY id ASC");
      expect(rows.length, 2);
      expect(rows[0]['op_revision'], 1);
      expect(rows[1]['op_revision'], 2);
      expect(rows[1]['idempotency_key'], isNotNull,
          reason: 'falls back to operation_id without client key');
    });

    test('SyncOutbox.enqueue stamps the same metadata', () async {
      final entityId = generateUuidV4();
      await SyncOutbox.enqueue(
        tableName: 'personal_transaction',
        entityType: 'personal_transaction',
        entityId: entityId,
        operation: 'INSERT',
        data: {'id': entityId, 'amount': 9.0},
        userId: 7,
      );
      final ops = await SyncOutbox.nextBatch(limit: 10, userId: 7);
      final op = ops.firstWhere((o) => o.entityId == entityId);
      expect(op.opRevision, 1);
      expect(op.payloadHash, isNotNull);
      expect(op.idempotencyKey, op.operationId);
      // Stored bytes are byte-identical apart from the pre-existing
      // remote_id injection: original keys intact, replay shape unchanged.
      expect(op.data['id'], entityId);
      expect(op.data['amount'], 9.0);
      expect(op.data['remote_id'], entityId);
      // Shadow verifier confirms the staged bytes.
      expect(
          verifyStagedIntegrity(
              data: op.data, expectedHash: op.payloadHash),
          isTrue);
    });

    test('tampered bytes report false but never throw', () async {
      final data = {'id': 'x', 'amount': 1.0};
      final hash = fingerprintPayload(data);
      expect(verifyStagedIntegrity(data: data, expectedHash: hash), isTrue);
      final tampered = {'id': 'x', 'amount': 999.0};
      // Reports drift for logging...
      expect(
          verifyStagedIntegrity(data: tampered, expectedHash: hash),
          isFalse);
      // ...and legacy rows without a hash always pass through.
      expect(verifyStagedIntegrity(data: tampered), isTrue);
    });
  });
}
