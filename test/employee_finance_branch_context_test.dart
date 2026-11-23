import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/services/currency/business_currency_scope.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/employees/data/employee_api.dart';
import 'package:fyona_flutter/features/employees/data/employee_branch_context.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_debts_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_detail_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_payment_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends EmployeeApi {
  _Api() : super(ApiClient(dio: Dio()));
  Map<String, dynamic>? sent;
  @override
  Future<Map<String, dynamic>> salary(String id) async => {
    'salary': [],
    'base_currency': 'SAR',
    'remaining_salary': 1000,
  };
  @override
  Future<Map<String, dynamic>> debts(String id) async => {
    'debts': [
      for (final direction in ['employee_owes', 'employer_owes'])
        {
          'id': direction,
          'invoice_no': direction,
          'kind': 'charge',
          'direction': direction,
          'amount': 100,
          'outstanding_amount': 100,
          'currency': 'SAR',
        },
    ],
  };
  @override
  Future<Map<String, dynamic>> addDebt(
    String id,
    Map<String, dynamic> body,
  ) async {
    sent = body;
    return {'id': 'paid'};
  }

  @override
  Future<Map<String, dynamic>> paySalary(
    String id,
    Map<String, dynamic> body,
  ) async {
    sent = body;
    return {'id': 'paid', 'amount': body['amount'], 'currency': 'SAR'};
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BranchScope.branchId = null;
    BranchScope.branchName = null;
    BranchScope.organizationId = null;
    BranchScope.token = null;
    BranchScope.allMode = false;
  });
  tearDown(() {
    BranchScope.branchId = null;
    BranchScope.branchName = null;
    BranchScope.organizationId = null;
    BranchScope.allMode = false;
  });

  test(
    'branch resolution is ordered and never borrows another company branch',
    () {
      const companies = [
        {
          'organization_id': 'store',
          'branches': [
            {'id': 'b1', 'name': 'Main'},
          ],
        },
        {
          'organization_id': 'other',
          'branches': [
            {'id': 'b2', 'name': 'Other'},
          ],
        },
      ];
      expect(
        EmployeeBranchContext.resolve({
          'organization_id': 'missing',
        }, companies).id,
        isNull,
      );
      expect(
        EmployeeBranchContext.resolve({
          'organization_id': 'store',
        }, companies).id,
        'b1',
      );
      expect(EmployeeBranchContext.resolve({}, companies).id, isNull);
      expect(
        EmployeeBranchContext.resolve({
          'branch_ids': ['b3'],
          'managed_branches': [
            {'id': 'b1', 'name': 'Main'},
          ],
        }, companies).id,
        'b3',
      );
      expect(
        EmployeeBranchContext.resolve({
          'managed_branches': [
            {'id': 'b1', 'name': 'Main'},
          ],
        }, companies).name,
        'Main',
      );
      BranchScope.branchId = 'selected';
      expect(
        EmployeeBranchContext.resolve({
          'branch_ids': ['b1'],
        }, companies).id,
        'selected',
      );
      BranchScope.allMode = true;
      expect(
        EmployeeBranchContext.resolve({
          'branch_ids': ['b1'],
        }, companies).id,
        'b1',
      );
      expect(EmployeeBranchContext.payment().id, isNull);
      expect(EmployeeBranchContext.payment(branchId: 'b1').name, isNull);
    },
  );

  for (final flow in [
    'salary',
    'create-on',
    'create-for',
    'collect',
    'settle',
  ]) {
    testWidgets(
      '$flow carries employee branch from detail through payment and submission',
      (tester) async {
        tester.view.physicalSize = const Size(600, 2200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        // Keep actions on the editable employee view. "All branches" is
        // intentionally read-only and is tested separately below.
        BranchScope.allMode = false;
        await tester.runAsync(() => AppLocalizations.preload('en'));
        final api = _Api();
        final requested = <String>[];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              employeeApiProvider.overrideWithValue(api),
              employeesProvider.overrideWith(
                (ref) async => [
                  {
                    'id': 'e1',
                    'full_name': 'Employee',
                    'status': 'linked',
                    'organization_id': 'store',
                    'branch_ids': ['b1'],
                    'salary': 1000,
                    'salary_currency': 'SAR',
                    'permissions': {},
                  },
                ],
              ),
              branchAccessProvider.overrideWith(
                (ref) async => [
                  {
                    'organization_id': 'store',
                    'branches': [
                      {'id': 'b1', 'name': 'Employee branch'},
                      {'id': 'b2', 'name': 'Other branch'},
                    ],
                  },
                ],
              ),
              employeePaymentAccountsProvider.overrideWith((ref, id) async {
                requested.add(id);
                return [
                  PersonalBankAccount(
                    id: 'cash',
                    bankName: 'كاش',
                    currency: 'SAR',
                    balance: 1000,
                    accountType: 'cash',
                  ),
                ];
              }),
              bizEnabledCurrenciesProvider.overrideWith((ref) async => {'SAR'}),
              currencyEngineProvider.overrideWithValue(CurrencyEngine()),
            ],
            child: MaterialApp(
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: const EmployeeDetailPage(id: 'e1'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(flow == 'salary' ? 'الراتب' : 'الديون'));
        await tester.pumpAndSettle();
        if (flow == 'salary') {
          await tester.tap(find.text('صرف راتب'));
        } else {
          if (flow == 'collect' || flow == 'settle') {
            await tester.tap(find.text('تسديد/تحصيل دين'));
            await tester.pumpAndSettle();
            if (flow == 'settle') {
              await tester.tap(find.text('تسديد دين للموظف'));
              await tester.pumpAndSettle();
            }
            await tester.tap(find.byType(Card).last);
          } else {
            if (flow == 'create-for') {
              await tester.tap(find.text('دين للموظف'));
              await tester.pumpAndSettle();
            }
            await tester.tap(find.text('إنشاء دين جديد'));
          }
        }
        await tester.pumpAndSettle();
        expect(find.byType(EmployeePaymentPage), findsOneWidget);
        expect(find.textContaining('ادخل فرع محدد'), findsNothing);
        expect(find.text('Employee branch'), findsOneWidget);
        expect(requested, ['b1']);
        final branchTile = tester.widget<ListTile>(
          find.byKey(const ValueKey('employee-payment-branch')),
        );
        expect(branchTile.onTap, isNull);
        // Changing the unrelated global scope must not redirect this payment.
        BranchScope.branchId = 'b2';
        BranchScope.branchName = 'Other branch';
        await tester.tap(find.text('الكاش'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('اختر عملة الكاش'));
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .descendant(
                of: find.byType(BottomSheet),
                matching: find.byType(ListTile),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, '10');
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        final submit = find.byType(FilledButton).last;
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        // Inspect the mutation without exercising the separate receipt dialog.
        await tester.pump();
        expect(api.sent?['branch_id'], 'b1');
        if (flow != 'salary') {
          expect(
            api.sent?['kind'],
            flow == 'collect' || flow == 'settle' ? 'settlement' : 'charge',
          );
          expect(
            api.sent?['direction'],
            flow == 'settle' || flow == 'create-for'
                ? 'employer_owes'
                : 'employee_owes',
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('all branches does not expose employee debt mutations', (
    tester,
  ) async {
    BranchScope.allMode = true;
    final api = _Api();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [employeeApiProvider.overrideWithValue(api)],
        child: const MaterialApp(
          home: EmployeeDebtsPage(employeeId: 'e1', employeeName: 'Employee'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('إنشاء دين جديد'), findsNothing);
    expect(find.text('تسديد/تحصيل دين'), findsNothing);
    expect(api.sent, isNull);
  });

  for (final mode in ['salary', 'debt']) {
    testWidgets('branchless $mode has a warning and no submit action', (
      tester,
    ) async {
      final api = _Api();
      final requested = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            employeeApiProvider.overrideWithValue(api),
            employeePaymentAccountsProvider.overrideWith((ref, id) async {
              requested.add(id);
              return [];
            }),
          ],
          child: MaterialApp(
            home: EmployeePaymentPage(
              mode: mode,
              employeeId: 'branchless',
              employeeName: 'Branchless',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('ادخل فرع محدد'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(requested, isEmpty);
      expect(api.sent, isNull);
    });
  }
}
