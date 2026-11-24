part of 'directory_database.dart';

extension BusinessSalesReport on BusinessLedger {
  Future<Set<String>> salesReportCurrencies(BusinessLedgerAccess access) {
    final branch = _branch(access, BusinessLedgerAction.readSalesReport);
    return _directory._read(
      (db) async => {
        for (final row in await db.rawQuery(
          '''
        SELECT DISTINCT currency FROM $_commerceInvoices i
        WHERE branch_id = ? AND $_reportInvoicePosted
        ''',
          [branch],
        ))
          businessCurrency(row['currency'] as String),
      },
    );
  }

  Future<Map<String, dynamic>> salesReport(
    BusinessLedgerAccess access, {
    required String currency,
    String? from,
    String? to,
    BusinessReportFx fx = const BusinessReportFx.empty(),
  }) {
    final branch = _branch(access, BusinessLedgerAction.readSalesReport);
    final window = _SalesReportWindow(from, to);
    final target = businessCurrency(currency);
    final canReadProduct = access._actions.contains(
      BusinessLedgerAction.readInventory,
    );
    return _directory._transaction((db) async {
      final data = await _reportDocuments(
        db,
        branch,
        target,
        window,
        fx,
        detail: true,
        canReadProduct: canReadProduct,
        showProfit: access._actions.contains(
          BusinessLedgerAction.readInvoiceProfit,
        ),
      );
      return {
        'report': 'sales_purchases',
        'currency': target,
        'branch_ids': [branch],
        'local_valuation': 'as_recorded',
        'fx_basis': _reportFxBasis,
        'totals_complete': data.complete,
        'sales': data.sales.payload(),
        'purchases': data.purchases.payload(),
        'invoices': data.invoices,
        'top_products': data.topProducts,
        'products_ranked': data.productsComplete,
        'cost_of_sales': data.costOfSales?.payload(
          showNativeWhenIncomplete: false,
        ),
        'gross_profit': data.grossProfit?.payload(
          showNativeWhenIncomplete: false,
        ),
        'profit_cost_unknown': data.costOfSales?.unclassified == true,
      };
    });
  }

