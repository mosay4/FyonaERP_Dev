import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/inventory/data/falcon_device_runner.dart';
import 'package:fyona_flutter/features/inventory/data/inventory_api.dart';
import 'package:fyona_flutter/features/inventory/domain/falcon_device_summary.dart';
import 'package:fyona_flutter/features/inventory/domain/services/falcon_memory_store.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/falcon_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Falcon on device-ledger data: the phone computes the deterministic
/// summary (same rules as the server), sends only that, shows the key
/// numbers at once, reuses unchanged reports and offers a retry on failure.
const _items = [
  {
    'id': 'p1', 'name': 'أرز بسمتي', 'unit': 'كيس', 'stock': 3, 'min_stock': 10,
    'sell_price': 50, 'cost_price': 40, 'sales': 5000, 'qty_sold': 100,
    'cogs': 4000, 'profit': 1000, 'purchases': 4400, 'qty_purchased': 110,
  },
  {
    'id': 'p2', 'name': 'زيت ذرة', 'unit': 'علبة', 'stock': 40, 'min_stock': 5,
    'sell_price': 20, 'cost_price': 19, 'sales': 0, 'qty_sold': 0,
    'cogs': 0, 'profit': 0, 'purchases': 760, 'qty_purchased': 40,
  },
  {
    'id': 'p3', 'name': 'سكر', 'unit': 'كيس', 'stock': 0, 'min_stock': 5,
    'sell_price': 30, 'cost_price': 29, 'sales': 900, 'qty_sold': 30,
    'cogs': 870, 'profit': 30, 'purchases': 870, 'qty_purchased': 30,
  },
  {
    'id': 'p4', 'name': 'ملح', 'unit': 'كيس', 'stock': 0, 'min_stock': 0,
    'sell_price': 1, 'cost_price': 1, 'sales': 0, 'qty_sold': 0,
    'cogs': 0, 'profit': 0, 'purchases': 0, 'qty_purchased': 0,
  },
];

List<Map<String, dynamic>> _rows() =>
    [for (final i in _items) Map<String, dynamic>.from(i)];

