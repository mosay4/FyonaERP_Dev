import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/sync_outbox.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/network/dio_provider.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/core/services/sync_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Auth-expiry reconnect: device offline 90 days, token dead on return.
///
/// Drives the REAL SyncEngine.processQueue against a fake HTTP layer:
/// while `sessionDead` every replay gets 401/403; flipping it simulates a
/// successful re-login. No app code outside sync_engine.dart is involved.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const userId = 7;
  final oldDate = DateTime.now()
      .toUtc()
      .subtract(const Duration(days: 90))
      .toIso8601String();

  late bool sessionDead;
  late int forcedStatus;

  Dio makeFakeDio() {
    final dio = Dio(BaseOptions(baseUrl: 'http://fake.local'));
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (sessionDead) {
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response(
              requestOptions: options,
              statusCode: forcedStatus,
              data: {'detail': 'session expired'},
            ),
          ));
          return;
        }
        if (options.path.contains('sync/pull')) {
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'success': true,
              'data': {
                'entities': [],
                'server_time': DateTime.now().toUtc().toIso8601String(),
              },
            },
          ));
          return;
        }
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {},
        ));
      },
    ));
    return dio;
  }

  /// A live engine bound to the fake network (no AuthNotifier involved —
  /// userIdOverride pins the namespace exactly like the warmed stable id).
  Future<(ProviderContainer, SyncEngine)> makeEngine() async {
    final container = ProviderContainer(overrides: [
      apiClientProvider
          .overrideWithValue(ApiClient(dio: makeFakeDio())),
      connectivityServiceProvider.overrideWithValue(
        ConnectivityService(debugOnline: true),
      ),
    ]);
    late Ref testRef;
    final probe = Provider((ref) {
      testRef = ref;
      return 0;
    });
    container.read(probe);
    final engine = SyncEngine(testRef, userIdOverride: userId);
    await engine.init();
    return (container, engine);
  }

  Future<void> cleanDb() async {
    await DatabaseHelper.rawDelete('DELETE FROM personal_entity_cache');
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
    await DatabaseHelper.rawDelete('DELETE FROM sync_operation_log');
    await DatabaseHelper.rawDelete('DELETE FROM sync_cursor');
  }

  Future<void> seedOldOps() async {
    final txId = generateUuidV4();
    await SyncOutbox.enqueue(
      tableName: 'personal_transaction',
      entityType: 'personal_transaction',
      entityId: txId,
      operation: 'INSERT',
      data: {'id': txId, 'amount': 250.0, 'client_operation_id': 'op-tx-1'},
      userId: userId,
      occurredAt: oldDate,
    );
    await SyncOutbox.enqueue(
      tableName: 'personal_bank_account',
      entityType: 'personal_bank_account',
      entityId: 'bank-90',
      operation: 'UPDATE',
      data: {
        'id': 'bank-90',
        'bank_name': 'Renamed90DaysAgo',
        '__changed': ['bank_name'],
      },
      userId: userId,
      occurredAt: oldDate,
    );
    final goalId = generateUuidV4();
    await SyncOutbox.enqueue(
      tableName: 'personal_savings_goal',
      entityType: 'personal_savings_goal',
      entityId: goalId,
      operation: 'INSERT',
      data: {'id': goalId, 'name': 'OldGoal'},
      userId: userId,
      occurredAt: oldDate,
    );
    await SyncOutbox.enqueue(
      tableName: 'personal_debt',
      entityType: 'personal_debt',
      entityId: 'debt-90',
      operation: 'DELETE',
      userId: userId,
      occurredAt: oldDate,
    );
  }

  Future<List<Map<String, dynamic>>> queueRows() =>
      DatabaseHelper.rawQuery('SELECT * FROM sync_queue ORDER BY id ASC');

  setUp(() async {
    await cleanDb();
    sessionDead = true;
    forcedStatus = 401;
  });

  tearDown(() async {
    await cleanDb();
  });

  group('auth expiry reconnect', () {
    test('TEST 1+2: 90-day ops + 401 stay pending (never conflict), auth-needed',
        () async {
      await seedOldOps();
      final (container, engine) = await makeEngine();
      try {
        final before = await queueRows();
        final opIdsBefore =
            before.map((r) => r['operation_id'].toString()).toSet();

        await engine.processQueue();

        final after = await queueRows();
        // No loss: all four ops still queued...
        expect(after.length, 4, reason: 'no op may be lost on 401');
        // ...still pending/retryable, never conflict...
        for (final r in after) {
          expect(r['status'], 'pending',
              reason: '401 must not conflict ops');
        }
        expect(
            after.where((r) => r['status'] == 'conflict'), isEmpty);
        // ...with identical identities (idempotent retry safe)...
        final opIdsAfter =
            after.map((r) => r['operation_id'].toString()).toSet();
        expect(opIdsAfter, opIdsBefore);
        // ...and no retry exhaustion consumed by auth failures.
        for (final r in after) {
          expect((r['retry_count'] as num).toInt(), 0,
              reason: 'auth failures must not burn retries');
        }
        // Clear auth-needed state surfaced.
        expect(engine.isAuthNeeded, isTrue);
        expect(engine.status, SyncState.authNeeded);
      } finally {
        engine.dispose();
        container.dispose();
      }
    });

    test('TEST 2b: 403 behaves like 401 (pending, auth-needed)', () async {
      forcedStatus = 403;
      await seedOldOps();
      final (container, engine) = await makeEngine();
      try {
        await engine.processQueue();
        final after = await queueRows();
        expect(after.length, 4);
        expect(after.where((r) => r['status'] == 'conflict'), isEmpty);
        expect(engine.isAuthNeeded, isTrue);
      } finally {
        engine.dispose();
        container.dispose();
      }
    });

    test('TEST 3+4+6: re-login replays everything, no loss, no duplication',
        () async {
      await seedOldOps();
      final (container, engine) = await makeEngine();
      try {
        // Dead round first (parks ops under auth-needed).
        await engine.processQueue();
        expect(engine.isAuthNeeded, isTrue);

        // Re-login: session alive again.
        sessionDead = false;
        await engine.processQueue();

        // All four ops confirmed and gone from the queue...
        final remaining = await queueRows();
        expect(remaining, isEmpty, reason: 'all ops must sync after login');
        // ...audited exactly once each (no duplication)...
        final log = await DatabaseHelper.rawQuery(
            'SELECT operation_id FROM sync_operation_log');
        expect(log.length, 4, reason: 'each op archived exactly once');
        // ...flag cleared, pull ran (cursor advanced in the same cycle).
        expect(engine.isAuthNeeded, isFalse);
        expect(engine.status, SyncState.synced);
        final cursor = await DatabaseHelper.query('sync_cursor',
            where: 'entity_type = ?', whereArgs: ['_global_$userId']);
        expect(cursor.isNotEmpty, isTrue,
            reason: 'pull must run in the recovery cycle');
      } finally {
        engine.dispose();
        container.dispose();
      }
    });

    test('TEST 5a: restart BEFORE re-auth keeps ops pending, flag rebuilds',
        () async {
      await seedOldOps();
      final (c1, e1) = await makeEngine();
      try {
        await e1.processQueue();
        expect(e1.isAuthNeeded, isTrue);
      } finally {
        e1.dispose();
        c1.dispose();
      }

      // Kill (in-memory flag dies with the engine) + relaunch.
      await DatabaseHelper.close();
      final (c2, e2) = await makeEngine();
      try {
        // Fresh engine knows nothing yet...
        expect(e2.isAuthNeeded, isFalse);
        await e2.processQueue();
        // ...but the first 401 rebuilds the state from the durable queue.
        final after = await queueRows();
        expect(after.length, 4, reason: 'restart must not lose ops');
        expect(after.where((r) => r['status'] == 'conflict'), isEmpty);
        expect(e2.isAuthNeeded, isTrue);
      } finally {
        e2.dispose();
        c2.dispose();
      }
    });

    test('TEST 5b: restart AFTER re-auth loses nothing and sends nothing twice',
        () async {
      await seedOldOps();
      final (c1, e1) = await makeEngine();
      try {
        await e1.processQueue();
        sessionDead = false;
        await e1.processQueue();
        expect(await queueRows(), isEmpty);
      } finally {
        e1.dispose();
        c1.dispose();
      }

      // Restart after a clean sync: queue stays empty, archive intact.
      await DatabaseHelper.close();
      final (c2, e2) = await makeEngine();
      try {
        await e2.processQueue();
        expect(await queueRows(), isEmpty);
        final log = await DatabaseHelper.rawQuery(
            'SELECT operation_id FROM sync_operation_log');
        expect(log.length, 4, reason: 'archive must survive the restart');
      } finally {
        e2.dispose();
        c2.dispose();
      }
    });
  });
}
