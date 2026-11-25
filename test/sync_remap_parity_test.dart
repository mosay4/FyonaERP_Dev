import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/sync_engine.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/personal_ledger_test_support.dart';

/// Online/offline parity for idempotent-dedupe remaps (recurring execution
/// offline, then sync): the phantom local row is replaced by the canonical
/// server row — never dropped. Even when the follow-up pull fails or misses
/// the row, the transaction stays visible with identical content.
void main() {
  const uid = 79;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  PersonalCacheRepository cache() => PersonalCacheRepository();

  Future<void> cleanDb() async {
    await (await testLedger()).rawDelete(
        'DELETE FROM personal_entity_cache WHERE user_id = ?',
        [uid.toString()]);
    await (await testLedger()).rawDelete('DELETE FROM sync_queue');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  Map<String, dynamic> phantomTx(String id) => {
        'id': id,
        'tx_type': 'expense',
        'amount': 250,
        'currency': 'SAR',
        'category': 'test',
        'client_operation_id': 'recur_rule1_2026-09-20',
      };

  Map<String, dynamic> dedupeResponse(String canonicalId) => {
        'id': canonicalId,
        'tx_type': 'expense',
        'amount': 250,
        'currency': 'SAR',
        'category': 'test',
        'client_operation_id': 'recur_rule1_2026-09-20',
        'deduped': true,
      };

  Future<List<Map<String, dynamic>>> txRows() =>
      cache().getCollection(uid, 'personal_transaction');

  test('remap anchors canonical row and drops phantom', () async {
    await cache().upsertItem(
        uid, 'personal_transaction', 'local-phantom', phantomTx('local-phantom'));
    await reconcileRemap(
      cache: cache(),
      userId: uid,
      entityType: 'personal_transaction',
      response: dedupeResponse('server-canonical'),
      remapFrom: 'local-phantom',
      remapTo: 'server-canonical',
    );
    final rows = await txRows();
    expect(rows.length, 1);
    expect(rows.single['id'], 'server-canonical');
    expect(rows.single['amount'], 250);
    expect(rows.single['client_operation_id'], 'recur_rule1_2026-09-20');
  });

  test('remap without a canonical payload keeps old behavior safely', () async {
    await cache().upsertItem(
        uid, 'personal_transaction', 'local-phantom', phantomTx('local-phantom'));
    // No usable canonical row (id mismatch) → phantom dropped, nothing
    // invented. This preserves the previous semantics for exotic shapes.
    await reconcileRemap(
      cache: cache(),
      userId: uid,
      entityType: 'personal_transaction',
      response: {'ok': true},
      remapFrom: 'local-phantom',
      remapTo: 'server-canonical',
    );
    expect(await txRows(), isEmpty);
  });

  test('no-op when identities already match', () async {
    await cache().upsertItem(
        uid, 'personal_transaction', 'same-id', phantomTx('same-id'));
    await reconcileRemap(
      cache: cache(),
      userId: uid,
      entityType: 'personal_transaction',
      response: dedupeResponse('same-id'),
      remapFrom: 'same-id',
      remapTo: 'same-id',
    );
    final rows = await txRows();
    expect(rows.length, 1);
    expect(rows.single['id'], 'same-id');
  });

  test('offline recurring execution survives a deduping sync', () async {
    // Offline world: dead network, local mirror only.
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
    await svc.addBankAccount(
        bankName: 'Parity Bank', currency: 'SAR', openingBalance: 1000);
    final accounts =
        await PersonalCacheRepository().getCollection(uid, 'personal_bank_account');
    final accountId = accounts.single['id'].toString();
    final now = DateTime.now();
    final rule = RecurringTransaction(
      id: 'rule-parity',
      type: 'expense',
      amount: 250,
      category: 'test',
      frequency: 'daily',
      nextDate: DateTime(now.year, now.month, now.day),
      bankAccountId: accountId,
      currency: 'SAR',
      accountType: 'fixed',
      executionType: 'reminder',
      reminderTime: '00:00',
    );
    // Offline execution lands locally with the deterministic op id.
    await svc.executeRecurringNow(rule);
    var rows = await txRows();
    expect(rows.length, 1);
    final localId = rows.single['id'].toString();
    final opId = rows.single['client_operation_id'].toString();
    expect(opId, startsWith('recur_rule-parity_'));

    // Reconnect: the server already holds this intent (same op id) under
    // another id, and the follow-up pull MISSES it (the reported bug).
    // Parity demands the transaction stays visible with identical content.
    await reconcileRemap(
      cache: cache(),
      userId: uid,
      entityType: 'personal_transaction',
      response: {
        'id': 'server-canonical-tx',
        'tx_type': 'expense',
        'amount': 250,
        'currency': 'SAR',
        'category': 'test',
        'client_operation_id': opId,
        'deduped': true,
      },
      remapFrom: localId,
      remapTo: 'server-canonical-tx',
    );
    rows = await txRows();
    expect(rows.length, 1);
    expect(rows.single['id'], 'server-canonical-tx');
    expect(rows.single['amount'], 250);
    expect(rows.single['client_operation_id'], opId);
  });

  test('manual and auto executions of one rule share no key', () async {
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
    await svc.addBankAccount(
        bankName: 'Key Bank', currency: 'SAR', openingBalance: 100000);
    final accounts =
        await PersonalCacheRepository().getCollection(uid, 'personal_bank_account');
    final accountId = accounts.single['id'].toString();
    final now = DateTime.now();
    RecurringTransaction rule() => RecurringTransaction(
          id: 'rule-keys',
          type: 'income',
          amount: 100,
          category: 'test',
          frequency: 'daily',
          nextDate: DateTime(now.year, now.month, now.day),
          bankAccountId: accountId,
          currency: 'SAR',
          accountType: 'fixed',
          executionType: 'auto',
          reminderTime: '00:00',
        );
    // Yesterday's auto execution already advanced the rule; simulate the
    // same-day manual tap the user reported as vanishing.
    await svc.executeRecurringNow(rule());
    await svc.executeRecurringNow(rule(), manual: true);
    final rows = await txRows();
    expect(rows.length, 2);
    final keys = rows.map((r) => r['client_operation_id'].toString()).toList();
    expect(keys.toSet().length, 2);
    expect(keys.any((k) => RegExp(r'^recur_rule-keys_\d{4}-\d{2}-\d{2}$').hasMatch(k)), isTrue);
    expect(keys.any((k) => RegExp(r'^recur_rule-keys_\d{4}-\d{2}-\d{2}_\d{6}$').hasMatch(k)), isTrue);
  });
}
