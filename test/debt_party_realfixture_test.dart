import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/core/theme/app_theme.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';
import 'package:fyona_flutter/features/purchases/data/purchase_api.dart';
import 'package:fyona_flutter/features/purchases/presentation/providers/purchase_providers.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/party_detail_page.dart';

// Exact shape returned by GET /merchant-links/overview for the real supplier.
const _realSupplierOverview = {
  'link_id': null,
  'kind': 'supplier',
  'display_currency': 'SAR',
  'display_total': '514.76',
  'fx_missing': [],
  'per_currency': [
    {'currency': 'USD', 'total': '137.27'},
  ],
  'individual': [
    {
      'id': 'c21a8281-554a-4592-9cbb-8db18e39b322',
      'number': 'PUR-20261013-0001',
      'date': '2026-10-13',
      'total': '187.27',
      'paid': '0',
      'remaining': '137.27',
      'currency': 'USD',
      'status': 'open',
      'group_id': null,
    }
  ],
  'operations': [
    {
      'id': 'c21a8281-554a-4592-9cbb-8db18e39b322',
      'number': 'PUR-20261013-0001',
      'date': '2026-10-13',
      'total': '187.27',
      'paid': '0',
      'remaining': '137.27',
      'currency': 'USD',
      'status': 'open',
      'group_id': null,
    }
  ],
  'groups': [],
  'group_name': null,
  'party': {
    'id': '2724a179-2a01-45f2-8da5-d355ad8ac7e1',
    'name': 'يحيئ',
    'phone': null,
    'created_at': '2026-10-08T22:00:27.040081+00:00',
  },
  'link': {
    'linked': false,
    'status': 'none',
    'phone': null,
    'public_code': null,
    'contact': {'via': 'phone', 'value': null},
  },
  'contact': {'via': 'phone', 'value': null},
  'requests': [],
};

class _FakeMerchant extends MerchantApi {
  _FakeMerchant() : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> businessOverview(
          {required String partyKind,
          required String partyId,
          String? currency,
          String? groupId,
          String? dateFrom,
          String? dateTo}) async =>
      Map<String, dynamic>.from(_realSupplierOverview);
}

class _FakePurchase extends PurchaseApi {
  _FakePurchase() : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> supplierBalance(String id) async => {'debts': []};
}

void main() {
  testWidgets('party detail builds with the REAL overview payload + app theme',
      (tester) async {
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
        home: const PartyDetailPage(id: 'S1', isSupplier: true),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'party detail must build without exceptions (black screen)');
    expect(find.text('يحيئ'), findsWidgets);
  });
}
