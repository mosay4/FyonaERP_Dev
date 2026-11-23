import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/personal_recurring_form_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_utils.dart';

/// Wizard gating (user-mandated):
/// - step 5 (frequency) opens with NOTHING pre-selected; Next warns until
///   the user picks a period, then warns until the execution day is picked.
/// - the bottom section is titled "تحديد وقت ويوم التنفيذ".
/// - skipping the time defaults to 09:00 (visible in the review step).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {});
    await ensureTestLocalization();
  });

  Future<void> pumpForm(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
            path: '/',
            builder: (_, __) => const PersonalRecurringFormPage()),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          locale: const Locale('ar'),
          localizationsDelegates:
              AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapNext(WidgetTester tester) async {
    await tester.tap(find.text('التالي'));
    await tester.pumpAndSettle();
  }

  testWidgets('frequency unselected, day mandatory, time defaults to 09:00',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await pumpForm(tester);

    // Step 1 (type) → step 2 (name).
    await tapNext(tester);
    await tester.enterText(find.byType(TextField), 'راتب شهري');
    await tester.pumpAndSettle();
    // Step 3 (category).
    await tapNext(tester);
    await tester.tap(find.text('طعام'));
    await tester.pumpAndSettle();
    // Step 4 (amount).
    await tapNext(tester);
    await tester.enterText(find.byType(TextField), '5000');
    await tester.pumpAndSettle();
    // Step 5 (frequency + execution day/time).
    await tapNext(tester);

    // The bottom section carries the new title.
    expect(find.text('تحديد وقت ويوم التنفيذ'), findsOneWidget);

    // Nothing pre-selected: Next warns to pick a period first.
    await tapNext(tester);
    expect(find.text('اختر مدة العملية أولاً'), findsOneWidget);
    // Let the snackbar expire so the next warning is observable.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // Pick monthly, still no day: Next warns that the day is mandatory.
    await tester.tap(find.text('شهري'));
    await tester.pumpAndSettle();
    await tapNext(tester);
    expect(find.text('يجب تحديد يوم التنفيذ بالضبط'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // Pick the execution day from the bottom section (defaults to today).
    // The bottom row is the one showing the "unspecified" value.
    final dayRow = find.ancestor(
      of: find.text('غير محدد'),
      matching: find.byType(GestureDetector),
    );
    await tester.tap(dayRow.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('حسنًا'));
    await tester.pumpAndSettle();

    // Now Next advances to the account step — without ever picking a time.
    await tapNext(tester);
    expect(find.text('الحساب'), findsOneWidget);

    // Pick-at-execution → execution step.
    await tester.tap(find.textContaining('اختيار الحساب عند التنفيذ'));
    await tester.pumpAndSettle();
    await tapNext(tester);
    expect(find.text('طريقة التنفيذ'), findsOneWidget);

    // Default execution type (auto) → review step shows the 09:00 default.
    await tapNext(tester);
    expect(find.textContaining('09:00'), findsWidgets);

    expect(tester.takeException(), isNull);
  });
}
