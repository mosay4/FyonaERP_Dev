part of 'directory_database.dart';

extension BusinessMoneyReport on BusinessLedger {
  Future<Set<String>> moneyReportCurrencies(BusinessLedgerAccess access) {
    final branch = _branch(access, BusinessLedgerAction.readMoneyReport);
    return _directory._read((db) async {
      final rows = await db.rawQuery(
        '''
        SELECT currency FROM ${BusinessLedger._accounts} WHERE branch_id = ?
          AND closed_us IS NULL AND is_active = 1
        UNION SELECT l.currency FROM ${BusinessLedger._legs} l WHERE l.branch_id = ?
          AND $_visibleBankLeg
      ''',
        [branch, branch],
      );
      return {
        for (final row in rows) businessCurrency(row['currency'] as String),
      };
    });
  }

  Future<Map<String, dynamic>> moneyReport(
    BusinessLedgerAccess access, {
    required String currency,
    String? from,
    String? to,
    String? accountId,
    BusinessReportFx fx = const BusinessReportFx.empty(),
  }) {
    final branch = _branch(access, BusinessLedgerAction.readMoneyReport);
    final target = businessCurrency(currency);
    final window = _SalesReportWindow(from, to);
    return _directory._transaction((txn) async {
      final accounts = await txn.query(
        BusinessLedger._accounts,
        where: 'branch_id = ? AND closed_us IS NULL AND is_active = 1',
        whereArgs: [branch],
        orderBy: 'bank_name, currency, account_type, created_us, id',
      );
      final active = {for (final row in accounts) row['id'] as String: row};
      if (accountId != null && !active.containsKey(accountId)) {
        throw const DirectoryAccessDenied();
      }
      final balances = _ReportAmounts(target, fx);
      for (final row in accounts) {
        balances.add(
          row['currency'] as String,
          BigInt.from(row['balance_minor'] as int),
        );
      }
      final branchFlows = _MoneyReportFlow(target, fx);
      final accountFlows = {
        for (final row in accounts)
          row['id'] as String: _MoneyReportFlow(row['currency'] as String, fx),
      };
      final scoped = accountId == null ? null : accountFlows[accountId]!;
      final legs = await txn.rawQuery(
        '''
        SELECT l.account_id, l.currency, l.kind, l.legacy, l.expense_category,
          l.delta_minor, l.created_us, t.side AS branch_side,
          COALESCE(orig.created_us, l.created_us) AS transfer_us,
          COALESCE(c.currency, json_extract(cmd.result, '\$.to_currency')) AS credit_currency,
          COALESCE(c.delta_minor, json_extract(cmd.result, '\$.credit_minor')) AS credit_minor
        FROM ${BusinessLedger._legs} l
        LEFT JOIN ${BusinessLedger._legs} c
          ON l.kind IN ('transfer_out', 'transfer_reversal_out')
            AND l.branch_id = c.branch_id AND l.command_id = c.command_id
            AND c.kind = REPLACE(l.kind, '_out', '_in') AND c.hidden = 0
        LEFT JOIN $_branchTransfers t ON t.branch_id = l.branch_id AND t.id = l.command_id
          AND t.kind = 'financial'
        LEFT JOIN $_branchTransfers orig ON orig.branch_id = t.branch_id AND orig.id = t.reversal_of
        LEFT JOIN ${BusinessLedger._commands} cmd
          ON cmd.branch_id = t.branch_id AND cmd.id = COALESCE(t.reversal_of, t.id)
        WHERE l.branch_id = ? AND $_visibleBankLeg
          AND (l.kind NOT IN ('deposit', 'withdrawal') OR l.legacy = 1 OR $_unreferencedBankLeg)
        ${window.where('l.created_us')}
      ''',
        [branch, ...window.args],
      );
      const historyGaps = false;
      var legacySettlements = false;
      for (final row in legs) {
        final flow = accountFlows[row['account_id']];
        final native = row['currency'] as String;
        final amount = BigInt.from(row['delta_minor'] as int);
        final legacy = row['legacy'] == 1;
        final when = row['created_us'] as int;
        switch (row['kind']) {
          case 'deposit':
          case 'withdrawal':
            final incoming = row['kind'] == 'deposit';
            final total = incoming ? branchFlows.inflow : branchFlows.outflow;
            final perAccount = incoming ? flow?.inflow : flow?.outflow;
            // Imported (legacy) bank legs are money that came in or went out
            // like any other: they count in the flows. They never carry an
            // expense category, so they are never promoted to an expense.
            total.add(native, amount.abs(), operationUs: when);
            perAccount?.add(native, amount.abs(), operationUs: when);
            final category = row['expense_category'];
            if (!incoming && category is String) {
              branchFlows.expense(native, category, amount.abs(), when);
              if (identical(flow, scoped)) {
                flow?.expense(native, category, amount.abs(), when);
              }
            }
          case 'transfer_out':
          case 'transfer_in':
          case 'transfer_reversal_out':
          case 'transfer_reversal_in':
            flow?.transfers.add(native, amount, operationUs: when);
            final sent = row['kind'] == 'transfer_out';
            final undo =
                row['kind'] == 'transfer_reversal_in' &&
                    row['branch_side'] == 'out' ||
                row['kind'] == 'transfer_reversal_out' &&
                    row['branch_side'] == null;
            if (!sent && !undo) continue;
            final sign = sent ? BigInt.one : -BigInt.one;
            final credit = row['credit_minor'], code = row['credit_currency'];
            branchFlows.transfers.add(
              native,
              amount.abs() * sign,
              operationUs: row['transfer_us'] as int,
              booked: code is String && credit is int && code != native
                  ? (code, BigInt.from(credit).abs() * sign)
                  : null,
            );
          case 'reconciliation_increase':
          case 'reconciliation_decrease':
            branchFlows.settlements.add(native, amount, operationUs: when);
            flow?.settlements.add(native, amount, operationUs: when);
            legacySettlements = legacySettlements || legacy;
        }
      }
      // Imported expense documents travel as archive facts. A related bank
      // leg is not used to infer their category, date or amount.
      final archived = await _reportArchivedExpenses(txn, branch, window);
      for (final expense in archived) {
        final native = _fixtureCurrency(expense['currency']);
        final category = _fixtureOptionalText(expense['category'])?.trim();
        final amount = BigInt.from(_fixtureMinor(expense['amount']));
        final when = _reportArchiveOperationUs(expense);
        branchFlows.expense(native, category, amount, when);
        if (scoped != null && expense['bank_account_id'] == accountId) {
          scoped.expense(native, category, amount, when);
        }
      }
      final archivedRecs = await txn.rawQuery(
        '''
        SELECT payload FROM $_reconciliationRecords
        WHERE branch_id = ? AND rtype = 'bank' AND status = 'approved'
        ORDER BY json_extract(payload, '\$.approved_at') DESC, id DESC
      ''',
        [branch],
      );
      final items = <Map<String, dynamic>>[];
      for (final row in archivedRecs) {
        final record = _reconciliationPayload(row);
        if (!_reportApprovalInWindow(record['approved_at'], window)) continue;
        final settlements = [
          for (final line in (record['settlements'] as List).cast<Map>())
            if (line['applied'] == true &&
                (accountId == null || line['account_id'] == accountId))
              line,
        ];
        if (settlements.isEmpty) continue;
        items.add({
          'id': record['id'],
          'ref_code': record['ref_code'],
          'approved_at': record['approved_at'],
          'settlements': settlements,
        });
      }
      final pending = await _reportHasPendingCash(txn, branch);
      final complete =
          balances.complete &&
          branchFlows.complete &&
          accountFlows.values.every((f) => f.complete);
      return {
        'report': 'money',
        'currency': target,
        'branch_ids': [branch],
        'local_valuation': 'as_recorded',
        'fx_basis': _reportFxBasis,
        'totals_complete': complete,
        'legacy_flow_unclassified': historyGaps,
        'legacy_settlements_unlinked': legacySettlements,
        'pending_shared_cash': pending,
        'inflow': branchFlows.inflow.payload(),
        'outflow': branchFlows.outflow.payload(),
        'transfers': branchFlows.transfers.payload(),
        'balances': {...balances.payload(), 'basis': 'current'},
        'expenses': branchFlows.expensesPayload(),
        'expense_scoped': scoped?.expensesPayload(),
        'accounts': [
          for (final row in accounts)
            {
              for (final key in [
                'id',
                'bank_name',
                'account_name',
                'account_type',
                'currency',
              ])
                key: row[key],
              'balance': BusinessMoney.display(row['balance_minor'] as int),
              for (final (key, amount) in accountFlows[row['id']]!.columns)
                key: amount.totalValue,
            },
        ],
        'settlements': {
          ...branchFlows.settlements.payload(),
          'count': items.length,
          'items': items,
        },
      };
    });
  }
}

