import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/widgets/tree/tree_canvas_page.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/financial_tree_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const TreeCanvasPage(),
  ),
);

ProviderContainer _container() => ProviderContainer(
  overrides: [
    currencyEngineProvider.overrideWith((ref) => CurrencyEngine()),
  ],
);

/// Loads the Arabic translation table under the real event loop. In widget
/// tests the ARB asset load only completes inside `runAsync`; once cached the
/// delegate resolves synchronously during the subsequent widget builds.
Future<void> _loadArabicLocales(WidgetTester tester) async {
  await tester.runAsync(
    () => AppLocalizations.delegate.load(const Locale('ar')),
  );
}

void main() {
  testWidgets('renders KPI dashboard, demo tree cards and quick add', (tester) async {
    await _loadArabicLocales(tester);
    SharedPreferences.setMockInitialValues({});
    final container = _container();
    addTearDown(container.dispose);

    await container.read(financialTreeProvider.notifier).createDemoTree();

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    // لوحة المؤشرات الدائمة
    expect(find.text('صافي الثروة'), findsOneWidget);
    expect(find.text('النقد الحر'), findsOneWidget);
    expect(find.text('إجمالي الدخل'), findsOneWidget);
    expect(find.text('إجمالي المصروفات'), findsOneWidget);
    expect(find.text('ديون مستحقة'), findsOneWidget);

    // بطاقات الشجرة التجريبية
    expect(find.text('الراتب الشهري'), findsOneWidget);
    expect(find.text('قرض شخصي'), findsOneWidget);

    // زر الإضافة السريع
    expect(find.text('إضافة عنصر'), findsOneWidget);
  });

  testWidgets('empty state offers create first tree action', (tester) async {
    await _loadArabicLocales(tester);
    SharedPreferences.setMockInitialValues({});
    final container = _container();
    addTearDown(container.dispose);

    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    expect(find.text('لا توجد أشجار مالية بعد'), findsOneWidget);
    expect(find.text('أنشئ شجرتك الأولى'), findsOneWidget);
  });
}