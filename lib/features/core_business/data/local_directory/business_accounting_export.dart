part of 'directory_database.dart';

/// Columns of every sheet of the accounting export (stable keys; the file
/// writer turns them into AR / EN headers). Money is a decimal string with
/// two places, quantities a decimal string, dates `YYYY-MM-DD`.
const businessExportSheets = <String, List<String>>{
  'opening_accounts': [
    'account_id', 'bank', 'account_name', 'account_number', 'iban', 'currency',
    'balance_cutoff', 'balance_now',
  ],
  'opening_parties': [
    'party_id', 'kind', 'name', 'phone', 'email', 'currency', 'balance_cutoff', 'open_documents',
  ],
  'opening_stock': [
    'product_id', 'name', 'sku', 'barcode', 'unit', 'quantity_cutoff', 'quantity_now',
    'avg_cost', 'value_cutoff', 'image_file',
  ],
  'documents': [
    'document_id', 'source', 'type', 'number', 'date', 'party_kind', 'party_id', 'party_name',
    'currency', 'total', 'paid_cutoff', 'remaining_cutoff', 'remaining_now', 'status_cutoff', 'warning',
  ],
  'document_lines': [
    'document_id', 'number', 'date', 'line_id', 'product_id', 'description', 'unit', 'quantity',
    'unit_price', 'discount', 'tax_rate', 'total',
  ],
  'payments': [
    'payment_id', 'document_id', 'number', 'date', 'account_id', 'method', 'payment_currency',
    'original', 'applied', 'debt_currency', 'exchange_rate',
  ],
  'returns': ['return_id', 'document_id', 'number', 'date', 'total'],
  'bank_movements': [
    'account_id', 'date_time', 'kind', 'description', 'delta', 'balance_after', 'reference',
  ],
};

/// Numeric columns (written as numbers in Excel).
const businessExportNumeric = {
  'balance_cutoff', 'balance_now', 'open_documents', 'quantity_cutoff', 'quantity_now', 'avg_cost',
  'value_cutoff', 'total', 'paid_cutoff', 'remaining_cutoff', 'remaining_now', 'quantity',
  'unit_price', 'discount', 'tax_rate', 'original', 'applied', 'delta', 'balance_after',
};

typedef BusinessExportEmit = Future<void> Function(String sheet, List<Object?> row);

/// What the export proved about itself (goes into the manifest).
final class BusinessExportResult {
  BusinessExportResult(this.cutoff, this.asOfUs);
  final String cutoff;
  final int asOfUs;
  final rows = <String, int>{};

  /// Control totals per currency: receivables, payables, bank, stock value.
  final controls = <String, Map<String, BigInt>>{};
  final warnings = <String>[];

  /// Product images: media ref → file name inside the export.
  final images = <String, String>{};

  void _control(String name, String currency, BigInt minor) {
    final c = controls.putIfAbsent(name, () => {});
    c[currency] = (c[currency] ?? BigInt.zero) + minor;
  }

  Map<String, Object?> toJson() => {
        'cutoff': cutoff,
        'as_of_us': asOfUs,
        'rows': rows,
        'controls': {
          for (final e in controls.entries)
            e.key: {for (final c in e.value.entries) c.key: BusinessMoney.displayTotal(c.value)},
        },
        'warnings': warnings,
      };
}

String _exportMinor(int? minor) => minor == null ? '' : BusinessMoney.display(minor);
String _exportBig(BigInt minor) => BusinessMoney.displayTotal(minor);
String _exportScaled(int? value, int places) {
  if (value == null) return '';
  final scale = BigInt.from(10).pow(places);
  final v = BigInt.from(value), m = v.abs();
  final frac = (m % scale).toString().padLeft(places, '0').replaceFirst(RegExp(r'0+$'), '');
  return '${v.isNegative ? '-' : ''}${m ~/ scale}${frac.isEmpty ? '' : '.$frac'}';
}

