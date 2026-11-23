import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/profile/presentation/pages/profile_page.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/employees/data/employee_permissions.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_profile_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';

void main() {
  testWidgets('open employee profile follows full to custom live permission changes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() => AppLocalizations.preload('ar'));
    BranchScope.organizationId = 'merchant';
    addTearDown(() => BranchScope.organizationId = null);
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (!details.exceptionAsString().startsWith('ListTile background color or ink splashes may be invisible.')) {
        original?.call(details);
      }
    };
    addTearDown(() => FlutterError.onError = original);
    final live = StateProvider<Map<String, bool>>((ref) => defaultEmployeePermissions());
    var profileLoads = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        employeeWorkspaceCompanyProvider.overrideWith((ref) => {'role': 'member'}),
        employeePermissionsProvider.overrideWith((ref) => ref.watch(live)),
        branchAccessProvider.overrideWith((ref) async => []),
        myEmployeeProfileForProvider('merchant').overrideWith((ref) async {
          profileLoads++;
          return {'employee': {'full_name': 'Employee', 'permissions': defaultEmployeePermissions()}};
        }),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const EmployeeProfilePage(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.widget<ProfilePage>(find.byType(ProfilePage)).employeeFull, isTrue);
    final container = ProviderScope.containerOf(tester.element(find.byType(EmployeeProfilePage)));
    container.read(live.notifier).state = {
      ...defaultEmployeePermissions(), 'invoices': false,
    };
    await tester.pumpAndSettle();
    expect(tester.widget<ProfilePage>(find.byType(ProfilePage)).employeeFull, isFalse);
    final l10n = AppLocalizations(const Locale('ar'));
    await l10n.load();
    for (final key in ['invDesignHubTitle', 'prefAllowNegative', 'profileBackupSync']) {
      expect(find.text(l10n.translate(key)), findsNothing);
    }
    expect(find.text('تخصيص عملات قسم الأعمال'), findsNothing);
    expect(profileLoads, 1, reason: 'Live permissions must override the cached full-access profile');
    expect(tester.takeException(), isNull);
  });
  for (final full in [false, true]) {
    testWidgets('original profile restricts employee controls full=$full', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(() => AppLocalizations.preload('ar'));
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final original = FlutterError.onError;
      FlutterError.onError = (details) {
        if (!details.exceptionAsString().startsWith(
          'ListTile background color or ink splashes may be invisible.',
        )) {
          original?.call(details);
        }
      };
      addTearDown(() => FlutterError.onError = original);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            locale: const Locale('ar'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: ProfilePage(
              business: true,
              employeeFull: full,
              employee: const {
                'full_name': 'Assigned Name',
                'phone': '777123456',
                'salary': 1500,
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = AppLocalizations(const Locale('ar'));
      await l10n.load();
      expect(find.byType(ProfilePage), findsOneWidget);
      expect(find.text('Assigned Name'), findsOneWidget);
      expect(find.text('777123456'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      for (final key in [
        'profileSubscription',
        'profileResetAccount',
        'profileAccountSecurity',
      ]) {
        expect(find.text(l10n.translate(key)), findsNothing, reason: key);
      }
      expect(find.text(l10n.translate('activeSessionsTitle')), findsNothing);
      for (final key in [
        'invDesignHubTitle',
        'prefAllowNegative',
        'profileBackupSync',
      ]) {
        expect(
          find.text(l10n.translate(key)),
          full ? findsWidgets : findsNothing,
          reason: key,
        );
      }
      expect(
        find.text(l10n.sessionTimeout),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
