import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:fyona_flutter/core/router/shell_keys.dart';
import 'package:fyona_flutter/core/theme/app_colors.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_payment_page.dart';
import 'package:fyona_flutter/features/dashboard/presentation/providers/business_dashboard_providers.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/features/branches/data/branch_api.dart';
import 'package:fyona_flutter/features/employees/data/employee_api.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/job_requests_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employment_invitation_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employer_workspace_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_debts_page.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_salary_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/shared/services/notification_router.dart';
import 'package:fyona_flutter/shared/widgets/receipt/receipt_modal.dart';
import 'package:fyona_flutter/features/employees/presentation/widgets/salary_receipt.dart';

class TestLocalizations extends LocalizationsDelegate<AppLocalizations> {
  const TestLocalizations();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture(translations);
  @override
  bool shouldReload(TestLocalizations old) => false;
}

late AppLocalizations translations;

class EmploymentApi extends EmployeeApi {
  EmploymentApi() : super(ApiClient(dio: Dio()));
  bool accepted = false;
  bool revoked = false;
  int salaryLoads = 0;
  final fetched = <String>[];
  Map<String, dynamic> get invitationData => {
    'id': 'exact',
    'status': accepted ? 'accepted' : 'pending',
    'merchant': {'name': 'Merchant Identity', 'phone': '0551234567'},
    'organization': {'id': 'store', 'name': 'Original Store'},
    'employee': {'id': 'employee-a', 'full_name': 'Self HR Name'},
    'salary': 1500,
    'salary_currency': 'SAR',
  };
  @override
  Future<List<Map<String, dynamic>>> myInvitations() async => [invitationData];
  @override
  Future<Map<String, dynamic>> invitation(String id) async {
    fetched.add(id);
    if (revoked) throw StateError('404 revoked');
    return invitationData;
  }

  @override
  Future<Map<String, dynamic>> respond(String id, bool accept) async {
    accepted = accept;
    return invitationData;
  }

  @override
  Future<Map<String, dynamic>> salary(String id) async {
    salaryLoads++;
    return {'payments': []};
  }
}

