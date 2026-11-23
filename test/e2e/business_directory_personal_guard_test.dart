// Test-only: existing Personal service and sync over HTTP, one process and
// SQLite file per run. This is not Business offline code.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/database/repositories/sync_outbox.dart';
import 'package:fyona_flutter/core/di/providers.dart';
import 'package:fyona_flutter/core/di/repository_providers.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/network/repositories.dart';
import 'package:fyona_flutter/core/services/connectivity_service.dart';
import 'package:fyona_flutter/core/services/sync_engine.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  if (Platform.environment['FYONA_PROBE_MODE'] == null) {
    test('Personal probe needs a live directory lab', () {},
        skip: 'Run tools/verify_directory_personal.py with the isolated lab');
    return;
  }
  test('isolated live Personal probe', () async {
    final env = Platform.environment;
    final mode = env['FYONA_PROBE_MODE']!;
    final base = Uri.parse(env['FYONA_PROBE_BASE']!);
    if (!DirectoryPilotBuild.enabled ||
        base != DirectoryPilotBuild.setupUri) {
      fail('Only the specified Phase 1 QA origin is allowed');
    }
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.debugDatabasePath = env['FYONA_PROBE_DB'];
    const localUser = 41;
    final online = !{'stage', 'review-offline'}.contains(mode);
    final conn = ConnectivityService(debugOnline: online);
    final dio = Dio(BaseOptions(
      baseUrl: base.toString(),
      followRedirects: false,
      headers: {'Authorization': 'Bearer ${env['FYONA_PROBE_TOKEN']}'},
      connectTimeout: const Duration(seconds: 4),
      receiveTimeout: const Duration(seconds: 8),
    ));
    var requests = 0;
    var replayPosts = 0;
    var lost = false;
    var wireOnline = online;
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (o, handler) {
        if (!wireOnline) {
          handler.reject(DioException(
            requestOptions: o,
            type: DioExceptionType.connectionError,
          ));
          return;
        }
        requests++;
        if (o.method == 'POST' && o.path == '/personal/finance/transactions') {
          replayPosts++;
        }
        handler.next(o);
      },
      onResponse: (r, handler) {
        final o = r.requestOptions;
        if (!lost && mode == 'lose-receipt' && o.method == 'POST' &&
            o.path == '/personal/finance/transactions') {
          lost = true;
          wireOnline = false;
          conn.debugSetOnline(false);
          handler.reject(DioException(
            requestOptions: o,
            type: DioExceptionType.connectionError,
          ));
          return;
        }
        handler.next(r);
      },
    ));
    final api = ApiClient(dio: dio);
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(api),
      syncRepositoryProvider.overrideWithValue(SyncRepository(api)),
      connectivityServiceProvider.overrideWithValue(conn),
      syncEngineProvider.overrideWith(
        (ref) => SyncEngine(ref, userIdOverride: localUser),
      ),
    ]);
    final engine = container.read(syncEngineProvider);
    final cache = PersonalCacheRepository();
    final service = PersonalFinanceService(apiClient: api, cache: cache)
      ..setUserId(localUser);
    await engine.init();
    try {
      if (mode == 'stage') {
        await service.addBankAccount(
          bankName: 'Phase zero durable account',
          currency: 'SAR',
          openingBalance: 10,
        );
        final bank = (await service.getBankAccounts()).single;
        expect(await service.addTransaction(
          type: 'income',
          amount: 5,
          category: 'other',
          date: DateTime.now(),
          accountId: bank.id,
          currency: 'SAR',
        ), isTrue);
        expect(await SyncOutbox.pendingCount(userId: localUser), greaterThan(0));
        expect(requests, 0);
      } else if (mode == 'review-offline') {
        final rows = await cache.getCollection(localUser, 'personal_transaction');
        expect(rows.length, 1);
        expect((await service.getBankAccounts()).single.balance, 15);
        expect(await SyncOutbox.pendingCount(userId: localUser), greaterThan(0));
        expect(requests, 0);
      } else if (mode == 'lose-receipt') {
        await engine.processQueue();
        expect(lost, isTrue);
        expect(replayPosts, 1);
        final local = await engine.localSyncSnapshot();
        expect((local['pending'] as int) + (local['failed'] as int), greaterThan(0));
      } else if (mode == 'retry' || mode == 'destination') {
        await engine.processQueue();
        final rows = await cache.getCollection(localUser, 'personal_transaction');
        expect(rows.length, 1);
        final banks = await cache.getCollection(localUser, 'personal_bank_account');
        expect(banks.length, 1);
        expect(num.parse('${banks.single['balance']}'), 15);
        expect(await SyncOutbox.pendingCount(userId: localUser), 0);
        expect(await SyncOutbox.failedCount(userId: localUser), 0);
        expect(replayPosts, mode == 'retry' ? 1 : 0);
      } else {
        fail('Unknown test mode');
      }
      // The status timer from a completed processQueue must be drained before
      // the test runner shuts down; this changes no production behavior.
      await Future<void>.delayed(const Duration(milliseconds: 105));
    } finally {
      engine.dispose();
      container.dispose();
      dio.close(force: true);
      await DatabaseHelper.close();
    }
    // ignore: avoid_print
    print('PROBE_OK $mode');
  }, timeout: const Timeout(Duration(seconds: 32)));
}
