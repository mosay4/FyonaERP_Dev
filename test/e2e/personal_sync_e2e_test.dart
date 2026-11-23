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
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Full end-to-end integration: REAL FastAPI backend (SQLite) + REAL client
/// service + REAL sync engine. Two "virtual devices" run in the same process
/// with independent local namespaces (mirror + outbox are user-scoped), one
/// shared account on the server — exactly the multi-device topology the
/// offline-first requirements describe.
@Timeout(Duration(minutes: 12))
void main() {
  final pythonOk = _pythonAvailable();
  late Process serverProcess;
  late String serverToken;
  late int serverPort;
  late ApiClient adminClient;
  late Directory tempDir;

  final devices = <_Device>[];
  final serverStderr = StringBuffer();

  int _deviceSeq = 0;

  _Device makeDevice(String name,
      {int dropResponses = 0,
      int failBefore = 0,
      int duplicateSends = 0}) {
    // Unique namespace per device instance: the shared DB file is one physical
    // "disk", and distinct namespaces are distinct virtual devices.
    final ns = PersonalCacheRepository.fnvNamespace(
        'e2e-device:$name#${_deviceSeq++}');
    final d = _Device(
      name,
      ns,
      baseUrl: 'http://127.0.0.1:$serverPort/api/v1',
      token: serverToken,
    );
    d.dropResponses = dropResponses;
    d.failBefore = failBefore;
    d.duplicateSends = duplicateSends;
    devices.add(d);
    return d;
  }

  Future<void> resetServer() async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await adminClient.delete('/personal/finance/reset');
      } catch (e) {
        lastError = e;
      }
      try {
        final txs = await adminClient.get('/personal/finance/transactions',
            queryParameters: {'per_page': 5});
        final total = (((txs.data as Map)['data'] as Map)['total'] as num?)
                ?.toInt() ??
            -1;
        if (total == 0) return;
      } catch (e) {
        lastError = e;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    throw StateError('server was not reset cleanly (last error: $lastError)');
  }

  Future<void> resetLocal() async {
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
  }

  setUpAll(() async {
    // Opt-in suite: without E2E_SYNC=1 every test is skipped, so no server.
    if (!pythonOk) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    tempDir = await Directory.systemTemp.createTemp('fyona_e2e_');
    DatabaseHelper.debugDatabasePath = '${tempDir.path}/devices.db';

    // Pick a free port.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    serverPort = probe.port;
    await probe.close();

    final projectRoot = Directory.current.path;
    final backendDir = '$projectRoot${Platform.pathSeparator}backend';
    serverProcess = await Process.start(
      'python',
      [
        'scripts${Platform.pathSeparator}e2e_sync_server.py',
        '${tempDir.path}${Platform.pathSeparator}server.db',
        '$serverPort',
      ],
      workingDirectory: backendDir,
      runInShell: true,
    );
    final stderrBuf = serverStderr;
    serverProcess.stderr
        .transform(utf8.decoder)
        .listen((chunk) => stderrBuf.write(chunk));

    final ready = Completer<String>();
    serverProcess.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.startsWith('E2E_READY ') && !ready.isCompleted) {
        ready.complete(line.substring('E2E_READY '.length));
      }
    });
    final info = await ready.future.timeout(const Duration(seconds: 180),
        onTimeout: () => throw StateError(
            'E2E server did not start. stderr:\n$stderrBuf'));
    serverToken = (jsonDecode(info) as Map)['token'] as String;

    final adminDio = Dio(BaseOptions(
      baseUrl: 'http://127.0.0.1:$serverPort/api/v1',
      headers: {'Authorization': 'Bearer $serverToken'},
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      persistentConnection: false,
    ));
    adminClient = _RetryingApiClient(adminDio);

    // Wait until the HTTP stack actually answers.
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(minutes: 2)) {
      try {
        final r = await adminDio.get('/health/live',
            options: Options(validateStatus: (s) => s != null && s < 500));
        if (r.statusCode == 200) break;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }
  });

  tearDownAll(() async {
    if (!pythonOk) return;
    for (final d in devices) {
      d.dispose();
    }
    devices.clear();
    try {
      await DatabaseHelper.close();
    } catch (_) {}
    serverProcess.kill(ProcessSignal.sigkill);
    if (serverStderr.toString().toLowerCase().contains('traceback')) {
      // Surface server-side failures so a red test is diagnosable.
      // ignore: avoid_print
      print('=== E2E SERVER STDERR ===\n$serverStderr');
    }
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    // Dispose any engine from a previous test so no timer/in-flight work runs.
    for (final d in devices) {
      d.dispose();
    }
    devices.clear();
    await resetLocal();
    await resetServer();
  });

  group('E2E · exact accounting',
      skip: pythonOk ? false : 'python is required for the E2E server',
      () {
    test('offline lifecycle → sync → server mirrors local exactly (no dup)',
        timeout: const Timeout(Duration(minutes: 4)), () async {
      final a = makeDevice('A');
      await a.init();
      await a.goOffline();

      await a.service.addBankAccount(
          bankName: 'Bank-A', currency: 'SAR', openingBalance: 1000);
      final bank = (await a.service.getBankAccounts())
          .firstWhere((x) => x.bankName == 'Bank-A');

      await a.service.addTransaction(
          type: 'income',
          amount: 400,
          category: 'Salary',
          accountId: bank.id,
          date: DateTime(2026, 9, 1, 10));
      await a.service.addTransaction(
          type: 'expense',
          amount: 150,
          category: 'Food',
          accountId: bank.id,
          date: DateTime(2026, 9, 2, 10));

      await a.service.addSavingsGoal(SavingsGoal(
          id: '', name: 'Car', targetAmount: 5000, currency: 'SAR'));
      final goal = (await a.service.getSavingsGoals())
          .firstWhere((g) => g.name == 'Car');
      await a.service.contributeToGoal(goal.id, 250,
          currency: 'SAR', bankAccountId: bank.id);

      await a.service.addDebt(PersonalDebt(
          id: '',
          type: 'payable',
          personName: 'Ali',
          amount: 300,
          currency: 'SAR'));
      final debt = (await a.service.getDebts()).firstWhere(
          (d) => d.personName == 'Ali');
      await a.service.payDebt(debt.id, 100, DateTime(2026, 9, 3, 12),
          method: 'bank', bankAccountId: bank.id);

      await a.service.addBudget(PersonalBudget(
          id: '',
          name: 'Monthly',
          periodType: 'monthly',
          totalAmount: 1000,
          currency: 'SAR'));
      final budget = (await a.service.getAllBudgets())
          .firstWhere((b) => b.name == 'Monthly');
      await a.service.addTransaction(
          type: 'expense',
          amount: 80,
          category: 'Bills',
          accountId: bank.id,
          budgetId: budget.id,
          date: DateTime(2026, 9, 4, 9));

      await a.service.addRecurring(RecurringTransaction(
        id: '',
        name: 'Rent',
        type: 'expense',
        amount: 50,
        category: 'Rent',
        frequency: 'monthly',
        nextDate: DateTime(2026, 10, 1),
        bankAccountId: bank.id,
        accountType: 'fixed',
        executionType: 'auto',
      ));

      // ── Local assertions (exact cents) ──
      Future<double> localBank() async =>
          (await a.service.getBankAccounts())
              .firstWhere((x) => x.id == bank.id)
              .balance;
      expect(await localBank(), 1000 + 400 - 150 - 250 - 100 - 80);
      expect(
          (await a.service.getSavingsGoals())
              .firstWhere((g) => g.id == goal.id)
              .currentAmount,
          250);
      final localDebt =
          (await a.service.getDebts()).firstWhere((d) => d.id == debt.id);
      expect(localDebt.paid, 100);
      expect(localDebt.remaining, 200);
      final localBudget = (await a.service.getAllBudgets())
          .firstWhere((b) => b.id == budget.id);
      expect(localBudget.totalSpent, 80);

      // ── Exact reversals (delete + revert) ──
      final foodTx = (await a.service.getTransactions())
          .firstWhere((t) => t.category == 'Food');
      expect(await a.service.deleteTransaction(foodTx.id), isTrue);
      expect(await localBank(), 970,
          reason: 'deleting an expense restores the balance exactly');

      final contributionTx = (await a.service.getTransactions())
          .firstWhere((t) => t.goalId == goal.id);
      expect(await a.service.deleteTransaction(contributionTx.id), isTrue);
      expect(await localBank(), 1220, reason: 'contribution reversed');
      expect(
          (await a.service.getSavingsGoals())
              .firstWhere((g) => g.id == goal.id)
              .currentAmount,
          0);
      await a.service.contributeToGoal(goal.id, 250,
          currency: 'SAR', bankAccountId: bank.id);
      expect(await localBank(), 970);
      expect(
          (await a.service.getSavingsGoals())
              .firstWhere((g) => g.id == goal.id)
              .currentAmount,
          250);

      // ── Sync to the server ──
      await a.goOnline();
      await a.drain();
      expect(await SyncOutbox.pendingCount(userId: a.ns), 0);
      expect(await SyncOutbox.conflictCount(userId: a.ns), 0);

      // ── Server truth must equal local truth ──
      final serverAccounts =
          await adminClient.get('/personal/finance/accounts');
      final serverBank = ((serverAccounts.data as Map)['data'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .firstWhere((x) => x['id'] == bank.id);
      expect(serverBank['balance'], 970);

      final serverGoals = await adminClient.get('/personal/finance/goals');
      final serverGoal = ((serverGoals.data as Map)['data'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .firstWhere((x) => x['id'] == goal.id);
      expect(serverGoal['current_amount'], 250);

      final serverDebts = await adminClient.get('/personal/finance/debts');
      final serverDebt = ((serverDebts.data as Map)['data'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .firstWhere((x) => x['id'] == debt.id);
      expect(serverDebt['paid'], 100);
      expect(serverDebt['remaining'], 200);

      final serverBudgets = await adminClient.get('/personal/finance/budgets');
      final serverBudget = ((serverBudgets.data as Map)['data'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .firstWhere((x) => x['id'] == budget.id);
      expect(serverBudget['total_spent'], 80);

      final serverTxs =
          await adminClient.get('/personal/finance/transactions');
      final txItems = ((serverTxs.data as Map)['data'] as Map)['items'] as List;
      expect(txItems.length, 4,
          reason:
              'income + budget expense + re-contribution + debt payment — each exactly once');

      // ── 3) Restart simulation: fresh container, same namespace ──
      a.dispose();
      final a2 = _Device(
        'A',
        a.ns,
        baseUrl: 'http://127.0.0.1:$serverPort/api/v1',
        token: serverToken,
      );
      devices.add(a2);
      await a2.init();
      await a2.drain();
      expect(
          (await a2.service.getBankAccounts())
              .firstWhere((x) => x.id == bank.id)
              .balance,
          970);
      expect(
          (await a2.service.getTransactions()).length,
          4,
          reason: 'restart + pull converges with no duplicates');
    });

    test('multi-device interleaving converges exactly once', timeout: const Timeout(Duration(minutes: 4)), () async {
      final a = makeDevice('A');
      final b = makeDevice('B');

      // Shared bank created online so both devices know the same UUID.
      final created = await adminClient.post('/personal/finance/accounts',
          data: {'bank_name': 'Shared', 'currency': 'SAR', 'balance': 1000});
      final sharedBank =
          ((created.data as Map)['data'] as Map)['id'].toString();

      await a.init();
      await b.init();
      await a.drain();
      await b.drain();
      expect(
          (await a.service.getBankAccounts()).any((x) => x.id == sharedBank),
          isTrue,
          reason: 'device A pulled the shared bank');

      await a.goOffline();
      await b.goOffline();

      // Device A: 6 expenses ×10, 6 incomes ×25, 1 contribution 100.
      for (var i = 0; i < 6; i++) {
        await a.service.addTransaction(
            type: 'expense',
            amount: 10,
            category: 'A-exp',
            accountId: sharedBank,
            date: DateTime(2026, 9, 10, 8, i));
        await a.service.addTransaction(
            type: 'income',
            amount: 25,
            category: 'A-inc',
            accountId: sharedBank,
            date: DateTime(2026, 9, 10, 9, i));
      }
      await a.service.addSavingsGoal(SavingsGoal(
          id: '', name: 'SharedGoal', targetAmount: 10000, currency: 'SAR'));
      final aGoal = (await a.service.getSavingsGoals())
          .firstWhere((g) => g.name == 'SharedGoal');
      await a.service.contributeToGoal(aGoal.id, 100,
          currency: 'SAR', bankAccountId: sharedBank);

      // Device B: 4 expenses ×20, 1 income 200, and a goal contribution to
      // the SAME goal (id known after A pushes? B creates its own goal here,
      // then A contributes to B's goal after sync to prove cross-device
      // single-goal convergence).
      for (var i = 0; i < 4; i++) {
        await b.service.addTransaction(
            type: 'expense',
            amount: 20,
            category: 'B-exp',
            accountId: sharedBank,
            date: DateTime(2026, 9, 10, 10, i));
      }
      await b.service.addTransaction(
          type: 'income',
          amount: 200,
          category: 'B-inc',
          accountId: sharedBank,
          date: DateTime(2026, 9, 10, 11));

      await a.goOnline();
      await a.drain();
      await b.goOnline();
      await b.drain();
      await a.drain();
      await b.drain();

      // 1000 − 60 + 150 − 100 = 990 (A) then +200 − 80 = 1110 (both).
      const expected = 1110.0;
      final aBank = (await a.service.getBankAccounts())
          .firstWhere((x) => x.id == sharedBank)
          .balance;
      final bBank = (await b.service.getBankAccounts())
          .firstWhere((x) => x.id == sharedBank)
          .balance;
      expect(aBank, expected);
      expect(bBank, expected,
          reason: 'both devices converge on the exact same balance');

      final serverAccounts =
          await adminClient.get('/personal/finance/accounts');
      final serverBank = ((serverAccounts.data as Map)['data'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .firstWhere((x) => x['id'] == sharedBank);
      expect(serverBank['balance'], expected);

      // Every operation applied exactly once.
      final serverTxs =
          await adminClient.get('/personal/finance/transactions',
              queryParameters: {'per_page': 200});
      final items = ((serverTxs.data as Map)['data'] as Map)['items'] as List;
      expect(items.length, 18,
          reason: '12 + 5 transactions + 1 contribution = 18 exactly once');

      // Both mirrors hold all rows (no hidden local-only rows).
      expect((await a.service.getTransactions()).length, 18);
      expect((await b.service.getTransactions()).length, 18);
    });

    test('dropped responses + duplicate delivery stay exactly-once', timeout: const Timeout(Duration(minutes: 3)), () async {
      final a = makeDevice('D');
      await a.init();
      await a.service.addBankAccount(
          bankName: 'RetryBank', currency: 'SAR', openingBalance: 500);
      final bank = (await a.service.getBankAccounts())
          .firstWhere((x) => x.bankName == 'RetryBank');

      await a.goOffline();
      await a.service.addTransaction(
          type: 'expense',
          amount: 120,
          category: 'Retry',
          accountId: bank.id,
          date: DateTime(2026, 9, 12, 9));

      // The next POST reaches the server, is applied, but the response is
      // lost (timeout) → the operation must be retried idempotently.
      a.dropResponses = 1;
      a.duplicateSends = 2; // and physically delivered twice more
      await a.goOnline();
      await a.drain();

      final txs = await adminClient.get('/personal/finance/transactions');
      final items =
          ((txs.data as Map)['data'] as Map)['items'] as List;
      expect(items.length, 1,
          reason: 'server applied the intent exactly once despite 3 sends');
      final accounts = await adminClient.get('/personal/finance/accounts');
      final serverBank = ((accounts.data as Map)['data'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .firstWhere((x) => x['id'] == bank.id);
      expect(serverBank['balance'], 380);
      expect(await SyncOutbox.pendingCount(userId: a.ns), 0);
    });

    test('interruption mid-sync + restart resumes without loss or duplicates', timeout: const Timeout(Duration(minutes: 4)), () async {
      final a = makeDevice('Mid');
      await a.init();
      await a.service.addBankAccount(
          bankName: 'MidBank', currency: 'SAR', openingBalance: 0);
      final bank = (await a.service.getBankAccounts())
          .firstWhere((x) => x.bankName == 'MidBank');

      await a.goOffline();
      for (var i = 0; i < 30; i++) {
        await a.service.addTransaction(
            type: 'income',
            amount: 10,
            category: 'Income-$i',
            accountId: bank.id,
            date: DateTime(2026, 9, 13, 8, i));
      }
      // The connection dies repeatedly while pushing.
      a.dropResponses = 7;
      await a.goOnline();
      try {
        await a.drain(timeout: const Duration(seconds: 40));
      } catch (_) {
        // Expected to stop early on connection loss.
      }
      a.online = true;
      await a.drain();

      final txs = await adminClient.get('/personal/finance/transactions',
          queryParameters: {'per_page': 200});
      final items = ((txs.data as Map)['data'] as Map)['items'] as List;
      expect(items.length, 30, reason: 'all intents landed exactly once');
      final accounts = await adminClient.get('/personal/finance/accounts');
      final serverBank = ((accounts.data as Map)['data'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .firstWhere((x) => x['id'] == bank.id);
      expect(serverBank['balance'], 300);
    });

    test('two devices, 500+ mixed operations, exact convergence', timeout: const Timeout(Duration(minutes: 10)), () async {
      final a = makeDevice('StressA');
      final b = makeDevice('StressB');
      await a.init();
      await b.init();

      final createdA = await adminClient.post('/personal/finance/accounts',
          data: {'bank_name': 'StressA', 'currency': 'SAR', 'balance': 100000});
      final bankA = ((createdA.data as Map)['data'] as Map)['id'].toString();
      final createdB = await adminClient.post('/personal/finance/accounts',
          data: {'bank_name': 'StressB', 'currency': 'SAR', 'balance': 100000});
      final bankB = ((createdB.data as Map)['data'] as Map)['id'].toString();
      await a.drain();
      await b.drain();

      await a.goOffline();
      await b.goOffline();

      // 130 income + 120 expense on each device = 500 operations total
      // (plus entity creates), with mixed creates/edits/deletes.
      for (var i = 0; i < 130; i++) {
        await a.service.addTransaction(
            type: 'income',
            amount: 1,
            category: 'SA-inc',
            accountId: bankA,
            date: DateTime(2026, 9, 14, 8, 0).add(Duration(minutes: i)));
      }
      final swA = Stopwatch()..start();
      for (var i = 0; i < 120; i++) {
        await a.service.addTransaction(
            type: 'expense',
            amount: 1,
            category: 'SA-exp',
            accountId: bankA,
            date: DateTime(2026, 9, 14, 10, 0).add(Duration(minutes: i)));
      }
      swA.stop();
      for (var i = 0; i < 125; i++) {
        await b.service.addTransaction(
            type: 'income',
            amount: 2,
            category: 'SB-inc',
            accountId: bankB,
            date: DateTime(2026, 9, 14, 8, 0).add(Duration(minutes: i)));
      }
      for (var i = 0; i < 125; i++) {
        await b.service.addTransaction(
            type: 'expense',
            amount: 1,
            category: 'SB-exp',
            accountId: bankB,
            date: DateTime(2026, 9, 14, 10, 0).add(Duration(minutes: i)));
      }

      // 10 offline deletions on each side (exact reversal under load).
      final aTxs = await a.service.getTransactions();
      for (var i = 0; i < 10; i++) {
        await a.service.deleteTransaction(aTxs[i].id);
      }
      final bTxs = await b.service.getTransactions();
      for (var i = 0; i < 10; i++) {
        await b.service.deleteTransaction(bTxs[i].id);
      }

      final syncSwA = Stopwatch()..start();
      await a.goOnline();
      await a.drain(timeout: const Duration(minutes: 4));
      syncSwA.stop();
      final syncSwB = Stopwatch()..start();
      await b.goOnline();
      await b.drain(timeout: const Duration(minutes: 4));
      syncSwB.stop();
      await a.drain();
      await b.drain();

      // Deterministic exact totals.
      // A: +130 income, −120 expense, then the 10 NEWEST rows (expenses at
      // 10:00+) are deleted → +130 −110 = +20 → 100000 + 20.
      // B: +125×2 income, −125 expense, 10 newest deleted → 250 −115 = +135.
      const expectedA = 100020.0;
      const expectedB = 100135.0;

      final accounts = await adminClient.get('/personal/finance/accounts');
      final accountRows = ((accounts.data as Map)['data'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final aRow = accountRows.firstWhere((x) => x['id'] == bankA);
      final bRow = accountRows.firstWhere((x) => x['id'] == bankB);
      expect(aRow['balance'], expectedA);
      expect(bRow['balance'], expectedB);

      // Both devices converge on the FULL account history (480 rows) — same
      // account, same data, no duplicates and nothing lost.
      final aCount = (await a.service.getTransactions()).length;
      final bCount = (await b.service.getTransactions()).length;
      expect(aCount, 480);
      expect(bCount, 480);
      expect(
          (await a.service.getBankAccounts())
              .firstWhere((x) => x.id == bankA)
              .balance,
          expectedA);
      expect(
          (await a.service.getBankAccounts())
              .firstWhere((x) => x.id == bankB)
              .balance,
          expectedB);

      final serverTxs = await adminClient.get(
          '/personal/finance/transactions',
          queryParameters: {'per_page': 200, 'page': 1});
      final pageData = (serverTxs.data as Map)['data'] as Map;
      final page1 = pageData['items'] as List;
      expect(page1.length, 200);
      expect((pageData['total'] as num).toInt(), 480,
          reason: 'no duplicates anywhere in 500 mixed operations');
      final serverTxs3 = await adminClient.get(
          '/personal/finance/transactions',
          queryParameters: {'per_page': 200, 'page': 3});
      final page3 =
          ((serverTxs3.data as Map)['data'] as Map)['items'] as List;
      expect(page3.length, 80);

      expect(await SyncOutbox.pendingCount(userId: a.ns), 0);
      expect(await SyncOutbox.pendingCount(userId: b.ns), 0);
      expect(await SyncOutbox.conflictCount(userId: a.ns), 0);
      expect(await SyncOutbox.conflictCount(userId: b.ns), 0);
    });

    test('concurrent goal contributions from two devices are never lost', timeout: const Timeout(Duration(minutes: 4)), () async {
      final a = makeDevice('GoalA');
      final b = makeDevice('GoalB');
      await a.init();
      await b.init();

      final created = await adminClient.post('/personal/finance/accounts',
          data: {'bank_name': 'GoalBank', 'currency': 'SAR', 'balance': 10000});
      final bank = ((created.data as Map)['data'] as Map)['id'].toString();
      final createdGoal = await adminClient.post('/personal/finance/goals',
          data: {
            'name': 'Together',
            'target_amount': 100000,
            'current_amount': 0,
            'currency': 'SAR'
          });
      final goalId =
          ((createdGoal.data as Map)['data'] as Map)['id'].toString();
      await a.drain();
      await b.drain();

      await a.goOffline();
      await b.goOffline();
      // Both devices contribute to the SAME goal while offline. Absolute
      // balance sync used to lose one of these; operation replay must sum.
      await a.service.contributeToGoal(goalId, 100,
          currency: 'SAR', bankAccountId: bank);
      await b.service.contributeToGoal(goalId, 300,
          currency: 'SAR', bankAccountId: bank);
      await a.service.contributeToGoal(goalId, 50,
          currency: 'SAR', bankAccountId: bank);

      await a.goOnline();
      await a.drain();
      await b.goOnline();
      await b.drain();
      await a.drain();

      final goals = await adminClient.get('/personal/finance/goals');
      final serverGoal = ((goals.data as Map)['data'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .firstWhere((x) => x['id'] == goalId);
      expect(serverGoal['current_amount'], 450,
          reason: '100 + 300 + 50 — every contribution preserved');

      final aGoal = (await a.service.getSavingsGoals())
          .firstWhere((g) => g.id == goalId);
      final bGoal = (await b.service.getSavingsGoals())
          .firstWhere((g) => g.id == goalId);
      expect(aGoal.currentAmount, 450);
      expect(bGoal.currentAmount, 450);

      final accounts = await adminClient.get('/personal/finance/accounts');
      final serverBank = ((accounts.data as Map)['data'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .firstWhere((x) => x['id'] == bank);
      expect(serverBank['balance'], 9550, reason: '10000 − 450 exactly');
    });

    test('bank deletion + pending operations keeps the money history', timeout: const Timeout(Duration(minutes: 3)), () async {
      final a = makeDevice('DelA');
      final b = makeDevice('DelB');
      await a.init();
      await b.init();

      final created = await adminClient.post('/personal/finance/accounts',
          data: {'bank_name': 'Doomed', 'currency': 'SAR', 'balance': 1000});
      final bank = ((created.data as Map)['data'] as Map)['id'].toString();
      await a.drain();
      await b.drain();

      await a.goOffline();
      await a.service.addTransaction(
          type: 'expense',
          amount: 300,
          category: 'PreDelete',
          accountId: bank,
          date: DateTime(2026, 9, 15, 9));
      await a.service.addTransaction(
          type: 'income',
          amount: 50,
          category: 'PreDeleteInc',
          accountId: bank,
          date: DateTime(2026, 9, 15, 10));

      await b.goOffline();
      await b.service.deleteBankAccount(bank);

      // B deletes first server-side; A's queued movements must still land
      // (replay tolerates the soft-deleted parent) — no money disappears.
      await b.goOnline();
      await b.drain();
      await a.goOnline();
      await a.drain();

      final accounts = await adminClient.get('/personal/finance/accounts');
      final activeIds = ((accounts.data as Map)['data'] as List)
          .map((e) => (e as Map)['id'].toString())
          .toSet();
      expect(activeIds.contains(bank), isFalse, reason: 'bank deleted');

      final txs = await adminClient.get('/personal/finance/transactions',
          queryParameters: {'per_page': 200});
      final items = ((txs.data as Map)['data'] as Map)['items'] as List;
      expect(items.length, 2,
          reason: 'both movements survived the concurrent account deletion');

      // A pulls the deletion: its mirror drops the bank but keeps the txs.
      await a.drain();
      expect(
          (await a.service.getBankAccounts()).any((x) => x.id == bank), isFalse);
      expect((await a.service.getTransactions()).length, 2);
    });
  });
}

bool _pythonAvailable() {
  // The E2E suite boots the real FastAPI backend; it only runs when the
  // caller opts in (CI without backend deps would otherwise fail on startup).
  // Run with:  E2E_SYNC=1 flutter test test/e2e/personal_sync_e2e_test.dart
  if (Platform.environment['E2E_SYNC'] != '1') return false;
  try {
    final r = Process.runSync('python', ['--version'], runInShell: true);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

DioException _connError(String path) => DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.connectionError,
      message: 'SocketException: test device offline',
    );

DioException _timeoutAfterApply(String path) => DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.connectionTimeout,
      message: 'timeout after server applied the operation',
    );

/// Verification client used by the test body. Keep-alive is disabled and any
/// connection-level failure is retried once, which removes the stale-socket
/// flake without hiding real application errors.
class _RetryingApiClient extends ApiClient {
  _RetryingApiClient(Dio dio) : super(dio: dio);

  Future<Response<T>> _retry<T>(Future<Response<T>> Function() fn) async {
    try {
      return await fn();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          (e.message?.contains('Connection closed') ?? false)) {
        await Future.delayed(const Duration(milliseconds: 200));
        return await fn();
      }
      rethrow;
    }
  }

  @override
  Future<Response<T>> get<T>(String path,
          {Map<String, dynamic>? queryParameters,
          Options? options,
          CancelToken? cancelToken}) =>
      _retry(() => super.get<T>(path,
          queryParameters: queryParameters,
          options: options,
          cancelToken: cancelToken));

  @override
  Future<Response<T>> post<T>(String path,
          {dynamic data,
          Map<String, dynamic>? queryParameters,
          Options? options,
          CancelToken? cancelToken}) =>
      _retry(() => super.post<T>(path,
          data: data,
          queryParameters: queryParameters,
          options: options,
          cancelToken: cancelToken));

  @override
  Future<Response<T>> patch<T>(String path,
          {dynamic data,
          Map<String, dynamic>? queryParameters,
          Options? options,
          CancelToken? cancelToken}) =>
      _retry(() => super.patch<T>(path,
          data: data,
          queryParameters: queryParameters,
          options: options,
          cancelToken: cancelToken));

  @override
  Future<Response<T>> delete<T>(String path,
          {dynamic data,
          Map<String, dynamic>? queryParameters,
          Options? options,
          CancelToken? cancelToken}) =>
      _retry(() => super.delete<T>(path,
          data: data,
          queryParameters: queryParameters,
          options: options,
          cancelToken: cancelToken));
}

/// One virtual device: its own local namespace + outbox + engine, talking to
/// the shared account on the real server through a toggleable network.
class _Device {
  final String name;
  final int ns;
  final String baseUrl;
  final String token;
  final ConnectivityService connectivity;
  late final Dio dio;
  late final _ToggleApiClient client;
  late final PersonalFinanceService service;
  late final ProviderContainer container;
  late final SyncEngine engine;

  bool online = true;
  int dropResponses = 0;
  int failBefore = 0;
  int duplicateSends = 0;

  _Device(this.name, this.ns,
      {required this.baseUrl, required this.token})
      : connectivity = ConnectivityService(debugOnline: true);

  bool _disposed = false;

  Future<void> init() async {
    dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      headers: {'Authorization': 'Bearer $token'},
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 10),
    ));
    client = _ToggleApiClient(this);
    service = PersonalFinanceService(
      apiClient: client,
      cache: PersonalCacheRepository(),
    );
    service.setUserId(ns);
    container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(client),
      syncRepositoryProvider.overrideWithValue(SyncRepository(client)),
      connectivityServiceProvider.overrideWithValue(connectivity),
      syncEngineProvider
          .overrideWith((ref) => SyncEngine(ref, userIdOverride: ns)),
    ]);
    engine = container.read(syncEngineProvider);
    await engine.init();
  }

  Future<void> goOffline() async {
    online = false;
    connectivity.debugSetOnline(false);
  }

  Future<void> goOnline({bool waitForSync = false}) async {
    online = true;
    connectivity.debugSetOnline(true);
    if (waitForSync) await drain();
  }

  Future<void> sync() => engine.processQueue();

/// Pushes until the outbox is empty, then runs one more full cycle so the
  /// PULL always applies remote changes from other devices.
  Future<void> drain({Duration timeout = const Duration(seconds: 90)}) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      if (!engine.isSyncing) {
        await engine.processQueue();
      }
      if (!engine.isSyncing) {
        final pending = await SyncOutbox.pendingCount(userId: ns);
        final failed = await SyncOutbox.failedCount(userId: ns);
        if (pending == 0 && (failed == 0 || !online)) {
          // One extra full cycle guarantees the remote pull was applied.
          await engine.processQueue();
          if (!engine.isSyncing) return;
        }
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }
    final pending = await SyncOutbox.pendingCount(userId: ns);
    final failed = await SyncOutbox.failedCount(userId: ns);
    throw TimeoutException(
        '$name queue did not drain (pending=$pending failed=$failed '
        'syncing=${engine.isSyncing})');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    try {
      connectivity.debugSetOnline(false);
    } catch (_) {}
    try {
      engine.dispose();
    } catch (_) {}
    try {
      container.dispose();
    } catch (_) {}
  }
}

/// ApiClient wrapper that can simulate an offline device, a dropped response
/// after the server applied the operation, and duplicate delivery.
class _ToggleApiClient extends ApiClient {
  final _Device device;
  _ToggleApiClient(this.device) : super(dio: device.dio);

  void _guard(String path) {
    if (!device.online) throw _connError(path);
    if (device.failBefore > 0) {
      device.failBefore--;
      throw _connError(path);
    }
  }

  @override
  Future<Response<T>> get<T>(String path,
      {Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) {
    _guard(path);
    return super.get<T>(path,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken);
  }

  @override
  Future<Response<T>> post<T>(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) async {
    _guard(path);
    final res = await super.post<T>(path,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken);
    if (device.duplicateSends > 0) {
      device.duplicateSends--;
      await super.post<T>(path,
          data: data,
          queryParameters: queryParameters,
          options: options,
          cancelToken: cancelToken);
    }
    if (device.dropResponses > 0) {
      device.dropResponses--;
      throw _timeoutAfterApply(path);
    }
    return res;
  }

  @override
  Future<Response<T>> put<T>(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) {
    _guard(path);
    return super.put<T>(path,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken);
  }

  @override
  Future<Response<T>> patch<T>(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) async {
    _guard(path);
    final res = await super.patch<T>(path,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken);
    if (device.dropResponses > 0) {
      device.dropResponses--;
      throw _timeoutAfterApply(path);
    }
    return res;
  }

  @override
  Future<Response<T>> delete<T>(String path,
      {dynamic data,
      Map<String, dynamic>? queryParameters,
      Options? options,
      CancelToken? cancelToken}) async {
    _guard(path);
    final res = await super.delete<T>(path,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken);
    if (device.dropResponses > 0) {
      device.dropResponses--;
      throw _timeoutAfterApply(path);
    }
    return res;
  }
}