  /// Every indicator and comparison reads the same branch snapshot. A mixed
  /// or unsupported value only withholds its own total, not unrelated facts.
  Future<Map<String, dynamic>> overviewReport(
    BusinessLedgerAccess access, {
    required String currency,
    String? from,
    String? to,
    required bool home,
    DateTime? today,
    BusinessReportFx fx = const BusinessReportFx.empty(),
  }) {
    final branch = _branch(access, BusinessLedgerAction.readOverviewReport);
    final window = _SalesReportWindow(from, to);
    final target = businessCurrency(currency);
    final now = (today ?? DateTime.now()).toLocal();
    final compare = window.previous(now);
    final showProfit = access._actions.contains(
      BusinessLedgerAction.readInvoiceProfit,
    );
    final showCost = access._actions.contains(
      BusinessLedgerAction.readInventoryCost,
    );
    return _directory._transaction((db) async {
      final current = await _reportDocuments(
        db,
        branch,
        target,
        window,
        fx,
        showProfit: showProfit,
        purchases: !home,
      );
      final flow = await _overviewFlow(db, branch, target, window, fx);
      final profit = _reportProfit(current.grossProfit, flow);
      final previous = compare == null
          ? null
          : await _reportDocuments(
              db,
              branch,
              target,
              compare,
              fx,
              showProfit: showProfit,
              purchases: !home,
            );
      final prevFlow = compare == null
          ? null
          : await _overviewFlow(db, branch, target, compare, fx);
      final pastProfit = prevFlow == null
          ? null
          : _reportProfit(previous?.grossProfit, prevFlow);
      final sale = current.sales.total;
      final buy = current.purchases.total;
      final pastSale = previous?.sales.total;
      final pastBuy = previous?.purchases.total;
      final pastSpent = prevFlow?.expenses;
      final customers = _DebtReportParties(target, fx);
      final suppliers = _DebtReportParties(target, fx);
      for (final row in await _reportOpenDebts(
        db,
        branch,
        BusinessLedger._date(now),
      )) {
        (row['kind'] == 'customer' ? customers : suppliers).add(
          row['id'] as String,
          row['name'] as String,
          row['currency'] as String,
          BigInt.from(row['minor'] as int),
        );
      }
      Map<String, dynamic> stock = {};
      var completeStock = true;
      if (!home) {
        final stockValue = await _reportStockValuation(
          db,
          branch,
          target,
          showCost,
          fx,
        );
        final products = await db.rawQuery(
          '''
           SELECT p.id, p.min_stock_4 FROM $_commerceProducts p
          WHERE p.branch_id = ? AND p.deleted_us IS NULL
            AND p.is_active = 1 AND p.is_service = 0
          ''',
          [branch],
        );
        var out = 0, low = 0;
        for (final row in products) {
          final quantity = stockValue.quantities[row['id']] ?? BigInt.zero;
          if (quantity <= BigInt.zero) {
            out++;
          } else if (quantity <= _reportMinStock(row)) {
            low++;
          }
        }
        stock = {
          'products': products.length,
          'out_count': out,
          'low_count': low,
          ...stockValue.payload,
        };
        completeStock = stockValue.complete;
      }
      final sold = {...sale.payload(), 'count': current.sales.count};
      final comparison = {
        'sold_delta': _reportDelta(sale, pastSale),
        'prev_sold': pastSale?.totalValue,
        'purchases_delta': _reportDelta(buy, pastBuy),
        'prev_purchases': pastBuy?.totalValue,
        'spent_delta': _reportDelta(flow.expenses, pastSpent),
        'prev_spent': pastSpent?.totalValue,
        'profit_delta': profit == null
            ? null
            : _reportDelta(profit, pastProfit),
        'prev_profit': pastProfit?.totalValue,
      };
      final unclassified = flow.income.unclassified;
      return {
        'report': home ? 'home' : 'overview',
        'currency': target,
        'branch_ids': [branch],
        'local_valuation': 'as_recorded',
        'fx_basis': _reportFxBasis,
        'totals_complete':
            current.sales.net.complete &&
            sale.complete &&
            flow.income.complete &&
            flow.expenses.complete &&
            (profit?.complete ?? true) &&
            customers.total.complete &&
            (home ||
                (current.purchases.net.complete &&
                    buy.complete &&
                    suppliers.total.complete &&
                    completeStock)),
        'legacy_flow_unclassified': unclassified,
        'pending_shared_cash': await _reportHasPendingCash(db, branch),
        'profit_cost_unknown': current.costOfSales?.unclassified == true,
        'uncosted_stock': stock['uncosted_stock'],
        'comparison': comparison,
        'chart': current.sales.chart,
        if (home)
          'kpis': {
            'sold': sold,
            'profit': profit?.payload(showNativeWhenIncomplete: false),
            'income': flow.income.payload(),
            'spent': flow.expenses.payload(),
            'customer_debt': customers.payload(),
          }
        else ...{
          'sales': sold,
          'purchases': buy.payload(),
          'income': flow.income.payload(),
          'profit': profit?.payload(showNativeWhenIncomplete: false),
          'expenses': flow.expenses.payload(),
          'customer_debt': customers.payload(),
          'supplier_debt': suppliers.payload(),
          'inventory': stock,
        },
        'gross_sales': current.sales.gross.payload(),
        'sales_discounts': current.sales.discounts.payload(),
        'sales_returns': current.sales.returns.payload(),
        'net_sales': current.sales.net.payload(),
        'cost_of_sales': current.costOfSales?.payload(
          showNativeWhenIncomplete: false,
        ),
        'gross_profit': current.grossProfit?.payload(
          showNativeWhenIncomplete: false,
        ),
        'net_profit': profit?.payload(showNativeWhenIncomplete: false),
      };
    });
  }
}

