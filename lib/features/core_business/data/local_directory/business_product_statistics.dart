part of 'directory_database.dart';

/// No live FX is used. A historic amount may only be converted with the
/// quote pinned to that line when it was issued. Missing cost/FX stays
/// unknown; a partial total is never presented as the full total.
extension BusinessProductStatistics on BusinessLedger {
  Future<Map<String, dynamic>> commerceProductStats(
    BusinessLedgerAccess access,
    String product, {
    String? from,
    String? to,
    String? displayCurrency,
    // The Falcon reads totals for every product: the movement list (the
    // costliest part) is for the statistics screen only.
    bool movements = true,
  }) {
    final branch = _branch(access, BusinessLedgerAction.readInventory);
    final showCost = access._actions.contains(
      BusinessLedgerAction.readInventoryCost,
    );
    final showProfit = access._actions.contains(
      BusinessLedgerAction.readInventoryProfit,
    );
    final since = from == null ? null : DateTime.parse(from);
    final through = to == null ? null : DateTime.parse(to);
    final until = through == null
        ? null
        : DateTime(through.year, through.month, through.day + 1);
    return _directory._transaction((txn) async {
      final card = (await txn.query(
        _commerceProducts,
        columns: ['cost_currency', 'name', 'unit', 'min_stock_4', 'is_service', 'image'],
        where: 'branch_id = ? AND id = ? AND deleted_us IS NULL',
        whereArgs: [branch, product],
      )).singleOrNull;
      if (card == null) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
      }
      // The stock on hand NOW (not limited to the chosen period), so the
      // statistics screen shows the quantity beside what was sold.
      final onHand = (await txn.query(
        _commerceStock,
        columns: ['quantity_milli'],
        where: 'branch_id = ? AND product_id = ?',
        whereArgs: [branch, product],
      )).singleOrNull;
      final currencies = [
        for (final row in await txn.query(
          _commercePrices,
          columns: ['currency'],
          where: 'branch_id = ? AND product_id = ?',
          whereArgs: [branch, product],
          orderBy: 'rowid',
        ))
          row['currency'] as String,
      ];
      final rows = await txn.rawQuery(
        '''
        SELECT l.*, i.invoice_type, i.currency
        FROM $_commerceLines l JOIN $_commerceInvoices i
          ON i.branch_id = l.branch_id AND i.id = l.invoice_id
        WHERE l.branch_id = ? AND l.product_id = ? AND i.deleted_us IS NULL
          AND i.status NOT IN ('draft', 'cancelled')
          ${from == null ? '' : 'AND i.date >= ?'}
          ${to == null ? '' : 'AND i.date <= ?'}
        ORDER BY i.date, i.created_us, i.id
      ''',
        [branch, product, ?from, ?to],
      );
      final selected = displayCurrency?.trim().toUpperCase();
      final display =
          selected != null &&
              (currencies.isEmpty || currencies.contains(selected))
          ? businessCurrency(selected)
          : currencies.firstOrNull ??
                rows.firstOrNull?['currency'] as String? ??
                card['cost_currency'] as String? ??
                'SAR';

      final salesIds = <Object?>{};
      final purchaseIds = <Object?>{};
      var saleQty = BigInt.zero;
      var buyQty = BigInt.zero;
      final sales = _StockStatTotal();
      final purchases = _StockStatTotal();
      final costs = _StockStatTotal();
      final profits = _StockStatTotal();
      for (final row in rows) {
        final money = row['currency'] as String;
        final price = row['price_currency'] as String?;
        final rate = row['exchange_rate'] as String?;
        final totalMinor = row['total_minor'] as int;
        final base = row['base_micro'] as int;
        void sum(_StockStatTotal target, int? amount) =>
            target.add(amount, money, display, price, rate);
        if (row['invoice_type'] == 'sale') {
          salesIds.add(row['invoice_id']);
          saleQty += BigInt.from(base);
          sum(sales, totalMinor);
          if (showCost || showProfit) {
            final cost =
                row['cost_total_minor'] as int? ??
                (row['is_service'] == 1
                    ? null
                    : await _commerceCapturedCost(
                        txn,
                        branch,
                        row['id'] as String,
                        money,
                        price,
                        rate,
                        base,
                      ));
            if (showCost) sum(costs, cost);
            if (showProfit) {
              sum(
                profits,
                row['profit_minor'] as int? ??
                    (cost == null ? null : totalMinor - cost),
              );
            }
          }
        } else {
          purchaseIds.add(row['invoice_id']);
          buyQty += BigInt.from(base);
          sum(purchases, totalMinor);
        }
      }
      return {
        'name': card['name'],
        'image': _deviceInventoryImage(card['image']),
        'unit': card['unit'],
        'is_service': card['is_service'] == 1,
        'stock': onHand == null
            ? 0
            : _commerceDecimal(onHand, 'quantity_milli', 1000),
        'min_stock': _commerceDecimal(card, 'min_stock_4', 10000),
        'display_currency': display,
        'priced_currencies': currencies,
        'fx_incomplete':
            sales.incomplete ||
            purchases.incomplete ||
            (showCost && costs.incomplete) ||
            (showProfit && profits.incomplete),
        'sales_total': sales.display,
        'sales_quantity': saleQty.toDouble() / 1000000,
        'sales_count': salesIds.length,
        'purchases_total': purchases.display,
        'purchases_quantity': buyQty.toDouble() / 1000000,
        'purchases_count': purchaseIds.length,
        'cogs': showCost ? costs.display : null,
        'profit': showProfit ? profits.display : null,
        'movements': movements
            ? await _productMovements(
                txn,
                branch,
                product,
                showCost: showCost,
                limit: 200,
                from: since,
                until: until,
              )
            : const [],
      };
    });
  }
}

