import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/di/personal_providers.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/personal_recurring_detail_page.dart'
    show recurringExecutionBanks;
import 'package:fyona_flutter/features/personal/presentation/providers/personal_providers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The recurring flow must fill its own bank list from the local mirror —
/// it may never depend on another section having loaded banks first
/// (deep links / notification taps land here directly, offline included).
/// And the manual-execution sheet must offer cash accounts too: cash-only
/// users otherwise face an empty bank list.
void main() {
  const uid = 82;

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

  test('provider load fills banks from mirror while offline', () async {
    final svc = makeService();
    await svc.addBankAccount(
        bankName: 'كاش', currency: 'SAR', openingBalance: 5000);
    await svc.addBankAccount(
        bankName: 'بنك', currency: 'USD', openingBalance: 100);

    final container = ProviderContainer(overrides: [
      personalFinanceServiceProvider.overrideWithValue(svc),
    ]);
    addTearDown(container.dispose);
    await container.read(personalFinanceProvider.notifier).load();

    final banks = container.read(personalFinanceProvider).bankAccounts;
    expect(banks.length, 2);
  });

  test('execution options include cash accounts', () {
    final all = [
      PersonalBankAccount(
          id: 'c1', bankName: 'كاش', currency: 'SAR', balance: 5000),
      PersonalBankAccount(
          id: 'b1', bankName: 'بنك', currency: 'USD', balance: 100),
    ];
    final options = recurringExecutionBanks(all);
    expect(options.length, 2);
    expect(options.any((a) => a.bankName == 'كاش'), isTrue);
  });
}
