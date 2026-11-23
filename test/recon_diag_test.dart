import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/reconciliation/data/reconciliation_api.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_bank_pages.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_inventory_count_page.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/widgets/recon_results.dart';

void main() {
  Future<void> preload(WidgetTester t) async {
    await t.runAsync(() => AppLocalizations.preload('ar'));
  }
  Future<void> pumpFor(WidgetTester t, Duration d, int n) async {
    for (var i = 0; i < n; i++) {
      await t.pump(d);
    }
  }

  testWidgets('REGRESSION: result shows the REAL numbers (never animation zeros)',
      (tester) async {
    await preload(tester);
    final fake = DiagApi(ApiClient(dio: Dio()));
    await tester.pumpWidget(ProviderScope(
      overrides: [reconciliationApiProvider.overrideWithValue(fake)],
      child: MaterialApp.router(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: GoRouter(routes: [
          GoRoute(
              path: '/',
              builder: (_, _) =>
                  const ReconBankRunPage(accountIds: 'a1')),
          GoRoute(
              path: '/reconciliation/bank/result',
              builder: (_, state) {
                final extra = state.extra as Map? ?? const {};
                return ReconBankResultPage(
                    record: Map<String, dynamic>.from(
                        (extra['record'] as Map?) ?? const {}));
              }),
        ]),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 150),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 6));
    await tester.enterText(find.byType(TextField).first, '900');
    await tester.pumpAndSettle();
    await tester.tap(find.text('ابدأ المطابقة'));
    await pumpFor(tester, const Duration(milliseconds: 250), 20);
    await tester.pump();
    await tester.pump();
    // Numbers must be the REAL ones.
    expect(find.text('1,000'), findsWidgets, reason: 'system 1,000 missing');
    expect(find.text('900'), findsWidgets, reason: 'actual 900 missing');
    expect(find.text('-100'), findsWidgets, reason: 'diff missing');
  });

  testWidgets('REGRESSION: count page renders the product + unit boxes',
      (tester) async {
    await preload(tester);
    final record = {
      'id': 'r1',
      'ref_code': 'RCN-1',
      'status': 'draft',
      'lines': [
        {
          'product_id': 'p1',
          'name': 'تونه',
          'image': null,
          'unit': 'قطعة',
          'system_qty': 1,
          'counted_qty': null,
          'base_qty': null,
        },
      ],
      'units': {
        'p1': [
          {'unit_id': 'u1', 'name': 'كرتون', 'factor': 12}
        ]
      },
    };
    await tester.pumpWidget(ProviderScope(
      overrides: [
        reconciliationApiProvider
            .overrideWithValue(DiagApi(ApiClient(dio: Dio()))),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: ReconInventoryCountPage(record: record),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('تونه'), findsOneWidget, reason: 'product card missing');
    // Search + base box + the carton box.
    expect(find.byType(TextField), findsNWidgets(3));
  });

  testWidgets(
      'REGRESSION: single-unit product shows ONE box; factor-1 unit skipped',
      (tester) async {
    await preload(tester);
    final record = {
      'id': 'r1', 'ref_code': 'RCN-1', 'status': 'draft', 'scope': 'product',
      'lines': [
        {
          'product_id': 'p1', 'name': 'تونه', 'image': null, 'unit': 'قطعة',
          'system_qty': 1, 'counted_qty': null, 'base_qty': null,
        },
      ],
      'units': {
        'p1': [
          // a bogus factor-1 duplicate of the base unit (the old «1×0» box)
          {'unit_id': 'u0', 'name': 'قطعة', 'factor': 1},
        ]
      },
    };
    await tester.pumpWidget(ProviderScope(
      overrides: [
        reconciliationApiProvider
            .overrideWithValue(DiagApi(ApiClient(dio: Dio()))),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: ReconInventoryCountPage(record: record),
      ),
    ));
    await tester.pumpAndSettle();
    // ONLY the base box + the search field — no duplicate unit box.
    expect(find.byType(TextField), findsNWidgets(2),
        reason: 'search + 1 base box (no bogus unit box)');
    expect(find.textContaining('(×1'), findsNothing);
    // extra unit still shows its own box with the factor
    await tester.pumpWidget(const SizedBox()); // reset the state
    await tester.pumpAndSettle();
    final record2 = {
      ...record,
      'units': {
        'p1': [
          {'unit_id': 'u1', 'name': 'كرتون', 'factor': 12},
        ]
      },
    };
    await tester.pumpWidget(ProviderScope(
      overrides: [
        reconciliationApiProvider
            .overrideWithValue(DiagApi(ApiClient(dio: Dio()))),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: ReconInventoryCountPage(record: record2),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('كرتون'), findsWidgets,
        reason: 'real extra unit must keep its own box');
  });

  testWidgets('REGRESSION: result table prints numbers from the first frame',
      (tester) async {
    await preload(tester);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: ReconDiffTable(rows: const [
          ReconResultRow(
              name: 'USD', system: 1000, actual: 900, diff: -100, unit: 'USD'),
        ]),
      ),
    ));
    await tester.pump(); // FIRST frame — values must already be real
    expect(find.text('1,000'), findsOneWidget);
    expect(find.text('900'), findsOneWidget);
    expect(find.text('-100'), findsOneWidget);
  });
}

class DiagApi extends ReconciliationApi {
  DiagApi(super.client);
  @override
  Future<List<Map<String, dynamic>>> accounts() async => [
        {
          'id': 'a1', 'bank_name': 'بنك', 'account_name': 'دولار',
          'account_number': 'A1', 'currency': 'USD', 'balance': 1000,
          'account_type': 'checking', 'is_cash': false,
        }
      ];
  @override
  Future<Map<String, dynamic>> bankCheck({
    required List<Map<String, dynamic>> entries,
    String? notes,
    String? periodStart,
    String? periodEnd,
    String? idempotencyKey,
  }) async {
    return {
      'id': 'rec1',
      'ref_code': 'RCN-1',
      'status': 'checked',
      'lines': [
        {
          'account_id': 'a1', 'name': 'بنك', 'bank_name': 'بنك',
          'currency': 'USD', 'system': 1000,
          'actual': (entries.first['actual'] as num).toDouble(),
          'diff': (entries.first['actual'] as num) - 1000,
          'status': 'short',
        }
      ],
    };
  }
}
