part of 'directory_database.dart';

const _bankEdits = 'business_bank_account_edits';
const _bankProjections = 'business_bank_projection_receipts';
const _ledgerCashNames = ['كاش', 'Cash', 'CASH'];

bool _isLedgerCash(String name) => _ledgerCashNames.contains(name.trim());
String _bankNameKey(String name) =>
    name.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
String _slotKey(String name) =>
    _isLedgerCash(name) ? 'cash' : 'bank:${_bankNameKey(name)}';
String _shownCashType(String type) => type == 'cash' ? 'checking' : type;

Future<void> _requireBankSlot(
  DatabaseExecutor db,
  String branch,
  String bank,
  String currency,
  String type, {
  String? except,
}) async {
  await _requireCashSlotNotReserved(db, branch, bank, currency);
  final rows = await db.query(
    BusinessLedger._accounts,
    columns: ['id', 'bank_name', 'account_type'],
    where: 'branch_id = ? AND currency = ? AND closed_us IS NULL',
    whereArgs: [branch, currency],
  );
  if (rows.any(
    (row) =>
        row['id'] != except &&
        _slotKey(row['bank_name'] as String) == _slotKey(bank) &&
        (_isLedgerCash(bank)
            ? _shownCashType(row['account_type'] as String) ==
                  _shownCashType(type)
            : row['account_type'] == type),
  )) {
    throw const BusinessLedgerError(BusinessLedgerProblem.duplicateBankAccount);
  }
}

Future<int> _remainingCash(
  DatabaseExecutor db,
  String branch,
  String except,
) async {
  final result = await db.rawQuery(
    '''
    SELECT COUNT(*) AS n FROM ${BusinessLedger._accounts}
    WHERE branch_id = ? AND closed_us IS NULL AND is_active = 1 AND id <> ?
      AND trim(bank_name) IN (?, ?, ?)
  ''',
    [branch, except, ..._ledgerCashNames],
  );
  return result.single['n'] as int;
}

Future<void> _recordAccountEdit(
  Transaction txn,
  String branch,
  String command,
  Map<String, Object?> previous,
  Map<String, Object?> changes,
  DateTime now,
) async {
  await txn.insert(_bankEdits, {
    'branch_id': branch,
    'command_id': command,
    'account_id': previous['id'],
    'previous': jsonEncode(previous),
    'current': jsonEncode({...previous, ...changes}),
    'created_us': now.microsecondsSinceEpoch,
  });
}

Future<Map<String, Object?>?> _restoreCashSlot(
  Transaction txn,
  String branch,
  String command,
  String currency,
  String type,
  DateTime now, {
  bool checkingAlias = false,
}) async {
  final rows = await txn.query(
    BusinessLedger._accounts,
    where:
        'branch_id = ? AND cash_stashed = 1 AND closed_us IS NOT NULL AND currency = ?'
        ' AND (account_type = ?${checkingAlias && type == 'checking' ? " OR account_type = 'cash'" : ''})'
        ' AND trim(bank_name) IN (?, ?, ?)',
    whereArgs: [branch, currency, type, ..._ledgerCashNames],
    orderBy: 'closed_us DESC, id',
    limit: 1,
  );
  final old = rows.singleOrNull;
  if (old == null) return null;
  final id = old['id'];
  const changes = {'closed_us': null, 'is_active': 1, 'cash_stashed': 0};
  await txn.update(
    BusinessLedger._accounts,
    changes,
    where: 'branch_id = ? AND id = ?',
    whereArgs: [branch, id],
  );
  await _recordAccountEdit(txn, branch, command, old, changes, now);
  // No opening-leg replay. This is the same cash account and statement.
  return {'id': id, 'balance_minor': old['balance_minor'], 'restored': true};
}

Future<void> _newCashAccount(
  Transaction txn,
  String branch,
  String command,
  String currency,
  DateTime now,
) async {
  await _requireCashSlotNotReserved(txn, branch, 'كاش', currency);
  await txn.insert(BusinessLedger._accounts, {
  'id': const Uuid().v5(command, currency),
  'branch_id': branch,
  'bank_name': 'كاش',
  'account_name': 'حساب الكاش',
  'account_number': 'CASH',
  'account_type': 'checking',
  'currency': currency,
  'balance_minor': 0,
  'created_us': now.microsecondsSinceEpoch,
  });
}

