import 'package:uuid/uuid.dart';

import '../../core_business/data/local_directory/directory_database.dart';
import '../../core_business/data/local_directory/directory_pilot.dart';
import '../../core_business/data/local_directory/directory_scope.dart';
import '../../core_business/data/local_ledger/business_money.dart';

/// Routes employee payroll and debts to the device ledger instead of the
/// legacy REST writers, and maps its rows to the same shapes the employee
/// screens already read. It reports ONLY the device ledger's own records:
/// what a registered branch wrote before its cutover stays on the server, and
/// the two sources are never mixed into one total.
final class EmployeeLocalFinance {
  EmployeeLocalFinance({
    required DirectoryAccess? Function() scope,
    required DirectoryPilotStore Function() store,
    required bool Function() allowed,
    Future<String?> Function()? cashSession,
  }) : _scope = scope,
       _store = store,
       _allowed = allowed,
       _cashSession = cashSession;

  final DirectoryAccess? Function() _scope;
  final DirectoryPilotStore Function() _store;
  final bool Function() _allowed;
  final Future<String?> Function()? _cashSession;

  static const _uuid = Uuid();

  /// A new command id for a form submit without its own idempotency key.
  static String newCommandId() => _uuid.v4();

  bool _selected(DirectoryAccess? scope) =>
      scope != null && _allowed() && sameDirectoryScope(scope, _scope());

  Future<T> _run<T>(
    Set<BusinessLedgerAction> actions,
    Future<T> Function(BusinessLedger ledger, BusinessLedgerAccess access)
    run, {
    String? branchId,
  }) async {
    final scope = _scope();
    if (scope == null ||
        !_selected(scope) ||
        (branchId != null && branchId != scope.branchId)) {
      throw const DirectoryAccessDenied();
    }
    // A payout from a shared till needs the bound cash session; a private
    // account or a pure read does not.
    final session = await _cashSession?.call();
    final access = BusinessLedgerAccess(scope, actions, cashSessionId: session);
    final result = await _store().withLedger(
      access,
      () => _allowed() ? _scope() : null,
      (ledger) => run(ledger, access),
    );
    if (!_selected(scope)) throw const DirectoryAccessDenied();
    return result;
  }

  static double _major(Object? minor) => (minor as int) / 100.0;

  static String _time(Object? micros) =>
      DateTime.fromMicrosecondsSinceEpoch(micros as int).toIso8601String();

  static int _minor(Object? amount) {
    final value = amount is num ? amount.toString() : '$amount';
    return BusinessMoney.minor(value);
  }

  /// The accounts the payroll and debt forms pick from.
  Future<List<Map<String, Object?>>> bankAccounts() => _run({
    BusinessLedgerAction.readBank,
  }, (ledger, access) => ledger.accounts(access));

  Map<String, Object?> _salaryRow(
    Map<String, Object?> row,
    Map<String, Object?>? receipt,
    String? bankName,
  ) => {
    'id': row['command_id'],
    'operation_no': row['command_id'],
    'invoice_no': row['command_id'],
    'amount': _major(row['amount_minor']),
    'currency': row['currency'],
    'paid_at': _time(row['created_us']),
    'notes': receipt?['notes'],
    'period': row['period'],
    'bank_name': bankName,
    'branch_name': null,
  };

  Map<String, Object?> _debtRow(Map<String, Object?> row) => {
    'id': row['debt_id'],
    'invoice_no': row['debt_id'],
    'direction': row['direction'],
    'kind': 'charge',
    'amount': _major(row['amount_minor']),
    'currency': row['currency'],
    'outstanding_amount': _major(row['remaining_minor']),
    'remaining_amount': _major(row['remaining_minor']),
    'notes': row['note'],
    'created_at': _time(row['created_us']),
    'closed_at': row['closed_us'] == null ? null : _time(row['closed_us']),
    'bank_name': null,
    'branch_name': null,
  };

  Map<String, Object?> _settlementRow(
    Map<String, Object?> receiptRow,
    Map<String, Object?> payload,
  ) => {
    'id': receiptRow['command_id'],
    'invoice_no': receiptRow['command_id'],
    'direction': payload['direction'],
    'kind': 'settlement',
    'debt_id': payload['debt_id'],
    'original_debt_invoice': payload['debt_id'],
    'amount': _major(payload['amount_minor']),
    'remaining_amount': _major(payload['after_minor']),
    'currency': payload['currency'],
    'notes': payload['notes'],
    'created_at': _time(receiptRow['created_us']),
    'bank_name': payload['bank_name'] ?? bankNameFor(payload['account_id']),
    'branch_name': null,
  };

