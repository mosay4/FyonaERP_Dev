import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/branches/presentation/pages/branch_inventory_picker_page.dart';
import 'package:fyona_flutter/features/core_business/presentation/widgets/business_number_field.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/warehouse_settings.dart';

/// The warehouse «التصانيف» setting switched on (the categories filter
/// follows it).
class _CategoriesOn extends WarehouseSettingsNotifier {
  _CategoriesOn() {
    state = const WarehouseSettings(categories: true);
  }
  @override
  Future<void> load() async {}
}

final _categoriesOn = [
  warehouseSettingsProvider.overrideWith((_) => _CategoriesOn()),
];

void main() {
  testWidgets(
    'selection rejects excess stock and returns the chosen quantity',
    (tester) async {
      await tester.runAsync(() => AppLocalizations.preload('ar'));
      List<Map<String, dynamic>>? result;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await Navigator.of(context)
                        .push<List<Map<String, dynamic>>>(
                          MaterialPageRoute(
                            builder: (_) => BranchInventoryPickerPage(
                              products: [
                                {
                                  'id': 'stock',
                                  'name': 'مخزون قابل للتجزئة',
                                  'unit': 'قطعة',
                                  'available': '35.0000',
                                  'image': 'missing.jpg',
                                  'units': const [],
                                },
                                {
                                  'id': 'empty',
                                  'name': 'منتج نفد',
                                  'unit': 'قطعة',
                                  'available': 0,
                                  'units': const [],
                                },
                              ],
                              sourceBranchName: 'الراسل',
                              targetBranchName: 'المستلم',
                            ),
                          ),
                        );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('منتج نفد'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('inventory-select-empty')),
            )
            .onPressed,
        isNull,
      );
    await tester.tap(find.byKey(const ValueKey('inventory-select-stock')));
    await tester.pumpAndSettle();
    final quantityField = find.byKey(const ValueKey('inventory-quantity-stock'));
    await tester.tap(find.byKey(const ValueKey('inventory-increase-stock')));
    await tester.pump();
    expect(tester.widget<BusinessNumberField>(quantityField).controller!.text, '2');
    await tester.tap(find.byKey(const ValueKey('inventory-decrease-stock')));
    await tester.pump();
    expect(tester.widget<BusinessNumberField>(quantityField).controller!.text, '1');
    await tester.enterText(quantityField, '35');
    await tester.pump();
    expect(tester.widget<IconButton>(find.byKey(
        const ValueKey('inventory-increase-stock'))).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('inventory-quantity-stock')),
        '36',
      );
      await tester.tap(find.byKey(const ValueKey('inventory-confirm')));
      await tester.pump();
      expect(result, isNull);
      expect(
        find.byKey(const ValueKey('inventory-product-stock')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('inventory-quantity-stock')),
        '12.5',
      );
      await tester.tap(find.byKey(const ValueKey('inventory-confirm')));
      await tester.pumpAndSettle();
      expect(result, hasLength(1));
      expect(result!.single['quantity'], 12.5);
      expect(result!.single['product']['id'], 'stock');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('product rows stay visible when an image cannot load', (
    tester,
  ) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: BranchInventoryPickerPage(
            products: [
              {
                'id': 'pictured',
                'name': 'منتج بصورة',
                'image': 'missing-product-image.jpg',
                'unit': 'قطعة',
                'available': 35.0,
                'units': const [],
              },
            ],
            sourceBranchName: 'الصافيه',
            targetBranchName: 'حده',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('منتج بصورة').hitTestable(), findsOneWidget);
  });

  testWidgets('product rows render at phone size with enlarged Arabic text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: BranchInventoryPickerPage(
            products: List.generate(
              12,
              (i) => {
                'id': 'p$i',
                'name': 'منتج المخزن رقم $i',
                'image': 'missing-image.jpg',
                'available': 35.0,
                'unit': 'قطعة',
                'units': const [],
              },
            ),
            sourceBranchName: 'الفرع العام',
            targetBranchName: 'الصافيه',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('منتج المخزن رقم 0').hitTestable(), findsOneWidget);
  });

  testWidgets('picker renders products and category filters', (tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final products = [
      {
        'id': 'p1',
        'name': 'زبادي',
        'name_ar': 'زبادي',
        'barcode': '123',
        'unit': 'قطعة',
        'image': '',
        'available': 35.0,
        'category_id': 'c1',
        'category_name': 'خضروات',
        'category_name_ar': 'خضروات',
        'units': [
          {'id': 'u1', 'name': 'قطعة', 'factor': 1, 'is_base': true},
        ],
      },
      {
        'id': 'p2',
        'name': 'زيت',
        'unit': 'قطعة',
        'image': '',
        'available': 21.0,
        'units': const [],
      },
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: _categoriesOn,
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: BranchInventoryPickerPage(
            products: products,
            sourceBranchName: 'الصافيه',
            targetBranchName: 'حده',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('زبادي'), findsOneWidget);
    expect(find.text('زيت'), findsOneWidget);
    // Two TEXT filters: «منتجات فردية» (every product, also the ones in a
    // category) and «التصانيف»; no «جميع المنتجات».
    expect(find.text('خضروات'), findsNothing);
    expect(find.byKey(const ValueKey('inventory-filter-all')), findsNothing);
    expect(
      find.byKey(const ValueKey('inventory-filter-individual')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('inventory-filter-categories')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('inventory-filter-individual')));
    await tester.pumpAndSettle();
    expect(find.text('زيت'), findsOneWidget);
    expect(find.text('زبادي'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('inventory-filter-categories')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inventory-category-c1')), findsOneWidget);
    expect(find.byKey(const ValueKey('inventory-product-p1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('inventory-category-c1')));
    await tester.pumpAndSettle();
    expect(find.text('زبادي'), findsOneWidget);
    expect(find.text('زيت'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'category boxes and products work on a narrow phone at 200 percent text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => AppLocalizations.preload('ar'));
      await tester.pumpWidget(
        ProviderScope(
          overrides: _categoriesOn,
          child: MaterialApp(
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: BranchInventoryPickerPage(
              products: [
                {
                  'id': 'p',
                  'name': 'منتج تجريبي',
                  'available': 35,
                  'category_id': 'c',
                  'units': const [],
                  'image': 'missing.jpg',
                },
              ],
              categories: [
                {'id': 'c', 'name': 'أغذية', 'image': 'missing-category.jpg'},
              ],
              sourceBranchName: 'الفرع العام',
              targetBranchName: 'الصافيه',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final content = find
          .descendant(
            of: find.byKey(const ValueKey('branch-inventory-content')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('inventory-product-p')),
        120,
        scrollable: content,
      );
      await tester.pumpAndSettle();
      expect(find.text('منتج تجريبي').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      final tabs = find.byKey(const ValueKey('inventory-filter-categories'));
      await tester.ensureVisible(tabs);
      await tester.tap(tabs);
      await tester.pumpAndSettle();
      final category = find.byKey(const ValueKey('inventory-category-c'));
      await tester.scrollUntilVisible(category, 120, scrollable: content);
      await tester.tap(category);
      await tester.pumpAndSettle();
      final product = find.byKey(const ValueKey('inventory-product-p'));
      await tester.scrollUntilVisible(product, 120, scrollable: content);
      expect(find.text('منتج تجريبي').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
