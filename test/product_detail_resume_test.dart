import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/product_detail_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/warehouse_settings.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';
import 'package:go_router/go_router.dart';

class _Ws extends WarehouseSettingsNotifier {
  _Ws() {
    state = const WarehouseSettings();
  }
  @override
  Future<void> load() async {}
}

/// An in-memory route target, like LocalCommerceTarget: go_router cannot
/// serialise it, so a re-parse of the stack drops it.
final class _Record {
  const _Record(this.id);
  final String id;
}

void main() {
  const product = <String, dynamic>{
    'id': 'p1',
    'name': 'زبادي',
    'unit': 'قطعة',
    'stock': 74,
    'price': 30,
    'cost_currency': 'USD',
  };

  // Coming back from the background re-parses the router stack
  // (router.refresh() after an auth / branch-epoch change). The page is
  // rebuilt without its in-memory target → id '' → an empty «product».
  testWidgets('product stays shown after the router re-parses on resume', (
    tester,
  ) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    var reads = 0;
    var empty = false;
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/inventory/product',
          builder: (_, state) {
            final extra = state.extra;
            return ProductDetailPage(
              id: extra is _Record
                  ? extra.id
                  : state.uri.queryParameters['id'] ?? '',
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        productDetailProvider.overrideWith((ref, key) async {
          reads++;
          // A missing record reads as an empty map (device ledger contract).
          return key.id == 'p1' && !empty ? product : <String, dynamic>{};
        }),
        productUnitsProvider.overrideWith(
          (ref, key) async => <String, dynamic>{'units': []},
        ),
        productLotsProvider.overrideWith(
          (ref, key) async => <Map<String, dynamic>>[],
        ),
        branchesProvider.overrideWith((ref) async => <Map<String, dynamic>>[]),
        currentUserRoleProvider.overrideWithValue('owner'),
        warehouseSettingsProvider.overrideWith((ref) => _Ws()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    router.push('/inventory/product', extra: const _Record('p1'));
    await tester.pumpAndSettle();
    expect(find.text('زبادي'), findsWidgets);
    expect(find.text('74 قطعة'), findsWidgets);

    // Resume: the router re-parses and rebuilds the same page without
    // its target.
    router.refresh();
    await tester.pumpAndSettle();
    expect(find.byType(ProductDetailPage), findsOneWidget);
    expect(
      tester.widget<ProductDetailPage>(find.byType(ProductDetailPage)).id,
      isEmpty,
      reason: 'go_router really drops the in-memory target on a re-parse',
    );
    expect(find.text('زبادي'), findsWidgets);
    expect(find.text('74 قطعة'), findsWidgets);

    // A later re-read that finds nothing never blanks the product.
    empty = true;
    final before = reads;
    container.invalidate(productDetailProvider);
    await tester.pumpAndSettle();
    expect(reads, greaterThan(before));
    expect(find.text('زبادي'), findsWidgets);
    expect(find.text('74 قطعة'), findsWidgets);
    expect(find.text('0 قطعة'), findsNothing);
  });

  test('only a real new record replaces the one a page was opened for', () {
    expect(productRecordReplaces('', null, 'p1', null), isFalse);
    expect(productRecordReplaces('p2', null, 'p1', null), isTrue);
    expect(productRecordReplaces('p1', null, 'p1', null), isFalse);
  });
}