final _statPrecision = BigInt.from(100000000);

BusinessRate? _frozenPriceQuote(String? price, String money, String? rate) {
  if (price == null || money == price || rate == null) return null;
  try {
    return BusinessRate(price, money, rate);
  } on FormatException {
    return null;
  }
}

final class _StockStatTotal {
  BigInt _precise = BigInt.zero;
  bool incomplete = false;

  void add(
    int? minor,
    String money,
    String target,
    String? price,
    String? rate,
  ) {
    if (minor == 0) return;
    final quote = _frozenPriceQuote(price, money, rate);
    if (minor == null || (money != target && quote?.from != target)) {
      incomplete = true;
      return;
    }
    final precise = BigInt.from(minor) * _statPrecision;
    _precise += money == target ? precise : quote!.originalScaled(precise);
  }

  String? get display => incomplete
      ? null
      : BusinessMoney.displayTotal(
          BusinessMoney.roundRatio(_precise, _statPrecision),
        );
}

Future<int?> _commerceCapturedCost(
  DatabaseExecutor db,
  String branch,
  String item,
  String money,
  String? price,
  String? rate,
  int expected, {
  bool outstandingOnly = false,
}) async {
  final rows = await db.query(
    _commerceConsumptions,
    where: 'branch_id = ? AND item_id = ?',
    whereArgs: [branch, item],
  );
  var quantity = 0;
  var precise = BigInt.zero;
  final quote = _frozenPriceQuote(price, money, rate);
  for (final row in rows) {
    final qty =
        (row['quantity_micro'] as int) -
        (outstandingOnly ? row['restored_micro'] as int : 0);
    if (qty == 0) continue;
    final currency = row['currency'] as String?;
    final cost4 = row['unit_cost_4'] as int;
    if (currency == null || (currency != money && quote?.from != currency)) {
      return null;
    }
    final cost = BigInt.from(cost4) * BigInt.from(qty);
    precise += currency == money ? cost : quote!.convertScaled(cost);
    quantity += qty;
  }
  return quantity != expected
      ? null
      : BusinessMoney.roundRatio(precise, _statPrecision).toInt();
}
