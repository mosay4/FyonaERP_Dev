import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
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

/// Focused reproduction of the reported bug: an income added while ONLINE
/// must stay visible through push → queue-delete → pull, exactly like the
/// offline path — no vanish, no need for manual refreshes.
@Timeout(Duration(minutes: 8))
void main() {
  final runE2E = Platform.environment['E2E_SYNC'] == '1';
  late Process serverProcess;
  late String serverToken;
  late int serverPort;
  late Directory tempDir;
  final serverStderr = StringBuffer();

  Future<ApiClient> makeClient(String token) async {
    final dio = Dio(BaseOptions(
      baseUrl: 'http://127.0.0.1:$serverPort/api/v1',
      headers: {'Authorization': 'Bearer $token'},
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 10),
      persistentConnection: false,
    ));
    return ApiClient(dio: dio);
  }

  setUpAll(() async {
    if (!runE2E) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = await Directory.systemTemp.createTemp('fyona_income_e2e_');
    DatabaseHelper.debugDatabasePath = '${tempDir.path}/device.db';

    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    serverPort = probe.port;
    await probe.close();

    final projectRoot = Directory.current.path;
    serverProcess = await Process.start(
      'python',
      [
        'scripts${Platform.pathSeparator}e2e_sync_server.py',
        '${tempDir.path}${Platform.pathSeparator}server.db',
        '$serverPort',
      ],
      workingDirectory: '$projectRoot${Platform.pathSeparator}backend',
      runInShell: true,
    );
    serverProcess.stderr
        .transform(utf8.decoder)
        .listen((chunk) => serverStderr.write(chunk));
    final ready = Completer<String>();
    serverProcess.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.startsWith('E2E_READY ') && !ready.isCompleted) {
        ready.complete(line.substring('E2E_READY '.length));
      }
    });
    final info = await ready.future.timeout(const Duration(seconds: 180));
    serverToken = (jsonDecode(info) as Map)['token'] as String;
  });

  tearDownAll(() async {
    if (!runE2E) return;
    try {
      await DatabaseHelper.close();
    } catch (_) {}
    try {
      serverProcess.kill(ProcessSignal.sigkill);
    } catch (_) {}
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> resetAll(ApiClient admin) async {
    for (final table in const [
      'personal_entity_cache',
      'sync_queue',
      'sync_operation_log',
      'sync_cursor',
    ]) {
      try {
        await DatabaseHelper.rawDelete('DELETE FROM $table');
      } catch (_) {}
    }
    for (var i = 0; i < 3; i++) {
      try {
        await admin.delete('/personal/finance/reset');
        return;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  group('online income visibility', skip: runE2E ? false : 'needs E2E_SYNC=1',
      () {
    test('added-online income survives the whole sync cycle', () async {
      final admin = await makeClient(serverToken);
      await resetAll(admin);

      const ns = 424242;
      final connectivity = ConnectivityService(debugOnline: true);
      final dio = Dio(BaseOptions(
        baseUrl: 'http://127.0.0.1:$serverPort/api/v1',
        headers: {'Authorization': 'Bearer $serverToken'},
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
        persistentConnection: false,
      ));
      final client = ApiClient(dio: dio);
      final service = PersonalFinanceService(
        apiClient: client,
        cache: PersonalCacheRepository(),
      );
      service.setUserId(ns);
      final container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(client),
        syncRepositoryProvider.overrideWithValue(SyncRepository(client)),
        connectivityServiceProvider.overrideWithValue(connectivity),
        syncEngineProvider
            .overrideWith((ref) => SyncEngine(ref, userIdOverride: ns)),
      ]);
      final engine = container.read(syncEngineProvider);
      await engine.init();

      Future<void> drain() async {
        final sw = Stopwatch()..start();
        while (sw.elapsed < const Duration(seconds: 60)) {
          if (!engine.isSyncing) await engine.processQueue();
          if (!engine.isSyncing) {
            final pending = await SyncOutbox.pendingCount(userId: ns);
            if (pending == 0) {
              await engine.processQueue();
              if (!engine.isSyncing) return;
            }
          }
          await Future.delayed(const Duration(milliseconds: 150));
        }
        throw TimeoutException('queue did not drain');
      }

      Future<String> dumpState(String tag) async {
        final rows = await PersonalCacheRepository()
            .getCollection(ns, 'personal_transaction');
        final ops = await DatabaseHelper.rawQuery(
            'SELECT entity_id, status FROM sync_queue WHERE user_id = ?',
            [ns.toString()]);
        final buf = StringBuffer('$tag mirror=${rows.length} ');
        for (final r in rows) {
          buf.write(
              "[${r['id']} ${r['tx_type']}/${r['amount']} ${r['currency']}] ");
        }
        buf.write('queue=${ops.length} ');
        for (final o in ops) {
          buf.write('(${o['entity_id']}:${o['status']}) ');
        }
        // ignore: avoid_print
        print(buf.toString());
        return buf.toString();
      }

      try {
        // Account exists and is already synced (the normal app situation).
        await service.addBankAccount(
            bankName: 'IncBank', currency: 'SAR', openingBalance: 1000);
        await drain();
        final bank = (await service.getBankAccounts())
            .firstWhere((x) => x.bankName == 'IncBank');

        // Phase 1+2 like the UI: add, then immediately reread.
        final ok = await service.addTransaction(
          type: 'income',
          amount: 250,
          category: 'Salary',
          accountId: bank.id,
          currency: 'SAR',
          date: DateTime.now(),
        );
        expect(ok, isTrue);
        var list = await service.getTransactions();
        expect(
          list.any((t) => t.amount == 250 && t.type == 'income'),
          isTrue,
          reason: 'visible right after add (online)',
        );
        await dumpState('after-add');

        // Let the fire-and-forget sync fully settle (push + pull).
        await drain();
        await dumpState('after-sync');

        // The user refreshes — the income must still be there, every time.
        for (var i = 0; i < 3; i++) {
          list = await service.getTransactions();
          expect(
            list.any((t) => t.amount == 250 && t.type == 'income'),
            isTrue,
            reason: 'still visible after sync (read $i)',
          );
        }

        // Exactly one such row locally, queue fully drained.
        final rows = await PersonalCacheRepository()
            .getCollection(ns, 'personal_transaction');
        final matches = rows
            .where((r) =>
                (r['amount'] as num?)?.toDouble() == 250 &&
                (r['tx_type']?.toString() == 'income'))
            .toList();
        expect(matches.length, 1, reason: 'no duplicate, no loss');
        expect(await SyncOutbox.pendingCount(userId: ns), 0);
      } finally {
        try {
          engine.dispose();
        } catch (_) {}
        try {
          container.dispose();
        } catch (_) {}
      }
    });
  });
}
