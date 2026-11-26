import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/router/route_names.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/presentation/providers/local_commerce_navigation.dart';
import 'package:fyona_flutter/features/employees/data/employee_permissions.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/employees/presentation/widgets/employee_feature_gate.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/product_detail_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';
import 'package:fyona_flutter/features/returns/presentation/pages/returns_page.dart';
import 'package:fyona_flutter/features/returns/presentation/providers/returns_providers.dart';
import 'package:fyona_flutter/features/reports/presentation/pages/report_view_page.dart';
import 'package:fyona_flutter/features/reports/presentation/pages/reports_hub_page.dart';
import 'package:fyona_flutter/features/reports/data/reports_api.dart';
import 'package:fyona_flutter/features/sales/presentation/widgets/sale_customer_section.dart';
import 'package:fyona_flutter/features/purchases/presentation/widgets/purchase_supplier_section.dart';
import 'reports_feature_test.dart' show FakeReportsApi;

void main() {
  Future<void> host(
    WidgetTester tester,
    Widget page,
    Map<String, bool> denied, {
    String path = '/',
    Object? extra,
  }) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final router = GoRouter(
      initialLocation: path,
      initialExtra: extra,
      routes: [
        GoRoute(path: '/', builder: (_, _) => page),
        if (path != '/')
          GoRoute(path: Uri.parse(path).path, builder: (_, _) => page),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeePermissionsProvider.overrideWith(
            (ref) => {...defaultEmployeePermissions(), ...denied},
          ),
          employeeWorkspaceCompanyProvider.overrideWith(
            (ref) => {'role': 'member'},
          ),
          productDetailProvider((id: 'p', target: null)).overrideWith(
            (ref) async => {
              'id': 'p',
              'name': 'Product',
              'unit': 'piece',
              'stock': 4,
            },
          ),
          productUnitsProvider((
            id: 'p',
            target: null,
          )).overrideWith((ref) async => {'units': []}),
          productLotsProvider((
            id: 'p',
            target: null,
          )).overrideWith((ref) async => []),
          productPricesProvider((
            id: 'p',
            target: null,
          )).overrideWith((ref) async => []),
          returnsListProvider('all').overrideWith((ref) async => []),
          businessReportsApiProvider.overrideWithValue(
            FakeReportsApi(ApiClient(dio: Dio())),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'inventory parent does not expose denied edit/delete/quantity actions',
    (tester) async {
      await host(tester, const ProductDetailPage(id: 'p'), {
        'inventory.edit': false,
        'inventory.delete': false,
      });
      // Header + the base unit row (each unit row names the product); the
      // units card opens with its arrow.
      final toggle = find.byKey(const ValueKey('unitDetailsToggle'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('Product'), findsNWidgets(2));
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      expect(find.byIcon(Icons.tune), findsNothing);
      expect(find.byIcon(Icons.history), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'return choices reflow and denied child has no option or filter',
    (tester) async {
      await host(tester, const ReturnsPage(), {'sales.returns': false});
      final l10n = AppLocalizations(const Locale('ar'));
      await l10n.load();
      expect(find.text(l10n.translate('retCustomerReturn')), findsNothing);
      expect(find.text(l10n.translate('retSupplierReturn')), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'report export child denial removes PDF action without denying view',
    (tester) async {
      await host(tester, const ReportViewPage(kind: 'inventory'), {
        'reports.export': false,
      });
      expect(find.byIcon(Icons.picture_as_pdf_outlined), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hidden bank balances remove financial report cards and nested home totals',
    (tester) async {
      await host(tester, const ReportsHubPage(), {'banks.balances': false});
      final l10n = AppLocalizations(const Locale('ar'));
      await l10n.load();
      expect(find.text(l10n.translate('repInventory')), findsOneWidget);
      for (final key in [
        'repMoney',
        'repSalesPurchases',
        'repDebts',
        'repOverview',
      ]) {
        expect(find.text(l10n.translate(key)), findsNothing, reason: key);
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final purchase in [false, true]) {
    testWidgets(
      'invoice form omits denied quick-add party action purchase=$purchase',
      (tester) async {
        await host(
          tester,
          Scaffold(
            body: purchase
                ? const PurchaseSupplierSection()
                : const SaleCustomerSection(),
          ),
          {purchase ? 'suppliers.add' : 'customers.add': false},
        );
        final l10n = AppLocalizations(const Locale('ar'));
        await l10n.load();
        await tester.tap(
          find.text(
            l10n.translate(
              purchase ? 'purTapToSelectSupplier' : 'saleTapToSelectCustomer',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            l10n.translate(purchase ? 'purQuickAddSupplier' : 'saleQuickAdd'),
          ),
          findsNothing,
        );
        expect(
          find.text(
            l10n.translate(purchase ? 'purCashSupplier' : 'saleCashCustomer'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final uri in [
    '/inventory/product/edit',
    '/inventory/product/edit?id=p',
    '/customers/detail?id=c',
    '/branches/transfers',
    '/reports/view?kind=money',
  ]) {
    testWidgets('deep route never mounts denied body $uri', (tester) async {
      await host(
        tester,
        EmployeeFeatureGate(
          route: Uri.parse(uri).path,
          child: const Text('SECRET BODY'),
        ),
        {for (final key in defaultEmployeePermissions().keys) key: false},
        path: uri,
      );
      expect(find.text('SECRET BODY'), findsNothing);
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (path, kind, permissions) in [
    (
      RouteNames.invoicesView,
      'purchase',
      {'sales.view': true, 'purchases.view': false},
    ),
    (
      RouteNames.inventoryProductEdit,
      null,
      {'inventory.add': true, 'inventory.edit': false},
    ),
    (
      RouteNames.returnsView,
      'purchase_return',
      {'returns': true, 'purchases.returns': false},
    ),
  ]) {
    testWidgets('a scoped detail keeps its original permission $path', (
      tester,
    ) async {
      const id = '76471393-f452-4cdb-8ca9-000714ea799e';
      final scope = DirectoryAccess(
        workspace: DirectoryWorkspace(
          server: 'https://scoped-fixture.example.test/api/v1',
          accountId: id,
          organizationId: id,
        ),
        branchId: id,
        readable: const {},
        writable: const {},
        financialCutover: true,
      );
      await host(
        tester,
        EmployeeFeatureGate(route: path, child: const Text('Protected record')),
        permissions,
        path: path,
        extra: LocalCommerceTarget(scope, path, id, kind: kind),
      );
      expect(find.text('Protected record'), findsNothing);
      expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
