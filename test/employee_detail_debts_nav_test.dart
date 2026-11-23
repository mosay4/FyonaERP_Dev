import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/employees/data/employee_api.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_detail_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';

class FakeApi extends EmployeeApi {
  FakeApi() : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> debts(String id) async =>
      {'organization_name': 'متجر', 'debts': [], 'balances': {}};
}

void main() {
  testWidgets('managed branch card refreshes assignments and empty state', (tester) async {
    var branches = <Map<String, dynamic>>[
      {'id': 'b1', 'name': 'Assigned First'},
      {'id': 'b2', 'name': 'Assigned Second'},
    ];
    final container = ProviderContainer(overrides: [
      employeesProvider.overrideWith((ref) async => [
        {'id': 'e1', 'full_name': 'Employee', 'status': 'linked',
          'salary': 500, 'salary_currency': 'SAR', 'permissions': {},
          'managed_branches': branches},
      ]),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container,
      child: const MaterialApp(home: EmployeeDetailPage(id: 'e1'))));
    await tester.pumpAndSettle();
    expect(find.text('Assigned branches'), findsOneWidget);
    expect(find.text('Assigned First'), findsOneWidget);
    expect(find.text('Assigned Second'), findsOneWidget);
    branches = [branches.last];
    container.invalidate(employeesProvider);
    await tester.pumpAndSettle();
    expect(find.text('Assigned First'), findsNothing);
    expect(find.text('Assigned Second'), findsOneWidget);
    branches = [];
    container.invalidate(employeesProvider);
    await tester.pumpAndSettle();
    expect(find.text('No branches are currently assigned.'), findsOneWidget);
    expect(find.text('Assigned Second'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('linked employee title scales fully on a narrow Arabic screen', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [employeesProvider.overrideWith((ref) async => [
        {'id': 'e1', 'full_name': 'موظف', 'status': 'linked',
          'salary': 500, 'salary_currency': 'SAR', 'permissions': {}},
      ])],
      child: const MaterialApp(home: Directionality(
        textDirection: TextDirection.rtl, child: EmployeeDetailPage(id: 'e1'))),
    ));
    await tester.pumpAndSettle();
    final title = find.text('ملف الموظف');
    expect(title, findsOneWidget);
    expect(find.ancestor(of: title, matching: find.byType(FittedBox)), findsOneWidget);
    expect(tester.widget<Text>(title).overflow, isNot(TextOverflow.ellipsis));
    expect(tester.takeException(), isNull);
  });

  testWidgets('employee detail opens debts without route decoding', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        employeeApiProvider.overrideWithValue(FakeApi()),
        branchAccessProvider.overrideWith((ref) async => []),
        employeesProvider.overrideWith((ref) async => [
          {'id': 'e1', 'full_name': 'محمد 100%', 'status': 'linked',
            'salary': 500, 'salary_currency': 'SAR', 'permissions': {},
            'online': true},
        ]),
      ],
      child: const MaterialApp(home: EmployeeDetailPage(id: 'e1')),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الديون'));
    await tester.pumpAndSettle();
    expect(find.text('ديون محمد 100%'), findsOneWidget);
    expect(find.textContaining('Argument'), findsNothing);
  });
}
