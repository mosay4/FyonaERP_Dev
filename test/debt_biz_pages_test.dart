import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/core/theme/app_theme.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/business_debts_page.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/customers_page.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/suppliers_page.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';
import 'package:fyona_flutter/features/purchases/data/purchase_api.dart';
import 'package:fyona_flutter/features/purchases/presentation/providers/purchase_providers.dart';

class _FakeMerchant extends MerchantApi {
  _FakeMerchant() : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> debtNotifications({String? linkId, String? side}) async =>
      {'unread': 2, 'items': []};
  @override
  Future<void> markDebtNotificationsRead({List<String>? ids}) async {}
}

class _FakePurchase extends PurchaseApi {
  _FakePurchase() : super(ApiClient(dio: Dio()));
  @override
  Future<List<dynamic>> searchSuppliers(String q) async => [
        {'id': 's1', 'name': 'يحيئ', 'phone': null},
      ];
  @override
  Future<List<dynamic>> searchCustomers(String q) async => [
        {'id': 'c1', 'name': 'محمد', 'phone': '777'},
      ];
  @override
  Future<Map<String, dynamic>> customerBalance(String id) async => {'debts': []};
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  await tester.runAsync(() => AppLocalizations.preload('ar'));
  SharedPreferences.setMockInitialValues(const {});
  AppColors.setLightMode(true);
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      merchantApiProvider.overrideWithValue(_FakeMerchant()),
      purchaseApiProvider.overrideWithValue(_FakePurchase()),
    ],
    child: MaterialApp(
      theme: AppTheme.lightTheme,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: home,
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('business debts home builds', (tester) async {
    await _pump(tester, const BusinessDebtsPage());
    expect(tester.takeException(), isNull);
    expect(find.text('ديون الموردين'), findsOneWidget);
  });

  testWidgets('suppliers debts list builds', (tester) async {
    await _pump(tester, const SuppliersPage(debtsContext: true));
    expect(tester.takeException(), isNull);
    expect(find.text('يحيئ'), findsOneWidget);
  });

  testWidgets('customers debts list builds', (tester) async {
    await _pump(tester, const CustomersPage(debtsContext: true));
    expect(tester.takeException(), isNull);
    expect(find.text('محمد'), findsOneWidget);
  });
}
