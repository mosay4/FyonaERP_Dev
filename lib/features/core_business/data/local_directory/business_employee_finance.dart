part of 'directory_database.dart';

// Device payroll, employee debts and their receipts. The connected salary and
// debt writers stay fenced for a registered branch; this is the only writer.
const _employeePayroll = 'business_employee_payroll';
const _employeeDebts = 'business_employee_debts';
const _employeeDebtLegs = 'business_employee_debt_legs';
const _employeeReceipts = 'business_employee_receipts';

Future<void> _createBusinessEmployeeFinance(DatabaseExecutor db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_employeePayroll (
      branch_id TEXT NOT NULL,
      command_id TEXT NOT NULL,
      employee_id TEXT NOT NULL,
      amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
      currency TEXT NOT NULL,
      period TEXT,
      created_us INTEGER NOT NULL,
      PRIMARY KEY (branch_id, command_id)
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS $_employeePayroll\_by_employee ON $_employeePayroll
      (branch_id, employee_id, created_us DESC, command_id)
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_employeeDebts (
      branch_id TEXT NOT NULL,
      debt_id TEXT NOT NULL,
      employee_id TEXT NOT NULL,
      direction TEXT NOT NULL DEFAULT 'employee_owes'
        CHECK (direction IN ('employee_owes', 'employer_owes')),
      amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
      currency TEXT NOT NULL,
      remaining_minor INTEGER NOT NULL
        CHECK (remaining_minor BETWEEN 0 AND amount_minor),
      note TEXT,
      created_us INTEGER NOT NULL,
      closed_us INTEGER,
      PRIMARY KEY (branch_id, debt_id)
    )
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS $_employeeDebts\_by_employee ON $_employeeDebts
      (branch_id, employee_id, created_us DESC, debt_id)
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_employeeDebtLegs (
      branch_id TEXT NOT NULL,
      command_id TEXT NOT NULL,
      debt_id TEXT NOT NULL,
      delta_minor INTEGER NOT NULL CHECK (delta_minor > 0),
      created_us INTEGER NOT NULL,
      PRIMARY KEY (branch_id, command_id),
      FOREIGN KEY (branch_id, debt_id)
        REFERENCES $_employeeDebts (branch_id, debt_id)
    )
  ''');
  await db.execute('''
    CREATE TABLE IF NOT EXISTS $_employeeReceipts (
      branch_id TEXT NOT NULL,
      command_id TEXT NOT NULL,
      employee_id TEXT NOT NULL,
      kind TEXT NOT NULL
        CHECK (kind IN ('salary', 'debt', 'debt_settlement')),
      payload TEXT NOT NULL,
      created_us INTEGER NOT NULL,
      PRIMARY KEY (branch_id, command_id)
    )
  ''');
}

extension BusinessEmployeeFinance on BusinessLedger {
  String? _employeeNote(String? note) {
    final value = DirectoryDatabase._optional(note);
    if (value != null && value.runes.length > 200) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidEmployee);
    }
    return value;
  }

  Future<void> _employeeReceiptRow(
    DatabaseExecutor db,
    String branch,
    String commandId,
    String employeeId,
    String kind,
    Map<String, Object?> payload,
    DateTime now,
  ) async {
    await db.insert(_employeeReceipts, {
      'branch_id': branch,
      'command_id': commandId,
      'employee_id': employeeId,
      'kind': kind,
      'payload': jsonEncode(payload),
      'created_us': now.microsecondsSinceEpoch,
    });
  }

  /// A salary is recorded with its receipt in one transaction. Funding it
  /// from an account is optional; a shared till can only fund it through the
  /// ordinary cash arbitration, never with a second private writer.
  Future<Map<String, Object?>> payEmployeeSalary(
    BusinessLedgerAccess access, {
    required String commandId,
    required String employeeId,
    required int amountMinor,
    required String currency,
    String? accountId,
    String? period,
    String? notes,
    bool Function()? allowed,
  }) async {
    final branch = _branch(access, BusinessLedgerAction.payEmployeeSalary);
    final employee = _employeeScope(access, employeeId);
    BusinessLedger._amount(amountMinor);
    final cur = businessCurrency(currency);
    final label = _employeeNote(period);
    final note = _employeeNote(notes);
    return _commit(
      branch,
      commandId,
      ['employee_salary', employee, amountMinor, cur, label, accountId, note],
      (txn, now) async {
        if (accountId != null) {
          await _employeePayout(
            txn,
            branch,
            access,
            commandId,
            accountId,
            cur,
            amountMinor,
            now,
            'راتب موظف',
            'الرواتب',
          );
        }
        await txn.insert(_employeePayroll, {
          'branch_id': branch,
          'command_id': commandId,
          'employee_id': employee,
          'amount_minor': amountMinor,
          'currency': cur,
          'period': label,
          'created_us': now.microsecondsSinceEpoch,
        });
        final receipt = {
          'kind': 'salary',
          'employee_id': employee,
          'amount_minor': amountMinor,
          'currency': cur,
          'period': label,
          'notes': note,
          'account_id': accountId,
          'bank_name': await _employeeBankName(txn, branch, accountId),
          'paid_us': now.toIso8601String(),
        };
        await _employeeReceiptRow(
          txn,
          branch,
          commandId,
          employee,
          'salary',
          receipt,
          now,
        );
        await _requireDelegation(
          txn,
          branch,
          access,
          BusinessLedgerAction.payEmployeeSalary,
        );
        return {'receipt_id': commandId, ...receipt};
      },
      allowed: allowed,
      validate: (txn) => _requireDelegation(
        txn,
        branch,
        access,
        BusinessLedgerAction.payEmployeeSalary,
      ),
    );
  }

  Future<Map<String, Object?>> createEmployeeDebt(
    BusinessLedgerAccess access, {
    required String commandId,
    required String employeeId,
    required int amountMinor,
    required String currency,
    String direction = 'employee_owes',
    String? note,
    String? accountId,
    bool Function()? allowed,
  }) async {
    final branch = _branch(access, BusinessLedgerAction.createEmployeeDebt);
    final employee = _employeeScope(access, employeeId);
    if (direction != 'employee_owes' && direction != 'employer_owes') {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidEmployee);
    }
    BusinessLedger._amount(amountMinor);
    final cur = businessCurrency(currency);
    final noteValue = _employeeNote(note);
    return _commit(
      branch,
      commandId,
      [
        'employee_debt',
        employee,
        amountMinor,
        cur,
        direction,
        noteValue,
        if (accountId != null) accountId,
      ],
      (txn, now) async {
        if (accountId != null) {
          if (direction == 'employee_owes') {
            await _employeePayout(
              txn,
              branch,
              access,
              commandId,
              accountId,
              cur,
              amountMinor,
              now,
              'دين على موظف',
              'ديون الموظفين',
            );
          } else {
            await _employeeAccount(txn, branch, accountId, cur);
          }
        }
        await txn.insert(_employeeDebts, {
          'branch_id': branch,
          'debt_id': commandId,
          'employee_id': employee,
          'direction': direction,
          'amount_minor': amountMinor,
          'currency': cur,
          'remaining_minor': amountMinor,
          'note': noteValue,
          'created_us': now.microsecondsSinceEpoch,
        });
        final receipt = {
          'kind': 'debt',
          'employee_id': employee,
          'debt_id': commandId,
          'direction': direction,
          'amount_minor': amountMinor,
          'remaining_minor': amountMinor,
          'currency': cur,
          'note': noteValue,
          'bank_name': await _employeeBankName(txn, branch, accountId),
          'cash_effect': direction == 'employee_owes' && accountId != null
              ? 'debit'
              : 'none',
          'created_us': now.toIso8601String(),
        };
        await _employeeReceiptRow(
          txn,
          branch,
          commandId,
          employee,
          'debt',
          receipt,
          now,
        );
        await _requireDelegation(
          txn,
          branch,
          access,
          BusinessLedgerAction.createEmployeeDebt,
        );
        return {'receipt_id': commandId, ...receipt};
      },
      allowed: allowed,
      validate: (txn) => _requireDelegation(
        txn,
        branch,
        access,
        BusinessLedgerAction.createEmployeeDebt,
      ),
    );
  }

  Future<void> _employeePayout(
    Transaction txn,
    String branch,
    BusinessLedgerAccess access,
    String commandId,
    String accountId,
    String currency,
    int amountMinor,
    DateTime now,
    String description,
    String category,
  ) async {
    final account = await _employeeAccount(txn, branch, accountId, currency);
    final shared = await cashSync._config(txn, branch, accountId);
    if (shared != null) {
      // One writer per shared resource: the cash arbitration decides, the
      // payroll record and its receipt only ride along with the same command.
      await cashSync._stageWithdrawal(
        txn,
        branch,
        access.cashSessionId,
        commandId,
        accountId,
        now,
        account,
        shared,
        amountMinor,
        description: description,
        expenseCategory: category,
      );
      return;
    }
    final next = BusinessLedger._balance(account, -amountMinor);
    if (next < 0 && !await _allowsNegative(txn, branch)) {
      throw const BusinessLedgerError(
        BusinessLedgerProblem.insufficientBalance,
      );
    }
    await _post(
      txn,
      branch,
      commandId,
      accountId,
      now,
      kind: 'withdrawal',
      delta: -amountMinor,
      next: next,
      description: description,
      expenseCategory: category,
    );
  }

  Future<Map<String, Object?>> _employeeAccount(
    Transaction txn,
    String branch,
    String id,
    String currency,
  ) async {
    final account = await _account(txn, branch, id);
    if (account['currency'] != currency) {
      throw const BusinessLedgerError(BusinessLedgerProblem.currencyMismatch);
    }
    return account;
  }

  Future<String?> _employeeBankName(
    Transaction txn,
    String branch,
    String? id,
  ) async => id == null
      ? null
      : (await _account(txn, branch, id))['bank_name'] as String?;

  /// Settles one employee debt, in its own currency, without converting or
  /// mixing it with any other debt. The leg, the new remainder and the
  /// receipt commit together or not at all.
  Future<Map<String, Object?>> settleEmployeeDebt(
    BusinessLedgerAccess access, {
    required String commandId,
    required String debtId,
    required int amountMinor,
    String? accountId,
    String? employeeId,
    String? currency,
    String? direction,
    String? notes,
    bool Function()? allowed,
  }) async {
    final branch = _branch(access, BusinessLedgerAction.settleEmployeeDebt);
    if (!isDirectoryId(debtId)) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidEmployee);
    }
    BusinessLedger._amount(amountMinor);
    final actor = access.employee;
    final employee = employeeId == null
        ? null
        : _employeeScope(access, employeeId);
    final expectedCurrency = currency == null
        ? null
        : businessCurrency(currency);
    final note = _employeeNote(notes);
    late Map<String, Object?> debt;
    return _commit(
      branch,
      commandId,
      [
        'employee_debt_settlement',
        debtId,
        amountMinor,
        accountId,
        if (note != null) note,
      ],
      validate: (txn) async {
        await _requireDelegation(
          txn,
          branch,
          access,
          BusinessLedgerAction.settleEmployeeDebt,
        );
        final rows = await txn.query(
          _employeeDebts,
          where: 'branch_id = ? AND debt_id = ?',
          whereArgs: [branch, debtId],
        );
        if (rows.length != 1) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.invalidEmployee,
          );
        }
        debt = rows.single;
        final expectedEmployee = employee ?? actor?.employeeId;
        if (expectedEmployee != null &&
            debt['employee_id'] != expectedEmployee) {
          throw const DirectoryAccessDenied();
        }
        if (direction != null && debt['direction'] != direction) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.invalidEmployee,
          );
        }
        if (expectedCurrency != null && debt['currency'] != expectedCurrency) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.currencyMismatch,
          );
        }
      },
      (txn, now) async {
        final remaining = debt['remaining_minor'] as int;
        if (amountMinor > remaining) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.insufficientBalance,
          );
        }
        if (accountId != null) {
          final cur = debt['currency'] as String;
          if (debt['direction'] == 'employee_owes') {
            final account = await _employeeAccount(txn, branch, accountId, cur);
            await cashSync._requirePrivate(txn, branch, accountId);
            await _post(
              txn,
              branch,
              commandId,
              accountId,
              now,
              kind: 'deposit',
              delta: amountMinor,
              next: BusinessLedger._balance(account, amountMinor),
              description: 'تحصيل دين من موظف',
            );
          } else {
            await _employeePayout(
              txn,
              branch,
              access,
              commandId,
              accountId,
              cur,
              amountMinor,
              now,
              'تسديد دين موظف',
              'ديون الموظفين',
            );
          }
        }
        final after = remaining - amountMinor;
        await txn.update(
          _employeeDebts,
          {
            'remaining_minor': after,
            'closed_us': after == 0 ? now.microsecondsSinceEpoch : null,
          },
          where: 'branch_id = ? AND debt_id = ?',
          whereArgs: [branch, debtId],
        );
        await txn.insert(_employeeDebtLegs, {
          'branch_id': branch,
          'command_id': commandId,
          'debt_id': debtId,
          'delta_minor': amountMinor,
          'created_us': now.microsecondsSinceEpoch,
        });
        final receipt = {
          'kind': 'debt_settlement',
          'employee_id': debt['employee_id'],
          'debt_id': debtId,
          'direction': debt['direction'],
          'amount_minor': amountMinor,
          'before_minor': remaining,
          'after_minor': after,
          'currency': debt['currency'],
          'account_id': accountId,
          'bank_name': await _employeeBankName(txn, branch, accountId),
          'notes': note,
          'settled_us': now.toIso8601String(),
        };
        await _employeeReceiptRow(
          txn,
          branch,
          commandId,
          debt['employee_id'] as String,
          'debt_settlement',
          receipt,
          now,
        );
        await _requireDelegation(
          txn,
          branch,
          access,
          BusinessLedgerAction.settleEmployeeDebt,
        );
        return {'receipt_id': commandId, ...receipt};
      },
      allowed: allowed,
    );
  }

  /// Complete per-currency totals: currencies are never summed together and
  /// no salary, debt, leg or receipt is left out of the totals.
  Future<Map<String, Object?>> employeeFinance(
    BusinessLedgerAccess access, {
    String? employeeId,
  }) async {
    final actor = access.employee;
    final String branch;
    final String? employee;
    if (actor == null) {
      branch = _branch(access, BusinessLedgerAction.readEmployeeFinance);
      employee = employeeId == null ? null : _employeeScope(access, employeeId);
    } else {
      branch = _branch(access, BusinessLedgerAction.readEmployeeFinance);
      employee = employeeId == null
          ? actor.employeeId
          : _employeeScope(access, employeeId);
    }
    return _directory._read((db) async {
      await _requireDelegation(
        db,
        branch,
        access,
        BusinessLedgerAction.readEmployeeFinance,
      );
      final filter = employee == null ? '' : ' AND employee_id = ?';
      final args = [branch, if (employee != null) employee];
      final salaries = await db.query(
        _employeePayroll,
        where: 'branch_id = ?$filter',
        whereArgs: args,
        orderBy: 'created_us DESC, command_id',
      );
      final debts = await db.query(
        _employeeDebts,
        where: 'branch_id = ?$filter',
        whereArgs: args,
        orderBy: 'created_us DESC, debt_id',
      );
      final receipts = await db.query(
        _employeeReceipts,
        where: 'branch_id = ?$filter',
        whereArgs: args,
        orderBy: 'created_us DESC, command_id',
      );
      final totals = <String, Map<String, int>>{};
      void add(String currency, String key, int minor) {
        final bucket = totals.putIfAbsent(
          currency,
          () => {
            'salary_minor': 0,
            'debt_minor': 0,
            'settled_minor': 0,
            'open_minor': 0,
          },
        );
        bucket[key] = (bucket[key] ?? 0) + minor;
      }

      for (final row in salaries) {
        add(
          row['currency'] as String,
          'salary_minor',
          row['amount_minor'] as int,
        );
      }
      for (final row in debts) {
        final currency = row['currency'] as String;
        final amount = row['amount_minor'] as int;
        final remaining = row['remaining_minor'] as int;
        add(currency, 'debt_minor', amount);
        add(currency, 'settled_minor', amount - remaining);
        add(currency, 'open_minor', remaining);
      }
      return {
        'employee_id': employee,
        'salaries': [
          for (final row in salaries) Map<String, Object?>.from(row),
        ],
        'debts': [for (final row in debts) Map<String, Object?>.from(row)],
        'receipts': [
          for (final row in receipts)
            {
              ...Map<String, Object?>.from(row),
              'payload': jsonDecode(row['payload'] as String),
            },
        ],
        'totals': totals,
      };
    });
  }

  Future<Map<String, Object?>> employeeReceipt(
    BusinessLedgerAccess access,
    String commandId,
  ) async {
    final branch = _branch(access, BusinessLedgerAction.readEmployeeFinance);
    if (!isDirectoryId(commandId)) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidEmployee);
    }
    return _directory._read((db) async {
      await _requireDelegation(
        db,
        branch,
        access,
        BusinessLedgerAction.readEmployeeFinance,
      );
      final rows = await db.query(
        _employeeReceipts,
        where: 'branch_id = ? AND command_id = ?',
        whereArgs: [branch, commandId],
      );
      if (rows.length != 1) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidEmployee);
      }
      final row = rows.single;
      final actor = access.employee;
      if (actor != null && row['employee_id'] != actor.employeeId) {
        throw const DirectoryAccessDenied();
      }
      return {
        ...Map<String, Object?>.from(row),
        'payload': jsonDecode(row['payload'] as String),
      };
    });
  }

  /// Only committed and accepted facts for this employee, with no account
  /// identifiers or balances. A later settlement cannot skip an unresolved
  /// step in the same debt. The archive may be read locally, not republished
  /// until the owner has approved this restored ledger.
  Future<List<Map<String, Object?>>> employeeDeliveryReceipts(
    BusinessLedgerAccess access,
    String employeeId,
  ) {
    final branch = _branch(access, BusinessLedgerAction.readEmployeeFinance);
    final employee = _employeeScope(access, employeeId, ownerOnly: true);
    return _directory._transaction((db) async {
      if (await _syncFrozen(db, branch)) throw const DirectoryAccessDenied();
      final rows = await db.rawQuery(
        '''
        SELECT r.command_id, r.payload, r.kind, r.created_us,
          q.command_id AS pending, s.command_id AS suspended, d.decision
        FROM $_employeeReceipts r
        LEFT JOIN ${BusinessCashSync._queue} q USING (branch_id, command_id)
        LEFT JOIN $_cashSuspended s USING (branch_id, command_id)
        LEFT JOIN ${BusinessCashSync._decisions} d USING (branch_id, command_id)
        WHERE r.branch_id = ? AND r.employee_id = ?
        ORDER BY r.created_us, r.rowid LIMIT 2001
      ''',
        [branch, employee],
      );
      if (rows.length > 2000) {
        // Do not publish an incomplete ledger or a truncated debt total.
        throw const DirectoryAccessDenied();
      }
      final balances = <String, int>{};
      final receipts = <Map<String, Object?>>[];
      for (final row in rows) {
        if (row['pending'] != null ||
            row['suspended'] != null ||
            (row['decision'] != null && row['decision'] != 'accepted')) {
          continue;
        }
        final data = jsonDecode(row['payload'] as String) as Map;
        final id = row['command_id'] as String;
        final kind = row['kind'];
        if (kind == 'debt') {
          balances[id] = data['amount_minor'] as int;
        } else if (kind == 'debt_settlement') {
          final original = data['debt_id'] as String;
          final before = balances[original];
          if (before == null || before != data['before_minor']) continue;
          balances[original] = data['after_minor'] as int;
        }
        receipts.add({
          'id': id,
          'kind': kind,
          'currency': data['currency'],
          'amount_minor': data['amount_minor'],
          'created_at': DateTime.fromMicrosecondsSinceEpoch(
            row['created_us'] as int,
            isUtc: true,
          ).toIso8601String(),
          if ((data['notes'] ?? data['note']) case final String note)
            'notes': note,
          if (data['bank_name'] case final String name) 'bank_name': name,
          if (data['cash_effect'] case final String effect)
            'cash_effect': effect,
          if (data['direction'] case final String direction)
            'direction': direction,
          if (kind == 'debt_settlement') ...{
            'original_id': data['debt_id'],
            'remaining_minor': data['after_minor'],
          },
        });
      }
      return receipts;
    });
  }
}
