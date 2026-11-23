import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:fyona_flutter/core/database/database_helper.dart';
import 'package:fyona_flutter/core/database/repositories/personal_cache_repository.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/network/dio_provider.dart';
import 'package:fyona_flutter/features/personal/di/personal_providers.dart';
import 'package:fyona_flutter/features/personal/domain/services/personal_finance_service.dart';
import 'package:fyona_flutter/features/personal/presentation/pages/personal_budget_form_page.dart';

import 'test_utils.dart';

/// Budget wizard: amounts survive Back/Next, and Next is blocked until every
/// selected category carries an amount.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    // Haptics + restores have no platform host in tests.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {});
    await ensureTestLocalization();
  });

  PersonalFinanceService makeService() {
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'));
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) => handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          message: 'offline',
        ),
      ),
    ));
    final svc = PersonalFinanceService(
      apiClient: ApiClient(dio: dio),
      cache: PersonalCacheRepository(),
    );
    svc.setUserId(7);
    return svc;
  }

  Future<void> cleanDb() async {
    await DatabaseHelper.rawDelete('DELETE FROM personal_entity_cache');
    await DatabaseHelper.rawDelete('DELETE FROM sync_queue');
  }

  setUp(() async => cleanDb());
  tearDown(() async => cleanDb());

  Future<void> pumpForm(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/form',
      routes: [
        GoRoute(
          path: '/form',
          builder: (_, __) => const PersonalBudgetFormPage(),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          personalFinanceServiceProvider
              .overrideWithValue(makeService()),
          apiClientProvider.overrideWithValue(
              ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9')))),
        ],
        child: MaterialApp.router(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Types into a field (tap to focus, write straight into the test input).
  /// NOTE: never pass a pre-chained (.first/.at) finder to enterText — its
  /// internal descendant search mishandles chained finders.
  Future<void> typeInto(
      WidgetTester tester, Finder field, String text) async {
    await tester.tap(field);
    await tester.pump();
    tester.testTextInput.enterText(text);
    await tester.pump();
  }

  Future<void> tapNext(WidgetTester tester) async {
    await tester.tap(find.text(AppLocalizations.t('next')));
    await tester.pumpAndSettle();
  }

  Future<void> tapBack(WidgetTester tester) async {
    await tester.tap(find.text(AppLocalizations.t('previous')));
    await tester.pumpAndSettle();
  }

  Future<void> reachAmountStep(WidgetTester tester) async {
    // Step 0: name.
    await typeInto(tester, find.byType(TextField), 'Test');
    await tapNext(tester);
    // Step 1: currency (preselected) -> next.
    await tapNext(tester);
    // Step 2: period (defaults) -> next.
    await tapNext(tester);
    // Step 3: add one custom category.
    await typeInto(tester, find.byType(TextField), 'طعام_test');
    await tester.tap(find.byIcon(Icons.add_circle_rounded));
    await tester.pumpAndSettle();
    expect(find.text('طعام_test'), findsOneWidget);
    await tapNext(tester);
  }

  group('budget wizard amounts', () {
    testWidgets('amounts persist across Next then Back', (tester) async {
      await pumpForm(tester);
      await reachAmountStep(tester);

      // Step 4: total + per-category amount.
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      await typeInto(tester, fields.at(0), '2000');
      await typeInto(tester, fields.at(1), '500');
      await tester.pumpAndSettle();

      await tapNext(tester); // -> review step
      await tapBack(tester); // -> back to amounts

      final back = find.byType(TextField);
      final totalCtrl =
          tester.widget<TextField>(back.at(0)).controller!;
      final catCtrl = tester.widget<TextField>(back.at(1)).controller!;
      // Total field formats with grouping; the category keeps exact input.
      expect(totalCtrl.text.replaceAll(',', ''), '2000');
      expect(catCtrl.text, '500',
          reason: 'typed category amount must survive Back/Next');
    });

    testWidgets('Next is blocked naming the unfunded category', (tester) async {
      await pumpForm(tester);
      await reachAmountStep(tester);

      final fields = find.byType(TextField);
      await typeInto(tester, fields.at(0), '2000');
      // Leave the category amount empty, then Next.
      await tapNext(tester);

      // Still on step 4 with a naming error (no navigation happened).
      expect(
        find.text(AppLocalizations.t(
            'budgetCatAmountRequired', {'name': 'طعام_test'})),
        findsOneWidget,
        reason: 'must name the category missing an amount',
      );
    });
  });
}
