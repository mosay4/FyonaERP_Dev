import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/database/repositories/personal_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/currency/enabled_currencies_service.dart';
import 'package:fyona_flutter/features/ai/domain/agent/tool_executor.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Sara + a bank holding the same currency twice (USD جاري + USD توفير):
/// creating the second type is allowed, the same type is a duplicate, and
/// a write pinned to one account id lands on exactly that account.
void main() {
  const uid = 98;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  PersonalFinanceService makeService() {
    final dio = Dio(BaseOptions(
        baseUrl: 'http://127.0.0.1:9',
        connectTimeout: const Duration(seconds: 2)));
    final svc = PersonalFinanceService(
      apiClient: ApiClient(dio: dio),
      cache: PersonalCacheRepository(),
      repo: PersonalRepository(),
    );
    svc.setUserId(uid);
    return svc;
  }

  Future<void> clean() async {
    await DatabaseHelper.rawDelete(
        'DELETE FROM personal_entity_cache WHERE user_id = ?', [uid.toString()]);
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
  }

  setUp(() async => clean());
  tearDown(() async => clean());

  test('create_bank_account: savings next to checking is not a duplicate',
      () async {
    final svc = makeService();
    await saveEnabledCurrencies(
      {...await loadEnabledCurrencies(svc.currentUserId.toString()), 'USD'},
      svc.currentUserId.toString(),
    );
    final exec = ToolExecutor(svc);
    final first = await exec.execute('create_bank_account',
        {'bank_name': 'الكريمي', 'currency': 'USD'});
    expect(first.errorCode, isNot('DUPLICATE_ACCOUNT'));
    final second = await exec.execute('create_bank_account',
        {'bank_name': 'الكريمي', 'currency': 'USD', 'account_type': 'savings'});
    expect(second.errorCode, isNot('DUPLICATE_ACCOUNT'));
    final rows = (await svc.getBankAccounts())
        .where((a) => a.bankName == 'الكريمي' && a.currency == 'USD')
        .toList();
    expect(rows.length, 2);
    expect(rows.map((a) => a.accountType).toSet(), {'checking', 'savings'});
    // The created entity is the NEW savings row, not its checking sibling.
    final savings = rows.firstWhere((a) => a.accountType == 'savings');
    expect(second.entityId, anyOf(isNull, savings.id));

    final third = await exec.execute('create_bank_account',
        {'bank_name': 'الكريمي', 'currency': 'USD', 'account_type': 'savings'});
    expect(third.errorCode, 'DUPLICATE_ACCOUNT');
  });

  test('create_transaction pinned to the savings id writes on savings only',
      () async {
    final svc = makeService();
    await saveEnabledCurrencies(
      {...await loadEnabledCurrencies(svc.currentUserId.toString()), 'USD'},
      svc.currentUserId.toString(),
    );
    await svc.addBankAccount(
        bankName: 'الكريمي', currency: 'USD', openingBalance: 100);
    await svc.addBankAccount(
        bankName: 'الكريمي',
        currency: 'USD',
        openingBalance: 900,
        accountType: 'savings');
    final rows = (await svc.getBankAccounts())
        .where((a) => a.bankName == 'الكريمي')
        .toList();
    final savings = rows.firstWhere((a) => a.accountType == 'savings');
    final r = await ToolExecutor(svc).execute('create_transaction', {
      'type': 'income',
      'amount': 50,
      'currency': 'USD',
      'account_id': savings.id,
      'category': 'same-cur-test',
    });
    expect(r.errorCode, isNot('CURRENCY_MISMATCH'));
    final tx = (await svc.getTransactions())
        .firstWhere((t) => t.category == 'same-cur-test');
    expect(tx.accountId, savings.id);
  });
}
