import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/di/personal_providers.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/personal_providers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Instant paint: account cards + transactions must be in provider state
/// after load() WITHOUT any network — the mirror alone suffices.
void main() {
  const uid = 83;

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

  test('load() publishes mirror banks+txs offline, no spinner state', () async {
    final svc = makeService();
    await svc.addBankAccount(
        bankName: 'بنك', currency: 'SAR', openingBalance: 1000);
    final banks =
        await PersonalCacheRepository().getCollection(uid, 'personal_bank_account');
    final bankId = banks.single['id'].toString();
    await svc.addTransaction(
      type: 'income',
      amount: 250,
      category: 'test',
      date: DateTime.now(),
      accountId: bankId,
      currency: 'SAR',
    );

    final container = ProviderContainer(overrides: [
      personalFinanceServiceProvider.overrideWithValue(svc),
    ]);
    addTearDown(container.dispose);
    await container.read(personalFinanceProvider.notifier).load();

    final st = container.read(personalFinanceProvider);
    expect(st.isLoading, isFalse);
    expect(st.bankAccounts.length, 1);
    expect(st.bankAccounts.single.balance, 1250);
    expect(st.transactions.length, 1);
  });
}
