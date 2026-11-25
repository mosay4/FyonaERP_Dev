import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';
import 'package:fyona_flutter/features/purchases/data/purchase_api.dart';
import 'package:fyona_flutter/features/purchases/presentation/providers/purchase_providers.dart';
import 'package:fyona_flutter/features/core_business/presentation/pages/party_detail_page.dart';

class _FakeMerchant extends MerchantApi {
  final bool fail;
  _FakeMerchant({this.fail = false}) : super(ApiClient(dio: Dio()));

  @override
  Future<Map<String, dynamic>> businessOverview(
      {required String partyKind,
      required String partyId,
      String? currency,
      String? groupId,
      String? dateFrom,
      String? dateTo}) async {
    if (fail) throw Exception('DioException [bad response] 500');
    return {
      'link_id': 'L1',
      'kind': partyKind,
      'display_currency': 'SAR',
      'per_currency': [
        {'currency': 'USD', 'total': '1250.00'},
        {'currency': 'YER_OLD', 'total': '12500.00'},
      ],
      'individual': [
        {
          'id': 'I1',
          'number': 'INV-20261014-0007',
          'date': '2026-10-14',
          'total': '250.00',
          'paid': '0',
          'remaining': '250.00',
          'currency': 'USD',
          'group_id': null,
        },
      ],
      'operations': [
        {
          'id': 'I1',
          'number': 'INV-20261014-0007',
          'date': '2026-10-14',
          'total': '250.00',
          'paid': '0',
          'remaining': '250.00',
          'currency': 'USD',
          'group_id': null,
        },
      ],
      'groups': [
        {'id': 'G1', 'name': 'شهر أكتوبر', 'kind': 'manual', 'count': 2},
      ],
      'group_name': null,
      'fx_missing': [],
      'display_total': '2000.00',
      'party': {
        'id': partyId,
        'name': 'محمد',
        'phone': '777123456',
        'created_at': '2026-10-13T00:00:00',
      },
      'link': {
        'linked': true,
        'status': 'accepted',
        'phone': '777123456',
        'public_code': '363912',
        'contact': {'via': 'code', 'value': '363912'},
      },
      'contact': {'via': 'code', 'value': '363912'},
      'requests': [],
    };
  }

  @override
  Future<Map<String, dynamic>> linkStatus(
      {required String partyKind, required String partyId}) async {
    if (fail) throw Exception('DioException [bad response] 500');
    return {'linked': false, 'status': 'none'};
  }

  @override
  Future<List<Map<String, dynamic>>> settlementRequests(
          {required String partyKind, required String partyId}) async =>
      [];
}

class _FakePurchase extends PurchaseApi {
  _FakePurchase() : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> customerBalance(String id) async => {'debts': []};
  @override
  Future<Map<String, dynamic>> supplierBalance(String id) async => {'debts': []};
  @override
  Future<List<dynamic>> customerOperations(String id) async => [];
  @override
  Future<List<dynamic>> supplierOperations(String id) async => [];
}

Future<void> _pump(WidgetTester tester, {bool fail = false}) async {
  await tester.runAsync(() => AppLocalizations.preload('ar'));
  SharedPreferences.setMockInitialValues(const {
    'enabled_currencies_global': ['SAR', 'USD', 'YER_OLD', 'YER_NEW'],
  });
  tester.view.physicalSize = const Size(400, 820);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      merchantApiProvider.overrideWithValue(_FakeMerchant(fail: fail)),
      purchaseApiProvider.overrideWithValue(_FakePurchase()),
    ],
    child: MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: ThemeData.light(),
      home: const PartyDetailPage(id: 'C1', isSupplier: false),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('party detail: real name, sections rows, no raw code, no overflow',
      (tester) async {
    await _pump(tester);
    expect(tester.takeException(), isNull);
    // Real name shown (never "—" when the overview returns it).
    expect(find.text('محمد'), findsWidgets);
    // Two merchant actions only (individual debts + sections).
    expect(find.text('مجموعات الديون'), findsOneWidget);
    expect(find.text('ديون منفردة'), findsOneWidget);
    expect(find.text('طلبات السداد'), findsNothing);
    // No raw storage currency token in the UI.
    expect(find.text('YER_OLD', skipOffstage: false), findsNothing);
    // No inline preview list: one button opens the party's full history.
    expect(find.text('أحدث العمليات'), findsNothing);
    final button = find.byKey(const ValueKey('party-operations-button'));
    expect(find.text('عرض عمليات العميل'), findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('فاتورة بيع', skipOffstage: false), findsWidgets);
  });

  testWidgets('party detail: backend failure shows a friendly retry (no stack)',
      (tester) async {
    await _pump(tester, fail: true);
    // Friendly Arabic message + retry icon; never the raw DioException text.
    expect(find.textContaining('DioException'), findsNothing);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });
}
