import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/dashboard/data/business_finance_api.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/business_transaction_details_page.dart';
import 'package:fyona_flutter/features/dashboard/presentation/providers/business_dashboard_providers.dart';

class _FakeApi extends BusinessFinanceApi {
  final Map<String, dynamic> row;
  _FakeApi(this.row) : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>?> getTransaction(String s, String i) async => row;
}

void main() {
  testWidgets('status is translated (paid → مدفوعة) and manager labelled (ar)',
      (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final row = {
      'id': 'x', 'source_type': 'invoice', 'source_id': 'x', 'kind': 'sale',
      'direction': 'in', 'amount': 30.0, 'currency': 'USD',
      'date': '2026-10-04T14:46:00+00:00', 'account': null, 'party': null,
      'reference': 'INV-1', 'notes': null, 'status': 'paid',
      'invoice_id': 'x', 'by_name': 'Fyona Shop', 'by_is_manager': true,
    };
    await tester.pumpWidget(ProviderScope(
      overrides: [businessFinanceApiProvider.overrideWithValue(_FakeApi(row))],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const BusinessTransactionDetailsPage(
            sourceType: 'invoice', sourceId: 'x'),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('مدفوعة'), findsOneWidget);          // never raw "paid"
    expect(find.text('paid'), findsNothing);
    expect(find.text('نُفّذت بواسطة'), findsOneWidget);
    expect(find.text('المدير'), findsOneWidget);           // manager label
    expect(find.text('فاتورة بيع'), findsOneWidget);       // kind translated
  });

  testWidgets('english theme renders Paid + Manager', (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('en'));
    final row = {
      'id': 'x', 'source_type': 'invoice', 'source_id': 'x', 'kind': 'sale',
      'direction': 'in', 'amount': 30.0, 'currency': 'USD',
      'date': '2026-10-04T14:46:00+00:00', 'account': null, 'party': null,
      'reference': 'INV-1', 'notes': null, 'status': 'paid',
      'invoice_id': 'x', 'by_name': 'Fyona Shop', 'by_is_manager': true,
    };
    await tester.pumpWidget(ProviderScope(
      overrides: [businessFinanceApiProvider.overrideWithValue(_FakeApi(row))],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const BusinessTransactionDetailsPage(
            sourceType: 'invoice', sourceId: 'x'),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Paid'), findsOneWidget);
    expect(find.text('Executed by'), findsOneWidget);
    expect(find.text('Manager'), findsOneWidget);
  });

  testWidgets('rate is rendered as ordered tokens (1 دولار = 534 ...)',
      (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final row = {
      'id': 'x', 'source_type': 'transfer', 'source_id': 'x', 'kind': 'transfer',
      'direction': 'out', 'amount': 534.0, 'currency': 'YER_OLD',
      'date': '2026-10-04T14:46:00+00:00', 'account': null, 'party': null,
      'reference': null, 'notes': null, 'status': 'completed',
      'invoice_id': null, 'by_name': 'Fyona Shop', 'by_is_manager': false,
      'transfer': {
        'from_account': 'بنك', 'from_currency': 'USD', 'from_amount': 1.0,
        'to_account': 'بنك', 'to_currency': 'YER_OLD', 'to_amount': 534.0,
        'rate': 534.0,
      },
    };
    await tester.pumpWidget(ProviderScope(
      overrides: [businessFinanceApiProvider.overrideWithValue(_FakeApi(row))],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const BusinessTransactionDetailsPage(
            sourceType: 'transfer', sourceId: 'x'),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1'), findsOneWidget);
    expect(find.text('دولار'), findsOneWidget);
    expect(find.text('534'), findsOneWidget);
    expect(find.text('ريال يمني قديم'), findsOneWidget);
  });
}
