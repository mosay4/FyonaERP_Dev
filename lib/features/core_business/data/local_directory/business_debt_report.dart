part of 'directory_database.dart';

extension BusinessDebtReport on BusinessLedger {
  Future<Set<String>> debtReportCurrencies(BusinessLedgerAccess access) {
    final branch = _branch(access, BusinessLedgerAction.readDebtReport);
    return _directory._read((db) async {
      final rows = await db.rawQuery(
        '''
        SELECT currency FROM ${BusinessLedger._debts} WHERE branch_id = ? AND cancelled_us IS NULL
        UNION SELECT currency FROM $_commerceInvoices WHERE branch_id = ? AND deleted_us IS NULL
        UNION SELECT payment_currency FROM ${BusinessLedger._paymentHistory} WHERE branch_id = ?
        UNION SELECT payment_currency FROM $_commercePayments WHERE branch_id = ?
      ''',
        [branch, branch, branch, branch],
      );
      return {
        for (final row in rows) businessCurrency(row['currency'] as String),
      };
    });
  }

  /// Outstanding debt is current (as in the connected report); collections
  /// use the selected period and the amounts frozen at posting. A third
  /// currency requires a documented observation at the payment date.
  Future<Map<String, dynamic>> debtReport(
    BusinessLedgerAccess access, {
    required String currency,
    String? from,
    String? to,
    DateTime? today,
    BusinessReportFx fx = const BusinessReportFx.empty(),
  }) {
    final branch = _branch(access, BusinessLedgerAction.readDebtReport);
    final target = businessCurrency(currency);
    final start = _reportDay(from), end = _reportDay(to);
    if (start != null && end != null && start.compareTo(end) > 0) {
      throw const FormatException('Invalid report period');
    }
    final cutoff = BusinessLedger._date(today ?? DateTime.now());
    return _directory._transaction((txn) async {
      final debts = await _reportOpenDebts(txn, branch, cutoff);

      const payments =
          '''
        WITH payment_rows AS (
          SELECT i.branch_id, i.kind, i.party_id, i.id AS invoice_id,
            p.id AS payment_id, p.date, p.created_us, p.payment_currency,
            p.debt_currency, p.original_minor, p.applied_minor
          FROM ${BusinessLedger._paymentHistory} p JOIN ${BusinessLedger._debts} i
            ON i.branch_id = p.branch_id AND i.id = p.invoice_id
          WHERE p.branch_id = ? AND i.cancelled_us IS NULL
            AND (p.command_id IS NULL OR EXISTS (
              SELECT 1 FROM ${BusinessLedger._legs} l
              WHERE l.branch_id = p.branch_id AND l.command_id = p.command_id
                AND l.account_id = p.account_id AND $_visibleBankLeg
            ))
          UNION ALL
          SELECT i.branch_id, i.party_kind, i.party_id, i.id, p.id, p.date,
            p.created_us, p.payment_currency, p.debt_currency,
            p.original_minor, p.applied_minor
          FROM $_commercePayments p JOIN $_commerceInvoices i
            ON i.branch_id = p.branch_id AND i.id = p.invoice_id
          WHERE p.branch_id = ? AND $_reportInvoicePosted
        )
      ''';
      final paid = await txn.rawQuery(
        '''
        $payments
        SELECT kind, date, created_us, payment_currency, debt_currency,
          original_minor, applied_minor
        FROM payment_rows WHERE 1 = 1
        ${start == null ? '' : 'AND date >= ?'}
        ${end == null ? '' : 'AND date <= ?'}
      ''',
        [branch, branch, ?start, ?end],
      );
      final recent = await txn.rawQuery(
        '''
        $payments
        SELECT m.kind, m.date, m.payment_currency, m.original_minor, p.name AS party
        FROM payment_rows m LEFT JOIN ${DirectoryDatabase._table} p
          ON p.branch_id = m.branch_id AND p.kind = m.kind AND p.id = m.party_id
        WHERE 1 = 1
          ${start == null ? '' : 'AND m.date >= ?'}
          ${end == null ? '' : 'AND m.date <= ?'}
        ORDER BY m.date DESC, m.created_us DESC, m.payment_id DESC, m.invoice_id DESC
        LIMIT 8
      ''',
        [branch, branch, ?start, ?end],
      );

      final customers = _DebtReportParties(target, fx),
          suppliers = _DebtReportParties(target, fx);
      final overdue = _ReportAmounts(target, fx);
      var pastDue = 0;
      for (final row in debts) {
        final code = row['currency'] as String;
        final value = BigInt.from(row['minor'] as int);
        (row['kind'] == 'customer' ? customers : suppliers).add(
          row['id'] as String,
          row['name'] as String,
          code,
          value,
        );
        final past = row['overdue_minor'] as int;
        if (past != 0) overdue.add(code, BigInt.from(past));
        pastDue += row['overdue_count'] as int;
      }
      final collected = _ReportAmounts(target, fx),
          paidSuppliers = _ReportAmounts(target, fx);
      for (final row in paid) {
        final code = row['payment_currency'] as String;
        final amount = BigInt.from(row['original_minor'] as int);
        final applied = BigInt.from(row['applied_minor'] as int);
        final debt = row['debt_currency'] as String;
        (row['kind'] == 'customer' ? collected : paidSuppliers).add(
          code,
          amount,
          operationUs: _reportOperationUs(row),
          booked: code == debt ? null : (debt, applied),
        );
      }
      final complete = ![
        customers.total,
        suppliers.total,
        collected,
        paidSuppliers,
        overdue,
      ].any((bucket) => !bucket.complete);
      return {
        'report': 'debts',
        'currency': target,
        'local_valuation': 'as_recorded',
        'fx_basis': _reportFxBasis,
        'totals_complete': complete,
        'branch_ids': [branch],
        'customers': customers.payload(),
        'suppliers': suppliers.payload(),
        'collected': collected.payload(),
        'paid_to_suppliers': paidSuppliers.payload(),
        'overdue': {...overdue.payload(), 'count': pastDue},
        'recent_movements': [
          for (final row in recent)
            {
              'party': row['party'],
              'kind': row['kind'],
              'date': row['date'],
              'currency': row['payment_currency'],
              'amount': BusinessMoney.displayTotal(
                BigInt.from(row['original_minor'] as int) *
                    BigInt.from(row['kind'] == 'supplier' ? -1 : 1),
              ),
            },
        ],
      };
    });
  }
}

