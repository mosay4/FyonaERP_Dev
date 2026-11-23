import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/dio_provider.dart';
import 'package:fyona_flutter/features/auth/presentation/providers/auth_provider.dart';
import 'package:fyona_flutter/features/subscription/data/models/subscription_models.dart';
import 'package:fyona_flutter/features/subscription/presentation/pages/plans_page.dart';
import 'package:fyona_flutter/features/subscription/presentation/providers/subscription_providers.dart';

class _Auth extends StateNotifier<AuthState> implements AuthNotifier {
  _Auth() : super(const AuthState());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await AppLocalizations.preload('ar');
    await AppLocalizations.preload('en');
  });
  for (final language in ['ar', 'en']) {
    for (final filter in [null, 'personal', 'business', 'premium', 'invalid']) {
      testWidgets('$language package=$filter paid cards and view all navigation', (tester) async {
        tester.view.physicalSize = const Size(800, 6000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final dio = Dio();
        dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) =>
            handler.resolve(Response(requestOptions: options, statusCode: 200, data: {'data': {}}))));
        final router = GoRouter(initialLocation: '/subscription${filter == null ? '' : '?package=$filter'}', routes: [
          GoRoute(path: '/subscription', builder: (_, state) => PlansPage(packageFilter: state.uri.queryParameters['package'])),
        ]);
        await tester.pumpWidget(ProviderScope(overrides: [
          authProvider.overrideWith((ref) => _Auth()),
          apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
          subscriptionStatusProvider.overrideWith((ref) async => {'status': 'active'}),
          subscriptionPlansProvider.overrideWith((ref) async => [
            for (final key in ['personal', 'business', 'premium'])
              SubscriptionPlan(id: key, name: 'paid-$key', packageType: key, priceYearly: 10),
          ]),
        ], child: MaterialApp.router(routerConfig: router, locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates, supportedLocales: const [Locale('ar'), Locale('en')])));
        await tester.pump();
        await tester.pumpAndSettle();
        final filtered = const ['personal', 'business', 'premium'].contains(filter);
        for (final key in ['personal', 'business', 'premium']) {
          expect(find.text('paid-$key'), !filtered || key == filter ? findsOneWidget : findsNothing,
            reason: tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(' | '));
        }
        final all = find.text(language == 'ar' ? 'عرض جميع الباقات' : 'View all plans');
        if (filtered) {
          expect(all, findsOneWidget);
          await tester.tap(all);
          await tester.pump();
          await tester.pumpAndSettle();
          expect(router.routeInformationProvider.value.uri.toString(), '/subscription');
          for (final key in ['personal', 'business', 'premium']) {
            expect(find.text('paid-$key'), findsOneWidget);
          }
        } else {
          expect(find.text('paid-personal'), findsOneWidget);
          expect(all, findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        router.dispose();
        dio.close();
      });
    }
  }
}
