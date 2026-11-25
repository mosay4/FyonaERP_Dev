import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/di/providers.dart'
    show apiClientProvider, secureStorageProvider;
import 'package:fyona_flutter/core/localization/app_localizations.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/core/storage/secure_storage.dart'
    show SecureStorageService;
import 'package:fyona_flutter/core/utils/currency_formatter.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/employees/data/employee_api.dart';
import 'package:fyona_flutter/features/employees/data/employee_local_finance.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/employees/presentation/pages/employee_payment_page.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

class _NoVault extends Fake implements SecureStorageService {
  @override
  Future<String?> getToken() async => null;
}

void main() {
  final workspace = DirectoryWorkspace(
    server: DirectoryPilotBuild.baseUrl,
    accountId: _id(),
    organizationId: _id(),
  );
  final scope = DirectoryAccess(
    workspace: workspace,
    branchId: _id(),
    readable: {},
    writable: {},
    financialCutover: true,
  );
  final employee = _id();
  late Directory root;
  late FixtureDirectoryKeys keys;
  late DirectoryPilotStore store;
  late DirectoryDatabase db;
  late String account;
  late int requests;
  final attempted = <String>[];

  Dio blockingDio() {
    final dio = Dio(BaseOptions(baseUrl: workspace.server));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          requests++;
          attempted.add('${request.method} ${request.path}');
          handler.reject(
            DioException.connectionError(
              requestOptions: request,
              reason: 'هذه العملية لازم تتم محليًا بدون سيرفر',
            ),
          );
        },
      ),
    );
    addTearDown(() => dio.close(force: true));
    return dio;
  }

  EmployeeLocalFinance finance() => EmployeeLocalFinance(
    scope: () => scope,
    store: () => store,
    allowed: () => true,
    cashSession: () async => null,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    requests = 0;
    await BranchScope.save(
      token: 'fixture',
      branchId: scope.branchId,
      branchName: 'الفرع',
      allMode: false,
      organizationId: workspace.organizationId,
    );
    root = await Directory.systemTemp.createTemp('fyona-employee-payroll-');
    keys = FixtureDirectoryKeys();
    store = DirectoryPilotStore(root: () async => root, keys: keys);
    await store.remember(scope, {
      'status': 'active',
      'business_setup_completed': true,
      'sections': {
        'business': {
          'active': true,
          'end_date': DateTime.now()
              .add(const Duration(days: 1))
              .toIso8601String(),
        },
      },
    });
    db = await DirectoryDatabase.open(
      root: root,
      workspace: workspace,
      keys: keys,
    );
    account = _id();
    await db.ledger.createAccount(
      BusinessLedgerAccess(scope, BusinessLedgerAction.values.toSet()),
      commandId: account,
      bankName: 'مصرف الراجحي',
      accountName: 'الحساب الجاري',
      accountNumber: '100',
      currency: 'SAR',
      openingMinor: 500000,
    );
  });

  tearDown(() async {
    await db.close();
    await store.close();
    await root.delete(recursive: true);
    await BranchScope.clear();
  });

  test(
    'payroll and debts go to the device ledger and keep their receipts',
    () async {
      final api = EmployeeApi(
        ApiClient(dio: blockingDio()),
        localFinance: finance,
      );
      final opening = await api.salary(employee);
      expect(opening['base_currency'], 'SAR');
      expect(opening['payments'], isEmpty);

      final salary = await api.paySalary(employee, {
        'amount': 1500,
        'currency': 'SAR',
        'bank_account_id': account,
        'notes': 'راتب شهر 11',
        'branch_id': scope.branchId,
      });
      expect(salary['amount'], 1500.0);
      expect(salary['currency'], 'SAR');
      expect(salary['bank_name'], 'مصرف الراجحي');
      expect('${salary['invoice_no']}', '${salary['id']}');

      final charge = await api.addDebt(employee, {
        'kind': 'charge',
        'direction': 'employee_owes',
        'amount': 300,
        'currency': 'SAR',
        'notes': 'عهدة',
      });
      final owed = await api.addDebt(employee, {
        'kind': 'charge',
        'direction': 'employer_owes',
        'amount': 50,
        'currency': 'SAR',
      });
      final settled = await api.addDebt(employee, {
        'kind': 'settlement',
        'debt_id': charge['id'],
        'amount': 100,
        'currency': 'SAR',
        'payment_currency': 'SAR',
        'bank_account_id': account,
      });
      expect(settled['kind'], 'settlement');
      expect(settled['amount'], 100.0);

      final debts = await api.debts(employee);
      expect((debts['debts'] as List).map((row) => row['kind']).toSet(), {
        'charge',
        'settlement',
      });
      // What the employee owes is positive; what the shop owes is not.
      expect(debts['balances'], {'SAR': 150.0});
      final chargeRow = (debts['debts'] as List).whereType<Map>().firstWhere(
        (row) => row['id'] == charge['id'],
      );
      expect(chargeRow['outstanding_amount'], 200.0);
      expect(chargeRow['direction'], 'employee_owes');

      final view = await api.myFinance(employeeId: employee);
      expect((view['salary'] as List), hasLength(1));
      expect((view['debts'] as List), hasLength(3));

      // Salary went out and the employee's payment came in, without conversion.
      final access = BusinessLedgerAccess(
        scope,
        BusinessLedgerAction.values.toSet(),
      );
      expect(
        {
          for (final row in await db.ledger.accounts(access))
            row['id']: row['balance_minor'],
        },
        {account: 500000 - 150000 + 10000},
      );
      expect(requests, 0);
      final payout = await api.addDebt(employee, {
        'kind': 'settlement',
        'direction': 'employer_owes',
        'debt_id': owed['id'],
        'amount': 20,
        'currency': 'SAR',
        'bank_account_id': account,
        'notes': 'دفعة على الدين',
      });
      expect(payout['bank_name'], 'مصرف الراجحي');
      expect(
        (await db.ledger.accounts(access)).single['balance_minor'],
        500000 - 150000 + 10000 - 2000,
      );
      final delivered = await db.ledger.employeeDeliveryReceipts(
        access,
        employee,
      );
      expect(
        delivered.where((r) => r['id'] == payout['id']).single,
        containsPair('remaining_minor', 3000),
      );
      expect(
        delivered.where((r) => r['id'] == payout['id']).single,
        containsPair('notes', 'دفعة على الدين'),
      );

      // The device ledger never converts between currencies.
      await expectLater(
        api.addDebt(employee, {
          'kind': 'settlement',
          'debt_id': owed['id'],
          'amount': 10,
          'currency': 'SAR',
          'payment_currency': 'USD',
        }),
        throwsA(
          isA<BusinessLedgerError>().having(
            (e) => e.problem,
            'problem',
            BusinessLedgerProblem.currencyMismatch,
          ),
        ),
      );
      // One command id, one write: a retry returns the very same receipt.
      final replay = await api.paySalary(employee, {
        'idempotency_key': salary['id'],
        'amount': 1500,
        'currency': 'SAR',
        'bank_account_id': account,
        'notes': 'راتب شهر 11',
      });
      expect(replay['id'], salary['id']);
      expect((await api.salary(employee))['payments'], hasLength(1));
      expect(requests, 0);

      // Opaque form keys map to one stable local command for retries.
      final opaque = await api.paySalary(employee, {
        'idempotency_key': '1700000000000000-42',
        'amount': 250,
        'currency': 'SAR',
        'bank_account_id': account,
      });
      expect(
        await api.paySalary(employee, {
          'idempotency_key': '1700000000000000-42',
          'amount': 250,
          'currency': 'SAR',
          'bank_account_id': account,
        }),
        opaque,
      );
      expect((await api.salary(employee))['payments'], hasLength(2));
      expect(requests, 0);
    },
  );

  testWidgets('the payroll screen pays from the device ledger offline', (
    tester,
  ) async {
    final dio = blockingDio();
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(dio: dio)),
        secureStorageProvider.overrideWithValue(_NoVault()),
        businessLocalLedgerScopeProvider.overrideWithValue(scope),
        directoryPilotStoreProvider.overrideWithValue(store),
        employeeCanProvider.overrideWith((_, _) => true),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await AppLocalizations.preload('ar');
    });
    Map<Object?, Object?>? payment;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: FilledButton(
                  key: const ValueKey('open-payroll'),
                  onPressed: () async {
                    payment = await Navigator.of(ctx)
                        .push<Map<Object?, Object?>>(
                          MaterialPageRoute(
                            builder: (_) => EmployeePaymentPage(
                              mode: 'salary',
                              employeeId: employee,
                              employeeName: 'سالم',
                              organizationName: 'محل سالم',
                              branchId: scope.branchId,
                              branchName: 'الفرع',
                            ),
                          ),
                        );
                  },
                  child: const Text('افتح'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
    }

    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-payroll')));
    await settle();
    expect(requests, 0, reason: '$attempted');
    await tester.tap(find.text('البنوك'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('اختر البنك'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('مصرف الراجحي'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('اختر العملة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(currencyLabel('SAR', locale: 'ar')).first);
    await tester.pumpAndSettle();
    await settle(); // Real async reads finish outside the pump loop.
    await tester.enterText(find.widgetWithText(TextField, 'المبلغ'), '1500');
    await tester.pump();
    // The form is a lazy list: bring the submit button into view first.
    final submit = find.widgetWithText(FilledButton, 'صرف راتب');
    await tester.scrollUntilVisible(
      submit,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await settle();
    // The screen returned a local receipt and closed: no server was involved.
    expect(payment, isNotNull);
    expect(payment?['amount'], 1500.0);
    expect(payment?['bank_name'], 'مصرف الراجحي');
    expect(requests, 0);
    final access = BusinessLedgerAccess(
      scope,
      BusinessLedgerAction.values.toSet(),
    );
    final saved = await tester.runAsync(
      () => db.ledger.employeeFinance(access, employeeId: employee),
    );
    expect((saved!['salaries'] as List), hasLength(1));
    expect((saved['salaries'] as List).single['amount_minor'], 150000);
    expect(jsonEncode(saved['totals']), contains('150000'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }, skip: !DirectoryPilotBuild.signupEnabled);
}
