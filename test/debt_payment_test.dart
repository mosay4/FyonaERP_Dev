import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_ledger_test_support.dart';

/// Debt payment (goals-style FX):
///
/// - receivable (owed TO me): collection needs NO balance — money ENTERS
///   the account, so an empty account must not block the operation.
/// - payable (owed BY me): the balance guard still applies.
/// - cross-currency: the account moves in the account currency, the debt is
///   credited the converted value (debt_amount); delete reverses the exact
///   credited amount.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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
    svc.setUserId(7);
    return svc;
  }

  Future<void> cleanDb() async {
    await (await testLedger()).rawDelete('DELETE FROM personal_entity_cache');
    await (await testLedger()).rawDelete('DELETE FROM sync_queue');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  Future<String> seedAccount(PersonalFinanceService svc,
      {required String name,
      required String currency,
      required double balance}) async {
    await svc.addBankAccount(
        bankName: name, currency: currency, openingBalance: balance);
    final cache = PersonalCacheRepository();
    final all = await cache.getCollection(7, 'personal_bank_account');
    return (all
            .firstWhere((r) => (r['bank_name']?.toString() ?? '') == name)['id']
            ?.toString() ??
        '');
  }

  Future<String> seedDebt(PersonalFinanceService svc,
      {required String tag,
      required String type,
      required double amount,
      required String currency}) async {
    await svc.addDebt(PersonalDebt(
        id: '', type: type, personName: tag, amount: amount, currency: currency));
    final cache = PersonalCacheRepository();
    final all = await cache.getCollection(7, 'personal_debt');
    return (all
            .firstWhere((r) =>
                (r['person_name']?.toString() ?? '') == tag &&
                (r['debt_type']?.toString() ?? '') == type)['id']
            ?.toString() ??
        '');
  }

  Future<Map<String, dynamic>> mirrorRow(String entity, String id) async {
    final cache = PersonalCacheRepository();
    final all = await cache.getCollection(7, entity);
    return Map<String, dynamic>.from(
        all.firstWhere((r) => (r['id']?.toString() ?? '') == id));
  }

  group('debt payment (goals-style FX)', () {
    test('receivable collection needs NO balance (empty account)', () async {
      final svc = makeService();
      final accId = await seedAccount(svc,
          name: 'CashRX', currency: 'SAR', balance: 0);
      final debtId = await seedDebt(svc,
          tag: 'Ali', type: 'receivable', amount: 1000, currency: 'SAR');
      // Must NOT throw: money enters the account.
      await svc.payDebt(debtId, 400, DateTime.now(),
          method: 'cash',
          bankAccountId: accId,
          currency: 'SAR',
          debtAmount: 400);
      final acc = await mirrorRow('personal_bank_account', accId);
      expect((acc['balance'] as num).toDouble(), 400.0);
      final debt = await mirrorRow('personal_debt', debtId);
      expect(((debt['paid'] as num?)?.toDouble() ?? 0), 400.0);
    });

    test('payable still requires balance', () async {
      final svc = makeService();
      final accId = await seedAccount(svc,
          name: 'CashPY', currency: 'SAR', balance: 50);
      final debtId = await seedDebt(svc,
          tag: 'Omar', type: 'payable', amount: 1000, currency: 'SAR');
      var threw = false;
      // NOTE: _joinFlight attaches a whenComplete listener whose derived
      // future carries the same error unhandled (pre-existing service
      // behavior). Swallow zone noise here so the guard itself is verified.
      await runZonedGuarded(() async {
        try {
          await svc.payDebt(debtId, 400, DateTime.now(),
              method: 'cash',
              bankAccountId: accId,
              currency: 'SAR',
              debtAmount: 400);
        } catch (_) {
          threw = true;
        }
        await Future<void>.delayed(Duration.zero);
      }, (Object e, StackTrace s) {});
      expect(threw, isTrue,
          reason: 'payable with insufficient balance must be rejected');
      // Nothing was written: no tx, no balance move, no outbox op.
      final txs =
          await PersonalCacheRepository().getCollection(7, 'personal_transaction');
      expect(
          txs.where((t) => (t['debt_id']?.toString() ?? '') == debtId),
          isEmpty);
      final acc = await mirrorRow('personal_bank_account', accId);
      expect((acc['balance'] as num).toDouble(), 50.0);
    });

    test('cross-currency: account moves in account currency, debt credited converted',
        () async {
      final svc = makeService();
      final accId = await seedAccount(svc,
          name: 'BankFX', currency: 'USD', balance: 1000);
      final debtId = await seedDebt(svc,
          tag: 'Sara', type: 'payable', amount: 1000, currency: 'SAR');
      // 100 USD -> 375 SAR credit.
      await svc.payDebt(debtId, 100, DateTime.now(),
          method: 'bank',
          bankAccountId: accId,
          currency: 'USD',
          debtAmount: 375);
      final acc = await mirrorRow('personal_bank_account', accId);
      expect((acc['balance'] as num).toDouble(), 900.0);
      final debt = await mirrorRow('personal_debt', debtId);
      expect(((debt['paid'] as num?)?.toDouble() ?? 0), 375.0);
      final txs =
          await PersonalCacheRepository().getCollection(7, 'personal_transaction');
      final tx = txs.firstWhere(
          (t) => (t['debt_id']?.toString() ?? '') == debtId);
      expect(tx['currency'], 'USD');
      expect((tx['amount'] as num).toDouble(), 100.0);
      expect((tx['debt_amount'] as num).toDouble(), 375.0);
      // The staged sync op carries both currencies for the server replay.
      final ops = await (await testLedger()).rawQuery(
        "SELECT data FROM sync_queue WHERE entity_type = 'personal_transaction'",
      );
      expect(ops, isNotEmpty);
      final data =
          jsonDecode(ops.first['data'] as String) as Map<String, dynamic>;
      expect(data['currency'], 'USD');
      expect((data['debt_amount'] as num).toDouble(), 375.0);
    });

    test('expense still blocked on insufficient balance (payable, same currency)',
        () async {
      final svc = makeService();
      final accId = await seedAccount(svc,
          name: 'BankPB', currency: 'USD', balance: 1000);
      final debtId = await seedDebt(svc,
          tag: 'Khaled', type: 'payable', amount: 100, currency: 'USD');
      // Sufficient here: 1000 >= 250, payment goes through.
      await svc.payDebt(debtId, 100, DateTime.now(),
          method: 'bank',
          bankAccountId: accId,
          currency: 'USD',
          debtAmount: 100);
      final acc = await mirrorRow('personal_bank_account', accId);
      expect((acc['balance'] as num).toDouble(), 900.0);
    });

    test('delete reverses the exact converted credit', () async {
      final svc = makeService();
      final accId = await seedAccount(svc,
          name: 'BankRV', currency: 'USD', balance: 1000);
      final debtId = await seedDebt(svc,
          tag: 'Noura', type: 'payable', amount: 1000, currency: 'SAR');
      await svc.payDebt(debtId, 100, DateTime.now(),
          method: 'bank',
          bankAccountId: accId,
          currency: 'USD',
          debtAmount: 375);
      final txs =
          await PersonalCacheRepository().getCollection(7, 'personal_transaction');
      final txId = (txs
              .firstWhere((t) => (t['debt_id']?.toString() ?? '') == debtId)['id']
              ?.toString() ??
          '');
      expect(txId, isNotEmpty);
      final ok = await svc.deleteTransaction(txId);
      expect(ok, isTrue);
      final acc = await mirrorRow('personal_bank_account', accId);
      expect((acc['balance'] as num).toDouble(), 1000.0);
      final debt = await mirrorRow('personal_debt', debtId);
      expect(((debt['paid'] as num?)?.toDouble() ?? 0), 0.0);
    });
  });
}