const _reportPosted = "'confirmed','paid','partially_paid'";
const _reportInvoicePosted =
    'i.deleted_us IS NULL AND i.cancelled_us IS NULL AND i.status IN ($_reportPosted)';

final class _SalesReportWindow {
  _SalesReportWindow(String? from, String? to)
    : since = _at(_reportDay(from)),
      until = _next(_at(_reportDay(to))) {
    if (since != null && until != null && !since!.isBefore(until!)) {
      throw const FormatException('Invalid report period');
    }
  }

  _SalesReportWindow._(this.since, this.until);
  static DateTime? _at(String? day) => day == null ? null : DateTime.parse(day);
  static DateTime? _next(DateTime? day) =>
      day == null ? null : DateTime(day.year, day.month, day.day + 1);
  final DateTime? since, until;
  String? get start => since == null ? null : BusinessLedger._date(since!);
  String? get before => until == null ? null : BusinessLedger._date(until!);

  String where(String column) =>
      '''
    ${since == null ? '' : 'AND $column >= ?'}
    ${until == null ? '' : 'AND $column < ?'}
  ''';

  List<int> get args => [
    ?since?.microsecondsSinceEpoch,
    ?until?.microsecondsSinceEpoch,
  ];

  String dateWhere(String column) =>
      '''
    ${since == null ? '' : 'AND $column >= ?'}
    ${until == null ? '' : 'AND $column < ?'}
  ''';
  List<String> get dateArgs => [?start, ?before];

  bool includes(String date) =>
      (start == null || date.compareTo(start!) >= 0) &&
      (before == null || date.compareTo(before!) < 0);

  _SalesReportWindow? previous(DateTime now) {
    final start = since;
    final end = until ?? _next(now)!;
    if (start == null || !end.isAfter(start)) return null;
    final days = DateTime.utc(
      end.year,
      end.month,
      end.day,
    ).difference(DateTime.utc(start.year, start.month, start.day)).inDays;
    return _SalesReportWindow._(
      DateTime(start.year, start.month, start.day - days),
      start,
    );
  }
}

final class _SalesSection {
  _SalesSection(this.target, BusinessReportFx fx)
    : total = _ReportAmounts(target, fx),
      paid = _ReportAmounts(target, fx),
      balance = _ReportAmounts(target, fx),
      returns = _ReportAmounts(target, fx),
      gross = _ReportAmounts(target, fx),
      discounts = _ReportAmounts(target, fx),
      tax = _ReportAmounts(target, fx),
      net = _ReportAmounts(target, fx);
  final String target;
  final _ReportAmounts total,
      paid,
      balance,
      returns,
      gross,
      discounts,
      tax,
      net;
  final byDay = <String, _ReportAmounts>{};
  int count = 0, returnCount = 0;

  bool get complete =>
      total.complete && paid.complete && balance.complete && net.complete;
  List<Map<String, dynamic>> get chart => [
    for (final date in byDay.keys.toList()..sort())
      {'date': date, 'value': byDay[date]!.knownValue},
  ];

  Map<String, dynamic> payload() => {
    ...total.payload(),
    'count': count,
    'paid': paid.totalValue,
    'remaining': balance.totalValue,
    'paid_amounts': paid.payload(),
    'remaining_amounts': balance.payload(),
    'returns': {...returns.payload(), 'count': returnCount},
    'gross': gross.payload(),
    'discounts': discounts.payload(),
    'tax': tax.payload(),
    'net': net.payload(),
    'chart': chart,
  };
}

final class _SalesReportFacts {
  _SalesReportFacts(String target, BusinessReportFx fx, bool showProfit)
    : sales = _SalesSection(target, fx),
      purchases = _SalesSection(target, fx),
      costOfSales = showProfit ? _ReportAmounts(target, fx) : null;
  final _SalesSection sales, purchases;
  final _ReportAmounts? costOfSales;
  _ReportAmounts? get grossProfit {
    final cost = costOfSales;
    if (cost == null) return null;
    return _ReportAmounts(cost.currency, cost.fx)
      ..include(sales.net)
      ..include(cost, subtract: true);
  }

