import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_debt_projection.dart';
import 'package:fyona_flutter/features/core_business/presentation/widgets/debt_widgets.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/inventory/data/inventory_api.dart';
import 'package:fyona_flutter/features/inventory/presentation/widgets/product_picker.dart';
import 'package:fyona_flutter/features/purchases/data/purchase_api.dart';
import 'package:fyona_flutter/features/purchases/presentation/providers/purchase_providers.dart';
import 'package:fyona_flutter/features/purchases/presentation/widgets/purchase_supplier_section.dart';
import 'package:fyona_flutter/features/sales/data/sales_api.dart';
import 'package:fyona_flutter/features/sales/presentation/providers/sale_providers.dart';
import 'package:fyona_flutter/features/sales/presentation/widgets/sale_customer_section.dart';

/// Regressions for the sale/purchase invoice:
/// 1. The «بحث وتحديد منتجات» picker offers «بدون تصنيف» / «مع التصنيف»
///    when the categories feature is ON, and keeps the selection and
///    quantities while switching views.
/// 2. The «مديونية سابقة» chips show the device-ledger amount (the
///    projection answers `total`, the chips used to read `debt` → «—»).
void main() {
  Map<String, dynamic> product(String id, String name) => {
        'id': id,
        'name': name,
        'stock': 10,
        'price': '10',
        'unit': 'قطعة',
        'is_service': false,
      };

  final loose = product('p-loose', 'منتج بلا تصنيف');
  final drink = product('p-drink', 'عصير برتقال');

  InventoryApi stubInventory() {
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        Object data;
        if (o.path.contains('/categories')) {
          data = [
            {'id': 'c1', 'name': 'مشروبات', 'products_count': 1, 'image': ''},
          ];
        } else {
          final q = o.queryParameters;
          data = q['category_id'] == 'c1'
              ? [drink]
              : q['uncategorized'] == true
                  ? [loose]
                  : [loose, drink];
        }
        h.resolve(Response(
            requestOptions: o, statusCode: 200, data: {'data': data}));
      }));
    return InventoryApi(ApiClient(dio: dio));
  }

  Future<void> setUp(WidgetTester tester) async {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('ink splashes may be invisible')) {
        return;
      }
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget app(Widget home, {List<Override> overrides = const []}) =>
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: home,
        ),
      );

  Future<void> openPicker(WidgetTester tester,
      {required bool showCategories,
      void Function(List<PickedProduct>?)? resultOut}) async {
    await setUp(tester);
    final api = stubInventory();
    await tester.pumpWidget(app(Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () async {
              final r = await showProductMultiPicker(context,
                  api: api,
                  title: 'بحث وتحديد منتجات',
                  checkStock: false,
                  showCategories: showCategories);
              resultOut?.call(r);
            },
            child: const Text('OPEN'),
          ),
        ),
      ),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
  }

  testWidgets('picker without the categories feature has no section pills',
      (tester) async {
    await openPicker(tester, showCategories: false);
    expect(find.text('بدون تصنيف'), findsNothing);
    expect(find.text('مع التصنيف'), findsNothing);
    expect(find.text('منتج بلا تصنيف'), findsOneWidget);
    expect(find.text('عصير برتقال'), findsOneWidget);
  });

  testWidgets(
      'picker with categories: uncategorized, category squares, back, and '
      'selection/quantities kept across views', (tester) async {
    List<PickedProduct>? result;
    await openPicker(tester,
        showCategories: true, resultOut: (r) => result = r);

    // «بدون تصنيف» → only uncategorized products.
    await tester.tap(find.text('بدون تصنيف'));
    await tester.pumpAndSettle();
    expect(find.text('منتج بلا تصنيف'), findsOneWidget);
    expect(find.text('عصير برتقال'), findsNothing);
    await tester.tap(find.text('منتج بلا تصنيف'));
    await tester.pumpAndSettle();
    expect(find.textContaining('حفظ (1)'), findsOneWidget);

    // «مع التصنيف» → category squares (no product rows).
    await tester.tap(find.text('مع التصنيف'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('picker-category-c1')), findsOneWidget);
    expect(find.text('منتج بلا تصنيف'), findsNothing);

    // Open the category → its products, with a back affordance.
    await tester.tap(find.byKey(const ValueKey('picker-category-c1')));
    await tester.pumpAndSettle();
    expect(find.text('عصير برتقال'), findsOneWidget);
    expect(find.byKey(const ValueKey('picker-back-to-categories')),
        findsOneWidget);
    await tester.tap(find.text('عصير برتقال'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.add).last);
    await tester.pumpAndSettle();
    expect(find.textContaining('حفظ (2)'), findsOneWidget);

    // Back → squares again; the selection is untouched.
    await tester.tap(find.byKey(const ValueKey('picker-back-to-categories')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('picker-category-c1')), findsOneWidget);
    expect(find.textContaining('حفظ (2)'), findsOneWidget);

    await tester.tap(find.textContaining('حفظ (2)'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    final byId = {for (final p in result!) '${p.product['id']}': p.quantity};
    expect(byId, {'p-loose': 1, 'p-drink': 2});
  });

  // ── «مديونية سابقة» ──
  Map<String, dynamic> ledgerBalance() {
    // Exactly what LocalCommerceBridge.partyBalance answers on the device.
    final projection = BusinessDebtProjection([
      {
        'id': 'd1',
        'number': 'INV-1',
        'invoice_date': '2026-11-01',
        'currency': 'YER_OLD',
        'total_minor': 1350000,
        'paid_minor': 0,
        'group_id': null,
      },
      {
        'id': 'd2',
        'number': 'INV-2',
        'invoice_date': '2026-11-02',
        'currency': 'YER_NEW',
        'total_minor': 250050,
        'paid_minor': 50000,
        'group_id': null,
      },
    ]);
    return {'debts': projection.perCurrency, 'items': projection.operations};
  }

  test('debtRowAmount reads the device-ledger per-currency total', () {
    final rows = (ledgerBalance()['debts'] as List).cast<Map>();
    final byCur = {for (final r in rows) r['currency']: debtRowAmount(r)};
    expect(byCur['YER_OLD'], '13,500');
    expect(byCur['YER_NEW'], '2,000.5');
    // The connected shape (`debt`) still works.
    expect(debtRowAmount({'currency': 'USD', 'debt': 12.5}), '12.5');
    expect(debtRowAmount({'currency': 'USD'}), '—');
  });

  testWidgets('sale invoice: previous debt chips show the amounts',
      (tester) async {
    await setUp(tester);
    final container = ProviderContainer(overrides: [
      salesApiProvider.overrideWithValue(_FakeSalesApi(ledgerBalance())),
      employeeCanProvider.overrideWith((ref, key) => true),
    ]);
    addTearDown(container.dispose);
    container
        .read(saleDraftProvider.notifier)
        .setCustomer(const SaleCustomer(id: 'cu1', name: 'أحمد'));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: app(const Scaffold(body: SaleCustomerSection())),
    ));
    await tester.pumpAndSettle();
    expect(find.text('مديونية سابقة'), findsOneWidget);
    expect(find.text('13,500'), findsOneWidget);
    expect(find.text('2,000.5'), findsOneWidget);
    expect(find.text('—'), findsNothing);
    expect(find.text('ريال يمني قديم'), findsOneWidget);
  });

  testWidgets('purchase invoice: supplier payable chips show the amounts',
      (tester) async {
    await setUp(tester);
    final container = ProviderContainer(overrides: [
      purchaseApiProvider
          .overrideWithValue(_FakePurchaseApi(ledgerBalance())),
      employeeCanProvider.overrideWith((ref, key) => true),
    ]);
    addTearDown(container.dispose);
    container
        .read(purchaseDraftProvider.notifier)
        .setSupplier(const PurchaseSupplier(id: 'su1', name: 'مورد'));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: app(const Scaffold(body: PurchaseSupplierSection())),
    ));
    await tester.pumpAndSettle();
    expect(find.text('13,500'), findsOneWidget);
    expect(find.text('2,000.5'), findsOneWidget);
    expect(find.text('—'), findsNothing);
  });
}

class _FakeSalesApi extends SalesApi {
  _FakeSalesApi(this.balance) : super(ApiClient(dio: Dio()));
  final Map<String, dynamic> balance;
  @override
  Future<Map<String, dynamic>> customerBalance(String customerId) async =>
      balance;
}

class _FakePurchaseApi extends PurchaseApi {
  _FakePurchaseApi(this.balance) : super(ApiClient(dio: Dio()));
  final Map<String, dynamic> balance;
  @override
  Future<Map<String, dynamic>> supplierBalance(String id) async => balance;
}