Widget app(EmploymentApi api, Widget home) => ProviderScope(
  overrides: [
    employeeApiProvider.overrideWithValue(api),
    branchAccessProvider.overrideWith((ref) async => []),
    businessAccountsProvider.overrideWith((ref) async => []),
    employeeFinanceForProvider('employee-a').overrideWith(
      (ref) async => {
        'salary': [],
        'balances': {},
        'debts': [
          {
            'id': 'debt-a',
            'invoice_no': 'DBT-original',
            'amount': 25,
            'currency': 'SAR',
            'created_at': DateTime.now().toIso8601String(),
            'direction': 'employer_owes',
            'organization_name': 'Snapshot Store',
            'employee_name': 'Snapshot Employee',
            'bank_name': 'Original Bank',
            'notes': 'Original Notes',
          },
          {
            'id': 'debt-b',
            'amount': 50,
            'currency': 'SAR',
            'created_at': DateTime.now().toIso8601String(),
            'direction': 'employee_owes',
          },
        ],
      },
    ),
    myEmployeeFinanceProvider.overrideWith(
      (ref) => throw StateError('Global finance must not be read'),
    ),
  ],
  child: MaterialApp(
    localizationsDelegates: const [TestLocalizations()],
    home: home,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    translations = AppLocalizations(const Locale('en'));
    await translations.load();
  });
  testWidgets('pending card opens merchant details, not employee HR', (
    tester,
  ) async {
    final api = EmploymentApi();
    await tester.pumpWidget(app(api, const JobRequestsPage()));
    await tester.pumpAndSettle();
    expect(find.text('Self HR Name'), findsNothing);
    expect(find.text('بانتظار موافقتك'), findsOneWidget);
    await tester.tap(find.text('Original Store'));
    await tester.pumpAndSettle();
    expect(find.byType(EmploymentInvitationPage), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Merchant Identity'), findsOneWidget);
    expect(find.text('0551234567'), findsOneWidget);
    expect(find.textContaining('راتبك المحدد:'), findsOneWidget);
    expect(find.text('Self HR Name'), findsNothing);
    expect(find.byType(FilledButton), findsNWidgets(2));
  });

  testWidgets('accept opens store workspace and isolated read-only finance', (
    tester,
  ) async {
    final api = EmploymentApi();
    await tester.pumpWidget(app(api, const JobRequestsPage(inviteId: 'exact')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('أوافق'));
    await tester.tap(find.text('أوافق'));
    await tester.pumpAndSettle();
    expect(find.byType(EmployerWorkspacePage), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNWidgets(2));
    expect(find.text('راتبي'), findsOneWidget);
    expect(find.text('ديوني'), findsOneWidget);
    await tester.tap(find.text('راتبي'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<EmployeeSalaryPage>(find.byType(EmployeeSalaryPage))
          .readOnly,
      isTrue,
    );
    expect(find.text('صرف راتب'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('ديوني'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<EmployeeDebtsPage>(find.byType(EmployeeDebtsPage))
          .employeeId,
      'employee-a',
    );
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('دين على الموظف'), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.textContaining('دين لك'),
      ),
    );
    await tester.pumpAndSettle();
    final receipt = tester.widget<ReceiptModal>(find.byType(ReceiptModal)).data;
    expect(receipt.senderName, 'Snapshot Store');
    expect(receipt.receiverName, 'Snapshot Employee');
    expect(receipt.referenceNumber, 'DBT-original');
    expect(receipt.title, 'فاتورة دين');
  });

  testWidgets('read-only debt side chips filter records without add actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        EmploymentApi(),
        const EmployeeDebtsPage(
          employeeId: 'employee-a',
          employeeName: 'Current Employee',
          readOnly: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final records = find.byType(ListTile);
    final forEmployee = find.descendant(
      of: records,
      matching: find.textContaining('دين لك'),
    );
    final onEmployee = find.descendant(
      of: records,
      matching: find.textContaining('دين عليك'),
    );
    expect(records, findsNWidgets(2));

    await tester.tap(find.widgetWithText(ChoiceChip, 'دين لك'));
    await tester.pumpAndSettle();
    expect(forEmployee, findsOneWidget);
    expect(onEmployee, findsNothing);
    expect(records, findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.call_received_rounded)).color,
      AppColors.success,
    );

    await tester.tap(find.widgetWithText(ChoiceChip, 'دين عليك'));
    await tester.pumpAndSettle();
    expect(forEmployee, findsNothing);
    expect(onEmployee, findsOneWidget);
    expect(records, findsOneWidget);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.call_made_rounded)).color,
      AppColors.danger,
    );

    await tester.tap(find.widgetWithText(ChoiceChip, 'الكل'));
    await tester.pumpAndSettle();
    expect(records, findsNWidgets(2));
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byIcon(Icons.add), findsNothing);
    expect(find.text('دين للموظف'), findsNothing);
    expect(find.text('دين على الموظف'), findsNothing);
  });

  testWidgets('cold start invite auto-opens exact detail only once', (
    tester,
  ) async {
    final api = EmploymentApi();
    const route = '/job-requests?invite=exact';
    expect(NotificationRouter.resolveRoute(route), route);
    NotificationRouter.queuePending(route);
    expect(NotificationRouter.pendingCountForTests, contains(route));
    final router = GoRouter(
      navigatorKey: rootNavigatorKey,
      initialLocation: '/ready',
      routes: [
        GoRoute(path: '/ready', builder: (_, _) => const Scaffold()),
        GoRoute(
          path: '/job-requests',
          builder: (_, state) =>
              JobRequestsPage(inviteId: state.uri.queryParameters['invite']),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [employeeApiProvider.overrideWithValue(api)],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: const [TestLocalizations()],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(NotificationRouter.flushPending(), 1);
    await tester.pumpAndSettle();
    expect(api.fetched, ['exact']);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(EmploymentInvitationPage), findsNothing);
    expect(api.fetched, ['exact']);
  });

  testWidgets('salary payment Map result reloads and opens issued receipt', (
    tester,
  ) async {
    final api = EmploymentApi();
    await tester.pumpWidget(
      app(
        api,
        const EmployeeSalaryPage(
          employeeId: 'employee-a',
          employeeName: 'Current Employee',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('صرف راتب'));
    await tester.pumpAndSettle();
    Navigator.of(
      tester.element(find.byType(EmployeePaymentPage)),
    ).pop(<String, dynamic>{
      'amount': 100,
      'currency': 'SAR',
      'invoice_no': 'SAL-returned',
      'organization_name': 'Issued Store',
      'employee_name': 'Issued Employee',
    });
    await tester.pumpAndSettle();
    expect(
      api.salaryLoads,
      2,
      reason: 'Without a concrete branch, payment preview is blocked before loading a summary',
    );
    final receipt = tester.widget<ReceiptModal>(find.byType(ReceiptModal)).data;
    expect(receipt.referenceNumber, 'SAL-returned');
    expect(receipt.senderName, 'Issued Store');
  });

  testWidgets('revoked exact invitation shows empty state, no stale actions', (
    tester,
  ) async {
    final api = EmploymentApi()..revoked = true;
    await tester.pumpWidget(app(api, const JobRequestsPage(inviteId: 'exact')));
    await tester.pumpAndSettle();
    expect(find.text('طلب التوظيف غير متاح أو تم إلغاء الربط'), findsOneWidget);
    expect(find.text('أوافق'), findsNothing);
    expect(find.byType(EmployerWorkspacePage), findsNothing);
  });

  testWidgets('salary receipt uses original snapshot and branch', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [TestLocalizations()],
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSalaryReceipt(
                context,
                {
                  'employee_name': 'Issued Employee',
                  'organization_name': 'Issued Store',
                  'branch_name': 'Issued Branch',
                  'invoice_no': 'SAL-original',
                  'amount': 100,
                  'currency': 'SAR',
                  'base_salary': 500,
                  'remaining_salary': 400,
                },
                employeeName: 'Renamed Employee',
                organizationName: 'Renamed Store',
                branchName: 'Current Branch',
              ),
              child: const Text('receipt'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('receipt'));
    await tester.pumpAndSettle();
    final receipt = tester.widget<ReceiptModal>(find.byType(ReceiptModal)).data;
    expect(receipt.senderName, 'Issued Store');
    expect(receipt.receiverName, 'Issued Employee');
    expect(receipt.details.map((d) => d.value), contains('Issued Branch'));
    expect(receipt.referenceNumber, 'SAL-original');
  });
}
