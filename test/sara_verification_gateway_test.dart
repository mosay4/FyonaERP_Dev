import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_executor.dart';
import 'package:fyona_flutter/features/ai/domain/agent/verification_gateway.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/di/personal_providers.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';

/// P0 verification gateway tests: every outcome must reflect truth.
/// No network is touched except dead-port Dio (fast-fail); sync states are
/// driven through the real sync_queue / sync_operation_log tables.
void main() {
  const uid = 91;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  PersonalFinanceService makeService() {
    final dio = Dio(BaseOptions(
      baseUrl: 'http://127.0.0.1:9',
      connectTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
    ));
    final svc = PersonalFinanceService(
      apiClient: ApiClient(dio: dio),
      cache: PersonalCacheRepository(),
    );
    svc.setUserId(uid);
    return svc;
  }

  Future<void> cleanAll() async {
    await DatabaseHelper.rawDelete(
        'DELETE FROM personal_entity_cache WHERE user_id = ?',
        [uid.toString()]);
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
    await DatabaseHelper.rawDelete('DELETE FROM sync_operation_log');
  }

  setUp(() async => cleanAll());
  tearDown(() async => cleanAll());

  Future<void> seedQueueRow({
    required String entityType,
    required String entityId,
    required String status,
  }) async {
    await DatabaseHelper.insert('sync_queue', {
      'operation_id': 'op_${entityId}_$status',
      'table_name': 't',
      'entity_type': entityType,
      'entity_id': entityId,
      'operation': 'INSERT',
      'status': status,
      'user_id': uid,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> seedArchiveRow({
    required String entityType,
    required String entityId,
    required String status,
  }) async {
    await DatabaseHelper.insert('sync_operation_log', {
      'operation_id': 'op_${entityId}_$status',
      'entity_type': entityType,
      'entity_id': entityId,
      'operation': 'INSERT',
      'status': status,
      'user_id': uid,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  SaraVerificationGateway gw({
    Map<String, Map<String, dynamic>?> local = const {},
    bool localThrows = false,
    Future<Map<String, dynamic>?> Function(String, String)? server,
  }) {
    return SaraVerificationGateway(
      readLocal: (t, id) async {
        if (localThrows) throw Exception('mirror read blew up');
        final key = '$t:$id';
        if (!local.containsKey(key)) return null;
        return local[key];
      },
      readServer: server,
      serverTimeout: const Duration(milliseconds: 300),
    );
  }

  Map<String, dynamic> row(String id) => {'id': id, 'name': 'x'};

  group('gateway core states', () {
    test('local success + sync success => SUCCESS_CONFIRMED', () async {
      final g = gw(local: {'personal_budget:b1': row('b1')});
      await seedArchiveRow(
          entityType: 'personal_budget', entityId: 'b1', status: 'synced');
      final r = await g.verifyCreate(
        tool: 'create_budget', queueEntityType: 'personal_budget',
        resolveId: () async => 'b1',
        successAr: 'ok', successEn: 'ok',
        failureAr: 'fail', failureEn: 'fail',
      );
      expect(r.state, SaraVerificationState.successConfirmed);
      expect(r.serverConfirmed, isTrue);
      expect(SaraVerificationResult.toneFor(r.state), '✅');
    });

    test('local success + sync pending + server down => PENDING (not failed)', () async {
      final g = gw(local: {'personal_budget:b1': row('b1')});
      await seedQueueRow(
          entityType: 'personal_budget', entityId: 'b1', status: 'pending');
      final r = await g.verifyCreate(
        tool: 'create_budget', queueEntityType: 'personal_budget',
        resolveId: () async => 'b1',
        successAr: 'تم', successEn: 'done',
        failureAr: 'فشل', failureEn: 'failed',
      );
      expect(r.state, SaraVerificationState.successLocalPendingSync);
      expect(r.messageAr, contains('بانتظار المزامنة'));
      expect(SaraVerificationResult.toneFor(r.state), '⏳');
    });

    test('local success + sync failed => SYNC_FAILED', () async {
      final g = gw(local: {'personal_budget:b1': row('b1')});
      await seedQueueRow(
          entityType: 'personal_budget', entityId: 'b1', status: 'failed');
      final r = await g.verifyCreate(
        tool: 'create_budget', queueEntityType: 'personal_budget',
        resolveId: () async => 'b1',
        successAr: 'تم', successEn: 'done',
        failureAr: 'فشل', failureEn: 'failed',
      );
      expect(r.state, SaraVerificationState.syncFailed);
      expect(SaraVerificationResult.toneFor(r.state), '❌');
    });

    test('resolveId null => NOT_FOUND (commit failure path)', () async {
      final g = gw(local: const {});
      final r = await g.verifyCreate(
        tool: 'create_budget', queueEntityType: 'personal_budget',
        resolveId: () async => null,
        successAr: 'تم', successEn: 'done',
        failureAr: 'فشل', failureEn: 'failed',
      );
      expect(r.state, SaraVerificationState.notFound);
    });

    test('verification read failure => VERIFICATION_FAILED (never FAILED)', () async {
      final g = gw(localThrows: true);
      final r = await g.verifyCreate(
        tool: 'create_budget', queueEntityType: 'personal_budget',
        resolveId: () async => 'b1',
        successAr: 'تم', successEn: 'done',
        failureAr: 'فشل', failureEn: 'failed',
      );
      expect(r.state, SaraVerificationState.verificationFailed);
      expect(SaraVerificationResult.toneFor(r.state), '⚠️');
    });

    test('entity not found on read-back => NOT_FOUND', () async {
      final g = gw(local: const {});
      final r = await g.verifyCreate(
        tool: 'create_budget', queueEntityType: 'personal_budget',
        resolveId: () async => 'ghost',
        successAr: 'تم', successEn: 'done',
        failureAr: 'فشل', failureEn: 'failed',
      );
      expect(r.state, SaraVerificationState.notFound);
    });

    test('duplicate retry replays stored result without re-executing', () async {
      final g = gw(local: {'personal_budget:b1': row('b1')});
      var runs = 0;
      Future<SaraVerificationResult> run() async {
        runs++;
        return g.verifyCreate(
          tool: 'create_budget', queueEntityType: 'personal_budget',
          resolveId: () async => 'b1',
          successAr: 'تم', successEn: 'done',
          failureAr: 'فشل', failureEn: 'failed',
        );
      }

      const key = 'create_budget|amount=1';
      final first = await g.executeOnce(opKey: key, run: run);
      final second = await g.executeOnce(opKey: key, run: run);
      expect(runs, 1);
      expect(second.deduplicated, isTrue);
      expect(second.state, first.state);
      // Concurrent duplicates share one future.
      runs = 0;
      final results = await Future.wait([
        g.executeOnce(opKey: 'k2', run: run),
        g.executeOnce(opKey: 'k2', run: run),
      ]);
      expect(runs, 1);
      expect(results[0].state, results[1].state);
    });

    test('offline then reconnect: pending first, confirmed after', () async {
      var online = false;
      final g = gw(
        local: {'personal_budget:b1': row('b1')},
        server: (t, id) async {
          if (!online) throw DioException.connectionError(
              requestOptions: RequestOptions(path: '/x'),
              reason: 'no internet');
          return row('b1');
        },
      );
      final offline = await g.verifyCreate(
        tool: 'create_budget', queueEntityType: 'personal_budget',
        resolveId: () async => 'b1',
        successAr: 'تم', successEn: 'done',
        failureAr: 'فشل', failureEn: 'failed',
      );
      expect(offline.state, SaraVerificationState.successLocalPendingSync);
      online = true;
      final onlineRes = await g.verifyCreate(
        tool: 'create_budget', queueEntityType: 'personal_budget',
        resolveId: () async => 'b1',
        successAr: 'تم', successEn: 'done',
        failureAr: 'فشل', failureEn: 'failed',
      );
      expect(onlineRes.state, SaraVerificationState.successConfirmed);
      expect(onlineRes.serverConfirmed, isTrue);
    });

    test('timeout then retry: pending first, confirmed after', () async {
      var slow = true;
      final g = gw(
        local: {'personal_budget:b1': row('b1')},
        server: (t, id) async {
          if (slow) await Future.delayed(const Duration(seconds: 5));
          return row('b1');
        },
      );
      final timedOut = await g.verifyCreate(
        tool: 'create_budget', queueEntityType: 'personal_budget',
        resolveId: () async => 'b1',
        successAr: 'تم', successEn: 'done',
        failureAr: 'فشل', failureEn: 'failed',
      );
      expect(timedOut.state, SaraVerificationState.successLocalPendingSync);
      slow = false;
      final retried = await g.checkOperation(
        tool: 'get_operation_status',
        queueEntityType: 'personal_budget',
        entityId: 'b1',
      );
      expect(retried.state, SaraVerificationState.successConfirmed);
    });

    test('update mismatch => FAILED; delete gone => confirmed path', () async {
      final g = gw(local: {
        'personal_budget:b1': {'id': 'b1', 'name': 'old', 'total_amount': 5},
      });
      final mismatch = await g.verifyUpdate(
        tool: 'update_budget', queueEntityType: 'personal_budget',
        entityId: 'b1', expectFields: {'name': 'new'},
        successAr: 'تم', successEn: 'done',
        failureAr: 'فشل', failureEn: 'failed',
      );
      expect(mismatch.state, SaraVerificationState.failed);
      final gone = await g.verifyDelete(
        tool: 'delete_budget', queueEntityType: 'personal_budget',
        entityId: 'missing',
        successAr: 'تم', successEn: 'done',
        failureAr: 'فشل', failureEn: 'failed',
      );
      // missing locally + no queue rows + no server api => pending (honest:
      // the delete intent is recorded nowhere as failed).
      expect(gone.state, SaraVerificationState.successLocalPendingSync);
    });

    test('amountsMatch tolerance behavior', () {
      expect(SaraVerificationGateway.amountsMatch(100, 110, 10), isTrue);
      expect(SaraVerificationGateway.amountsMatch(100, 110.5, 10), isFalse);
      expect(SaraVerificationGateway.amountsMatch(100, 100.004, 0), isTrue);
    });

    test('opKeyFor is order-insensitive and normalized', () {
      final a = SaraVerificationGateway.opKeyFor(
          't', {'b': 1, 'a': ' X '});
      final b = SaraVerificationGateway.opKeyFor(
          't', {'a': 'x', 'b': 1.0});
      expect(a, b);
    });
  });

  group('executor transfer FX gate (real service + mirror)', () {
    test('cross-currency without engine rate => FAILED and nothing written',
        () async {
      final svc = makeService();
      await svc.addBankAccount(
          bankName: 'A', currency: 'USD', openingBalance: 100);
      await svc.addBankAccount(
          bankName: 'B', currency: 'SAR', openingBalance: 0);
      final banks = await PersonalCacheRepository()
          .getCollection(uid, 'personal_bank_account');
      final fromId =
          banks.firstWhere((m) => m['bank_name'] == 'A')['id'].toString();
      final toId =
          banks.firstWhere((m) => m['bank_name'] == 'B')['id'].toString();

      final exec = ToolExecutor(svc); // no fxEngine injected
      final before = await PersonalCacheRepository()
          .getCollection(uid, 'personal_transaction');
      final r = await exec.execute('create_transfer', {
        'from_account_id': fromId,
        'to_account_id': toId,
        'amount': 10,
      });
      expect(r.success, isFalse);
      expect(r.errorCode, 'NO_FX_RATE');
      final after = await PersonalCacheRepository()
          .getCollection(uid, 'personal_transaction');
      expect(after.length, before.length);
    });

    test('same-currency transfer executes and verifies by delta', () async {
      final svc = makeService();
      await svc.addBankAccount(
          bankName: 'A', currency: 'USD', openingBalance: 100);
      await svc.addBankAccount(
          bankName: 'B', currency: 'USD', openingBalance: 0);
      final banks = await PersonalCacheRepository()
          .getCollection(uid, 'personal_bank_account');
      final fromId =
          banks.firstWhere((m) => m['bank_name'] == 'A')['id'].toString();
      final toId =
          banks.firstWhere((m) => m['bank_name'] == 'B')['id'].toString();

      final exec = ToolExecutor(svc);
      final r = await exec.execute('create_transfer', {
        'from_account_id': fromId,
        'to_account_id': toId,
        'amount': 25,
      });
      // Mirror truth: both legs applied. Sync state is pending locally
      // (dead Dio), so the honest verdict is pending — never blind success.
      expect(r.verificationStatus, 'local_pending');
      expect(saraToneOf(r), '⏳');
      final after = await svc.getBankAccounts();
      final a = after.firstWhere((x) => x.id == fromId);
      final b = after.firstWhere((x) => x.id == toId);
      expect(a.balance, 75);
      expect(b.balance, 25);
    });

    test('cross-currency transfer uses injected real rate', () async {
      final svc = makeService();
      await svc.addBankAccount(
          bankName: 'A', currency: 'USD', openingBalance: 100);
      await svc.addBankAccount(
          bankName: 'B', currency: 'SAR', openingBalance: 0);
      final banks = await PersonalCacheRepository()
          .getCollection(uid, 'personal_bank_account');
      final fromId =
          banks.firstWhere((m) => m['bank_name'] == 'A')['id'].toString();
      final toId =
          banks.firstWhere((m) => m['bank_name'] == 'B')['id'].toString();

      final exec = ToolExecutor(svc, fxEngine: _FakeFxEngine());
      final r = await exec.execute('create_transfer', {
        'from_account_id': fromId,
        'to_account_id': toId,
        'amount': 10,
      });
      expect(r.verificationStatus, 'local_pending');
      final after = await svc.getBankAccounts();
      final b = after.firstWhere((x) => x.id == toId);
      expect(b.balance, 20); // 10 * fake rate 2.0, not invented 1.0
    });
  });

  group('executor create/delete end-to-end (mirror truth)', () {
    test('create bank resolves real ID and reports pending honestly',
        () async {
      final svc = makeService();
      final exec = ToolExecutor(svc);
      final r = await exec.execute('create_bank_account', {
        'bank_name': 'TestBank',
        'currency': 'USD',
        'opening_balance': 50,
      });
      expect(r.verificationStatus, 'local_pending');
      expect(r.entityId, isNotNull);
      expect(saraToneOf(r), '⏳');
      // The reported ID must be the real committed row.
      final banks = await svc.getBankAccounts();
      expect(banks.any((a) => a.id == r.entityId), isTrue);
    });

    test('delete then re-check surfaces current truth', () async {
      final svc = makeService();
      final exec = ToolExecutor(svc);
      final c = await exec.execute('create_bank_account', {
        'bank_name': 'GoneBank',
        'currency': 'USD',
        'opening_balance': 0,
      });
      final id = c.entityId!;
      final d = await exec.execute(
          'delete_bank_account', {'account_id': id});
      expect(d.verificationStatus, isNot('failed'));
      final check = await exec.execute('get_operation_status',
          {'entity_type': 'bank', 'entity_id': id});
      // Row is gone locally; nothing failed in queue => pending is honest
      // here only if a delete op is still queued; either pending or
      // not_found are truthful, failed/success-blind are not.
      expect(
          ['local_pending', 'not_found', 'confirmed'],
          contains(check.verificationStatus));
      expect(check.verificationStatus, isNot('failed'));
    });

    test('contribution verifies the exact amount delta', () async {
      final svc = makeService();
      await svc.addSavingsGoal(SavingsGoal(
          id: '', name: 'Car', targetAmount: 1000, currentAmount: 100));
      final exec = ToolExecutor(svc);
      final goals = await svc.getSavingsGoals();
      final gid = goals.single.id;
      final r = await exec.execute(
          'contribute_to_goal', {'goal_id': gid, 'amount': 40});
      expect(r.verificationStatus, isNot('failed'));
      final after = await svc.getSavingsGoals();
      expect(after.singleWhere((g) => g.id == gid).currentAmount, 140);
    });
  });
}

/// Fake FX engine: USD->SAR = 2.0, everything else unavailable.
class _FakeFxEngine extends CurrencyEngine {
  _FakeFxEngine()
      : super(
            apiClient:
                ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'))));

  @override
  double? getRate(String from, String to) {
    if (from == to) return 1.0;
    if (from == 'USD' && to == 'SAR') return 2.0;
    if (from == 'SAR' && to == 'USD') return 0.5;
    return null;
  }
}
