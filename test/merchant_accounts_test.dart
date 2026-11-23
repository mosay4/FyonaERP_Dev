import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/merchant_accounts_page.dart';

class _FakeMerchantApi extends MerchantApi {
  _FakeMerchantApi() : super(ApiClient(dio: Dio()));
  int accepted = 0, rejected = 0;

  @override
  Future<List<Map<String, dynamic>>> myInvites() async => [
        {
          'link_id': 'L1',
          'merchant_name': 'بقالة النور',
          'shop_name': 'بقالة النور',
          'merchant_code': '123456',
          'kind': 'customer',
        },
      ];

  @override
  Future<List<Map<String, dynamic>>> myMerchants() async => [
        {'link_id': 'M1', 'merchant_name': 'مؤسسة الأمل', 'kind': 'customer'},
      ];

  @override
  Future<void> acceptInvite(String linkId) async => accepted++;

  @override
  Future<void> rejectInvite(String linkId) async => rejected++;
}

void main() {
  Future<void> pump(WidgetTester tester, _FakeMerchantApi api) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [merchantApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const MerchantAccountsPage(),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('shows merchant-requests button with count + linked merchants',
      (tester) async {
    final api = _FakeMerchantApi();
    await pump(tester, api);
    expect(find.text('حساباتي مع التجار'), findsWidgets);
    expect(find.text('طلبات التجار'), findsOneWidget);
    expect(find.text('1'), findsOneWidget); // pending badge
    expect(find.text('مؤسسة الأمل'), findsOneWidget);

    await tester.tap(find.text('طلبات التجار'));
    await tester.pumpAndSettle();
    expect(find.text('بقالة النور'), findsOneWidget);
    expect(find.text('موافقة'), findsOneWidget);
    expect(find.text('إلغاء'), findsOneWidget);
  });

  testWidgets('approve → confirm dialog → acceptInvite called', (tester) async {
    final api = _FakeMerchantApi();
    await pump(tester, api);
    await tester.tap(find.text('طلبات التجار'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('موافقة'));
    await tester.pumpAndSettle();
    // Final confirmation dialog.
    expect(find.text('تأكيد الارتباط'), findsOneWidget);
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();
    expect(api.accepted, 1);
  });
}
