import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/dashboard/data/business_finance_api.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/business_income_expense_page.dart';
import 'package:fyona_flutter/features/dashboard/presentation/providers/business_dashboard_providers.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';


class _FakeApi extends BusinessFinanceApi {
  _FakeApi() : super(ApiClient(dio: Dio()));
  @override
  Future<List<dynamic>> listTransactions(
      {String? kind,
      String? period,
      String? search,
      String? dateFrom,
      String? dateTo,
      bool includeDocLegs = false}) async {
    final all = [
      {
        'id': 'i1', 'source_type': 'bank_tx', 'source_id': 'i1',
        'kind': 'income', 'direction': 'in', 'amount': 100.0,
        'currency': 'USD', 'date': '2026-10-04T10:00:00+00:00',
        'account': 'Bank A', 'party': null, 'reference': null,
        'notes': 'إيداع يدوي', 'status': null, 'invoice_id': null,
      },
      {
        'id': 'e1', 'source_type': 'bank_tx', 'source_id': 'e1',
        'kind': 'bank_withdrawal', 'direction': 'out', 'amount': 25.0,
        'currency': 'USD', 'date': '2026-10-04T09:00:00+00:00',
        'account': null, 'party': null, 'reference': null,
        'notes': 'فاتورة كهرباء', 'status': null, 'invoice_id': null,
      },
    ];
    if (kind == 'income') return all.where((r) => r['direction'] == 'in').toList();
    if (kind == 'expense') return all.where((r) => r['direction'] == 'out').toList();
    return all;
  }
}

Widget _wrap({BusinessFinanceApi? api}) => ProviderScope(
      overrides: [businessFinanceApiProvider.overrideWithValue(api ?? _FakeApi()),
        employeeCanProvider.overrideWith((ref, key) => true)],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const BusinessIncomeExpensePage(),
      ),
    );

void main() {
  test('Business expenses use the HTTP timeline and propagate connection errors', () async {
    final calls = <RequestOptions>[];
    var connected = true;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        calls.add(request);
        if (!connected) {
          handler.reject(DioException.connectionError(
            requestOptions: request, reason: 'disconnected',
          ));
          return;
        }
        handler.resolve(Response(
          requestOptions: request,
          data: {'data': [{'source_id': 'server-expense'}]},
        ));
      }));
    addTearDown(() => dio.close(force: true));
    final api = BusinessFinanceApi(ApiClient(dio: dio));
    expect(await api.listTransactions(kind: 'inout'), [
      {'source_id': 'server-expense'},
    ]);
    connected = false;
    await expectLater(api.listTransactions(kind: 'inout'), throwsA(isA<DioException>()));
    expect(calls.map((call) => call.path), List.filled(2, '/business/transactions'));
  });

  testWidgets('filters: mode chips + contextual action buttons', (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // all three mode chips exist
    expect(find.text('الكل'), findsWidgets);
    expect(find.text('المدخولات'), findsOneWidget);
    expect(find.text('المصروفات'), findsOneWidget);
    // mode=all → both actions
    expect(find.text('إضافة دخل'), findsOneWidget);
    expect(find.text('سحب مصروف'), findsOneWidget);
    // both rows render
    expect(find.text('دخل'), findsWidgets);
    expect(find.text('مصروف'), findsWidgets);

    // switch to المدخولات → only add income
    await tester.tap(find.text('المدخولات'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('إضافة دخل'), findsOneWidget);
    expect(find.text('سحب مصروف'), findsNothing);

    // switch to المصروفات → only withdraw
    await tester.tap(find.text('المصروفات'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('سحب مصروف'), findsOneWidget);
    expect(find.text('إضافة دخل'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