  /// The per-currency debt balance, signed exactly like the connected
  /// ledger: what the employee owes is positive, what the shop owes is not.
  Map<String, double> _balances(Iterable<Map<String, Object?>> charges) {
    final totals = <String, int>{};
    for (final row in charges) {
      final currency = row['currency'] as String;
      final sign = row['direction'] == 'employee_owes' ? 1 : -1;
      totals[currency] = (totals[currency] ?? 0) + sign * (row['remaining_minor'] as int);
    }
    return {for (final entry in totals.entries) entry.key: _major(entry.value)};
  }

  Future<Map<String, Object?>> _ledgerView(String employeeId) => _run(
    {BusinessLedgerAction.readEmployeeFinance},
    (ledger, access) => ledger.employeeFinance(access, employeeId: employeeId),
  );

  Map<String, Object?> _view(String employeeId, Map<String, Object?> data) {
    final receipts = [
      for (final row
          in (data['receipts'] as List).whereType<Map<String, Object?>>())
        row,
    ];
    final byCommand = {
      for (final row in receipts) row['command_id'] as String: row,
    };
    final salaries = [
      for (final row
          in (data['salaries'] as List).whereType<Map<String, Object?>>())
        _salaryRow(
          row,
          byCommand[row['command_id']]?['payload'] as Map<String, Object?>?,
          (byCommand[row['command_id']]?['payload'] as Map?)?['bank_name']
                  as String? ??
              bankNameFor(
                (byCommand[row['command_id']]?['payload']
                    as Map?)?['account_id'],
              ),
        ),
    ];
    final charges = (data['debts'] as List)
        .whereType<Map<String, Object?>>()
        .toList();
    final settlements = [
      for (final row in receipts)
        if (row['kind'] == 'debt_settlement')
          _settlementRow(row, row['payload'] as Map<String, Object?>),
    ];
    final debts = [
      for (final charge in charges)
        {
          ..._debtRow(charge),
          if (byCommand[charge['debt_id']]?['payload']
              case final Map receipt) ...{
            'bank_name': receipt['bank_name'],
            'cash_effect': receipt['cash_effect'],
          },
        },
      ...settlements,
    ]..sort((a, b) => ('${b['created_at']}').compareTo('${a['created_at']}'));
    return {
      'employee_id': employeeId,
      'organization_id': _scope()?.workspace.organizationId,
      'salary': salaries,
      'debts': debts,
      'balances': _balances(charges),
    };
  }

  List<Map<String, Object?>> _accounts = const [];

  /// Keeps the account names so a receipt can name the paying account.
  Future<void> _rememberAccounts() async {
    try {
      _accounts = await bankAccounts();
    } catch (_) {
      _accounts = const [];
    }
  }

  Future<Map<String, Object?>> salaryLedger(String employeeId) async {
    await _rememberAccounts();
    final view = _view(employeeId, await _ledgerView(employeeId));
    final last = (view['salary'] as List).whereType<Map>().firstOrNull;
    return {
      'organization_name': null,
      'base_salary': null,
      'base_currency':
          last?['currency'] ??
          (_accounts.isEmpty ? null : '${_accounts.first['currency']}'),
      'remaining_salary': null,
      'requires_historical_rate': true,
      'payments': view['salary'],
    };
  }

  Future<Map<String, Object?>> debtsLedger(String employeeId) async {
    await _rememberAccounts();
    final view = _view(employeeId, await _ledgerView(employeeId));
    return {
      'organization_name': null,
      'debts': view['debts'],
      'balances': view['balances'],
    };
  }

  Future<Map<String, Object?>> myFinance({String? employeeId}) async {
    if (employeeId == null) {
      // "My finance" for an account with no employee link has no device rows.
      return {'salary': [], 'debts': [], 'balances': <String, double>{}};
    }
    await _rememberAccounts();
    return _view(employeeId, await _ledgerView(employeeId));
  }

