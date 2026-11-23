import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Online/offline divergence in the debts section:
///
/// 1. Buttons vanish: deleting a payment offline left `status='paid'` while
///    paid/is_paid were reversed, so the card hid all four action buttons
///    (they render only when status != 'paid'). The reversal must restore
///    the status symmetrically with the pay path.
/// 2. Balances vanish: a slow fetch started BEFORE an offline write must
///    never overwrite that write on completion (stale-response race). The
///    guard predicate + mirror write stamps cover this.
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
    await DatabaseHelper.rawDelete('DELETE FROM personal_entity_cache');
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
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

  group('debt status round-trip (buttons must survive delete)', () {
    test('full pay then delete restores status active', () async {
      final svc = makeService();
      final accId = await seedAccount(svc,
          name: 'CashST', currency: 'SAR', balance: 5000);
      final debtId = await seedDebt(svc,
          tag: 'Jasem', type: 'receivable', amount: 1000, currency: 'SAR');

      await svc.payDebt(debtId, 1000, DateTime.now(),
          method: 'cash',
          bankAccountId: accId,
          currency: 'SAR',
          debtAmount: 1000);
      var debt = await mirrorRow('personal_debt', debtId);
      expect(((debt['paid'] as num?)?.toDouble() ?? 0), 1000.0);
      expect(debt['is_paid'], isTrue);
      expect(debt['status'], 'paid');

      final txs =
          await PersonalCacheRepository().getCollection(7, 'personal_transaction');
      final txId = (txs
              .firstWhere((t) => (t['debt_id']?.toString() ?? '') == debtId)['id']
              ?.toString() ??
          '');
      expect(txId, isNotEmpty);
      expect(await svc.deleteTransaction(txId), isTrue);

      debt = await mirrorRow('personal_debt', debtId);
      expect(((debt['paid'] as num?)?.toDouble() ?? -1), 0.0);
      expect(debt['is_paid'], isFalse);
      expect(debt['status'], 'active',
          reason: 'reversal must restore status or the card hides its buttons');
    });
  });

  group('stale-response guard', () {
    test('local write newer than fetch start is skipped', () {
      final svc = makeService();
      final now = DateTime.now();
      expect(
          svc.shouldSkipStaleSnapshot(
              localStamp: now,
              fetchStartedAt: now.subtract(const Duration(seconds: 5))),
          isTrue);
    });

    test('local write older than fetch start is applied', () {
      final svc = makeService();
      final now = DateTime.now();
      expect(
          svc.shouldSkipStaleSnapshot(
              localStamp: now.subtract(const Duration(seconds: 30)),
              fetchStartedAt: now),
          isFalse);
    });

    test('unknown stamps allow the write (previous behavior)', () {
      final svc = makeService();
      final now = DateTime.now();
      expect(
          svc.shouldSkipStaleSnapshot(
              localStamp: null, fetchStartedAt: now),
          isFalse);
      expect(
          svc.shouldSkipStaleSnapshot(
              localStamp: now, fetchStartedAt: null),
          isFalse);
    });

    test('mirror writes stamp rows for the guard to read', () async {
      final svc = makeService();
      final cache = PersonalCacheRepository();
      expect(
          await cache.getMirrorUpdatedAt(7, 'personal_bank_account', 'nope'),
          isNull);
      final accId = await seedAccount(svc,
          name: 'CashTS', currency: 'SAR', balance: 100);
      final stamp = await cache.getMirrorUpdatedAt(
          7, 'personal_bank_account', accId);
      expect(stamp, isNotNull);
      expect(
          DateTime.now().difference(stamp!).inMinutes.abs() < 5, isTrue,
          reason: 'write stamp must be fresh');
    });
  });
}
