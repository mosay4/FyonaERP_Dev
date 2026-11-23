import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/services/currency/business_currency_scope.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/employees/data/employee_api.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_form_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_detail_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employees_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_link_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/employees/presentation/widgets/employee_link_settings.dart';

class TestBranches extends BranchApi {
  TestBranches([this.count = 2]) : super(ApiClient(dio: Dio()));
  final int count;
  @override
  Future<List<Map<String, dynamic>>> list({bool archived = false}) async => [
    for (var i = 1; i <= count; i++) {'id': 'b$i', 'name': 'فرع $i'},
  ];
}

class TestEmployees extends EmployeeApi {
  TestEmployees() : super(ApiClient(dio: Dio()));
  String? searched;
  Map<String, dynamic> flags = {};
  @override
  Future<Map<String, dynamic>> lookup(String code) async {
    searched = code;
    return {
      ...flags,
      'name': 'اسم الحساب',
      'public_code': '123456',
      'phone': '777123456',
    };
  }
}

Widget host(Widget child, TestEmployees api, {int branchCount = 2}) =>
    ProviderScope(
      overrides: [
        employeeApiProvider.overrideWithValue(api),
        branchApiProvider.overrideWithValue(TestBranches(branchCount)),
        bizEnabledCurrenciesProvider.overrideWith(
          (ref) async => {'EUR', 'AED'},
        ),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: child,
      ),
    );

void main() {
  for (final flag in ['already_employee', 'pending_invitation', 'existing_employee']) {
    testWidgets('duplicate warning blocks confirmation and access: $flag', (tester) async {
      final api = TestEmployees()..flags = {flag: true, 'existing_employee_id': 'other'};
      EmployeeLinkDraft? draft;
      await tester.pumpWidget(host(Scaffold(body: EmployeeLinkSettings(onChanged: (v) => draft = v)), api));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '123456');
      await tester.tap(find.text('بحث عن الموظف'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('employee-duplicate-warning')), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('صلاحيات كاملة'), findsNothing);
      expect(draft!.blocked, isTrue);
      expect(draft!.ready, isFalse);
      expect(draft!.code, isNull);
    });
  }
  for (final detail in [false, true]) {
    testWidgets('link button opens only link page detail=$detail', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            employeesProvider.overrideWith(
              (ref) async => [
                {
                  'id': 'e1',
                  'full_name': 'Worker',
                  'status': 'unlinked',
                  'salary': 100,
                },
              ],
            ),
            employeeApiProvider.overrideWithValue(TestEmployees()),
            branchApiProvider.overrideWithValue(TestBranches()),
          ],
          child: MaterialApp(
            home: detail
                ? const EmployeeDetailPage(id: 'e1')
                : const EmployeesPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final link = find.text('ربط الموظف');
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(find.byType(EmployeeLinkPage), findsOneWidget);
      expect(find.byType(EmployeeFormPage), findsNothing);
      expect(find.byType(EmployeeLinkSettings), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'center confirmation shows only searched identifier, denial clears it',
    (tester) async {
      final api = TestEmployees();
      EmployeeLinkDraft? draft;
      await tester.pumpWidget(
        host(
          Scaffold(
            body: SingleChildScrollView(
              child: EmployeeLinkSettings(onChanged: (v) => draft = v),
            ),
          ),
          api,
        ),
      );
      await tester.pumpAndSettle();
      final input = find.byType(TextField);
      expect(
        tester.widget<TextField>(input).keyboardType,
        TextInputType.number,
      );
      await tester.enterText(input, '١٢٣٤٥٦');
      await tester.tap(find.text('بحث عن الموظف'));
      await tester.pumpAndSettle();
      expect(api.searched, '123456');
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('اسم الحساب'), findsOneWidget);
      expect(find.text('123456'), findsOneWidget);
      expect(find.text('777123456'), findsNothing);
      await tester.tap(find.text('لا، مو هو'));
      await tester.pumpAndSettle();
      expect(draft?.code, isNull);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      await tester.enterText(input, '777123456');
      await tester.tap(find.text('بحث عن الموظف'));
      await tester.pumpAndSettle();
      expect(find.text('777123456'), findsNWidgets(2)); // input and dialog
      expect(find.text('123456'), findsNothing);
      await tester.tap(find.text('نعم، هذا هو'));
      await tester.pumpAndSettle();
      expect(draft?.code, '777123456');
      expect(draft?.ready, isTrue);
      expect(draft?.branchIds, ['b1', 'b2']);
      await tester.tap(find.text('فرع 2'));
      await tester.pumpAndSettle();
      expect(draft?.branchIds, ['b1']);
      await tester.tap(find.text('فرع 1'));
      await tester.pumpAndSettle();
      expect(draft?.ready, isFalse);
      await tester.enterText(input, '222222');
      await tester.pumpAndSettle();
      expect(draft?.code, isNull);
      expect(find.text('صلاحيات كاملة'), findsNothing);
    },
  );

  testWidgets(
    'full permission switch off opens custom and on hides custom button',
    (tester) async {
      EmployeeLinkDraft? draft;
      await tester.pumpWidget(
        host(
          Scaffold(
            body: SingleChildScrollView(
              child: EmployeeLinkSettings(
                linked: true,
                onChanged: (v) => draft = v,
              ),
            ),
          ),
          TestEmployees(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('صلاحيات مخصصة'), findsNothing);
      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();
      expect(find.text('صلاحيات مخصصة'), findsOneWidget);
      expect(draft!.permissions.values.every((v) => v), isTrue);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('حفظ الصلاحيات'),
        500,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('حفظ الصلاحيات'));
      await tester.pumpAndSettle();
      expect(find.text('صلاحيات مخصصة'), findsOneWidget);
      expect(draft!.permissions['dashboard'], isFalse);
      expect(draft!.permissions.entries.where((e) => e.key != 'dashboard')
          .every((e) => e.value), isTrue);
      await tester.tap(find.widgetWithText(OutlinedButton, 'صلاحيات مخصصة'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
      await tester.scrollUntilVisible(find.text('حفظ الصلاحيات'), 500,
          scrollable: find.byType(Scrollable).last);
      await tester.tap(find.text('حفظ الصلاحيات'));
      await tester.pumpAndSettle();
      expect(draft!.permissions['dashboard'], isFalse);
      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();
      expect(find.text('صلاحيات مخصصة'), findsNothing);
      expect(draft!.permissions.values.every((v) => v), isTrue);
    },
  );

  testWidgets(
    'single branch controls stay hidden and business currencies replace personal defaults',
    (tester) async {
      await tester.pumpWidget(
        host(
          Scaffold(
            body: SingleChildScrollView(
              child: EmployeeLinkSettings(linked: true, onChanged: (_) {}),
            ),
          ),
          TestEmployees(),
          branchCount: 1,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('صلاحيات كاملة'), findsOneWidget);
      expect(find.text('الفروع اللي يديرها'), findsNothing);
      await tester.pumpWidget(
        host(const EmployeeFormPage(), TestEmployees(), branchCount: 1),
      );
      await tester.pumpAndSettle();
      expect(find.text('الفروع اللي يديرها'), findsNothing);
      await tester.tap(find.byIcon(Icons.currency_exchange_rounded));
      await tester.pumpAndSettle();
      expect(find.text('يورو'), findsOneWidget);
      expect(find.text('درهم إماراتي'), findsOneWidget);
      expect(find.text('ريال سعودي'), findsNothing);
      expect(find.text('دولار أمريكي'), findsNothing);
    },
  );
}