  final invoices = <Map<String, dynamic>>[];
  final topProducts = <Map<String, dynamic>>[];
  bool productsComplete = true;
  bool get complete =>
      sales.complete &&
      purchases.complete &&
      productsComplete &&
      (costOfSales?.complete ?? true);
}

Future<_SalesReportFacts> _reportDocuments(
  DatabaseExecutor db,
  String branch,
  String target,
  _SalesReportWindow window,
  BusinessReportFx fx, {
  bool detail = false,
  bool showProfit = false,
  bool canReadProduct = false,
  bool purchases = true,
}) async {
  final facts = _SalesReportFacts(target, fx, showProfit);
  final costs = facts.costOfSales;
  final invoicesWhere =
      '''
    i.branch_id = ? AND $_reportInvoicePosted
    ${window.dateWhere('i.date')} ${purchases ? '' : "AND i.invoice_type = 'sale'"}
  ''';
  final args = [branch, ...window.dateArgs];
  final lines = await db.rawQuery('''
    SELECT l.id, l.invoice_id, l.description, l.product_id, l.unit_name, l.quantity_micro,
      l.base_micro, l.is_service, l.total_minor, l.discount_minor, l.price_currency,
      l.exchange_rate, i.currency, i.date, i.created_us, i.invoice_type,
      ${detail ? 'p.unit, p.name, p.deleted_us' : 'NULL'}
    FROM $_commerceInvoices i JOIN $_commerceLines l
      ON l.branch_id = i.branch_id AND l.invoice_id = i.id
    ${detail ? 'LEFT JOIN $_commerceProducts p ON p.branch_id = l.branch_id AND p.id = l.product_id' : ''}
    WHERE $invoicesWhere
    ''', args);
  final invoiceLines = <String, List<_CommerceRow>>{};
  for (final line in lines) {
    (invoiceLines[line['invoice_id'] as String] ??= []).add(line);
  }
  final tender = detail
      ? await _reportInvoiceTender(db, invoicesWhere, args)
      : null;

  for (final row in await db.rawQuery('''
    SELECT i.id, i.invoice_type, i.currency, i.created_us, i.date, i.total_minor,
      i.subtotal_minor, i.discount_minor, i.tax_minor, i.paid_minor, i.balance_minor,
      ${detail ? 'i.number, i.status, p.name AS party' : 'NULL'}
    FROM $_commerceInvoices i
    ${detail ? '''
      LEFT JOIN ${DirectoryDatabase._table} p
        ON p.branch_id = i.branch_id AND p.kind = i.party_kind AND p.id = i.party_id
      ''' : ''}
    WHERE $invoicesWhere
    ORDER BY i.date DESC, i.created_us DESC, i.id DESC
    ''', args)) {
    final sale = row['invoice_type'] == 'sale';
    final section = sale ? facts.sales : facts.purchases;
    final code = row['currency'] as String;
    final total = BigInt.from(row['total_minor'] as int);
    final paid = BigInt.from(row['paid_minor'] as int);
    final balance = BigInt.from(row['balance_minor'] as int);
    final date = row['date'] as String;
    final at = _reportOperationUs(row);
    final daily = section.byDay.putIfAbsent(
      date,
      () => _ReportAmounts(target, fx),
    );
    final items = invoiceLines[row['id']] ?? const [];
    if (sale && items.isEmpty && total != BigInt.zero)
      costs?.unclassified = true;
    section.count++;
    final tax = BigInt.from(row['tax_minor'] as int);
    final discount = BigInt.from(row['discount_minor'] as int);
    final subtotal = BigInt.from(row['subtotal_minor'] as int);
    final sameQuote = _reportUniformQuote(code, items);
    var lineSum = BigInt.zero;
    final doc = _ReportAmounts(target, fx);
    for (final line in items) {
      final amount = BigInt.from(line['total_minor'] as int);
      final lineDiscount = BigInt.from(line['discount_minor'] as int);
      final quote = _reportLineQuote(line, code);
      doc.add(code, amount, operationUs: at, frozen: quote);
      section.gross.add(
        code,
        amount + lineDiscount,
        operationUs: at,
        frozen: quote,
      );
      section.discounts.add(code, lineDiscount, operationUs: at, frozen: quote);
      lineSum += amount;
    }
    if (lineSum != subtotal || subtotal - discount + tax != total) {
      // Not all imported invoices have a documented per-line decomposition.
      // The header remains authoritative; never blend mismatched amounts.
      section.gross.unclassified = true;
      section.discounts.unclassified = true;
      section.net.add(code, total - tax, operationUs: at);
      section.total.add(code, total, operationUs: at);
      daily.add(code, total, operationUs: at);
    } else {
      section.discounts.add(code, discount, operationUs: at, frozen: sameQuote);
      doc.add(code, -discount, operationUs: at, frozen: sameQuote);
      section.net.include(doc);
      doc.add(code, tax, operationUs: at, frozen: sameQuote);
      section.total.include(doc);
      daily.include(doc);
    }
    section.tax.add(code, tax, operationUs: at, frozen: sameQuote);
    if (tender != null) {
      _reportPaid(section.paid, code, paid, tender[row['id']] ?? const []);
    }
    // Open amounts are valued now, independent of the sale and tender rates.
    section.balance.add(code, balance);
    if (detail && facts.invoices.length < 40) {
      facts.invoices.add({
        'id': row['id'],
        'number': row['number'],
        'kind': row['invoice_type'],
        'party': row['party'],
        'currency': code,
        'total': BusinessMoney.displayTotal(total),
        'paid': BusinessMoney.displayTotal(paid),
        'balance': BusinessMoney.displayTotal(balance),
        'status': row['status'],
        'date': date,
      });
    }
  }
  if (detail) {
    final products = <(String?, String, String?), _SalesProduct>{};
    for (final row in lines.where((row) => row['invoice_type'] == 'sale')) {
      final code = row['currency'] as String;
      final lineTotal = BigInt.from(row['total_minor'] as int);
      final base = row['base_micro'] as int;
      final id = row['product_id'] as String?;
      final physical = row['is_service'] == 0;
      final unit = (physical ? row['unit'] : row['unit_name']) as String?;
      final name = (row['name'] ?? row['description']) as String;
      final product = products.putIfAbsent(
        (id, name, unit),
        () => _SalesProduct(
          target,
          fx,
          name,
          unit,
          canReadProduct && row['deleted_us'] == null ? id : null,
        ),
      );
      product.qty += BigInt.from(
        physical ? base : row['quantity_micro'] as int,
      );
      product.amount.add(
        code,
        lineTotal,
        operationUs: _reportOperationUs(row),
        frozen: _reportLineQuote(row, code),
      );
    }
    facts.productsComplete = products.values.every((p) => p.amount.complete);
    final sorted = products.values.toList()
      ..sort((a, b) {
        final order = facts.productsComplete
            ? b.amount.precise.compareTo(a.amount.precise)
            : 0;
        return order != 0 ? order : a.name.compareTo(b.name);
      });
    // Fetch thumbnails for the preview only, and never call a remote image
    // URL while rendering a device report.
    final preview = sorted.take(8).toList();
    final ids = {
      for (final p in preview)
        if (p.id != null) p.id!,
    };
    final images = ids.isEmpty
        ? <String, String>{}
        : {
            for (final row in await db.query(
              _commerceProducts,
              columns: ['id', 'image'],
              where:
                  'branch_id = ? AND id IN (${List.filled(ids.length, '?').join(',')})',
              whereArgs: [branch, ...ids],
            ))
              if (_deviceInventoryImage(row['image']) != null)
                row['id'] as String: row['image'] as String,
          };
    facts.topProducts.addAll(preview.map((p) => p.payload(images[p.id])));
  }
  final returnedLines = <String, List<_CommerceRow>>{};
  final returnsWhere =
      '''
    r.branch_id = ? AND r.status = 'confirmed' AND $_reportInvoicePosted
    ${window.dateWhere('r.date')} ${purchases ? '' : "AND r.invoice_type = 'sale'"}
  ''';
  for (final row in await db.rawQuery('''
    SELECT r.id, t.total_minor, l.price_currency, l.exchange_rate
    FROM $_commerceReturns r JOIN $_commerceInvoices i
      ON i.branch_id = r.branch_id AND i.id = r.invoice_id
    JOIN $_commerceReturnLines t ON t.branch_id = r.branch_id AND t.return_id = r.id
    JOIN $_commerceLines l ON l.branch_id = t.branch_id AND l.id = t.item_id
    WHERE $returnsWhere
  ''', args)) {
    (returnedLines[row['id'] as String] ??= []).add(row);
  }
  for (final row in await db.rawQuery('''
      SELECT r.id, r.invoice_type, i.currency, r.total_minor, r.date, r.created_us
      FROM $_commerceReturns r JOIN $_commerceInvoices i
        ON i.branch_id = r.branch_id AND i.id = r.invoice_id AND i.invoice_type = r.invoice_type
      WHERE $returnsWhere
      ''', args)) {
    final sale = row['invoice_type'] == 'sale';
    final section = sale ? facts.sales : facts.purchases;
    final code = row['currency'] as String;
    section.returnCount++;
    final at = _reportOperationUs(row);
    final total = BigInt.from(row['total_minor'] as int);
    final parts = returnedLines[row['id']] ?? const [];
    if (parts.fold(
          BigInt.zero,
          (sum, l) => sum + BigInt.from(l['total_minor'] as int),
        ) ==
        total) {
      for (final line in parts) {
        section.returns.add(
          code,
          BigInt.from(line['total_minor'] as int),
          operationUs: at,
          frozen: _reportLineQuote(line, code),
        );
      }
    } else {
      section.returns.add(code, total, operationUs: at);
      if (sale) costs?.unclassified = true;
    }
  }
  facts.sales.net.include(facts.sales.returns, subtract: true);
  facts.purchases.net.include(facts.purchases.returns, subtract: true);
  if (costs != null) await _reportSaleCosts(db, branch, window, costs);
  return facts;
}

