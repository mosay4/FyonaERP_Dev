import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_executor.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_registry.dart';
import 'package:fyona_flutter/features/ai/domain/agent/parameter_collector.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';

/// P2 Unified Tool Contract (Flutter side).
///
/// The JSON contract is the single source of truth: registry params,
/// categories, confirmation, verification, offline support and result shape
/// must match it, and the 7 core money operations are traced through the
/// REAL runtime path (executor → service → mirror → gateway) on isolated
/// test data. No real user data is touched.
Map<String, dynamic> _loadContract() {
  final file = File(
      'backend/app/domain/services/sara_tool_contract.v1.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  const uid = 94;

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

  Future<void> cleanDb() async {
    await DatabaseHelper.rawDelete(
        'DELETE FROM personal_entity_cache WHERE user_id = ?',
        [uid.toString()]);
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  Map<String, Map<String, dynamic>> contractTools() {
    final c = _loadContract();
    final out = <String, Map<String, dynamic>>{};
    for (final t in (c['tools'] as List)) {
      final m = (t as Map).cast<String, dynamic>();
      out[m['tool_id'] as String] = m;
    }
    return out;
  }

  group('contract parity: registry matches single source of truth', () {
    test('version is pinned and gateway states are frozen', () {
      final c = _loadContract();
      expect(c['contract_version'], '1.5.0');
      expect((c['gateway_states'] as List).cast<String>(), [
        'confirmed', 'local_pending', 'failed',
        'unverifiable', 'not_found', 'sync_failed',
      ]);
    });

    test('unique stable tool_ids, registry covers all flutter/dual tools', () {
      final tools = contractTools();
      final flutterIds = tools.entries
          .where((e) =>
              e.value['owner'] == 'flutter' || e.value['owner'] == 'dual')
          .map((e) => e.key)
          .toSet();
      final registryIds =
          AgentToolRegistry.tools.map((t) => t.name).toSet();
      expect(registryIds.length, AgentToolRegistry.tools.length);
      expect(registryIds, flutterIds);
    });

    test('required/optional params match per tool', () {
      final tools = contractTools();
      for (final def in AgentToolRegistry.tools) {
        final entry = tools[def.name]!;
        final req =
            def.params.where((p) => p.required).map((p) => p.name).toSet();
        final opt =
            def.params.where((p) => !p.required).map((p) => p.name).toSet();
        expect(req, (entry['required'] as List).cast<String>().toSet(),
            reason: def.name);
        expect(opt, (entry['optional'] as List).cast<String>().toSet(),
            reason: def.name);
      }
    });

    test('read/write classification is correct', () {
      final tools = contractTools();
      for (final def in AgentToolRegistry.tools) {
        final entry = tools[def.name]!;
        final expected = def.category == ToolCategory.read
            ? 'read'
            : def.category == ToolCategory.write
                ? 'write'
                : 'navigate';
        expect(entry['category'], expected, reason: def.name);
      }
    });

    test('confirmation metadata: destructive flags match registry', () {
      const destructive = {
        'delete_transaction', 'delete_bank_account', 'delete_savings_goal',
        'delete_debt', 'delete_budget', 'delete_recurring',
        'delete_currency', 'delete_category',
      };
      const financialWrite = {
        'create_transaction', 'create_transfer',
        'contribute_to_goal', 'pay_debt',
        'execute_recurring_now',
      };
      final tools = contractTools();
      for (final def in AgentToolRegistry.tools) {
        final entry = tools[def.name]!;
        final flagged = def.requiresConfirmation ||
            def.riskLevel == RiskLevel.critical;
        if (destructive.contains(def.name)) {
          expect(entry['confirm'], 'destructive', reason: def.name);
          expect(flagged, isTrue, reason: def.name);
        } else if (financialWrite.contains(def.name)) {
          expect(entry['confirm'], 'financial_write', reason: def.name);
        } else if (def.category == ToolCategory.write) {
          expect(entry['confirm'], 'safe_write', reason: def.name);
        } else {
          expect(entry['confirm'], 'none', reason: def.name);
        }
      }
    });

    test('verification + offline metadata match runtime truth', () {
      final tools = contractTools();
      for (final def in AgentToolRegistry.tools) {
        final entry = tools[def.name]!;
        if (def.category == ToolCategory.write) {
          expect(entry['verification'], 'gateway', reason: def.name);
          expect(entry['idempotency'], 'opkey', reason: def.name);
        }
        expect(entry['offline'], 'supported', reason: def.name);
      }
    });

    test('unknown tool returns unified rejection, never success', () async {
      final exec = ToolExecutor(makeService());
      final r = await exec.execute('__no_such_tool__', {});
      expect(r.success, isFalse);
      expect(r.verified, isFalse);
      expect(r.retryable, isFalse);
      expect(r.errorCode, 'UNKNOWN_TOOL');
      expect(r.tool, '__no_such_tool__');
    });
  });

  group('runtime verification: real path, isolated data', () {
    Future<Map<String, String>> seed() async {
      final svc = makeService();
      await svc.addBankAccount(
          bankName: 'Main SAR', currency: 'SAR', openingBalance: 10000);
      await svc.addBankAccount(
          bankName: 'Cash SAR', currency: 'SAR', openingBalance: 1000);
      await svc.addBankAccount(
          bankName: 'USD wallet', currency: 'USD', openingBalance: 500);
      final banks = await svc.getBankAccounts();
      final ids = <String, String>{};
      for (final b in banks) {
        ids['${b.bankName}|${b.currency}'] = b.id;
      }
      await svc.addSavingsGoal(SavingsGoal(
          id: '', name: 'Car', targetAmount: 20000, currency: 'SAR'));
      await svc.addDebt(PersonalDebt(
          id: '', type: 'payable', personName: 'Ali', amount: 5000,
          currency: 'SAR'));
      return ids;
    }

    Future<ToolExecutor> exec() async {
      await seed();
      return ToolExecutor(makeService());
    }

    String? txIdFor(ToolExecutionResult r) => r.entityId;

    test('create → delete transaction via gateway states', () async {
      final e = await exec();
      final created = await e.execute('create_transaction', {
        'type': 'expense', 'amount': 250, 'category': 'food',
        'description': 'P2 lunch', 'currency': 'SAR',
        'date': '2026-05-10',
      });
      expect(created.tool, 'create_transaction');
      expect(created.verificationStatus, 'local_pending');
      expect(created.success, isFalse); // never success before verification
      expect(created.verified, isFalse);
      expect(created.retryable, isTrue);
      final id = txIdFor(created);
      expect(id, isNotNull);
      expect(created.operationId, id);

      // Transaction editing was removed product-wide: the tool is gone and
      // the executor must reject it as unknown instead of editing.
      final edited = await e.execute('update_transaction', {
        'transaction_id': id, 'amount': 300,
      });
      expect(edited.success, isFalse);
      final svc = makeService();
      final row = (await svc.getTransactions())
          .firstWhere((t) => t.id == id);
      expect(row.amount, 250);

      final deleted = await e.execute(
          'delete_transaction', {'transaction_id': id});
      expect(deleted.verificationStatus, 'local_pending');
      final gone =
          (await svc.getTransactions()).where((t) => t.id == id);
      expect(gone, isEmpty);
    });

    test('contribute + pay_debt move money with currency intact', () async {
      final e = await exec();
      final svc = makeService();
      final goal =
          (await svc.getSavingsGoals()).firstWhere((g) => g.name == 'Car');
      final debt =
          (await svc.getDebts()).firstWhere((d) => d.personName == 'Ali');

      final c = await e.execute(
          'contribute_to_goal', {'goal_id': goal.id, 'amount': 1000});
      expect(c.verificationStatus, 'local_pending');
      expect(c.success, isFalse);
      expect(c.entityId, isNotNull);

      final p = await e.execute(
          'pay_debt', {'debt_id': debt.id, 'amount': 500});
      expect(p.verificationStatus, 'local_pending');
      expect(p.entityId, isNotNull);

      final goals2 = await svc.getSavingsGoals();
      expect(
          goals2.firstWhere((g) => g.id == goal.id).currency, 'SAR');
      final debts2 = await svc.getDebts();
      expect(debts2.firstWhere((d) => d.id == debt.id).currency, 'SAR');
    });

    test('create budget + transfer keep currency separation', () async {
      final ids = await seed();
      final e = ToolExecutor(makeService());
      final b = await e.execute('create_budget', {
        'name': 'P2 food', 'amount': 3000, 'currency': 'SAR',
      });
      expect(b.verificationStatus, 'local_pending');
      expect(b.entityId, isNotNull);

      final t = await e.execute('create_transfer', {
        'from_account_id': ids['Main SAR|SAR'],
        'to_account_id': ids['Cash SAR|SAR'],
        'amount': 200,
      });
      expect(t.verificationStatus, 'local_pending');
      expect(t.success, isFalse);

      final u = await e.execute('create_transaction', {
        'type': 'expense', 'amount': 50, 'category': 'food',
        'description': 'P2 coffee', 'currency': 'USD',
        'date': '2026-05-10',
      });
      expect(u.entityId, isNotNull);
      final bal = await e.execute('get_balance', {});
      expect(bal.success, isTrue);
      expect(bal.messageAr, contains('SAR'));
      expect(bal.messageAr, contains('USD'));
    });

    test('concurrent identical creates write exactly once', () async {
      final e = await exec();
      final params = {
        'type': 'expense', 'amount': 77, 'category': 'P2dup',
        'description': 'P2 concurrent', 'currency': 'SAR',
        'date': '2026-05-10',
      };
      final results = await Future.wait([
        e.execute('create_transaction', Map<String, dynamic>.from(params)),
        e.execute('create_transaction', Map<String, dynamic>.from(params)),
      ]);
      expect(results[0].entityId, isNotNull);
      expect(results[1].entityId, isNotNull);
      final svc = makeService();
      final matches = (await svc.getTransactions())
          .where((t) => t.description == 'P2 concurrent')
          .toList();
      expect(matches.length, 1);
    });

    test('missing params never partially execute (contract gate)', () {
      final def = AgentToolRegistry.findByName('create_transaction')!;
      final check = ParameterCollector.checkCompletion(def, {});
      expect(check.isComplete, isFalse);
      expect(check.missingRequired.map((m) => m.schema.name),
          containsAll(['type', 'amount', 'category']));
      final partial = ParameterCollector.checkCompletion(def, {'amount': 5});
      expect(partial.isComplete, isFalse);
    });

    test('create_debt keeps currency and direction (YER_OLD receivable)', () async {
      final e = ToolExecutor(makeService());
      final r = await e.execute('create_debt', {
        'person_name': 'Qasam Debt', 'amount': 1000000,
        'debt_type': 'receivable', 'currency': 'YER_OLD',
        'due_date': '2026-11-23',
      });
      expect(r.entityId, isNotNull);
      final debts = await makeService().getDebts();
      final d = debts.firstWhere((x) => x.id == r.entityId);
      expect(d.currency, 'YER_OLD');
      expect(d.type, 'receivable');
      expect(r.messageAr, contains('YER_OLD'));
      expect(r.messageAr, contains('دين لك'));
    });

    test('create_debt payable defaults to SAR without currency', () async {
      final e = ToolExecutor(makeService());
      final r = await e.execute('create_debt', {
        'person_name': 'Sara Debt', 'amount': 500,
        'debt_type': 'payable',
      });
      expect(r.entityId, isNotNull);
      final debts = await makeService().getDebts();
      final d = debts.firstWhere((x) => x.id == r.entityId);
      expect(d.currency, 'SAR');
      expect(r.messageAr, contains('دين عليك'));
    });

    test('create_budget makes ONE budget with inner categories', () async {
      final e = ToolExecutor(makeService());
      final r = await e.execute('create_budget', {
        'name': 'P2 trip',
        'amount': 1000000,
        'currency': 'SAR',
        'categories': jsonEncode([
          {'name': 'flights', 'amount': 300000},
          {'name': 'stay', 'amount': 100000},
        ]),
      });
      expect(r.entityId, isNotNull);
      final budgets = await makeService().getAllBudgets();
      final matches =
          budgets.where((b) => b.id == r.entityId).toList();
      expect(matches.length, 1);
      final b = matches.first;
      expect(b.totalAmount, 1000000);
      expect(b.currency, 'SAR');
      expect(b.categories.length, 2);
      expect(
          b.categories.map((c) => c.name).toSet(), {'flights', 'stay'});
      expect(r.messageAr, contains('أصناف'));
    });

    test('create_budget without categories is category-free', () async {
      final e = ToolExecutor(makeService());
      final r = await e.execute('create_budget', {
        'name': 'P2 plain', 'amount': 2000, 'currency': 'SAR',
      });
      expect(r.entityId, isNotNull);
      final budgets = await makeService().getAllBudgets();
      final b = budgets.firstWhere((x) => x.id == r.entityId);
      expect(b.categories, isEmpty);
    });

    test('create_budget with garbage categories still succeeds category-free',
        () async {
      final e = ToolExecutor(makeService());
      final r = await e.execute('create_budget', {
        'name': 'P2 garbage',
        'amount': 2000,
        'currency': 'SAR',
        'categories': 'not-json{{{',
      });
      expect(r.entityId, isNotNull);
      final budgets = await makeService().getAllBudgets();
      final b = budgets.firstWhere((x) => x.id == r.entityId);
      expect(b.totalAmount, 2000);
      expect(b.categories, isEmpty);
    });

    test('all runtime states belong to the frozen gateway set', () async {
      final e = await exec();
      // Reads use the pre-existing 'verified' convention (data read straight
      // from the source of truth — not a gateway write verdict).
      final read = await e.execute('get_balance', {});
      expect(read.verificationStatus, 'verified');
      const allowed = {
        'confirmed', 'local_pending', 'failed',
        'unverifiable', 'not_found', 'sync_failed',
      };
      final states = <String?>{
        (await e.execute('create_transaction', {
          'type': 'income', 'amount': 10, 'category': 'x',
          'date': '2026-05-10',
        })).verificationStatus,
        (await e.execute('delete_transaction',
                {'transaction_id': 'missing-id'}))
            .verificationStatus,
      };
      expect(states.difference(allowed), isEmpty);
    });
  });
}