Future<List<_CommerceRow>> _reportOpenDebts(
  DatabaseExecutor db,
  String branch,
  String cutoff,
) => db.rawQuery(
  '''
  WITH debts AS (
    SELECT branch_id, kind, party_id, currency, NULL AS due_date,
           (total_minor - paid_minor) AS open_minor
    FROM ${BusinessLedger._debts} WHERE branch_id = ? AND cancelled_us IS NULL
    UNION ALL
    SELECT branch_id, party_kind, party_id, currency, due_date, balance_minor
    FROM $_commerceInvoices i WHERE branch_id = ? AND $_reportInvoicePosted
      AND party_id IS NOT NULL
  )
  SELECT d.kind, p.id, p.name, d.currency, SUM(d.open_minor) AS minor,
    SUM(CASE WHEN d.kind = 'customer' AND d.due_date < ? THEN 1 ELSE 0 END) AS overdue_count,
    SUM(CASE WHEN d.kind = 'customer' AND d.due_date < ? THEN d.open_minor ELSE 0 END) AS overdue_minor
  FROM debts d JOIN ${DirectoryDatabase._table} p
    ON p.branch_id = d.branch_id AND p.kind = d.kind AND p.id = d.party_id
  WHERE d.open_minor > 0
  GROUP BY d.kind, p.id, p.name, d.currency
  ''',
  [branch, branch, cutoff, cutoff],
);

String? _reportDay(String? value) {
  if (value == null || value.isEmpty) return null;
  final day = DateTime.tryParse(value);
  if (day == null || day.toIso8601String().split('T').first != value) {
    throw const FormatException('Invalid report day');
  }
  return value;
}

const _reportFxBasis = {
  'operations': 'frozen_or_documented',
  'balances': 'latest_approved',
};

List<Map<String, Object?>> _nativeAmounts(Map<String, BigInt> amounts) => [
  for (final code in amounts.keys.toList()..sort())
    {'currency': code, 'total': BusinessMoney.displayTotal(amounts[code]!)},
];

int _reportOperationUs(_CommerceRow row) {
  final posted = row['created_us'] as int;
  final day = row['date'] as String?;
  if (day == null) return posted;
  final date = DateTime.parse(day);
  final end =
      DateTime(date.year, date.month, date.day + 1).microsecondsSinceEpoch - 1;
  return min(posted, end);
}