/// Validate the invoice's *net* paid amount against allocated receipts and
/// independently posted refunds. Never reuse a product/issue FX quote here.
Future<Map<String, List<_CommerceRow>>> _reportInvoiceTender(
  DatabaseExecutor db,
  String invoicesWhere,
  List<Object?> args,
) async {
  final rows = await db.rawQuery('''
    WITH selected AS (
      SELECT i.id, i.branch_id FROM $_commerceInvoices i WHERE $invoicesWhere
    )
    SELECT p.invoice_id, p.applied_minor AS posted_minor, p.payment_currency,
      p.original_minor, p.date, p.created_us
    FROM $_commercePayments p JOIN selected i
      ON i.branch_id = p.branch_id AND i.id = p.invoice_id
    UNION ALL
    SELECT r.invoice_id, -json_extract(c.result, '\$.refunded_minor'), l.currency,
      -ABS(l.delta_minor), r.date, r.created_us
    FROM $_commerceReturns r JOIN selected i
      ON i.branch_id = r.branch_id AND i.id = r.invoice_id
    JOIN ${BusinessLedger._legs} l ON l.branch_id = r.branch_id AND l.reference = r.number
    JOIN ${BusinessLedger._commands} c ON c.branch_id = l.branch_id AND c.id = l.command_id
    WHERE r.status = 'confirmed' AND $_visibleBankLeg
      AND json_extract(c.result, '\$.id') = r.id
      AND json_extract(c.result, '\$.refund_account_id') = l.account_id
      AND json_extract(c.result, '\$.refunded_minor') > 0
    ''', args);
  final grouped = <String, List<_CommerceRow>>{};
  for (final row in rows) {
    (grouped[row['invoice_id'] as String] ??= []).add(row);
  }
  return grouped;
}

