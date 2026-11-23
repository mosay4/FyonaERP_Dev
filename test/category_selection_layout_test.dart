import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/inventory/data/inventory_api.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/category_detail_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';

void main() {
  for (final locale in ['ar', 'en']) {
    testWidgets('Selection keeps product geometry and exposes remove ($locale)', (tester) async {
      await tester.runAsync(() => AppLocalizations.preload(locale));
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        handler.resolve(Response(requestOptions: options, statusCode: 200, data: {
          'data': options.path == '/categories'
              ? [{'id': 'category', 'name': 'Category'}]
              : List.generate(12, (i) => {
                  'id': 'p$i', 'name': 'Product $i', 'stock': 10,
                  'unit': 'Piece', 'category_id': 'category',
                }),
        }));
      }));
      await tester.pumpWidget(ProviderScope(
        overrides: [inventoryApiProvider.overrideWithValue(InventoryApi(ApiClient(dio: dio)))],
        child: MaterialApp(
          locale: Locale(locale),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const CategoryDetailPage(id: 'category'),
        ),
      ));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(tester.element(find.byType(CategoryDetailPage)));
      final row = find.byKey(const ValueKey('p0'));
      final before = tester.getRect(row);
      final textBefore = tester.getRect(find.text('Product 0'));
      await tester.tap(find.text(l10n.translate('invSelect')));
      await tester.pumpAndSettle();
      expect(tester.getRect(row), before);
      expect(tester.getRect(find.text('Product 0')), textBefore);
      await tester.tap(find.text('Product 0'));
      await tester.pumpAndSettle();
      expect(tester.getRect(row), before);
      expect(tester.getRect(find.text('Product 0')), textBefore);
      expect(find.descendant(of: row, matching: find.byIcon(Icons.check_circle)), findsOneWidget);
      final remove = find.byWidgetPredicate((w) => w is IconButton &&
          w.tooltip == l10n.translate('invRemoveCount', params: {'n': '1'}));
      expect(tester.widget<IconButton>(remove).onPressed, isNotNull);
      expect(tester.widget<Scaffold>(find.byType(Scaffold)).bottomNavigationBar, isNull);
      await tester.tap(find.text(l10n.translate('cancel')));
      await tester.pumpAndSettle();
      expect(tester.getRect(row), before);
      expect(find.descendant(of: row, matching: find.byIcon(Icons.check_circle)), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
