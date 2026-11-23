import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'package:fyona_flutter/features/employees/data/employee_api.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_custom_permissions_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_form_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_payment_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employees_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/product_movements_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/pages/inventory_home_page.dart';
import 'package:fyona_flutter/features/inventory/presentation/providers/inventory_providers.dart';
import 'employee_link_settings_test.dart' show TestBranches;

class _Employees extends EmployeeApi {
  _Employees() : super(ApiClient(dio: Dio()));
  @override
  Future<List<Map<String, dynamic>>> list() async => BranchScope.branchId == 'b1'
      ? [{'id': 'e', 'full_name': 'Worker', 'status': 'unlinked'}] : [];
  @override
  Future<Map<String, dynamic>> update(String id, Map<String, dynamic> body) async => body;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BranchScope.branchId = 'b1';
    BranchScope.allMode = false;
  });
  tearDown(() { BranchScope.branchId = null; BranchScope.allMode = false; });

  testWidgets('custom header save is separated far left in RTL and returns edits', (tester) async {
    Map<String, bool>? saved;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ar'), supportedLocales: const [Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () async { saved = await Navigator.push<Map<String, bool>>(context,
          MaterialPageRoute(builder: (_) => const EmployeeCustomPermissionsPage(value: {'dashboard': true}))); },
        child: const Text('Open'))))));
    await tester.tap(find.text('Open')); await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('save-custom-permissions-header'));
    final appbar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appbar.title, isA<Text>());
    expect(tester.getCenter(save).dx, lessThan(tester.getCenter(find.text('صلاحيات مخصصة')).dx - 40));
    await tester.tap(find.byType(Switch).first); await tester.pumpAndSettle();
    await tester.tap(save); await tester.pumpAndSettle();
    expect(saved?['dashboard'], isFalse);
  });

  testWidgets('employee branch epoch clears previous branch list to empty', (tester) async {
    final container = ProviderContainer(overrides: [employeeApiProvider.overrideWithValue(_Employees())]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: EmployeesPage())));
    await tester.pumpAndSettle(); expect(find.text('Worker'), findsOneWidget);
    BranchScope.branchId = 'b2'; container.read(branchEpochProvider.notifier).state++;
    await tester.pumpAndSettle();
    expect(find.text('Worker'), findsNothing);
    expect(find.text('لا يوجد موظفون في هذا الفرع'), findsOneWidget);
  });

  for (final all in [true, false]) {
    testWidgets('payment blocks without concrete branch all=$all and never loads accounts', (tester) async {
      BranchScope.allMode = all; if (!all) BranchScope.branchId = null;
      var loads = 0;
      await tester.pumpWidget(ProviderScope(overrides: [
        employeePaymentAccountsProvider.overrideWith((ref, id) async { loads++; return []; }),
      ], child: const MaterialApp(home: EmployeePaymentPage(mode: 'salary', employeeId: 'e', employeeName: 'Worker'))));
      await tester.pumpAndSettle();
      expect(find.textContaining('ادخل فرع محدد'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing); expect(loads, 0);
    });
  }

  for (final inventory in [false, true]) {
    testWidgets('Falcon entry disappears and reappears live inventory=$inventory', (tester) async {
      await tester.runAsync(() => AppLocalizations.preload('ar'));
      var allowed = false;
      final container = ProviderContainer(overrides: [
        employeeCanProvider('falcon').overrideWith((ref) => allowed),
        productStatsProvider.overrideWith((ref, key) async => {}),
        inventoryProductsProvider.overrideWith((ref, key) async => []),
        inventoryCategoriesProvider.overrideWith((ref) async => []),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(container: container,
        child: MaterialApp(locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: inventory ? const InventoryHomePage() : const ProductMovementsPage(id: 'p'))));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations(const Locale('ar')); await l10n.load();
      expect(find.byTooltip(l10n.translate('invFalcon')), findsNothing);
      allowed = true; container.invalidate(employeeCanProvider('falcon'));
      await tester.pumpAndSettle();
      expect(find.byTooltip(l10n.translate('invFalcon')), findsOneWidget);
    });
  }

  testWidgets('editing saves modifications message instead of new employee message', (tester) async {
    final router = GoRouter(initialLocation: '/', routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold()),
      GoRoute(path: '/edit', builder: (_, _) => const EmployeeFormPage(id: 'e')),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(overrides: [
      employeeApiProvider.overrideWithValue(_Employees()),
      branchApiProvider.overrideWithValue(TestBranches()),
      branchAccessProvider.overrideWith((ref) async => []),
    ], child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
    router.push('/edit'); await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'حفظ الموظف');
    await tester.scrollUntilVisible(save, 300,
      scrollable: find.descendant(of: find.byType(ListView).first,
        matching: find.byType(Scrollable)).first);
    await tester.tap(save); await tester.pumpAndSettle();
    expect(find.text('تم حفظ التعديلات'), findsOneWidget);
    expect(find.text('تم حفظ الموظف'), findsNothing);
  });
}