  Future<Map<String, Object?>> paySalary(
    String employeeId,
    Map<String, dynamic> body,
  ) async {
    await _rememberAccounts();
    final scope = _scope();
    final accountId = body['bank_account_id'];
    final currency = '${body['currency']}';
    final result = await _run(
      {BusinessLedgerAction.payEmployeeSalary},
      (ledger, access) => ledger.payEmployeeSalary(
        access,
        commandId: _commandId(body),
        employeeId: employeeId,
        amountMinor: _minor(body['amount']),
        currency: currency,
        accountId: accountId == null ? null : '$accountId',
        notes: body['notes'] == null ? null : '${body['notes']}',
        allowed: () => _selected(scope),
      ),
      branchId: body['branch_id'] as String?,
    );
    return {
      'id': result['receipt_id'],
      'operation_no': result['receipt_id'],
      'invoice_no': result['receipt_id'],
      'amount': _major(result['amount_minor']),
      'currency': result['currency'],
      'paid_at': result['paid_us'],
      'notes': result['notes'],
      'bank_name': result['bank_name'] ?? bankNameFor(accountId),
      'branch_name': null,
    };
  }

  Future<Map<String, Object?>> addDebt(
    String employeeId,
    Map<String, dynamic> body,
  ) async {
    await _rememberAccounts();
    final scope = _scope();
    final direction = '${body['direction'] ?? 'employee_owes'}';
    final notes = body['notes'] == null ? null : '${body['notes']}';
    final currency = '${body['currency']}';
    final paymentCurrency = '${body['payment_currency'] ?? body['currency']}';
    if (paymentCurrency != currency) {
      // The device ledger never converts: a debt settles in its own currency.
      throw const BusinessLedgerError(BusinessLedgerProblem.currencyMismatch);
    }
    final isSettlement = '${body['kind']}' == 'settlement';
    if (isSettlement) {
      final debtId = body['debt_id'];
      final result = await _run(
        {BusinessLedgerAction.settleEmployeeDebt},
        (ledger, access) => ledger.settleEmployeeDebt(
          access,
          commandId: _commandId(body),
          debtId: '$debtId',
          employeeId: employeeId,
          currency: currency,
          direction: body['direction'] as String?,
          notes: notes,
          amountMinor: _minor(body['amount']),
          accountId: body['bank_account_id'] == null
              ? null
              : '${body['bank_account_id']}',
          allowed: () => _selected(scope),
        ),
        branchId: body['branch_id'] as String?,
      );
      return {
        'id': result['receipt_id'],
        'invoice_no': result['receipt_id'],
        'direction': result['direction'],
        'kind': 'settlement',
        'debt_id': result['debt_id'],
        'original_debt_invoice': result['debt_id'],
        'amount': _major(result['amount_minor']),
        'remaining_amount': _major(result['after_minor']),
        'currency': result['currency'],
        'notes': notes,
        'created_at': result['settled_us'],
        'bank_name':
            result['bank_name'] ?? bankNameFor(body['bank_account_id']),
        'branch_name': null,
      };
    }
    final result = await _run(
      {BusinessLedgerAction.createEmployeeDebt},
      (ledger, access) => ledger.createEmployeeDebt(
        access,
        commandId: _commandId(body),
        employeeId: employeeId,
        amountMinor: _minor(body['amount']),
        currency: currency,
        direction: direction,
        note: notes,
        accountId: body['bank_account_id'] as String?,
        allowed: () => _selected(scope),
      ),
      branchId: body['branch_id'] as String?,
    );
    return {
      'id': result['receipt_id'],
      'invoice_no': result['receipt_id'],
      'direction': result['direction'],
      'kind': 'charge',
      'amount': _major(result['amount_minor']),
      'currency': result['currency'],
      'outstanding_amount': _major(result['remaining_minor']),
      'notes': result['note'],
      'created_at': result['created_us'],
      'bank_name': result['bank_name'] ?? bankNameFor(body['bank_account_id']),
      'branch_name': null,
    };
  }

  String? bankNameFor(Object? accountId) {
    if (accountId == null) return null;
    for (final account in _accounts) {
      if (account['id'] == accountId) return '${account['bank_name']}';
    }
    return null;
  }

  static String _commandId(Map<String, dynamic> body) {
    final key = body['idempotency_key'];
    if (key == null) return newCommandId();
    final id = '$key'.toLowerCase();
    if (isDirectoryId(id)) return id;
    // The connected form issues opaque keys; map each one deterministically
    // so a retry of the same submit stays the same command.
    return _uuid.v5(Uuid.NAMESPACE_URL, 'fyona.employee.local.command:$id');
  }
}