Future<bool> _reportHasPendingCash(DatabaseExecutor db, String branch) async =>
    (await db.query(
      BusinessCashSync._queue,
      columns: ['account_id'],
      where: 'branch_id = ?',
      whereArgs: [branch],
      limit: 1,
    )).isNotEmpty;

Future<List<Map>> _reportArchivedExpenses(
  DatabaseExecutor db,
  String branch,
  _SalesReportWindow window,
) async {
  final rows = await db.query(
    'business_cutover_rows',
    columns: ['payload'],
    where: "branch_id = ? AND table_name = 'expenses'",
    whereArgs: [branch],
  );
  final expenses = <Map>[];
  for (final row in rows) {
    final expense = jsonDecode(row['payload'] as String) as Map;
    if (_fixtureBool(expense['is_deleted'])) continue;
    final date = DateTime.fromMicrosecondsSinceEpoch(
      _reportArchiveOperationUs(expense),
    );
    if (!window.includes(BusinessLedger._date(date))) {
      continue;
    }
    expenses.add(expense);
  }
  return expenses;
}

int _reportArchiveOperationUs(Map expense) =>
    _fixtureTime(expense['expense_date']);

final class _MoneyReportFlow {
  _MoneyReportFlow(this.target, this.fx)
    : inflow = _ReportAmounts(target, fx),
      outflow = _ReportAmounts(target, fx),
      transfers = _ReportAmounts(target, fx),
      settlements = _ReportAmounts(target, fx),
      expenses = _ReportAmounts(target, fx);
  final String target;
  final BusinessReportFx fx;
  final _ReportAmounts inflow, outflow, transfers, settlements, expenses;
  final categories = <String?, _ReportAmounts>{};

  List<(String, _ReportAmounts)> get columns => [
    ('inflow', inflow),
    ('outflow', outflow),
    ('transfers', transfers),
    ('settlements', settlements),
  ];
  bool get complete =>
      expenses.complete && columns.every((col) => col.$2.complete);

  void expense(String code, String? category, BigInt amount, int when) {
    expenses.add(code, amount, operationUs: when);
    categories
        .putIfAbsent(category, () => _ReportAmounts(target, fx))
        .add(code, amount, operationUs: when);
  }

  Map<String, dynamic> expensesPayload() {
    final ranked = categories.entries.toList()
      ..sort((a, b) {
        final byAmount = expenses.complete
            ? b.value.precise.compareTo(a.value.precise)
            : 0;
        return byAmount != 0 ? byAmount : (a.key ?? '').compareTo(b.key ?? '');
      });
    return {
      ...expenses.payload(),
      'currency': target,
      'categories': [
        for (final row in (expenses.complete ? ranked.take(6) : ranked))
          {'category': row.key, 'currency': target, ...row.value.payload()},
      ],
    };
  }
}
