part of 'directory_database.dart';

// A bank leg is not another sale/return. Deposit and withdrawal with a
// document reference stay on the bank statement, not in either mixed list.
const _unreferencedBankLeg = "NULLIF(TRIM(l.reference), '') IS NULL";
const _visibleBankLeg =
    '''
  l.hidden = 0 AND NOT EXISTS (
    SELECT 1 FROM ${BusinessCashSync._decisions} d
    WHERE d.branch_id = l.branch_id AND d.command_id = l.command_id
      AND d.decision <> 'accepted'
  )
''';

extension BusinessOperations on BusinessLedger {
  Future<List<Map<String, dynamic>>> operations(
    BusinessLedgerAccess access, {
    required Set<String> allowedKinds,
    String? kind,
    String? search,
    String? period,
    String? dateFrom,
    String? dateTo,
    String? sourceType,
    String? sourceId,
    int limit = 100,
  }) {
    final branch = _branch(access, BusinessLedgerAction.readOperations);
    final kinds = allowedKinds
        .where(
          (k) => switch (kind) {
            null || '' => true,
            'expense' => k == 'expense' || k == 'bank_withdrawal',
            'inout' => const {
              'income',
              'expense',
              'bank_withdrawal',
            }.contains(k),
            'return' => k == 'sale_return' || k == 'purchase_return',
            'payment' => k == 'collection' || k == 'supplier_payment',
            'transfer' => k == 'transfer' || k == 'transfer_reversal',
            _ => k == kind,
          },
        )
        .toList();
    if (kinds.isEmpty) return Future.value(const []);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final since = dateFrom != null
        ? DateTime.parse(dateFrom)
        : switch (period) {
            'today' => today,
            'week' => DateTime(today.year, today.month, today.day - 7),
            'month' => DateTime(today.year, today.month, today.day - 30),
            _ => null,
          };
    final through = dateTo != null ? DateTime.parse(dateTo) : null;
    final until = through == null
        ? null
        : DateTime(through.year, through.month, through.day + 1);
    final needle = search?.trim().toLowerCase() ?? '';
    return _directory._read((db) async {
      final rows = await db.rawQuery(
        '''
        WITH selected(branch_id) AS (VALUES (?)), ops
          (source_type, source_id, kind, direction, amount_minor, currency, created_us,
            party, party_id, notes, ref, status, account, invoice_id, created_by, transfer, reconciliation_id)
        AS (
          SELECT 'invoice', i.id, i.invoice_type, CASE i.invoice_type WHEN 'sale' THEN 'in' ELSE 'out' END,
            i.total_minor, i.currency, i.created_us, p.name, p.id, i.notes, i.number, i.status,
            NULL, i.id, i.created_by, NULL, NULL
          FROM $_commerceInvoices i JOIN selected USING (branch_id)
          LEFT JOIN ${DirectoryDatabase._table} p ON p.branch_id = i.branch_id
            AND p.kind = i.party_kind AND p.id = i.party_id
          WHERE i.deleted_us IS NULL AND i.status NOT IN ('draft', 'cancelled')
          UNION ALL
          SELECT r.invoice_type || '_return', r.id, r.invoice_type || '_return',
            CASE r.invoice_type WHEN 'sale' THEN 'out' ELSE 'in' END,
            r.total_minor, i.currency, r.created_us, p.name, p.id, r.reason, r.number,
            r.status, NULL, r.invoice_id, r.created_by, NULL, NULL
          FROM $_commerceReturns r JOIN selected USING (branch_id)
          JOIN $_commerceInvoices i ON i.branch_id = r.branch_id AND i.id = r.invoice_id
          LEFT JOIN ${DirectoryDatabase._table} p ON p.branch_id = i.branch_id
            AND p.kind = i.party_kind AND p.id = i.party_id
          WHERE r.status = 'confirmed' AND i.deleted_us IS NULL
          UNION ALL
          SELECT 'opening_debt', d.id, CASE d.kind WHEN 'customer' THEN 'sale' ELSE 'purchase' END,
            CASE d.kind WHEN 'customer' THEN 'in' ELSE 'out' END,
            d.total_minor, d.currency, d.created_us, p.name, p.id, NULL, d.number,
            CASE WHEN d.paid_minor >= d.total_minor THEN 'paid'
              WHEN d.paid_minor > 0 THEN 'partial' ELSE 'open' END,
            NULL, d.id, NULL, NULL, NULL
          FROM ${BusinessLedger._debts} d JOIN selected USING (branch_id)
          JOIN ${DirectoryDatabase._table} p ON p.branch_id = d.branch_id AND p.kind = d.kind AND p.id = d.party_id
          WHERE d.cancelled_us IS NULL
          UNION ALL
          SELECT CASE WHEN l.kind = 'transfer_out' AND t.command_id IS NOT NULL THEN 'transfer'
                WHEN l.expense_category IS NOT NULL AND l.kind = 'withdrawal' THEN 'expense'
                ELSE 'bank_tx' END,
            l.command_id,
            CASE l.kind
              WHEN 'deposit' THEN 'income'
              WHEN 'withdrawal' THEN CASE WHEN l.expense_category IS NULL THEN 'bank_withdrawal' ELSE 'expense' END
              WHEN 'customer_collection' THEN 'collection'
              WHEN 'supplier_payment' THEN 'supplier_payment'
              WHEN 'withdrawal_reversal' THEN 'withdrawal_reversal'
              WHEN 'transfer_out' THEN 'transfer'
              WHEN 'transfer_in' THEN 'transfer'
              WHEN 'transfer_reversal_out' THEN 'transfer_reversal'
              WHEN 'transfer_reversal_in' THEN 'transfer_reversal'
              WHEN 'opening_balance' THEN 'opening'
              WHEN 'reconciliation_increase' THEN 'reconciliation'
              WHEN 'reconciliation_decrease' THEN 'reconciliation'
            END,
            CASE WHEN l.delta_minor > 0 THEN 'in' ELSE 'out' END,
            ABS(l.delta_minor), l.currency, l.created_us, l.expense_category, NULL, l.description, l.reference,
            NULL, a.bank_name, NULL, NULL,
            CASE WHEN t.command_id IS NOT NULL THEN
              json_object('from_account', a.bank_name, 'from_amount', ABS(l.delta_minor) / 100.0,
                'from_currency', l.currency, 'to_account', b.bank_name, 'to_amount', t.delta_minor / 100.0,
                 'to_currency', t.currency, 'rate', l.fx_rate) END,
             CASE WHEN l.kind IN ('reconciliation_increase', 'reconciliation_decrease')
               THEN json_extract(cmd.result, '\$.reconciliation_id') END
           FROM ${BusinessLedger._legs} l JOIN selected USING (branch_id)
           JOIN ${BusinessLedger._accounts} a ON a.branch_id = l.branch_id AND a.id = l.account_id
           LEFT JOIN ${BusinessLedger._commands} cmd ON cmd.branch_id = l.branch_id AND cmd.id = l.command_id
          LEFT JOIN ${BusinessLedger._legs} t ON l.kind = 'transfer_out'
            AND t.branch_id = l.branch_id AND t.command_id = l.command_id
            AND t.kind = 'transfer_in' AND t.hidden = 0
          LEFT JOIN ${BusinessLedger._accounts} b ON b.branch_id = t.branch_id AND b.id = t.account_id
          WHERE $_visibleBankLeg
          AND (l.kind NOT IN ('deposit', 'withdrawal') OR $_unreferencedBankLeg)
          AND NOT (l.kind IN ('transfer_in', 'transfer_reversal_in') AND EXISTS (
            SELECT 1 FROM ${BusinessLedger._legs} debit WHERE debit.branch_id = l.branch_id
              AND debit.command_id = l.command_id
              AND debit.kind = REPLACE(l.kind, '_in', '_out') AND debit.hidden = 0
          ))
        )
        SELECT * FROM ops WHERE kind IN (${List.filled(kinds.length, '?').join(',')})
          ${sourceId == null ? '' : 'AND source_type = ? AND source_id = ?'}
          ${since == null ? '' : 'AND created_us >= ?'}
          ${until == null ? '' : 'AND created_us < ?'}
          ${needle.isEmpty ? '' : '''
            AND (INSTR(LOWER(COALESCE(ref, '')), ?) > 0
              OR INSTR(LOWER(COALESCE(party, '')), ?) > 0
              OR INSTR(LOWER(COALESCE(account, '')), ?) > 0
              OR INSTR(LOWER(COALESCE(notes, '')), ?) > 0
              OR INSTR(printf('%.2f', amount_minor / 100.0), ?) > 0)
          '''}
        ORDER BY created_us DESC, source_type, source_id DESC LIMIT ?
      ''',
        [
          branch,
          ...kinds,
          if (sourceId != null) ...[sourceType, sourceId],
          ?since?.microsecondsSinceEpoch,
          ?until?.microsecondsSinceEpoch,
          if (needle.isNotEmpty) ...List.filled(5, needle),
          limit.clamp(1, 100),
        ],
      );
      return [
        for (final row in rows)
          {
            for (final key in [
              'source_type',
              'source_id',
              'kind',
              'direction',
              'currency',
              'party',
              'party_id',
              'notes',
              'status',
              'account',
              'invoice_id',
             'created_by',
             'reconciliation_id',
            ])
              key: row[key],
            'branch_id': branch,
            'date': _commerceDate(row['created_us']),
            'reference': row['ref'],
            'amount': _commerceDecimal(row, 'amount_minor', 100),
            if (row['transfer'] != null)
              'transfer': jsonDecode(row['transfer'] as String),
          },
      ];
    });
  }
}