void main() {
  group('summary on the phone = the server rules (test_falcon_device_dataset)',
      () {
    test('inventory', () {
      final d = falconDeviceSummary(_rows(), currency: 'sar', scope: 'inventory');
      expect(d['report_currency'], 'SAR');
      expect(d['total_sales'], 5900);
      expect(d['total_profit'], 1030);
      expect(d['inventory_value'], 3 * 40 + 40 * 19);
      expect(d['products_count'], 3, reason: 'idle «ملح» is not active');
      expect(d['low_stock'], ['أرز بسمتي']);
      expect(d['out_of_stock'], ['سكر']);
      expect([for (final i in d['slow_moving']) i['name']], ['زيت ذرة']);
      expect([for (final i in d['weak_margin']) i['name']], ['سكر']);
      expect((d['top_sellers'] as List).first['name'], 'أرز بسمتي');
      final rice = (d['reorder'] as List)
          .cast<Map>()
          .singleWhere((r) => r['name'] == 'أرز بسمتي');
      expect(rice['order_qty'], 17);
      expect(rice['order_cost'], 17 * 40);
      expect(
        [for (final r in d['reorder']) r['name']],
        isNot(contains('زيت ذرة')),
      );
      expect(d['stagnant_value_share'], closeTo(760 / 880, 1e-4));
    });

    test('product + reorder suggestion', () {
      final d = falconDeviceSummary(_rows(),
          currency: 'SAR', scope: 'product', refId: 'p1', category: 'حبوب');
      expect(d['name'], 'أرز بسمتي');
      expect(d['stock'], 3);
      expect(d['sales_quantity'], 100);
      expect(d['suggested_order_qty'], 17);
      expect(d['category_name'], 'حبوب');
    });

    test('all branches: one product per name + each branch on its own', () {
      final rows = [
        for (final b in [('b1', 'فرع الرياض'), ('b2', 'فرع جدة')])
          for (final i in _rows()) {...i, 'branch_id': b.$1, 'branch_name': b.$2},
      ];
      final d = falconDeviceSummary(rows, currency: 'SAR', scope: 'inventory');
      expect(d['branch_ids'], ['b1', 'b2']);
      expect([for (final b in d['branch_summaries']) b['branch_name']],
          ['فرع الرياض', 'فرع جدة']);
      expect(d['total_sales'], 11800);
      expect(d['products_count'], 3);
      expect((d['top_sellers'] as List).first['qty_sold'], 200);
    });

    test('bad numbers are sanitised', () {
      final d = falconDeviceSummary([
        {'name': 'x', 'stock': 'abc', 'qty_sold': double.nan},
      ], currency: '', scope: 'inventory');
      expect(d['report_currency'], 'USD');
      expect(d['products_count'], 0);
    });
  });

  group('runner', () {
    late List<RequestOptions> sent;
    late int reads;
    late Map<String, dynamic> answer;

    FalconDeviceRunner runner({Object? owner}) {
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        sent.add(o);
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'data': answer,
        }));
      }));
      return FalconDeviceRunner(
        network: ApiClient(dio: dio),
        owner: owner ?? Object(),
        cache: FalconDeviceCache.instance,
        read: (scope, ref, currency) async {
          reads++;
          return (items: _rows(), category: null);
        },
      );
    }

    setUp(() {
      FalconDeviceCache.instance.clear();
      sent = [];
      reads = 0;
      answer = {'status': 'good', 'ai': true};
    });

    test('sends the compact summary, never every row; long window', () async {
      final r = runner();
      final report = await r.analyze('inventory', null, reportCurrency: 'SAR');
      expect(report['status'], 'good');
      final body = Map<String, dynamic>.from(sent.single.data as Map);
      expect(body.containsKey('device_items'), isFalse);
      expect(body['device_summary']['total_sales'], 5900);
      expect(body['report_currency'], 'SAR');
      expect(sent.single.path, '/inventory/falcon/analyze');
      expect(sent.single.receiveTimeout, kFalconReceiveTimeout);
      expect(jsonEncode(body).length, lessThan(6000));
    });

    test('preview needs no network and its figures are reused once',
        () async {
      final r = runner();
      final preview = await r.preview('inventory', null, reportCurrency: 'SAR');
      expect(preview['total_sales'], 5900);
      expect(sent, isEmpty);
      await r.analyze('inventory', null, reportCurrency: 'SAR');
      expect(reads, 1, reason: 'the analysis reused the preview figures');
      await r.analyze('inventory', null, reportCurrency: 'SAR');
      expect(reads, 2, reason: 'fresh figures on the next run');
    });

    test('unchanged figures reuse the full report (no second call)', () async {
      final r = runner();
      await r.analyze('inventory', null, reportCurrency: 'SAR');
      final again = await r.analyze('inventory', null, reportCurrency: 'SAR');
      expect(sent, hasLength(1));
      expect(again['status'], 'good');
      await r.analyze('inventory', null, reportCurrency: 'USD');
      expect(sent, hasLength(2), reason: 'another currency is another report');
    });

    test('a report without the narrative is never reused', () async {
      answer = {'status': 'watch', 'ai': false};
      final r = runner();
      await r.analyze('inventory', null, reportCurrency: 'SAR');
      await r.analyze('inventory', null, reportCurrency: 'SAR');
      expect(sent, hasLength(2));
    });

    test('chat sends only the rows the analysis reads', () async {
      final r = runner();
      await r.chat('inventory', null, 'كم ربحي؟', const [],
          reportCurrency: 'SAR');
      final body = Map<String, dynamic>.from(sent.single.data as Map);
      expect([for (final i in body['device_items']) i['id']],
          ['p1', 'p2', 'p3']);
      expect(body['question'], 'كم ربحي؟');
    });
  });

  group('page', () {
    setUp(() {
      FalconMemoryStore.instance.clearAll();
      BranchScope.token = 'falcon-device-test';
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(() {
      FalconMemoryStore.instance.clearAll();
      BranchScope.token = null;
    });

    testWidgets('key numbers show at once; a failure keeps them and retries',
        (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => AppLocalizations.preload('ar'));
      final api = _DeviceApi();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          inventoryApiProvider.overrideWithValue(api),
          currentUserIdProvider.overrideWithValue('tester'),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const FalconPage(scope: 'inventory', title: 'اختبار'),
        ),
      ));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(api.previews, 1);
      expect(api.analyses, 1);
      final l10n = AppLocalizations.of(tester.element(find.byType(FalconPage)));
      expect(find.text(l10n.translate('falconKeyNumbers')), findsOneWidget,
          reason: 'the phone-computed numbers stay on screen');
      expect(find.byKey(const ValueKey('falcon-retry')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('falcon-retry')));
      await tester.tap(find.byKey(const ValueKey('falcon-retry')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(api.analyses, 2);
      expect(find.byKey(const ValueKey('falcon-retry')), findsNothing);
      expect(find.text('تحليل كامل'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}

/// A device-ledger source: preview from the phone, first analysis fails.
class _DeviceApi extends InventoryApi {
  _DeviceApi() : super(ApiClient(dio: Dio()));
  int previews = 0, analyses = 0;

  @override
  Future<Map<String, dynamic>?> falconPreview(String scope, String? refId,
      {String? reportCurrency}) async {
    previews++;
    return falconDeviceSummary(_rows(),
        currency: reportCurrency ?? 'USD', scope: scope);
  }

  @override
  Future<Map<String, dynamic>> falconAnalyze(String scope, String? refId,
      {String? reportCurrency}) async {
    analyses++;
    if (analyses == 1) throw DioException(requestOptions: RequestOptions());
    return {
      'status': 'good',
      'status_line': 'تحليل كامل',
      'ai': true,
      'stats': falconDeviceSummary(_rows(),
          currency: reportCurrency ?? 'USD', scope: scope),
    };
  }
}
