import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/employees/data/employee_api.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_payment_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_salary_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/core/services/currency/business_currency_scope.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeApi extends EmployeeApi {
  FakeApi() : super(ApiClient(dio: Dio()));
  @override
  Future<Map<String, dynamic>> salary(String id) async => {
    'salary': [
      {
        'id': 'p1',
        'operation_no': 'SAL-1',
        'invoice_no': 'SAL-1',
        'amount': 100,
        'currency': 'SAR',
        'paid_at': '2026-10-01T10:00:00',
        'base_salary': 500,
        'remaining_salary': 400,
      },
    ],
    'organization_name': 'متجر',
  };
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BranchScope.organizationId = 'store';
    BranchScope.branchId = 'b1';
    BranchScope.branchName = 'Main';
    BranchScope.allMode = false;
  });
  tearDown(() { BranchScope.organizationId = null; BranchScope.branchId = null; BranchScope.branchName = null; });
  final scopeOverrides = [
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
    employeeSalarySummaryProvider('e1').overrideWith(
      (ref) async => {
        'base_currency': 'SAR',
        'base_salary': '1500',
        'remaining_salary': '1500',
      },
    ),
    employeeDebtSummaryProvider(
      'e1',
    ).overrideWith((ref) async => {'debts': []}),
    bizEnabledCurrenciesProvider.overrideWith((ref) async => {'USD', 'SAR'}),
    currencyEngineProvider.overrideWithValue(CurrencyEngine()),
  ];
  for (final language in ['ar', 'en']) {
    for (final source in ['bank', 'cash']) {
      testWidgets('$language $source picker formats current balance', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              ...scopeOverrides,
              employeePaymentAccountsProvider('b1').overrideWith(
                (ref) async => [
                  PersonalBankAccount(
                    id: 'bank-usd',
                    bankName: 'بنك تجريبي',
                    balance: 11,
                    currency: 'USD',
                    accountType: 'checking',
                  ),
                  PersonalBankAccount(
                    id: 'cash-usd',
                    bankName: 'كاش',
                    balance: 11,
                    currency: 'USD',
                    accountType: 'cash',
                  ),
                ],
              ),
            ],
            child: MaterialApp(
              locale: Locale(language),
              supportedLocales: const [Locale('ar'), Locale('en')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: const EmployeePaymentPage(
                mode: 'salary',
                employeeId: 'e1',
                employeeName: 'محمد',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(source == 'bank' ? 'البنوك' : 'الكاش'));
        await tester.pumpAndSettle();
        if (source == 'bank') {
          await tester.tap(find.text('اختر البنك'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('بنك تجريبي'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('اختر العملة'));
        } else {
          await tester.tap(find.text('اختر عملة الكاش'));
        }
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            language == 'ar' ? 'الرصيد الحالي' : 'Current balance',
            findRichText: true,
          ),
          findsOneWidget,
        );
        expect(find.textContaining('11', findRichText: true), findsOneWidget);
        expect(
          find.textContaining(
            language == 'ar' ? '(حساب جاري)' : '(Checking)',
            findRichText: true,
          ),
          source == 'bank' ? findsOneWidget : findsNothing,
        );
        expect(
          find.textContaining('USD checking 11', findRichText: true),
          findsNothing,
        );
        final balance = tester.widget<Text>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                widget.textSpan?.toPlainText().contains('11') == true,
          ),
        );
        final spans = (balance.textSpan! as TextSpan).children!;
        expect(
          spans
              .whereType<TextSpan>()
              .singleWhere((span) => span.text == '11')
              .style
              ?.fontWeight,
          FontWeight.w800,
        );
        expect(spans.whereType<WidgetSpan>(), hasLength(1));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('salary page shows entry button, not inline form', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...scopeOverrides,
          employeeApiProvider.overrideWithValue(FakeApi()),
          employeePaymentAccountsProvider('b1').overrideWith(
            (ref) async => [
              PersonalBankAccount(
                id: 'cash-sar',
                bankName: 'كاش',
                balance: 1000,
                currency: 'SAR',
                accountType: 'cash',
              ),
            ],
          ),
        ],
        child: const MaterialApp(
          home: EmployeeSalaryPage(employeeId: 'e1', employeeName: 'محمد'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('صرف راتب'), findsOneWidget);
    expect(find.text('اختر الحساب البنكي والعملة'), findsNothing);
    await tester.tap(find.text('صرف راتب'));
    await tester.pumpAndSettle();
    expect(find.text('الكاش'), findsOneWidget);
    expect(find.text('البنوك'), findsOneWidget);
  });

  testWidgets('payment page source design', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...scopeOverrides,
          employeePaymentAccountsProvider('b1').overrideWith(
            (ref) async => [
              PersonalBankAccount(
                id: 'cash-sar',
                bankName: 'كاش',
                balance: 1000,
                currency: 'SAR',
                accountType: 'cash',
              ),
              PersonalBankAccount(
                id: 'bank-usd',
                bankName: 'بنك تجريبي',
                balance: 20,
                currency: 'USD',
                accountType: 'checking',
              ),
            ],
          ),
        ],
        child: const MaterialApp(
          home: EmployeePaymentPage(
            mode: 'salary',
            employeeId: 'e1',
            employeeName: 'محمد',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('صرف راتب'), findsWidgets);
    expect(find.text('الكاش'), findsOneWidget);
    expect(find.text('البنوك'), findsOneWidget);
  });
}
