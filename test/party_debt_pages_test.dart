import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/core/theme/app_theme.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/party_debt_pages.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';

class _Fake extends MerchantApi {
  final bool empty;
  _Fake({this.empty = false}) : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> businessOverview(
      {required String partyKind,
      required String partyId,
      String? currency,
      String? groupId,
      String? dateFrom,
      String? dateTo}) async =>
      {
        'display_currency': 'SAR',
        'grand_total': '500.00',
        'paid_total': '100.00',
        'remaining_total': '400.00',
        'fx_missing': [],
        'individual': empty
            ? []
            : [
                {
                  'id': 'INV1',
                  'number': 'INV-1',
                  'date': '2026-10-14',
                  'total': '500',
                  'paid': '100',
                  'remaining': '400',
                  'currency': 'SAR',
                }
              ],
        'operations': [],
        'groups': empty
            ? []
            : [
                {'id': 'G1', 'name': 'شهر أكتوبر', 'count': 2}
              ],
      };
}

Future<void> _pump(WidgetTester tester, Widget home, {bool empty = false}) async {
  await tester.runAsync(() => AppLocalizations.preload('ar'));
  SharedPreferences.setMockInitialValues(const {
    'enabled_currencies_global': ['SAR', 'USD'],
  });
  AppColors.setLightMode(true);
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ProviderScope(
    overrides: [merchantApiProvider.overrideWithValue(_Fake(empty: empty))],
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
  testWidgets('business individual debts: hero card + invoice', (tester) async {
    await _pump(tester,
        const PartyDebtsPage(partyKind: 'customer', partyId: 'C1', name: 'محمد'));
    expect(tester.takeException(), isNull);
    expect(find.text('محمد'), findsWidgets);
    expect(find.textContaining('500'), findsWidgets);
    expect(find.textContaining('INV-1'), findsOneWidget);
    expect(find.text('إضافة دين جديد'), findsOneWidget);
  });

  testWidgets('business sections: empty shows add button', (tester) async {
    await _pump(
        tester,
        const PartySectionsPage(
            partyKind: 'customer', partyId: 'C1', name: 'محمد'),
        empty: true);
    expect(tester.takeException(), isNull);
    expect(find.text('إضافة قسم جديد'), findsOneWidget);
  });

  testWidgets('business sections: grid shows the section', (tester) async {
    await _pump(
        tester,
        const PartySectionsPage(
            partyKind: 'customer', partyId: 'C1', name: 'محمد'));
    expect(find.text('شهر أكتوبر'), findsOneWidget);
    expect(find.textContaining('فاتورتان'), findsOneWidget);
  });
}