/// Read-only accounting export of ONE branch at a cut-off day.
///
/// Nothing here writes to the ledger and no new accounting rule is made:
/// every figure is anchored on the value the app itself shows today, and a
/// balance at a past day = today's value with the effect of every later
/// event taken back (payments, returns, bank legs, stock movements dated
/// after the cut-off). At a cut-off of today the export therefore equals the
/// app's own reports exactly (tested). Documents changed after the cut-off
/// in a way the history cannot take back (an edit or deletion) are listed
/// as warnings in the manifest instead of being guessed.
extension BusinessAccountingExport on BusinessLedger {
  Future<BusinessExportResult> exportAccounting(
    BusinessLedgerAccess access, {
    required DateTime cutoff,
    required BusinessExportEmit emit,
    String Function(String ref, String productId)? imageName,
    int pageSize = 2000,
  }) async {
    final branch = _branch(access, BusinessLedgerAction.readDebt);
    _branch(access, BusinessLedgerAction.readBank);
    final day = BusinessLedger._date(cutoff);
    final endUs = DateTime(cutoff.year, cutoff.month, cutoff.day + 1).microsecondsSinceEpoch - 1;
    // One moment for the whole export: rows written while it runs are not
    // half included (they are after `asOf` and simply left out).
    final asOf = DateTime.now().toUtc().microsecondsSinceEpoch;
    final out = BusinessExportResult(day, asOf);
    Future<void> put(String sheet, List<Object?> row) async {
      out.rows[sheet] = (out.rows[sheet] ?? 0) + 1;
      await emit(sheet, row);
    }

    for (final s in businessExportSheets.keys) {
      out.rows[s] = 0;
    }
    Future<List<Map<String, Object?>>> q(String sql, [List<Object?> args = const []]) =>
        _directory._read((db) => db.rawQuery(sql, args));

    // ---- Bank accounts: balance now − legs after the cut-off.
    for (final a in await q(
        'SELECT * FROM ${BusinessLedger._accounts} WHERE branch_id = ? AND created_us <= ? ORDER BY created_us, id',
        [branch, endUs])) {
      final after = (await q(
              'SELECT COALESCE(SUM(delta_minor), 0) AS s FROM ${BusinessLedger._legs} '
              'WHERE branch_id = ? AND account_id = ? AND created_us > ?',
              [branch, a['id'], endUs]))
          .first['s'] as int;
      final now = a['balance_minor'] as int;
      final at = now - after;
      out._control('bank', '${a['currency']}', BigInt.from(at));
      await put('opening_accounts', [
        a['id'], a['bank_name'], a['account_name'], a['account_number'], a['iban'], a['currency'],
        _exportMinor(at), _exportMinor(now),
      ]);
    }
    // ---- Bank movements up to the cut-off (paged by sequence).
    var seq = -1;
    while (true) {
      final rows = await q(
          'SELECT sequence, account_id, created_us, kind, description, delta_minor, balance_minor, command_id '
          'FROM ${BusinessLedger._legs} WHERE branch_id = ? AND created_us <= ? AND sequence > ? '
          'ORDER BY sequence LIMIT $pageSize',
          [branch, endUs, seq]);
      for (final r in rows) {
        await put('bank_movements', [
          r['account_id'],
          DateTime.fromMicrosecondsSinceEpoch(r['created_us'] as int).toIso8601String(),
          r['kind'], r['description'], _exportMinor(r['delta_minor'] as int?),
          _exportMinor(r['balance_minor'] as int?), r['command_id'],
        ]);
        seq = r['sequence'] as int;
      }
      if (rows.length < pageSize) break;
    }

    // ---- Documents (ledger debts + commerce invoices) and their history.
    final parties = <String, Map<String, Object?>?>{};
    final balances = <String, BigInt>{}; // party|currency
    final open = <String, int>{};
    Future<Map<String, Object?>?> party(String kind, Object? id) async {
      if (id == null) return null;
      final k = '$kind|$id';
      if (parties.containsKey(k)) return parties[k];
      return parties[k] = (await q(
              'SELECT id, kind, name, phone, email FROM ${DirectoryDatabase._table} WHERE branch_id = ? AND kind = ? AND id = ?',
              [branch, kind, id]))
          .singleOrNull;
    }

    Future<void> document({
      required String source, required String type, required Map<String, Object?> d, required String kind,
      required int total, required int remainingNow, required int remainingAt, String warning = '',
    }) async {
      final p = await party(kind, d['party_id']);
      final currency = '${d['currency']}';
      if (p != null && remainingAt > 0) {
        final k = '$kind|${p['id']}|$currency';
        balances[k] = (balances[k] ?? BigInt.zero) + BigInt.from(remainingAt);
        open[k] = (open[k] ?? 0) + 1;
      }
      if (warning.isNotEmpty) out.warnings.add('${d['number']}: $warning');
      final paidAt = total - remainingAt;
      await put('documents', [
        d['id'], source, type, d['number'], d['date'], kind, d['party_id'], p?['name'], currency,
        _exportMinor(total), _exportMinor(paidAt < 0 ? 0 : paidAt), _exportMinor(remainingAt),
        _exportMinor(remainingNow),
        remainingAt == 0 ? 'paid' : (paidAt > 0 ? 'partial' : 'open'), warning,
      ]);
    }

    // Ledger debts (opening balances and ordinary debts outside commerce).
    var after = '';
    while (true) {
      final rows = await q(
          "SELECT id, kind, party_id, invoice_date AS date, number, currency, total_minor, paid_minor, created_us, cancelled_us "
          'FROM ${BusinessLedger._debts} WHERE branch_id = ? AND invoice_date <= ? AND created_us <= ? AND id > ? '
          'ORDER BY id LIMIT $pageSize',
          [branch, day, asOf, after]);
      if (rows.isEmpty) break;
      final ids = [for (final r in rows) r['id']];
      final marks = List.filled(ids.length, '?').join(',');
      final pays = await q(
          'SELECT * FROM ${BusinessLedger._paymentHistory} WHERE branch_id = ? AND invoice_id IN ($marks) '
          'ORDER BY date, created_us, id',
          [branch, ...ids]);
      final edits = {
        for (final r in await q(
            'SELECT DISTINCT invoice_id FROM business_opening_debt_edits WHERE branch_id = ? AND invoice_id IN ($marks) '
            'AND created_us > ?',
            [branch, ...ids, endUs]))
          r['invoice_id'],
      };
      final byDoc = <Object?, List<Map<String, Object?>>>{};
      for (final p in pays) {
        byDoc.putIfAbsent(p['invoice_id'], () => []).add(p);
      }
      for (final d in rows) {
        after = '${d['id']}';
        final cancelled = d['cancelled_us'] as int?;
        if (cancelled != null && cancelled <= endUs) continue; // gone before the cut-off
        final total = d['total_minor'] as int, paid = d['paid_minor'] as int;
        final now = cancelled != null ? 0 : max(0, total - paid);
        var later = 0;
        for (final p in byDoc[d['id']] ?? const <Map<String, Object?>>[]) {
          final date = '${p['date']}';
          if (date.compareTo(day) <= 0) {
            await put('payments', [
              p['id'], d['id'], d['number'], date, p['account_id'], p['method'], p['payment_currency'],
              _exportMinor(p['original_minor'] as int?), _exportMinor(p['applied_minor'] as int?),
              p['debt_currency'], p['exchange_rate'],
            ]);
          } else {
            later += p['applied_minor'] as int;
          }
        }
        // Cancelled after the cut-off: it was owed at the cut-off.
        final at = cancelled != null ? max(0, total - (paid - later)) : min(total, now + later);
        await document(source: 'ledger', type: 'opening', d: d, kind: '${d['kind']}', total: total,
            remainingNow: now, remainingAt: at,
            warning: [
              if (edits.contains(d['id'])) 'edited_after_cutoff',
              if (cancelled != null) 'cancelled_after_cutoff',
            ].join(' '));
      }
    }

    // Commerce invoices (sales / purchases) that the app counts as posted.
    after = '';
    while (true) {
      final rows = await q(
          'SELECT * FROM $_commerceInvoices i WHERE i.branch_id = ? AND i.date <= ? AND i.created_us <= ? AND i.id > ? '
          "AND i.status <> 'draft' AND (i.deleted_us IS NULL OR i.deleted_us > ?) "
          'ORDER BY i.id LIMIT $pageSize',
          [branch, day, asOf, after, endUs]);
      if (rows.isEmpty) break;
      final ids = [for (final r in rows) r['id']];
      final marks = List.filled(ids.length, '?').join(',');
      final pays = await q(
          'SELECT * FROM $_commercePayments WHERE branch_id = ? AND invoice_id IN ($marks) ORDER BY date, created_us, id',
          [branch, ...ids]);
      final rets = await q(
          "SELECT * FROM $_commerceReturns WHERE branch_id = ? AND invoice_id IN ($marks) AND status = 'confirmed' "
          'ORDER BY date, created_us, id',
          [branch, ...ids]);
      final edited = {
        for (final r in await q(
            'SELECT DISTINCT invoice_id FROM $_commerceEdits WHERE branch_id = ? AND invoice_id IN ($marks) AND created_us > ?',
            [branch, ...ids, endUs]))
          r['invoice_id'],
      };
      final lines = await q(
          'SELECT * FROM $_commerceLines WHERE branch_id = ? AND invoice_id IN ($marks) ORDER BY invoice_id, rowid',
          [branch, ...ids]);
      final pByDoc = <Object?, List<Map<String, Object?>>>{};
      for (final p in pays) {
        pByDoc.putIfAbsent(p['invoice_id'], () => []).add(p);
      }
      final rByDoc = <Object?, List<Map<String, Object?>>>{};
      for (final r in rets) {
        rByDoc.putIfAbsent(r['invoice_id'], () => []).add(r);
      }
      final lByDoc = <Object?, List<Map<String, Object?>>>{};
      for (final l in lines) {
        lByDoc.putIfAbsent(l['invoice_id'], () => []).add(l);
      }
      for (final d in rows) {
        after = '${d['id']}';
        final cancelled = d['cancelled_us'] as int?;
        if (d['status'] == 'cancelled' && (cancelled == null || cancelled <= endUs)) continue;
        final purchase = d['invoice_type'] == 'purchase';
        final kind = purchase ? 'supplier' : 'customer';
        final total = d['total_minor'] as int;
        final deleted = d['deleted_us'] != null;
        final now = deleted || d['status'] == 'cancelled' ? 0 : d['balance_minor'] as int;
        // Replay in time order: payments reduce the balance; a return first
        // reduces the balance, the rest is refunded (same rule as the app).
        final events = <(String, int, int, Map<String, Object?>, bool)>[
          for (final p in pByDoc[d['id']] ?? const <Map<String, Object?>>[])
            ('${p['date']}', p['created_us'] as int, p['applied_minor'] as int, p, true),
          for (final r in rByDoc[d['id']] ?? const <Map<String, Object?>>[])
            ('${r['date']}', r['created_us'] as int, r['total_minor'] as int, r, false),
        ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
        var bal = total, at = total;
        for (final e in events) {
          final effect = e.$5 ? e.$3 : min(e.$3, bal);
          bal = max(0, bal - effect);
          if (e.$1.compareTo(day) <= 0) {
            at = bal;
            if (e.$5) {
              final p = e.$4;
              await put('payments', [
                p['id'], d['id'], d['number'], e.$1, p['account_id'], p['method'], p['payment_currency'],
                _exportMinor(p['original_minor'] as int?), _exportMinor(p['applied_minor'] as int?),
                p['debt_currency'], p['exchange_rate'],
              ]);
            } else {
              await put('returns', [e.$4['id'], d['id'], e.$4['number'], e.$1, _exportMinor(e.$3)]);
            }
          }
        }
        final warn = <String>[
          if (edited.contains(d['id'])) 'edited_after_cutoff',
          if (deleted) 'deleted_after_cutoff',
          if (d['status'] == 'cancelled') 'cancelled_after_cutoff',
        ];
        if (!deleted && d['status'] != 'cancelled' && bal != now) {
          // History does not explain today's balance (e.g. an edit): stay on
          // the app's value and take back only what is dated later.
          var later = 0;
          for (final e in events) {
            if (e.$1.compareTo(day) > 0 && e.$5) later += e.$3;
          }
          at = min(total, now + later);
          warn.add('history_mismatch');
        }
        await document(source: 'commerce', type: '${d['invoice_type']}', d: d, kind: kind, total: total,
            remainingNow: now, remainingAt: at, warning: warn.join(' '));
        for (final l in lByDoc[d['id']] ?? const <Map<String, Object?>>[]) {
          await put('document_lines', [
            d['id'], d['number'], d['date'], l['id'], l['product_id'], l['description'], l['unit_name'],
            _exportScaled(l['quantity_micro'] as int?, 6), _exportMinor(l['unit_minor'] as int?),
            _exportMinor(l['discount_minor'] as int?), _exportScaled(l['tax_rate_2'] as int?, 2),
            _exportMinor(l['total_minor'] as int?),
          ]);
        }
      }
    }

    // ---- Opening balances per party and currency.
    final keys = balances.keys.toList()..sort();
    for (final k in keys) {
      final parts = k.split('|');
      final p = parties['${parts[0]}|${parts[1]}']!;
      out._control(parts[0] == 'customer' ? 'receivable' : 'payable', parts[2], balances[k]!);
      await put('opening_parties', [
        p['id'], parts[0], p['name'], p['phone'], p['email'], parts[2], _exportBig(balances[k]!), open[k],
      ]);
    }

    // ---- Stock at the cut-off: today's quantity − movements after it.
    after = '';
    while (true) {
      final rows = await q(
          'SELECT p.id, p.name, p.sku, p.barcode, p.unit, p.image, p.cost_currency, s.quantity_milli, s.avg_cost_4 '
          'FROM $_commerceProducts p LEFT JOIN $_commerceStock s ON s.branch_id = p.branch_id AND s.product_id = p.id '
          'WHERE p.branch_id = ? AND p.is_service = 0 AND p.created_us <= ? AND p.deleted_us IS NULL AND p.id > ? '
          'ORDER BY p.id LIMIT $pageSize',
          [branch, endUs, after]);
      if (rows.isEmpty) break;
      final ids = [for (final r in rows) r['id']];
      final marks = List.filled(ids.length, '?').join(',');
      final later = {
        for (final r in await q(
            'SELECT product_id, SUM(quantity_micro) AS s FROM $_commerceMovements WHERE branch_id = ? '
            'AND product_id IN ($marks) AND created_us > ? GROUP BY product_id',
            [branch, ...ids, endUs]))
          r['product_id']: r['s'] as int,
      };
      for (final r in rows) {
        after = '${r['id']}';
        final nowMicro = ((r['quantity_milli'] as int?) ?? 0) * 1000;
        final atMicro = nowMicro - (later[r['id']] ?? 0);
        final avg = (r['avg_cost_4'] as int?) ?? 0;
        // value: (micro / 10⁶) × (avg / 10⁴) units = micro × avg / 10⁸ minor.
        final raw = BigInt.from(atMicro) * BigInt.from(avg);
        final half = BigInt.from(50000000) * BigInt.from(raw.isNegative ? -1 : 1);
        final value = (raw + half) ~/ BigInt.from(100000000);
        final image = '${r['image'] ?? ''}';
        var file = '';
        if (image.startsWith('media:')) {
          file = out.images.putIfAbsent(image, () => imageName?.call(image, '${r['id']}') ?? 'images/${r['id']}');
        }
        out._control('stock_value', '${r['cost_currency'] ?? ''}', value);
        await put('opening_stock', [
          r['id'], r['name'], r['sku'], r['barcode'], r['unit'], _exportScaled(atMicro, 6), _exportScaled(nowMicro, 6),
          _exportScaled(avg, 4), _exportBig(value), file,
        ]);
      }
    }
    return out;
  }
}
