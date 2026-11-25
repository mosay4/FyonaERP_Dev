import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart'
    show businessInventoryImagePrefix;
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';
import 'package:fyona_flutter/features/inventory/presentation/widgets/business_unit_image.dart';
import 'package:fyona_flutter/features/purchases/data/purchase_api.dart';
import 'package:fyona_flutter/features/purchases/presentation/providers/purchase_providers.dart';
import 'package:fyona_flutter/features/purchases/presentation/widgets/purchase_items_section.dart';
import 'package:fyona_flutter/features/sales/data/sales_api.dart';
import 'package:fyona_flutter/features/sales/presentation/providers/sale_providers.dart';
import 'package:fyona_flutter/features/sales/presentation/widgets/sale_items_section.dart';

/// Unit pickers (sale, purchase, returns, transfers) show each unit's photo:
/// its own (a carton) or, like the product page, the product's photo.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const _productPhoto = '$businessInventoryImagePrefix$_png';
const _cartonPhoto = '$businessInventoryImagePrefix'
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAADklEQVR4nGP4z8DwH4QBEfcD/ePF9e8AAAAASUVORK5CYII=';

Map<String, dynamic> _units() => {
  'product_image': _productPhoto,
  'units': [
    {
      'id': 'u-base',
      'name': 'قطعة',
      'factor': 1,
      'is_base': true,
      'sale_price': 1,
      'purchase_price': 1,
      'image': null,
    },
    {
      'id': 'u-carton',
      'name': 'كرتون',
      'factor': 12,
      'is_base': false,
      'sale_price': 10,
      'purchase_price': 8,
      'image': _cartonPhoto,
    },
  ],
};

class _Sales extends SalesApi {
  _Sales() : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> productUnits(String productId) async =>
      _units();
}

class _Purchases extends PurchaseApi {
  _Purchases() : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> productUnits(String productId) async =>
      _units();
}

SaleItem _line() => const SaleItem(
  productId: 'p1',
  unitId: 'u-base',
  description: 'عصير',
  unitName: 'قطعة',
  quantity: 1,
  unitPrice: 1,
);

Widget _host(Widget child, List<Override> overrides) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

int _photos(WidgetTester tester) => find
    .descendant(
      of: find.byType(BusinessUnitImage),
      matching: find.byType(Image),
    )
    .evaluate()
    .length;

void main() {
  Future<void> preload(WidgetTester tester) =>
      tester.runAsync(() => AppLocalizations.preload('ar'));

  test('a unit shows its own photo, else the product photo', () {
    final units = _units();
    final list = (units['units'] as List).cast<Map>();
    expect(businessUnitDisplayImage(list[1], units: units), _cartonPhoto);
    expect(businessUnitDisplayImage(list[0], units: units), _productPhoto);
    expect(
      businessUnitDisplayImage(list[0], product: {'image': _productPhoto}),
      _productPhoto,
    );
    expect(businessUnitDisplayImage(list[0]), isNull);
    expect(businessUnitDisplayImage(null, units: {'product_image': ''}), isNull);
  });

  testWidgets('sale: «اختر الوحدة» lists every unit WITH its photo',
      (tester) async {
    await preload(tester);
    final container = ProviderContainer(
      overrides: [salesApiProvider.overrideWithValue(_Sales())],
    );
    addTearDown(container.dispose);
    container.read(saleDraftProvider.notifier).addItem(_line());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _host(const SaleItemsSection(), const []),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('قطعة').first);
    await tester.pumpAndSettle();
    expect(find.text('كرتون'), findsWidgets);
    expect(_photos(tester), 2, reason: 'carton photo + product photo');
  });

  testWidgets('purchase: the unit sheet shows every unit WITH its photo',
      (tester) async {
    await preload(tester);
    final container = ProviderContainer(
      overrides: [purchaseApiProvider.overrideWithValue(_Purchases())],
    );
    addTearDown(container.dispose);
    container.read(purchaseDraftProvider.notifier).addItem(_line());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _host(const PurchaseItemsSection(), const []),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('قطعة').first);
    await tester.pumpAndSettle();
    expect(find.text('كرتون'), findsWidgets);
    expect(_photos(tester), 2, reason: 'carton photo + product photo');
  });

  testWidgets('returns: the returned line shows its unit photo',
      (tester) async {
    await preload(tester);
    await tester.pumpWidget(
      _host(
        const Column(
          children: [
            BusinessLineUnitImage(productId: 'p1', unitId: 'u-carton'),
            BusinessLineUnitImage(productId: 'p1', unitName: 'قطعة'),
            BusinessLineUnitImage(productId: null),
          ],
        ),
        [productUnitsProvider.overrideWith((ref, key) async => _units())],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BusinessUnitImage), findsNWidgets(2));
    expect(_photos(tester), 2);
  });
}
