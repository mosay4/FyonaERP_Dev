import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/product_detail_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/warehouse_settings.dart';
import 'package:fyona_flutter/shared/providers/current_user_provider.dart';

class _Ws extends WarehouseSettingsNotifier {
  _Ws(WarehouseSettings s) {
    state = s;
  }
  @override
  Future<void> load() async {}
}

void main() {
  final product = <String, dynamic>{
    'id': 'p1',
    'name': 'زبادي',
    'unit': 'قطعة',
    'stock': 74,
    'price': 30,
    'cost_price': 10,
    'cost_currency': 'USD',
    'image': null,
  };
  final units = <String, dynamic>{
    'units': [
      {
        'id': 'u0',
        'name': 'قطعة',
        'factor': 1,
        'is_base': true,
        'sale_price': null,
        'purchase_price': null,
      },
      {
        'id': 'u1',
        'name': 'باكيت',
        'factor': 8,
        'is_base': false,
        'sale_price': 200,
        'purchase_price': 80,
      },
    ],
    'barcodes': [],
  };

  Future<void> pump(WidgetTester tester, {required bool extra}) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productDetailProvider((
            id: 'p1',
            target: null,
          )).overrideWith((ref) async => product),
          productUnitsProvider((
            id: 'p1',
            target: null,
          )).overrideWith((ref) async => units),
          branchesProvider.overrideWith(
            (ref) async => <Map<String, dynamic>>[],
          ),
          currentUserRoleProvider.overrideWithValue('owner'),
          warehouseSettingsProvider.overrideWith(
            (ref) => _Ws(WarehouseSettings(extraOptions: extra)),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const ProductDetailPage(id: 'p1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('header shows ONLY the product name; base unit box has qty', (
    tester,
  ) async {
    await pump(tester, extra: false);
    expect(find.text('زبادي'), findsOneWidget);
    // Available quantity of the base unit is shown in the units box.
    expect(find.text('74 قطعة'), findsWidgets);
    // Extra unit box is hidden while «الخيارات الإضافية» is off.
    expect(find.text('باكيت'), findsNothing);
  });

  testWidgets('extra unit gets its own box when extraOptions is on', (
    tester,
  ) async {
    await pump(tester, extra: true);
    expect(find.text('باكيت'), findsOneWidget);
    // 74 / 8 = 9 whole packs + 2 leftover pieces — truthful, not rounded.
    expect(find.text('9 باكيت + 2 قطعة'), findsOneWidget);
  });

  testWidgets('adjust flow picks a unit first when the product has >1 unit', (
    tester,
  ) async {
    await pump(tester, extra: true);
    // Open «تعديل الكمية» (the tune action button).
    await tester.tap(find.text('تعديل الكمية').first);
    await tester.pumpAndSettle();
    // Mode sheet → increase.
    await tester.tap(find.text('زود الكمية'));
    await tester.pumpAndSettle();
    // Unit picker: both the base unit and the extra unit are selectable.
    expect(find.text('قطعة (الوحدة الأساسية)'), findsOneWidget);
    expect(find.text('باكيت ×8'), findsOneWidget);
  });

  testWidgets('single-unit product adjusts directly (no unit picker)', (
    tester,
  ) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    final single = {
      'units': [units['units']![0]],
      'barcodes': [],
    };
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productDetailProvider((
            id: 'p1',
            target: null,
          )).overrideWith((ref) async => product),
          productUnitsProvider((
            id: 'p1',
            target: null,
          )).overrideWith((ref) async => single),
          branchesProvider.overrideWith(
            (ref) async => <Map<String, dynamic>>[],
          ),
          currentUserRoleProvider.overrideWithValue('owner'),
          warehouseSettingsProvider.overrideWith(
            (ref) => _Ws(const WarehouseSettings()),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const ProductDetailPage(id: 'p1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('تعديل الكمية').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('زود الكمية'));
    await tester.pumpAndSettle();
    // No picker — the save button is shown directly.
    expect(find.text('باكيت ×8'), findsNothing);
    expect(find.text('حفظ التعديل'), findsOneWidget);
  });

  testWidgets('unit boxes use plain language, technical groups stay hidden', (
    tester,
  ) async {
    await pump(tester, extra: true);
    // «1 باكيت = 8 قطع» instead of «معامل التحويل ×8».
    expect(find.text('1 باكيت = 8 قطعة'), findsOneWidget);
    expect(find.textContaining('معامل التحويل'), findsNothing);
    // The technical family label is internal-only.
    expect(find.text('العدد والتغليف'), findsNothing);
  });
}
