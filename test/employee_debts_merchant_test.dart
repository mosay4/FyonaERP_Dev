import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/employees/data/employee_api.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_debts_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_payment_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/core/services/currency/business_currency_scope.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';

class FakeApi extends EmployeeApi {
  FakeApi() : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> debts(String id) async => {
    'organization_name': 'Test Store',
    'debts': [
      {
        'id': 'd1',
        'direction': 'employer_owes',
        'kind': 'charge',
        'amount': 50,
        'currency': 'SAR',
        'notes': 'advance',
        'created_at': '2020-01-20T10:00:00',
        'invoice_no': 'DBT-1',
      },
    ],
    'balances': {'SAR': -50},
  };
}

void main() {
  testWidgets('merchant debt page builds with data', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    BranchScope.organizationId = 'store';
    BranchScope.branchId = 'b1';
    addTearDown(() { BranchScope.organizationId = null; BranchScope.branchId = null; });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeeApiProvider.overrideWithValue(FakeApi()),
          branchAccessProvider.overrideWith(
            (ref) async => [
              {
                'organization_id': 'store',
                'role': 'owner',
                'branches': [
                  {'id': 'b1', 'name': 'Main'},
                ],
              },
            ],
          ),
          bizEnabledCurrenciesProvider.overrideWith((ref) async => {'SAR'}),
          currencyEngineProvider.overrideWithValue(CurrencyEngine()),
          employeePaymentAccountsProvider('b1').overrideWith(
            (ref) async => [
              PersonalBankAccount(
                id: 'c1',
                bankName: 'كاش',
                balance: 500,
                currency: 'SAR',
                accountType: 'cash',
              ),
            ],
          ),
        ],
        child: const MaterialApp(
          home: EmployeeDebtsPage(employeeId: 'e1', employeeName: 'Ali'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('ديون Ali'), findsOneWidget);
    expect(find.text('دين للموظف'), findsOneWidget);
    expect(find.text('إنشاء دين'), findsOneWidget);
    expect(find.text('(تعطي الموظف مبلغ)'), findsOneWidget);
    expect(find.text('(تاخذ من الموظف مبلغ)'), findsOneWidget);
    expect(find.text('هذا الشهر'), findsOneWidget);
    final segment = tester.widget<Text>(find.text('تسديد/تحصيل دين'));
    expect(segment.maxLines, isNull);
    expect(segment.softWrap, isTrue);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('تسديد/تحصيل دين'));
    await tester.pumpAndSettle();
    expect(find.text('تحصيل دين على الموظف'), findsOneWidget);
    expect(find.text('(تستلم من الموظف المبلغ)'), findsOneWidget);
    expect(find.text('(تدفع للموظف المبلغ)'), findsOneWidget);
    for (final label in [
      'هذا الشهر',
      'هذه السنة',
      'بين تاريخين',
      'كل الديون',
    ]) {
      expect(find.text(label), findsNothing);
    }
    expect(find.textContaining('اختر فاتورة الدين'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('تسديد دين للموظف'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('DBT-1'));
    await tester.pumpAndSettle();
    final payment = tester.widget<EmployeePaymentPage>(
      find.byType(EmployeePaymentPage),
    );
    expect(payment.kind, 'settlement');
    expect(payment.debt?['id'], 'd1');
    expect(find.text('فاتورة الدين: DBT-1'), findsOneWidget);
    expect(find.text('الكاش'), findsOneWidget);
    expect(find.text('البنوك'), findsOneWidget);
    expect(find.text('عملة الدين الأصلية'), findsNothing);
  });
}
