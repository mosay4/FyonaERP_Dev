import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/business_debts_page.dart';
import 'package:fyona_flutter/features/reports/data/reports_api.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';

class _FakeMerchant extends MerchantApi {
  _FakeMerchant() : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> debtNotifications({String? linkId, String? side}) async =>
      {'unread': 2, 'items': []};

  @override
  Future<void> markDebtNotificationsRead({List<String>? ids}) async {}
}

class _FakeReports extends BusinessReportsApi {
  _FakeReports() : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> debts(String? from, String? to,
      [String currency = 'SAR']) async {
    return {
      'customers': {'total': 737.36, 'count': 1, 'top': [], 'gaps': []},
      'suppliers': {'total': 514.76, 'count': 1, 'top': [], 'gaps': []},
      'collected': {'total': 100, 'gaps': []},
      'paid_to_suppliers': {'total': 50, 'gaps': []},
      'overdue': {'count': 0, 'total': 0, 'gaps': []},
      'recent_movements': [],
    };
  }

  @override
  Future<Map<String, dynamic>> debtNotifications({String? linkId, String? side}) async =>
      {'unread': 2, 'items': []};

  @override
  Future<void> markDebtNotificationsRead({List<String>? ids}) async {}
}

/// ref: "Business Debt Interface.pdf" — EXACTLY two boxes (ديون الموردين /
/// ديون العملاء), no totals, no amounts, no add button, plus a bell.
void main() {
  testWidgets('Business debts home shows only the two boxes + bell',
      (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        businessReportsApiProvider.overrideWithValue(_FakeReports()),
        merchantApiProvider.overrideWithValue(_FakeMerchant()),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const BusinessDebtsPage(),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ديون العملاء'), findsOneWidget);
    expect(find.text('ديون الموردين'), findsOneWidget);
    // No totals / amounts / add button on this page.
    expect(find.text('737.36'), findsNothing);
    expect(find.text('514.76'), findsNothing);
    expect(find.text('إضافة دين جديد'), findsNothing);
    // The bell opens the isolated debt-notification center (2 unread badge).
    expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