// An accumulator keeps eight fractional digits of a minor unit until the
// published total. Lot quantities (10^-6) times unit costs (10^-4) already
// have this scale in minor units.
BigInt _reportMinor(BigInt scaled) =>
    BusinessMoney.roundRatio(scaled, _statPrecision);

final class _ReportAmounts {
  _ReportAmounts(this.currency, this.fx);
  final String currency;
  final BusinessReportFx fx;
  final native = <String, BigInt>{};
  final missing = <String>{};
  BigInt precise = BigInt.zero;
  bool unclassified = false;

  bool get complete => !unclassified && missing.isEmpty;
  String? get totalValue =>
      complete ? BusinessMoney.displayTotal(_reportMinor(precise)) : null;

  void add(
    String code,
    BigInt amount, {
    int? operationUs,
    BusinessRate? frozen,
    (String, BigInt)? booked,
  }) => addPrecise(
    code,
    amount * _statPrecision,
    operationUs: operationUs,
    frozen: frozen,
    booked: booked == null ? null : (booked.$1, booked.$2 * _statPrecision),
  );

  void addPrecise(
    String code,
    BigInt amount, {
    int? operationUs,
    BusinessRate? frozen,
    (String, BigInt)? booked,
  }) {
    if (amount == BigInt.zero && (booked?.$2 ?? BigInt.zero) == BigInt.zero)
      return;
    native.update(code, (total) => total + amount, ifAbsent: () => amount);
    final match = code == currency
        ? amount
        : booked != null && booked.$1 == currency
        ? booked.$2
        : (booked == null
                  ? null
                  : fx.convert(
                      booked.$2,
                      booked.$1,
                      currency,
                      operationUs: operationUs,
                    )) ??
              fx.convert(
                amount,
                code,
                currency,
                operationUs: operationUs,
                frozen: frozen,
              );
    if (match == null) {
      missing.add(code);
    } else {
      precise += match;
    }
  }

  /// Compose valuations, not their native amounts: mixing historical rates
  /// by currency after the fact loses the frozen observations.
  void include(_ReportAmounts other, {bool subtract = false}) {
    assert(other.currency == currency);
    unclassified = unclassified || other.unclassified;
    missing.addAll(other.missing);
    precise += subtract ? -other.precise : other.precise;
    for (final entry in other.native.entries) {
      final value = subtract ? -entry.value : entry.value;
      native.update(entry.key, (sum) => sum + value, ifAbsent: () => value);
    }
  }

  void addUnvalued(String code, BigInt amount) {
    if (code == currency) {
      add(code, amount);
    } else if (amount != BigInt.zero) {
      missing.add(code);
      native.update(
        code,
        (sum) => sum + amount * _statPrecision,
        ifAbsent: () => amount * _statPrecision,
      );
    }
  }

  List<Map<String, Object?>> get originalAmounts => _nativeAmounts(
    native.map((code, value) => MapEntry(code, _reportMinor(value))),
  );

  Map<String, dynamic> payload({bool showNativeWhenIncomplete = true}) => {
    'total': totalValue,
    'per_currency': unclassified || !complete && !showNativeWhenIncomplete
        ? []
        : originalAmounts,
    'gaps': [
      for (final code in missing.toList()..sort()) {'currency': code},
    ],
  };
}

final class _DebtReportParties {
  _DebtReportParties(this.currency, this.fx)
    : total = _ReportAmounts(currency, fx);
  final String currency;
  final BusinessReportFx fx;
  final _ReportAmounts total;
  final parties = <String, ({String name, _ReportAmounts amounts})>{};

  void add(String id, String name, String code, BigInt value) {
    total.add(code, value);
    final party = parties.putIfAbsent(
      id,
      () => (name: name, amounts: _ReportAmounts(currency, fx)),
    );
    party.amounts.add(code, value);
  }

  Map<String, dynamic> payload() {
    final ranked = parties.entries.toList()
      ..sort((a, b) {
        final byCurrency = total.complete
            ? b.value.amounts.precise.compareTo(a.value.amounts.precise)
            : 0;
        if (byCurrency != 0) return byCurrency;
        final byName = a.value.name.compareTo(b.value.name);
        return byName != 0 ? byName : a.key.compareTo(b.key);
      });
    return {
      ...total.payload(),
      'count': parties.length,
      'top': [
        for (final row in ranked.take(10))
          {'name': row.value.name, 'debts': row.value.amounts.originalAmounts},
      ],
    };
  }
}
