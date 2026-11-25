import 'package:dio/dio.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:fyona_flutter/core/router/shell_keys.dart';
import 'package:fyona_flutter/core/services/currency/business_currency_scope.dart';
import 'package:fyona_flutter/core/services/currency/currency_engine.dart';
import 'package:fyona_flutter/core/services/section_scope.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/employees/data/employee_api.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_payment_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_finance_receipt_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/notifications/presentation/widgets/unread_notification_bell.dart';
import 'package:fyona_flutter/features/notifications/presentation/providers/notifications_providers.dart';
import 'package:fyona_flutter/features/personal/data/models/personal_models.dart';
import 'package:fyona_flutter/shared/services/notification_router.dart';

class _Api extends EmployeeApi {
  _Api() : super(ApiClient(dio: Dio()));
  Map<String, dynamic>? sent;
  @override
  Future<Map<String, dynamic>> addDebt(
    String id,
    Map<String, dynamic> body,
  ) async {
    sent = body;
    return {'id': 'settled'};
  }

  @override
  Future<Map<String, dynamic>> paySalary(
    String id,
    Map<String, dynamic> body,
  ) async {
    sent = body;
    return {'id': 'paid'};
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BranchScope.organizationId = 'store';
    BranchScope.branchId = 'a';
    BranchScope.allMode = false;
    BranchScope.token = null;
  });
  tearDown(() { BranchScope.organizationId = null; BranchScope.branchId = null; BranchScope.branchName = null; });

  test(
    'permitted-all remains read-only with an explicit signed snapshot hint',
    () {
      BranchScope.allMode = true;
      expect(BranchScope.readOnly, isTrue);
      final body = base64Url.encode(
        utf8.encode(
          jsonEncode({
            'branch_ids': ['a', 'b'],
            'write_scope': 'branch',
            'mode': 'all',
          }),
        ),
      );
      BranchScope.token = 'header.$body.signature';
      expect(BranchScope.readOnly, isTrue);
      expect(BranchScope.permittedBranchIds, ['a', 'b']);
      BranchScope.allMode = false;
      BranchScope.token = null;
    },
  );

  test(
    'Arabic and English payment/rate inputs parse without direction or precision relabeling',
    () {
      expect(parseEmployeeNumber('١٬٢٥٠٫٥٠'), 1250.5);
      expect(parseEmployeeNumber('1,250.50'), 1250.5);
      expect(parseEmployeeNumber('۳٫۷۵'), 3.75);
      expect(parseEmployeeNumber('NaN'), isNull);
    },
  );

  testWidgets(
    'selected debt settlement keeps SAR source and submits USD payment with invoice id',
    (tester) async {
      tester.view.physicalSize = const Size(500, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _Api();
      const debt = <String, dynamic>{
        'id': 'debt-sar',
        'invoice_no': 'DBT-SAR',
        'amount': 500,
        'outstanding_amount': '500.00',
        'currency': 'SAR',
        'direction': 'employer_owes',
      };
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            employeeApiProvider.overrideWithValue(api),
            branchAccessProvider.overrideWith(
              (ref) async => [
                {
                  'organization_id': 'store',
                  'role': 'owner',
                  'branches': [
                    {'id': 'a', 'name': 'Main'},
                  ],
                },
              ],
            ),
            employeeDebtSummaryProvider('e').overrideWith(
              (ref) async => {
                'debts': [debt],
              },
            ),
            employeePaymentAccountsProvider('a').overrideWith(
              (ref) async => [
                PersonalBankAccount(
                  id: 'usd-bank',
                  bankName: 'USD Bank',
                  balance: 100,
                  currency: 'USD',
                ),
              ],
            ),
            bizEnabledCurrenciesProvider.overrideWith(
              (ref) async => {'USD', 'SAR'},
            ),
            currencyEngineProvider.overrideWithValue(CurrencyEngine()),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const EmployeePaymentPage(
                        mode: 'debt',
                        kind: 'settlement',
                        direction: 'employer_owes',
                        employeeId: 'e',
                        employeeName: 'Employee',
                        debt: debt,
                      ),
                    ),
                  ),
                  child: const Text('Start'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(find.text('فاتورة الدين: DBT-SAR'), findsOneWidget);
      await tester.tap(find.text('البنوك'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('اختر البنك'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('USD Bank'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('اختر العملة'));
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
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('عملة الدين الأصلية'), findsNothing);
      await tester.enterText(find.byType(TextField).first, '50');
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('employee-payment-fx')),
        140,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const ValueKey('employee-payment-fx')),
        '3.75',
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'312[.,]5')), findsOneWidget);
      final confirm = find.widgetWithText(FilledButton, 'سداد للموظف');
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(api.sent?['debt_id'], 'debt-sar');
      expect(api.sent?['currency'], 'SAR');
      expect(api.sent?['payment_currency'], 'USD');
      expect(api.sent?['amount'], 50);
      expect(api.sent?['exchange_rate'], '3.750000000000');
    },
  );

  testWidgets(
    'two-branch salary fixes active branch before bank, currency and Decimal FX submission',
    (tester) async {
      tester.view.physicalSize = const Size(500, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _Api();
      final requested = <String>[];
      BranchScope.branchId = 'b';
      BranchScope.branchName = 'Branch B';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            employeeApiProvider.overrideWithValue(api),
            branchAccessProvider.overrideWith(
              (ref) async => [
                {
                  'organization_id': 'store',
                  'role': 'owner',
                  'branches': [
                    {'id': 'a', 'name': 'Branch A'},
                    {'id': 'b', 'name': 'Branch B'},
                  ],
                },
              ],
            ),
            employeeSalarySummaryProvider('e').overrideWith(
              (ref) async => {
                'base_salary': '1500',
                'base_currency': 'SAR',
                'remaining_salary': '1500',
              },
            ),
            employeePaymentAccountsProvider.overrideWith((ref, branch) async {
              requested.add(branch);
              return [
                PersonalBankAccount(
                  id: 'bank-$branch',
                  bankName: 'Bank $branch',
                  balance: 1000,
                  currency: 'USD',
                ),
              ];
            }),
            bizEnabledCurrenciesProvider.overrideWith(
              (ref) async => {'USD', 'SAR'},
            ),
            currencyEngineProvider.overrideWithValue(CurrencyEngine()),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const EmployeePaymentPage(
                        mode: 'salary',
                        employeeId: 'e',
                        employeeName: 'Employee',
                      ),
                    ),
                  ),
                  child: const Text('Start'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(find.text('Branch B'), findsOneWidget);
      final branchInfo = tester.widget<ListTile>(find.byKey(const ValueKey('employee-payment-branch')));
      expect(branchInfo.onTap, isNull);
      expect(find.text('اختر الفرع'), findsNothing);
      expect(requested, ['b']);
      await tester.tap(find.text('البنوك'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('اختر البنك'));
      await tester.pumpAndSettle();
      expect(find.text('Bank a'), findsNothing);
      await tester.tap(find.text('Bank b'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('اختر العملة'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('دولار أمريكي').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '100');
      await tester.enterText(
        find.byKey(const ValueKey('employee-payment-fx')),
        '3.75',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining(fmtNum(1125)), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'صرف راتب'));
      await tester.pumpAndSettle();
      expect(api.sent?['branch_id'], 'b');
      expect(api.sent?['bank_account_id'], 'bank-b');
      expect(api.sent?['currency'], 'USD');
      expect(api.sent?['exchange_rate'], '3.750000000000');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'denied notification bell is absent and does not load unread count',
    (tester) async {
      var loads = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeSectionProvider.overrideWith((ref) => AppSection.business),
            employeeCanProvider('notifications').overrideWith((ref) => false),
            unreadCountProvider.overrideWith((ref) async {
              loads++;
              return 1;
            }),
          ],
          child: MaterialApp(home: Scaffold(body: UnreadNotificationBell())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.notifications_outlined), findsNothing);
      expect(loads, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('queued cold-start finance tap opens only its exact receipt', (
    tester,
  ) async {
    const route =
        '/employee-profile/receipt?employee_id=e&record_id=exact&kind=salary';
    final router = GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: '/ready',
      routes: [
        GoRoute(path: '/ready', builder: (_, _) => const Scaffold()),
        GoRoute(
          path: '/employee-profile/receipt',
          builder: (_, state) => EmployeeFinanceReceiptPage(
            employeeId: state.uri.queryParameters['employee_id']!,
            recordId: state.uri.queryParameters['record_id']!,
            kind: state.uri.queryParameters['kind']!,
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    NotificationRouter.queuePending(route);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          employeeFinanceForProvider('e').overrideWith(
            (ref) async => {
              'salary': [
                {'id': 'other', 'invoice_no': 'SAL-OTHER'},
                {
                  'id': 'exact',
                  'invoice_no': 'SAL-EXACT',
                  'amount': 100,
                  'currency': 'USD',
                  'base_currency': 'SAR',
                  'converted_amount': '375.00',
                  'remaining_salary': 1125,
                },
              ],
            },
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(NotificationRouter.flushPending(), 1);
    await tester.pumpAndSettle();
    expect(find.text('SAL-EXACT'), findsOneWidget);
    expect(find.text('SAL-OTHER'), findsNothing);
    expect(find.text('375.00 SAR'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