extension BusinessBankManagement on BusinessLedger {
  /// Bank screens include inactive accounts; payment choices use [BusinessLedger.accounts]
  /// instead. Closed accounts remain in SQLCipher for the audit and reversals.
  Future<List<Map<String, Object?>>> managedBankAccounts(
    BusinessLedgerAccess access, {
    required bool includeBalances,
  }) {
    final branch = _branch(access, BusinessLedgerAction.readBank);
    return _directory._read(
      (db) => db.query(
        BusinessLedger._accounts,
        columns: [
          'id',
          'bank_name',
          'account_name',
          'account_number',
          'iban',
          'account_type',
          'currency',
          'is_active',
          if (includeBalances) 'balance_minor',
        ],
        where: 'branch_id = ? AND closed_us IS NULL',
        whereArgs: [branch],
        orderBy: 'created_us DESC, id',
      ),
    );
  }

  /// Idempotent default cash initialization. A read does not create rows.
  /// Existing configurations, including previously closed currency slots,
  /// are left exactly as they are.
  Future<void> initializeBankCash(
    BusinessLedgerAccess access, {
    required String commandId,
    required Iterable<String> currencies,
  }) async {
    final branch = _branch(access, BusinessLedgerAction.createBank);
    final codes = currencies.map(businessCurrency).toSet().toList()..sort();
    if (codes.isEmpty || codes.length > 100) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAccount);
    }
    await _commit(branch, commandId, ['default_cash', codes], (txn, now) async {
      final present = await txn.query(
        BusinessLedger._accounts,
        columns: ['id'],
        where: 'branch_id = ? AND trim(bank_name) IN (?, ?, ?)',
        whereArgs: [branch, ..._ledgerCashNames],
        limit: 1,
      );
      if (present.isNotEmpty) return {'created': false};
      for (final currency in codes) {
        await _newCashAccount(txn, branch, commandId, currency, now);
      }
      return {'created': true};
    });
  }

  Future<Set<String>> cashCurrencies(BusinessLedgerAccess access) async {
    final branch = _branch(access, BusinessLedgerAction.readBank);
    final rows = await _directory._read(
      (db) => db.query(
        BusinessLedger._accounts,
        columns: ['currency'],
        where:
            'branch_id = ? AND closed_us IS NULL AND is_active = 1'
            ' AND trim(bank_name) IN (?, ?, ?)',
        whereArgs: [branch, ..._ledgerCashNames],
      ),
    );
    return rows.map((row) => row['currency'] as String).toSet();
  }

  /// The enabled currencies and their cash slots are the same state. No second
  /// preference writer or off-ledger balance vault is needed in this branch.
  Future<void> customizeCashCurrencies(
    BusinessLedgerAccess access, {
    required String commandId,
    required Set<String> currencies,
    required Set<String> expected,
  }) async {
    final branch = _branch(access, BusinessLedgerAction.manageBank);
    final codes = currencies.map(businessCurrency).toSet().toList()..sort();
    final before = expected.map(businessCurrency).toSet().toList()..sort();
    if (codes.isEmpty || codes.length > 100) {
      throw const BusinessLedgerError(
        BusinessLedgerProblem.cannotDeleteLastCash,
      );
    }
    await _commit(branch, commandId, ['cash_currencies', before, codes], (
      txn,
      now,
    ) async {
      final rows = await txn.query(
        BusinessLedger._accounts,
        where:
            'branch_id = ? AND closed_us IS NULL AND trim(bank_name) IN (?, ?, ?)',
        whereArgs: [branch, ..._ledgerCashNames],
      );
      final current =
          rows
              .where((row) => row['is_active'] == 1)
              .map((row) => row['currency'] as String)
              .toSet()
              .toList()
            ..sort();
      if (jsonEncode(current) != jsonEncode(before)) {
        throw const BusinessLedgerError(BusinessLedgerProblem.accountChanged);
      }
      for (final row in rows.where((row) => !codes.contains(row['currency']))) {
        final id = row['id'] as String;
        await cashSync._requirePrivate(txn, branch, id);
        final changes = {
          'closed_us': now.microsecondsSinceEpoch,
          'cash_stashed': 1,
        };
        await txn.update(
          BusinessLedger._accounts,
          changes,
          where: 'branch_id = ? AND id = ?',
          whereArgs: [branch, id],
        );
        await _recordAccountEdit(txn, branch, commandId, row, changes, now);
      }
      for (final code in codes.where((code) => !current.contains(code))) {
        final inactive = rows.where((row) => row['currency'] == code).toList();
        if (inactive.isNotEmpty) {
          for (final row in inactive) {
            final id = row['id'] as String;
            await cashSync._requirePrivate(txn, branch, id);
            const changes = {'is_active': 1};
            await txn.update(
              BusinessLedger._accounts,
              changes,
              where: 'branch_id = ? AND id = ?',
              whereArgs: [branch, id],
            );
            await _recordAccountEdit(txn, branch, commandId, row, changes, now);
          }
          continue;
        }
        final stashed = await txn.query(
          BusinessLedger._accounts,
          columns: ['account_type'],
          where:
              'branch_id = ? AND cash_stashed = 1 AND closed_us IS NOT NULL'
              ' AND currency = ? AND trim(bank_name) IN (?, ?, ?)',
          whereArgs: [branch, code, ..._ledgerCashNames],
        );
        if (stashed.isEmpty) {
          await _newCashAccount(txn, branch, commandId, code, now);
        } else {
          for (final type
              in stashed.map((row) => row['account_type'] as String).toSet()) {
            await _restoreCashSlot(txn, branch, commandId, code, type, now);
          }
        }
      }
      return {'currencies': codes};
    });
  }

  Future<void> editBankAccount(
    BusinessLedgerAccess access, {
    required String accountId,
    required String commandId,
    String? bankName,
    String? accountName,
    String? accountNumber,
    String? iban,
    String? currency,
    String? type,
    int? balanceMinor,
    int? expectedBalanceMinor,
    bool? isActive,
  }) async {
    final branch = _branch(access, BusinessLedgerAction.manageBank);
    final cleanBank = bankName?.trim();
    if ((cleanBank != null &&
            (cleanBank.runes.length < 2 || cleanBank.runes.length > 200)) ||
        (accountNumber != null && accountNumber.trim().runes.length > 100) ||
        (iban != null && iban.trim().runes.length > 50)) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAccount);
    }
    final fields = <String, Object?>{
      if (cleanBank != null) 'bank_name': cleanBank,
      if (accountName != null)
        'account_name': BusinessLedger._requiredField(accountName, 200),
      if (accountNumber != null) 'account_number': accountNumber.trim(),
      if (iban != null) 'iban': iban.trim(),
      if (currency != null) 'currency': businessCurrency(currency),
      if (type != null) 'account_type': BusinessLedger._requiredField(type, 20),
      if (balanceMinor != null)
        'balance_minor': BusinessMoney.checked(balanceMinor),
      if (isActive != null) 'is_active': isActive ? 1 : 0,
    };
    await _commit(
      branch,
      commandId,
      ['bank_edit', accountId, fields, expectedBalanceMinor],
      (txn, now) async {
        final old = await _account(txn, branch, accountId, allowInactive: true);
        await cashSync._requirePrivate(txn, branch, accountId);
        final changed = fields.keys.any((field) => old[field] != fields[field]);
        if (!changed) return {'id': accountId};
        if (balanceMinor != null &&
            (expectedBalanceMinor == null ||
                old['balance_minor'] != expectedBalanceMinor)) {
          throw const BusinessLedgerError(BusinessLedgerProblem.accountChanged);
        }
        final current = {...old, ...fields};
        final bank = current['bank_name'] as String;
        if (_isLedgerCash(old['bank_name'] as String) &&
            (!_isLedgerCash(bank) || isActive == false) &&
            await _remainingCash(txn, branch, accountId) == 0) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.cannotDeleteLastCash,
          );
        }
        if (current['currency'] != old['currency']) {
          final paid = await txn.query(
            BusinessLedger._paymentHistory,
            columns: ['id'],
            where: 'branch_id = ? AND account_id = ?',
            whereArgs: [branch, accountId],
            limit: 1,
          );
          final commercePayments = paid.isEmpty
              ? await txn.query(
                  _commercePayments,
                  columns: ['id'],
                  where: 'branch_id = ? AND account_id = ?',
                  whereArgs: [branch, accountId],
                  limit: 1,
                )
              : paid;
          if (commercePayments.isNotEmpty) {
            // Undoing an already settled debt must use the original account
            // and currency; don't silently undo dollars into a SAR balance.
            throw const BusinessLedgerError(
              BusinessLedgerProblem.currencyHasPayments,
            );
          }
        }
        if ([
          'bank_name',
          'account_type',
          'currency',
        ].any((key) => old[key] != current[key])) {
          await _requireBankSlot(
            txn,
            branch,
            bank,
            current['currency'] as String,
            current['account_type'] as String,
            except: accountId,
          );
        }
        await txn.update(
          BusinessLedger._accounts,
          fields,
          where: 'branch_id = ? AND id = ?',
          whereArgs: [branch, accountId],
        );
        // Legacy edits do not create fake deposits/withdrawals. Preserve
        // the change separately and leave historical statement currencies.
        await _recordAccountEdit(txn, branch, commandId, old, fields, now);
        return {'id': accountId};
      },
    );
  }

  /// The whole list is resolved and retired in one transaction, even if the
  /// original screen deletes an entire multi-currency bank in one gesture.
  Future<void> closeBankAccounts(
    BusinessLedgerAccess access, {
    required String commandId,
    required Iterable<String> accountIds,
    bool onlyCash = false,
  }) async {
    final branch = _branch(access, BusinessLedgerAction.manageBank);
    final ids = accountIds.toSet().toList()..sort();
    if (ids.isEmpty ||
        ids.length > 400 ||
        ids.any((id) => !isDirectoryId(id))) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAccount);
    }
    await _commit(branch, commandId, ['bank_close', ids, onlyCash], (
      txn,
      now,
    ) async {
      for (final id in ids) {
        final old = await _account(txn, branch, id, allowInactive: true);
        await cashSync._requirePrivate(txn, branch, id);
        final cash = _isLedgerCash(old['bank_name'] as String);
        if (cash &&
            (ids.length != 1 || await _remainingCash(txn, branch, id) == 0)) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.cannotDeleteLastCash,
          );
        }
        if (onlyCash && !cash) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidAccount);
        }
        final changes = {
          'closed_us': now.microsecondsSinceEpoch,
          'cash_stashed': cash ? 1 : 0,
        };
        await txn.update(
          BusinessLedger._accounts,
          changes,
          where: 'branch_id = ? AND id = ?',
          whereArgs: [branch, id],
        );
        await _recordAccountEdit(txn, branch, commandId, old, changes, now);
      }
      return {'ids': ids};
    });
  }

  Future<List<Map<String, dynamic>>> bankHistory(
    BusinessLedgerAccess access,
    Iterable<String> accountIds, {
    required bool includeBalances,
  }) {
    final branch = _branch(access, BusinessLedgerAction.readBankHistory);
    final ids = accountIds.toSet().toList();
    return _directory._transaction((txn) async {
      final rows = <Map<String, Object?>>[];
      for (final id in ids) {
        await _account(txn, branch, id, allowInactive: true);
        rows.addAll(
          await txn.query(
            BusinessLedger._legs,
            columns: [
              'command_id',
              'account_id',
              'kind',
              'delta_minor',
              'created_us',
              'currency',
              'description',
              'reference',
              'fx_rate',
              'legacy',
              if (includeBalances) 'balance_minor',
            ],
            where: 'branch_id = ? AND account_id = ? AND hidden = 0',
            whereArgs: [branch, id],
            orderBy: 'created_us DESC, sequence DESC',
          ),
        );
      }
      rows.sort(
        (a, b) => (b['created_us'] as int).compareTo(a['created_us'] as int),
      );
      return [
        for (final row in rows)
          {
            'id': row['legacy'] == 1
                ? row['command_id']
                : '${row['command_id']}:${row['account_id']}',
            'bank_account_id': row['account_id'],
            'tx_type': _historyKind(row),
            'amount': BusinessMoney.display((row['delta_minor'] as int).abs()),
            'date': DateTime.fromMicrosecondsSinceEpoch(
              row['created_us'] as int,
              isUtc: true,
            ).toIso8601String(),
            'currency': row['currency'],
            'description': row['description'],
            'reference': row['reference'],
            'exchange_rate': row['fx_rate'],
            if (includeBalances)
              'running_balance': BusinessMoney.display(
                row['balance_minor'] as int,
              ),
          },
      ];
    });
  }

  static String _historyKind(Map<String, Object?> row) => switch (row['kind']) {
    'customer_collection' => 'deposit',
    'supplier_payment' => 'withdrawal',
    'invoice_cancel' =>
      (row['delta_minor'] as int) > 0 ? 'deposit' : 'withdrawal',
    'withdrawal_reversal' => 'transfer_reversal_in',
    _ => row['kind'] as String,
  };
}
