import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/inventory/data/inventory_api.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';
import 'package:fyona_flutter/features/reconciliation/data/reconciliation_api.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_inventory_pick_page.dart';
import 'package:fyona_flutter/features/reconciliation/presentation/pages/recon_inventory_count_page.dart';

void main() {
  testWidgets('REGRESSION: product pick carries the products into the count page',
      (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final recon = DiagRecon(ApiClient(dio: Dio()));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        reconciliationApiProvider.overrideWithValue(recon),
        inventoryApiProvider
            .overrideWithValue(DiagInv(ApiClient(dio: Dio()))),
      ],
      child: MaterialApp.router(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: GoRouter(routes: [
          GoRoute(
              path: '/',
              builder: (_, _) =>
                  const ReconInventoryPickPage(scope: 'product')),
          GoRoute(
              path: '/reconciliation/inventory/count',
              builder: (_, state) {
                final rec = state.extra as Map<String, dynamic>;
                return ReconInventoryCountPage(record: rec);
              }),
        ]),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 150),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 6));
    expect(find.text('تونه'), findsOneWidget, reason: 'product missing in picker');
    await tester.tap(find.text('تونه'));
    await tester.pumpAndSettle(const Duration(milliseconds: 200),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 8));
    // The count page must show the product card + its unit boxes.
    expect(find.text('تونه'), findsOneWidget, reason: 'count page empty!');
    expect(find.byType(TextField), findsWidgets, reason: 'no input boxes!');
  });

  testWidgets('REGRESSION: full-mode auto-start carries the products (post-frame)',
      (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final recon = DiagRecon(ApiClient(dio: Dio()));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        reconciliationApiProvider.overrideWithValue(recon),
        inventoryApiProvider
            .overrideWithValue(DiagInv(ApiClient(dio: Dio()))),
      ],
      child: MaterialApp.router(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: GoRouter(routes: [
          GoRoute(
              path: '/',
              builder: (_, _) =>
                  const ReconInventoryPickPage(scope: 'full')),
          GoRoute(
              path: '/reconciliation/inventory/count',
              builder: (_, state) {
                final rec = state.extra as Map<String, dynamic>;
                return ReconInventoryCountPage(record: rec);
              }),
        ]),
      ),
    ));
    await tester.pumpAndSettle(const Duration(milliseconds: 200),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 8));
    expect(find.text('تونه'), findsOneWidget,
        reason: 'full scope: count page empty — auto-start lost the data!');
    expect(find.byType(TextField), findsWidgets);
  });
}

class DiagRecon extends ReconciliationApi {
  DiagRecon(super.client);
  @override
  Future<Map<String, dynamic>> inventoryStart({
    required String scope,
    String? productId,
    String? categoryId,
    String? branchId,
    String? notes,
    String? idempotencyKey,
  }) async {
    return {
      'id': 'r1',
      'ref_code': 'RCN-1',
      'rtype': 'inventory',
      'status': 'draft',
      'lines': [
        {
          'product_id': 'p1', 'name': 'تونه', 'image': null, 'unit': 'قطعة',
          'system_qty': 1, 'counted_qty': null, 'base_qty': null,
        }
      ],
      'units': {
        'p1': [
          {'unit_id': 'u1', 'name': 'كرتون', 'factor': 12}
        ]
      },
    };
  }
}

class DiagInv extends InventoryApi {
  DiagInv(super.client);
  @override
  Future<List<Map<String, dynamic>>> listProducts({
    String search = '',
    String? stockStatus,
    String? expiry,
    int expiryDays = 30,
    String? categoryId,
    bool uncategorized = false,
    int page = 1,
    int perPage = 50,
  }) async {
    return [
      {'id': 'p1', 'name': 'تونه', 'stock': 1, 'unit': 'قطعة',
       'is_service': false, 'image': null},
    ];
  }
}
