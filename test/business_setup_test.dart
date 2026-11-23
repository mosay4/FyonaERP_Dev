import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/business_setup_page.dart';

/// The Business customization wizard must show REAL content and a pinned
/// action bar (رجوع/التالي/إنشاء) on a small phone in RTL — the reported bug
/// was an empty page with no texts and no buttons.
void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const BusinessSetupPage(),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('step 1 shows real options + a visible Next button',
      (tester) async {
    await pump(tester);
    expect(find.text('تخصيص قسم الأعمال'), findsOneWidget);
    expect(find.text('شنو شغلك؟'), findsOneWidget);
    expect(find.text('عملك الأساسية'), findsOneWidget);
    expect(find.text('بقالة'), findsOneWidget);
    expect(find.text('التالي'), findsOneWidget);
    final box = tester.getRect(find.text('التالي'));
    expect(box.bottom, lessThanOrEqualTo(640));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Next advances to stock step with a Back button',
      (tester) async {
    await pump(tester);
    await tester.tap(find.text('التالي'));
    await tester.pump();
    expect(find.text('كيف تدير المخزون؟'), findsOneWidget);
    expect(find.text('تستخدم الباركود'), findsOneWidget);
    expect(find.text('رجوع'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('step 3 shows the Create button', (tester) async {
    await pump(tester);
    await tester.tap(find.text('التالي'));
    await tester.pump();
    await tester.tap(find.text('التالي'));
    await tester.pump();
    expect(find.text('الأرقام والفواتير'), findsOneWidget);
    expect(find.text('إنشاء قسم الأعمال'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