void _reportPaid(
  _ReportAmounts bucket,
  String code,
  BigInt paid,
  List<_CommerceRow> tender,
) {
  if (bucket.currency == code || paid == BigInt.zero) {
    bucket.add(code, paid);
    return;
  }
  if (tender.fold(
        BigInt.zero,
        (sum, row) => sum + BigInt.from(row['posted_minor'] as int),
      ) !=
      paid) {
    bucket.addUnvalued(code, paid);
    return;
  }
  for (final row in tender) {
    final payment = row['payment_currency'] as String;
    bucket.add(
      code,
      BigInt.from(row['posted_minor'] as int),
      operationUs: _reportOperationUs(row),
      booked: (payment, BigInt.from(row['original_minor'] as int)),
    );
  }
}

BusinessRate? _reportLineQuote(_CommerceRow row, String code) =>
    _frozenPriceQuote(
      row['price_currency'] as String?,
      code,
      row['exchange_rate'] as String?,
    );

BusinessRate? _reportUniformQuote(String code, List<_CommerceRow> items) {
  BusinessRate? same;
  for (final row in items) {
    if (row['total_minor'] == 0) continue;
    final quote = _reportLineQuote(row, code);
    if (quote == null ||
        same != null &&
            (quote.from != same.from || quote.decimal != same.decimal)) {
      return null;
    }
    same = quote;
  }
  return same;
}

