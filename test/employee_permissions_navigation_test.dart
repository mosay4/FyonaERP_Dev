import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/dashboard/presentation/pages/widgets/business_bottom_nav.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_custom_permissions_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_navigation_guard.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/employees/data/employee_permissions.dart';
import 'package:fyona_flutter/features/personal/presentation/providers/merchant_unread_provider.dart';

void main() {
  testWidgets('header save returns edited permissions without leave confirmation', (tester) async {
    Map<String, bool>? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) =>
      TextButton(onPressed: () async {
        result = await Navigator.of(context).push<Map<String, bool>>(
          MaterialPageRoute(builder: (_) => const EmployeeCustomPermissionsPage(
            value: {'dashboard': false})));
      }, child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final header = find.byKey(const ValueKey('save-custom-permissions-header'));
    expect(header.hitTestable(), findsOneWidget);
    expect(find.ancestor(of: header, matching: find.byType(AppBar)), findsOneWidget);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    await tester.tap(header);
    await tester.pumpAndSettle();
    expect(result, defaultEmployeePermissions());
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(EmployeeCustomPermissionsPage), findsNothing);
    expect(employeePermissionsLeaveGuard, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final save in [false, true]) {
    testWidgets(
      'bottom business navigation guards custom permissions save=$save',
      (tester) async {
        await tester.runAsync(() => AppLocalizations.preload('ar'));
        Map<String, bool>? result;
        final router = GoRouter(
          initialLocation: '/employees/edit',
          routes: [
            ShellRoute(
              builder: (_, _, child) => Scaffold(
                body: child,
                bottomNavigationBar: const BusinessBottomNav(),
              ),
              routes: [
                GoRoute(
                  path: '/employees/edit',
                  builder: (context, _) => Center(
                    child: TextButton(
                      onPressed: () async {
                        result = await Navigator.of(context)
                            .push<Map<String, bool>>(
                              MaterialPageRoute(
                                builder: (_) =>
                                    const EmployeeCustomPermissionsPage(
                                      value: {'dashboard': false},
                                    ),
                              ),
                            );
                      },
                      child: const Text('custom'),
                    ),
                  ),
                ),
                GoRoute(
                  path: '/dashboard',
                  builder: (_, _) => const Text('destination'),
                ),
              ],
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              employeePermissionsProvider.overrideWith((ref) => {}),
              debtUnreadProvider(
                'merchant',
              ).overrideWith((ref) => Stream.value(0)),
            ],
            child: MaterialApp.router(
              routerConfig: router,
              locale: const Locale('ar'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('custom'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Switch).first);
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.home_rounded));
        await tester.pumpAndSettle();
        expect(find.text('تبغى تحفظ قبل ما تطلع؟'), findsOneWidget);
        expect(find.text('احفظ واطلع'), findsOneWidget);
        expect(find.text('اطلع بدون حفظ'), findsOneWidget);
        await tester.tap(find.text('إلغاء'));
        await tester.pumpAndSettle();
        expect(find.byType(EmployeeCustomPermissionsPage), findsOneWidget);
        expect(
          router.routeInformationProvider.value.uri.path,
          '/employees/edit',
        );
        await tester.tap(find.byIcon(Icons.home_rounded));
        await tester.pumpAndSettle();
        await tester.tap(find.text(save ? 'احفظ واطلع' : 'اطلع بدون حفظ'));
        await tester.pumpAndSettle();
        expect(find.text('destination'), findsOneWidget);
        expect(result, save ? defaultEmployeePermissions() : isNull);
        expect(employeePermissionsLeaveGuard, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
