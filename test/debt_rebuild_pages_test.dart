import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/personal/data/merchant_api.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/merchant_debt_pages.dart';

class _FakeDebtApi extends MerchantApi {
  final bool gap;
  final bool fail;
  _FakeDebtApi({this.gap = false, this.fail = false})
      : super(ApiClient(dio: Dio()));

  Map<String, dynamic> _overview() => {
        'link_id': 'L1',
        'kind': 'customer',
        'display_currency': gap ? 'USD' : 'SAR',
        'display_total': gap ? null : '1200.00',
        'fx_missing': gap ? ['YER_OLD'] : [],
        'per_currency': [
          {'currency': 'SAR', 'total': '1000.00'},
          {'currency': 'YER_OLD', 'total': '50000.00'},
        ],
        'individual': [
          {
            'id': 'OP1',
            'number': 'INV-1',
            'date': '2026-10-10T00:00:00',
            'total': '1000.00',
            'paid': '0',
            'remaining': '1000.00',
            'currency': 'SAR',
            'group_id': null,
          },
        ],
        'operations': [
          {
            'id': 'OP1',
            'number': 'INV-1',
            'date': '2026-10-10T00:00:00',
            'total': '1000.00',
            'paid': '0',
            'remaining': '1000.00',
            'currency': 'SAR',
            'group_id': null,
          },
        ],
        'groups': [
          {'id': 'G1', 'name': 'شهر أكتوبر', 'kind': 'manual', 'count': 2},
        ],
      };

  @override
  Future<Map<String, dynamic>> debtNotifications({String? linkId, String? side}) async =>
      {'unread': 0, 'items': []};

  @override
  Future<void> markDebtNotificationsRead({List<String>? ids}) async {}

  @override
  Future<Map<String, dynamic>> debtOverview(String linkId,
      {String? currency, String? groupId, String? dateFrom, String? dateTo}) async {
    if (fail) throw Exception('offline');
    final o = _overview();
    if (groupId != null && groupId.isNotEmpty) {
      return {
        ...o,
        'individual': [],
        'operations': [
          {
            'id': 'OP2',
            'number': 'INV-9',
            'date': '2026-10-11T00:00:00',
            'total': '200.00',
            'paid': '0',
            'remaining': '200.00',
            'currency': 'SAR',
            'group_id': groupId,
          },
        ],
      };
    }
    return o;
  }

  @override
  Future<List<Map<String, dynamic>>> mySettlementRequests(String linkId) async =>
      [
        {
          'id': 'R1',
          'amount': '100.00',
          'currency': 'SAR',
          'status': 'pending',
          'reject_reason': null,
        },
      ];

  @override
  Future<Map<String, dynamic>> operationDetail(
      String linkId, String invoiceId) async {
    if (fail) throw Exception('offline');
    return {
      'id': invoiceId,
      'number': 'INV-1',
      'date': '2026-10-10T00:00:00',
      'type': 'sale',
      'currency': 'SAR',
      'total': 1000.0,
      'paid': 200.0,
      'remaining': 800.0,
      'has_invoice_document': true,
      'discount': '0',
      'tax': '0',
      'items': [
        {
          'name': 'سكر 50ك',
          'qty': 2.0,
          'price': 500.0,
          'unit': 'كيس',
          'discount': '0',
          'tax_rate': '0',
          'total': 1000.0,
        },
      ],
      'payments': [
        {'id': 'P1', 'amount': '200.00', 'currency': 'SAR', 'date': '2026-10-11'},
      ],
    };
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  _FakeDebtApi? api,
  Locale locale = const Locale('ar'),
  ThemeMode mode = ThemeMode.light,
}) async {
  await tester.runAsync(() => AppLocalizations.preload(locale.languageCode));
  SharedPreferences.setMockInitialValues(const {
    'enabled_currencies_global': ['SAR', 'USD', 'YER_OLD', 'YER_NEW'],
  });
  tester.view.physicalSize = const Size(360, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(ProviderScope(
    overrides: [merchantApiProvider.overrideWithValue(api ?? _FakeDebtApi())],
    child: MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: mode,
      home: page,
    ),
  ));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('merchant overview: totals, currencies, sections, requests',
      (tester) async {
    await _pump(
        tester,
        const MerchantDebtOverviewPage(
            linkId: 'L1', merchantName: 'بقالة النور'));
    // Converted total shown, original currencies kept separate.
    expect(find.textContaining('1,200'), findsWidgets);
    // The individual tab no longer shows per-currency boxes; the raw
    // YER_OLD token must never appear in Arabic UI.
    expect(find.text('YER_OLD', skipOffstage: false), findsNothing);
    // Individual op uses the «فاتورة #» presentation.
    expect(find.textContaining('فاتورة'), findsWidgets);
    await tester.tap(find.text('الأقسام'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('شهر أكتوبر'), findsOneWidget);
  });

  testWidgets('merchant overview: honest FX gap, never "null"',
      (tester) async {
    await _pump(
        tester,
        const MerchantDebtOverviewPage(
            linkId: 'L1', merchantName: 'بقالة النور'),
        api: _FakeDebtApi(gap: true));
    expect(find.text('null', skipOffstage: false), findsNothing);
    expect(find.textContaining('0', skipOffstage: false), findsWidgets);
  });

  testWidgets('merchant overview: backend failure shows retry',
      (tester) async {
    await _pump(
        tester,
        const MerchantDebtOverviewPage(
            linkId: 'L1', merchantName: 'بقالة النور'),
        api: _FakeDebtApi(fail: true));
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('section page shows only its own operations', (tester) async {
    await _pump(
        tester,
        const DebtSectionPage(
            linkId: 'L1', groupId: 'G1', name: 'شهر أكتوبر'));
    expect(find.textContaining('INV-9'), findsOneWidget);
    expect(find.textContaining('INV-1'), findsNothing);
  });

  testWidgets('operation detail: items, payments, actions', (tester) async {
    await _pump(
        tester,
        const DebtOperationDetailPage(
            linkId: 'L1', invoiceId: 'OP1', name: 'INV-1'));
    expect(find.textContaining('سكر 50ك'), findsOneWidget);
    expect(find.textContaining('800'), findsWidgets);
    expect(find.byIcon(Icons.description_outlined), findsOneWidget);
    expect(find.byIcon(Icons.payments_outlined), findsOneWidget);
  });

  testWidgets('overview renders in English LTR + dark mode', (tester) async {
    await _pump(
        tester,
        const MerchantDebtOverviewPage(linkId: 'L1', merchantName: 'Noor'),
        locale: const Locale('en'),
        mode: ThemeMode.dark);
    expect(find.text('Noor'), findsOneWidget);
  });
}
