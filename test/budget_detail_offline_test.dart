import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/personal/domain/services/budget_aggregation.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';

/// Budget detail offline pipeline: seed the local mirror exactly like the
/// app does offline (budget + category-linked expenses, dead network), then
/// run the SAME computation the detail page runs in phase 1
/// (membership filter + engine conversion) and assert one true number:
/// total AND per-category move together, immediately, with no server.
///
/// NOTE: this intentionally avoids pumping the page — widget tests run in a
/// FakeAsync zone that freezes native sqflite-FFI awaits, so DB-backed pages
/// can never settle there. The pipeline under test is byte-for-byte the
/// page's phase-1 math.
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
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          message: 'offline',
        ),
      ),
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

  test('offline category expense moves category + total at once', () async {
    final svc = makeService();
    const catFood = '11111111-1111-4111-8111-111111111111';
    const catTrans = '22222222-2222-4222-8222-222222222222';
    await svc.addBudget(PersonalBudget(
      id: '',
      name: 'Test',
      totalAmount: 100000,
      currency: 'SAR',
      categories: [
        BudgetCategory(
            id: catFood,
            name: 'طعام',
            type: 'expense',
            allocatedAmount: 50000),
        BudgetCategory(
            id: catTrans,
            name: 'مواصلات',
            type: 'expense',
            allocatedAmount: 30000),
      ],
    ));
    final cache = PersonalCacheRepository();
    final brows = await cache.getCollection(7, 'personal_budget');
    expect(brows.length, 1);
    final bid = brows.first['id'].toString();

    // Baseline spending, then the food expense under test.
    Future<void> spend(double amount, String? bcid) => svc.addTransaction(
        type: 'expense',
        amount: amount,
        category: 'x',
        date: DateTime.now(),
        currency: 'SAR',
        budgetId: bid,
        budgetCategoryId: bcid);
    await spend(40000, null);
    await spend(23960, null);
    await spend(10800, catFood);

    // ── Same pipeline as BudgetDetailPage phase 1 ──
    final engine = CurrencyEngine();
    final all = await svc.getTransactions();
    expect(all.length, 3);
    final catIds = {catFood, catTrans};
    final mine = all
        .where((t) => budgetTxBelongs(
            t: t, budgetId: bid, categoryIds: catIds))
        .toList();
    expect(mine.length, 3, reason: 'all three expenses belong to the budget');
    double total = 0;
    final byCat = <String, double>{};
    for (final t in mine) {
      double converted = t.amount;
      if (t.currency != 'SAR') {
        final c = engine.convert(t.amount, t.currency, 'SAR');
        if (c > 0) converted = c;
      }
      total += converted;
      final bcId = t.budgetCategoryId;
      if (bcId != null && bcId.isNotEmpty) {
        byCat[bcId] = (byCat[bcId] ?? 0) + converted;
      }
    }
    expect(total, 74760.0,
        reason: 'total = 40000 + 23960 + 10800 in one recompute');
    expect(byCat[catFood], 10800.0,
        reason: 'food card moves with its expense');
  });
}
