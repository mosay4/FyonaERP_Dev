import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';
import 'support/business_cash_test_checkpoint.dart';

String _id() => const Uuid().v4();

void main() {
  final workspace = DirectoryWorkspace(
    server: 'http://localhost:18083/api/v1',
    accountId: _id(),
    organizationId: _id(),
  );
  const otherBranch = '11111111-1111-4111-8111-111111111111';
  final scope = DirectoryAccess(
    workspace: workspace,
    branchId: _id(),
    readable: {},
    writable: {},
    financialCutover: true,
  );
  final all = BusinessLedgerAction.values.toSet();
  final access = BusinessLedgerAccess(scope, all);
  const finance = {
    BusinessLedgerAction.readEmployeeFinance,
    BusinessLedgerAction.payEmployeeSalary,
    BusinessLedgerAction.createEmployeeDebt,
    BusinessLedgerAction.settleEmployeeDebt,
  };
  late Directory root;
  late FixtureDirectoryKeys keys;
  late DirectoryDatabase db;
  BusinessLedger ledger() => db.ledger;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fyona-employee-');
    keys = FixtureDirectoryKeys();
    db = await DirectoryDatabase.open(
      root: root,
      workspace: workspace,
      keys: keys,
    );
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  BusinessLedgerAccess speaking(String employee, int version) =>
      BusinessLedgerAccess(
        scope,
        all,
        employee: BusinessEmployeeDelegation(employee, version),
      );

  test(
    'a local delegation is versioned, revocable and confined to one employee',
    () async {
      final e1 = _id(), e2 = _id();
      final grantCommand = _id();
      final granted = await ledger().grantEmployeeDelegation(
        access,
        commandId: grantCommand,
        employeeId: e1,
        actions: finance,
      );
      final version = granted['version'] as int;
      expect(version, 1);
      expect(granted['revoked_us'], isNull);
      final asE1 = speaking(e1, version);
      await ledger().payEmployeeSalary(
        asE1,
        commandId: _id(),
        employeeId: e1,
        amountMinor: 5000,
        currency: 'SAR',
      );
      // An employee speaks only for itself and cannot delegate further.
      await expectLater(
        ledger().payEmployeeSalary(
          asE1,
          commandId: _id(),
          employeeId: e2,
          amountMinor: 100,
          currency: 'SAR',
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await expectLater(
        ledger().grantEmployeeDelegation(
          asE1,
          commandId: _id(),
          employeeId: e2,
          actions: finance,
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await expectLater(
        ledger().grantEmployeeDelegation(
          access,
          commandId: _id(),
          employeeId: e2,
          actions: {BusinessLedgerAction.manageBackup},
        ),
        throwsA(
          isA<BusinessLedgerError>().having(
            (e) => e.problem,
            'problem',
            BusinessLedgerProblem.invalidEmployee,
          ),
        ),
      );
      // Replaying the same grant command is free of a second write.
      final replay = await ledger().grantEmployeeDelegation(
        access,
        commandId: grantCommand,
        employeeId: e1,
        actions: finance,
      );
      expect(replay, granted);
      await expectLater(
        ledger().payEmployeeSalary(
          speaking(e1, version + 5),
          commandId: _id(),
          employeeId: e1,
          amountMinor: 100,
          currency: 'SAR',
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );

      final revoked = await ledger().revokeEmployeeDelegation(
        access,
        commandId: _id(),
        employeeId: e1,
      );
      expect(revoked['version'], version + 1);
      expect(revoked['revoked_us'], isNotNull);
      await expectLater(
        ledger().payEmployeeSalary(
          asE1,
          commandId: _id(),
          employeeId: e1,
          amountMinor: 100,
          currency: 'SAR',
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await expectLater(
        ledger().revokeEmployeeDelegation(
          access,
          commandId: _id(),
          employeeId: e1,
        ),
        throwsA(
          isA<BusinessLedgerError>().having(
            (e) => e.problem,
            'problem',
            BusinessLedgerProblem.noChanges,
          ),
        ),
      );
      final regranted = await ledger().grantEmployeeDelegation(
        access,
        commandId: _id(),
        employeeId: e1,
        actions: finance,
      );
      expect(regranted['version'], version + 2);
      await expectLater(
        ledger().payEmployeeSalary(
          asE1,
          commandId: _id(),
          employeeId: e1,
          amountMinor: 100,
          currency: 'SAR',
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      final renewed = speaking(e1, regranted['version'] as int);
      await ledger().payEmployeeSalary(
        renewed,
        commandId: _id(),
        employeeId: e1,
        amountMinor: 100,
        currency: 'SAR',
      );

      // A short-lived grant stops working when it expires.
      final expiring = await ledger().grantEmployeeDelegation(
        access,
        commandId: _id(),
        employeeId: e2,
        actions: finance,
        expiresAt: DateTime.now().add(const Duration(milliseconds: 300)),
      );
      final asE2 = speaking(e2, expiring['version'] as int);
      await ledger().createEmployeeDebt(
        asE2,
        commandId: _id(),
        employeeId: e2,
        amountMinor: 700,
        currency: 'SAR',
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await expectLater(
        ledger().createEmployeeDebt(
          asE2,
          commandId: _id(),
          employeeId: e2,
          amountMinor: 700,
          currency: 'SAR',
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );

      final own = await ledger().employeeDelegations(renewed);
      expect(own.map((row) => row['employee_id']), [e1]);
      final every = await ledger().employeeDelegations(access);
      expect(every.map((row) => row['employee_id']), containsAll([e1, e2]));
      expect(every.where((row) => row['active'] == true), hasLength(1));
    },
  );

  test(
    'employee payroll, debts and receipts are atomic, idempotent and isolated',
    () async {
      final e1 = _id(), e2 = _id();
      final granted = await ledger().grantEmployeeDelegation(
        access,
        commandId: _id(),
        employeeId: e1,
        actions: finance,
      );
      final asE1 = speaking(e1, granted['version'] as int);
      final salaryCommand = _id();
      final salary = await ledger().payEmployeeSalary(
        access,
        commandId: salaryCommand,
        employeeId: e1,
        amountMinor: 5000,
        currency: 'SAR',
        period: '2026-10',
      );
      expect(salary['kind'], 'salary');
      final replay = await ledger().payEmployeeSalary(
        access,
        commandId: salaryCommand,
        employeeId: e1,
        amountMinor: 5000,
        currency: 'SAR',
        period: '2026-10',
      );
      expect(replay, salary);
      await expectLater(
        ledger().payEmployeeSalary(
          access,
          commandId: salaryCommand,
          employeeId: e1,
          amountMinor: 5001,
          currency: 'SAR',
          period: '2026-10',
        ),
        throwsA(
          isA<BusinessLedgerError>().having(
            (e) => e.problem,
            'problem',
            BusinessLedgerProblem.commandConflict,
          ),
        ),
      );
      await ledger().payEmployeeSalary(
        access,
        commandId: _id(),
        employeeId: e2,
        amountMinor: 200,
        currency: 'USD',
      );
      await ledger().payEmployeeSalary(
        asE1,
        commandId: _id(),
        employeeId: e1,
        amountMinor: 300,
        currency: 'USD',
      );

      final debtCommand = _id();
      final debt = await ledger().createEmployeeDebt(
        access,
        commandId: debtCommand,
        employeeId: e1,
        amountMinor: 3000,
        currency: 'SAR',
        note: 'دفعة عهدة',
      );
      expect(debt['remaining_minor'], 3000);
      final settled = await ledger().settleEmployeeDebt(
        access,
        commandId: _id(),
        debtId: debt['debt_id'] as String,
        amountMinor: 1200,
      );
      expect(
        {settled['before_minor'], settled['after_minor'], settled['currency']},
        {3000, 1800, 'SAR'},
      );
      final closed = await asE1Debt(
        ledger(),
        asE1,
        debt['debt_id'] as String,
        1800,
      );
      expect(closed['after_minor'], 0);
      await expectLater(
        ledger().settleEmployeeDebt(
          access,
          commandId: _id(),
          debtId: debt['debt_id'] as String,
          amountMinor: 1,
        ),
        throwsA(
          isA<BusinessLedgerError>().having(
            (e) => e.problem,
            'problem',
            BusinessLedgerProblem.insufficientBalance,
          ),
        ),
      );
      // The rejected attempt wrote no leg: the same command id may be reused.
      final second = await ledger().createEmployeeDebt(
        access,
        commandId: _id(),
        employeeId: e2,
        amountMinor: 900,
        currency: 'USD',
      );
      await expectLater(
        ledger().settleEmployeeDebt(
          asE1,
          commandId: _id(),
          debtId: second['debt_id'] as String,
          amountMinor: 100,
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );

      final own = await ledger().employeeFinance(asE1);
      expect((own['salaries'] as List), hasLength(2));
      expect((own['debts'] as List), hasLength(1));
      expect(own['employee_id'], e1);
      expect(own['totals'], {
        'SAR': {'salary_minor': 5000, 'debt_minor': 3000, 'settled_minor': 3000, 'open_minor': 0},
        'USD': {'salary_minor': 300, 'debt_minor': 0, 'settled_minor': 0, 'open_minor': 0},
      });
      final every = await ledger().employeeFinance(access);
      expect((every['salaries'] as List), hasLength(3));
      expect((every['debts'] as List), hasLength(2));
      expect((every['receipts'] as List), hasLength(7));
      expect(every['totals'], {
        'SAR': {'salary_minor': 5000, 'debt_minor': 3000, 'settled_minor': 3000, 'open_minor': 0},
        'USD': {'salary_minor': 500, 'debt_minor': 900, 'settled_minor': 0, 'open_minor': 900},
      });

      final receipt = await ledger().employeeReceipt(access, salaryCommand);
      expect((receipt['payload'] as Map)['period'], '2026-10');
      await ledger().employeeReceipt(asE1, salaryCommand);
      await expectLater(
        ledger().employeeReceipt(asE1, _id()),
        throwsA(
          isA<BusinessLedgerError>().having(
            (e) => e.problem,
            'problem',
            BusinessLedgerProblem.invalidEmployee,
          ),
        ),
      );
      final otherReceipt = await ledger().payEmployeeSalary(
        access,
        commandId: _id(),
        employeeId: e2,
        amountMinor: 10,
        currency: 'SAR',
      );
      await expectLater(
        ledger().employeeReceipt(asE1, otherReceipt['receipt_id'] as String),
        throwsA(isA<DirectoryAccessDenied>()),
      );
    },
  );

  test('a revoked or lost permission stops the write before any row', () async {
    final e1 = _id();
    final granted = await ledger().grantEmployeeDelegation(
      access,
      commandId: _id(),
      employeeId: e1,
      actions: finance,
    );
    final asE1 = speaking(e1, granted['version'] as int);
    var permitted = 0;
    final command = _id();
    await expectLater(
      ledger().payEmployeeSalary(
        asE1,
        commandId: command,
        employeeId: e1,
        amountMinor: 2500,
        currency: 'SAR',
        allowed: () => permitted++ == 0,
      ),
      throwsA(isA<DirectoryAccessDenied>()),
    );
    expect(permitted, 2);
    final empty = await ledger().employeeFinance(access);
    expect(empty['salaries'], isEmpty);
    expect(empty['receipts'], isEmpty);
    // Nothing was recorded: the same command id writes exactly once on retry.
    final written = await ledger().payEmployeeSalary(
      asE1,
      commandId: command,
      employeeId: e1,
      amountMinor: 2500,
      currency: 'SAR',
    );
    expect(written['amount_minor'], 2500);
    expect((await ledger().employeeFinance(access))['salaries'], hasLength(1));

    await ledger().revokeEmployeeDelegation(
      access,
      commandId: _id(),
      employeeId: e1,
    );
    await expectLater(
      ledger().createEmployeeDebt(
        asE1,
        commandId: _id(),
        employeeId: e1,
        amountMinor: 100,
        currency: 'SAR',
      ),
      throwsA(isA<DirectoryAccessDenied>()),
    );
    await expectLater(
      ledger().payEmployeeSalary(
        access,
        commandId: _id(),
        employeeId: e1,
        amountMinor: 0,
        currency: 'SAR',
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (e) => e.problem,
          'problem',
          BusinessLedgerProblem.invalidAmount,
        ),
      ),
    );
    await expectLater(
      ledger().payEmployeeSalary(
        access,
        commandId: _id(),
        employeeId: e1,
        amountMinor: 100,
        currency: 'SAR',
        period: 'x' * 201,
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (e) => e.problem,
          'problem',
          BusinessLedgerProblem.invalidEmployee,
        ),
      ),
    );
    await expectLater(
      ledger().createEmployeeDebt(
        access,
        commandId: _id(),
        employeeId: 'not-an-id',
        amountMinor: 100,
        currency: 'SAR',
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (e) => e.problem,
          'problem',
          BusinessLedgerProblem.invalidEmployee,
        ),
      ),
    );
    // The employee's rows are unreachable through another branch scope.
    final elsewhere = BusinessLedgerAccess(
      DirectoryAccess(
        workspace: workspace,
        branchId: otherBranch,
        readable: {},
        writable: {},
        financialCutover: true,
      ),
      all,
    );
    expect((await ledger().employeeFinance(elsewhere))['salaries'], isEmpty);
  });

  test('payroll and settlements fund accounts in their own currency only', () async {
    final e1 = _id();
    final sar = _id(), usd = _id(), shared = _id();
    for (final (id, currency, opening) in [
      (sar, 'SAR', 10000),
      (usd, 'USD', 500),
      (shared, 'SAR', 1000),
    ]) {
      await ledger().createAccount(
        access,
        commandId: id,
        bankName: 'Bank fixture',
        accountName: 'Account $currency',
        accountNumber: '1$opening',
        currency: currency,
        openingMinor: opening,
      );
    }
    await ledger().cashSync.provision(
      access,
      shared,
      grantVersion: 1,
      allowNegative: false,
    );
    Future<Map<Object?, Object?>> balances() async =>
        {for (final row in await ledger().accounts(access)) row['id']: row['balance_minor']};

    // A payout never converts: the account must hold the salary currency.
    await expectLater(
      ledger().payEmployeeSalary(
        access,
        commandId: _id(),
        employeeId: e1,
        amountMinor: 100,
        currency: 'SAR',
        accountId: usd,
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (e) => e.problem,
          'problem',
          BusinessLedgerProblem.currencyMismatch,
        ),
      ),
    );
    // One writer per shared resource: a shared till moves only through the
    // cash arbitration, never with a private payroll leg.
    await expectLater(
      ledger().payEmployeeSalary(
        access,
        commandId: _id(),
        employeeId: e1,
        amountMinor: 100,
        currency: 'SAR',
        accountId: shared,
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (e) => e.problem,
          'problem',
          BusinessLedgerProblem.sharedCashRequiresArbitration,
        ),
      ),
    );
    expect((await ledger().employeeFinance(access))['salaries'], isEmpty);
    expect(await balances(), {sar: 10000, usd: 500, shared: 1000});

    final salary = await ledger().payEmployeeSalary(
      access,
      commandId: _id(),
      employeeId: e1,
      amountMinor: 2500,
      currency: 'SAR',
      accountId: sar,
      period: '2026-11',
    );
    expect(salary['account_id'], sar);
    expect(await balances(), {sar: 7500, usd: 500, shared: 1000});
    expect(await ledger().statement(access, sar), hasLength(2));
    // An overdraft stays blocked and leaves no payroll row behind.
    await expectLater(
      ledger().payEmployeeSalary(
        access,
        commandId: _id(),
        employeeId: e1,
        amountMinor: 8000,
        currency: 'SAR',
        accountId: sar,
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (e) => e.problem,
          'problem',
          BusinessLedgerProblem.insufficientBalance,
        ),
      ),
    );
    expect((await ledger().employeeFinance(access))['salaries'], hasLength(1));

    final debt = await ledger().createEmployeeDebt(
      access,
      commandId: _id(),
      employeeId: e1,
      amountMinor: 900,
      currency: 'SAR',
    );
    final settled = await ledger().settleEmployeeDebt(
      access,
      commandId: _id(),
      debtId: debt['debt_id'] as String,
      amountMinor: 400,
      accountId: sar,
    );
    expect(settled['account_id'], sar);
    expect(await balances(), {sar: 7900, usd: 500, shared: 1000});
    final session = _id();
    final publisher = BusinessLedgerAccess(scope, all, cashSessionId: session);
    await ledger().cashSync.bindReplica(publisher, sessionId: session,
      checkpoint: cashTestCheckpoint(scope, shared, balance: 1000),
    );
    final first = _id(), second = _id();
    for (final command in [first, second]) {
      await ledger().payEmployeeSalary(
        publisher, commandId: command, employeeId: e1,
        amountMinor: 100, currency: 'SAR', accountId: shared,
      );
    }
    Future<Set<Object?>> delivered() async => (await ledger().employeeDeliveryReceipts(access, e1))
        .where((row) => row['kind'] == 'salary').map((row) => row['id']).toSet();
    expect(await delivered(), {salary['receipt_id']});
    await ledger().cashSync.decide(
      publisher, commandId: first, sequence: 1,
      decision: BusinessCashDecision.permissionChanged,
    );
    await ledger().cashSync.decide(
      publisher, commandId: second, sequence: 2, decision: BusinessCashDecision.accepted,
    );
    expect(await delivered(), {salary['receipt_id'], second});
  });

  test('v13 upgrades in place and a captured branch keeps grants and finance', () async {
    final e1 = _id();
    final granted = await ledger().grantEmployeeDelegation(
      access,
      commandId: _id(),
      employeeId: e1,
      actions: finance,
    );
    final salary = await ledger().payEmployeeSalary(
      access,
      commandId: _id(),
      employeeId: e1,
      amountMinor: 4200,
      currency: 'SAR',
    );
    final debt = await ledger().createEmployeeDebt(
      access,
      commandId: _id(),
      employeeId: e1,
      amountMinor: 600,
      currency: 'SAR',
    );
    await ledger().settleEmployeeDebt(
      access,
      commandId: _id(),
      debtId: debt['debt_id'] as String,
      amountMinor: 100,
    );

    final file = File('${root.path}/employees.fyonabiz');
    final code = BusinessBackupCode.generate();
    await ledger().captureBackup(
      access,
      id: _id(),
      destination: file,
      code: code,
      allowed: () => true,
    );
    final copy = await DirectoryDatabase.open(
      root: await root.createTemp('recovery-'),
      workspace: workspace,
      keys: FixtureDirectoryKeys(),
    );
    addTearDown(copy.close);
    expect(
      await copy.ledger.restoreBackup(
        access,
        source: file,
        code: code,
        allowed: () => true,
      ),
      (alreadyRestored: false, hasSharedHistory: false),
    );
    final restored = await copy.ledger.employeeFinance(access);
    expect((restored['salaries'] as List).single['command_id'], salary['receipt_id']);
    expect((restored['debts'] as List).single['remaining_minor'], 500);
    expect(restored['totals'], {
      'SAR': {'salary_minor': 4200, 'debt_minor': 600, 'settled_minor': 100, 'open_minor': 500},
    });
    final grants = await copy.ledger.employeeDelegations(access);
    expect(grants.single['version'], granted['version']);
    expect(grants.single['active'], isTrue);
    await expectLater(
      copy.ledger.employeeDeliveryReceipts(access, e1),
      throwsA(isA<DirectoryAccessDenied>()),
    );

    // A v13 database upgrades in place without losing its earlier ledger.
    final account = _id();
    await db.ledger.createAccount(
      access,
      commandId: account,
      bankName: 'Bank fixture',
      accountName: 'Main till',
      accountNumber: '100',
      currency: 'SAR',
      openingMinor: 700,
    );
    await db.close();
    final raw = await databaseFactoryFfi.openDatabase(
      DirectoryDatabase.filePath(root, workspace),
      options: OpenDatabaseOptions(
        singleInstance: false,
        onConfigure: (it) async {
          await it.execute('PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"');
        },
      ),
    );
    await raw.transaction((txn) async {
      for (final table in employeeLedgerTables) {
        await txn.execute('DROP TABLE $table');
      }
      await txn.execute('PRAGMA user_version = 13');
    });
    await raw.close();
    db = await DirectoryDatabase.open(
      root: root,
      workspace: workspace,
      keys: keys,
    );
    final upgraded = await db.ledger.employeeFinance(access);
    expect(upgraded['salaries'], isEmpty);
    expect(upgraded['debts'], isEmpty);
    expect(
      {
        for (final row in await db.ledger.accounts(access))
          row['id']: row['balance_minor'],
      },
      {account: 700},
    );
    await db.ledger.payEmployeeSalary(
      access,
      commandId: _id(),
      employeeId: e1,
      amountMinor: 10,
      currency: 'SAR',
    );
    expect((await db.ledger.employeeFinance(access))['salaries'], hasLength(1));
  });
}

Future<Map<String, Object?>> asE1Debt(
  BusinessLedger ledger,
  BusinessLedgerAccess access,
  String debtId,
  int amountMinor,
) => ledger.settleEmployeeDebt(
  access,
  commandId: _id(),
  debtId: debtId,
  amountMinor: amountMinor,
);

const employeeLedgerTables = [
  'business_employee_grants',
  'business_employee_payroll',
  'business_employee_debts',
  'business_employee_debt_legs',
  'business_employee_receipts',
  'business_branch_transfers',
  'business_branch_transfer_lines',
];