final class _SalesProduct {
  _SalesProduct(
    String currency,
    BusinessReportFx fx,
    this.name,
    this.unit,
    this.id,
  ) : amount = _ReportAmounts(currency, fx);
  final String name;
  final String? unit, id;
  final _ReportAmounts amount;
  BigInt qty = BigInt.zero;
  Map<String, dynamic> payload(String? image) => {
    ...amount.payload(),
    'name': name,
    'unit': unit,
    'product_id': id,
    'image': image,
    'qty': _reportQuantity(qty),
  };
}

Future<({_ReportAmounts income, _ReportAmounts expenses})> _overviewFlow(
  DatabaseExecutor db,
  String branch,
  String currency,
  _SalesReportWindow window,
  BusinessReportFx fx,
) async {
  final income = _ReportAmounts(currency, fx),
      expenses = _ReportAmounts(currency, fx);
  final rows = await db.rawQuery(
    '''
    SELECT l.currency, l.kind, l.legacy, l.created_us, l.delta_minor AS amount
    FROM ${BusinessLedger._legs} l
    WHERE l.branch_id = ? AND $_visibleBankLeg
      AND (l.kind = 'deposit' OR (l.kind = 'withdrawal' AND l.expense_category IS NOT NULL))
      AND (l.legacy = 1 OR $_unreferencedBankLeg) ${window.where('l.created_us')}
    ''',
    [branch, ...window.args],
  );
  for (final row in rows) {
    if (row['legacy'] == 1) {
      // An imported deposit with no type might be an invoice payment.
      if (row['kind'] == 'deposit') income.unclassified = true;
      continue;
    }
    (row['kind'] == 'deposit' ? income : expenses).add(
      row['currency'] as String,
      BigInt.from(row['amount'] as int).abs(),
      operationUs: row['created_us'] as int,
    );
  }
  for (final row in await _reportArchivedExpenses(db, branch, window)) {
    expenses.add(
      _fixtureCurrency(row['currency']),
      BigInt.from(_fixtureMinor(row['amount'])),
      operationUs: _reportArchiveOperationUs(row),
    );
  }
  return (income: income, expenses: expenses);
}

_ReportAmounts? _reportProfit(
  _ReportAmounts? margin,
  ({_ReportAmounts income, _ReportAmounts expenses}) flow,
) {
  if (margin == null) return null;
  return _ReportAmounts(margin.currency, margin.fx)
    ..include(margin)
    ..include(flow.income)
    ..include(flow.expenses, subtract: true);
}

String? _reportDelta(_ReportAmounts current, _ReportAmounts? previous) =>
    current.complete && previous?.complete == true
    ? BusinessMoney.displayTotal(
        _reportMinor(current.precise - previous!.precise),
      )
    : null;
