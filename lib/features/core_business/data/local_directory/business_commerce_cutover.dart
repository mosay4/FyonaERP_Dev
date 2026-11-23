part of 'directory_database.dart';

/// Rehearse a single branch's commerce history alongside its banks and opening
/// debts. The receipt proves this projection only. It cannot start a writer.
extension BusinessCutoverFixtureCommerce on DirectoryDatabase {
  Future<BusinessCutoverReceipt> projectFixtureCommerce(
    DirectoryAccess access,
    BusinessCutoverReceipt expected, {
    bool live = false,
  }) {
    BusinessCutoverFixtureArchive(this)._checkFixture(access, live: live);
    final branch = access.branchId;
    return _transaction((txn) async {
      _requireFixture(
        await BusinessCutoverFixtureArchive._receipt(txn, branch) == expected,
      );
      final prior = await _projectionReceipt(txn, _commerceReceipts, branch);
      if (prior != null) {
        _requireFixture(prior == expected);
        return expected;
      }
      // A prior opening-only import may already have new payments. Never
      // merge its current balances with amounts from the frozen snapshot.
      _requireFixture(
        await _projectionReceipt(txn, _openingProjectionReceipts, branch) ==
            null,
      );
      await BusinessCutoverFixtureOpeningLedger._projectOpeningLedger(
        txn,
        access,
        expected,
      );
      await _CommerceProjection(txn, branch, expected).write();
      await _saveProjectionReceipt(txn, _commerceReceipts, branch, expected);
      return expected;
    }, exclusive: true);
  }
}

typedef _CommerceRow = Map<String, Object?>;

final class _CommerceProjection {
  _CommerceProjection(this.txn, this.branch, this.receipt);

  final Transaction txn;
  final String branch;
  final BusinessCutoverReceipt receipt;
  final products = <String, _CommerceRow>{};
  final units = <String, _CommerceRow>{};
  final invoices = <String, _CommerceRow>{};
  final lines = <String, _CommerceRow>{};
  final returns = <String, _CommerceRow>{};
  final lots = <String, _CommerceRow>{};
  final returnedQuantities = <String, int>{};
  final invoiceProducts = <(String, String)>{};
  final returnProducts = <(String, String)>{};

  Future<List<_CommerceRow>> _source(String table) =>
      BusinessCutoverFixtureArchive._sourceRows(txn, branch, table);

  Future<List<_CommerceRow>> _operational(String table, List<String> columns) =>
      txn.query(
        table,
        columns: columns,
        where: 'branch_id = ?',
        whereArgs: [branch],
      );

  _CommerceRow _row(_CommerceRow source) => {
    'branch_id': branch,
    'id': _fixtureId(source['id']),
  };

  void _checkUnit(String? id, String? product) {
    _requireFixture(
      id == null || (product != null && units[id]?['product_id'] == product),
    );
  }

  Future<void> write() async {
    final branchRow = (await _source('branches')).single;
    _requireFixture(branchRow['id'] == branch);
    final hasCatalogue = branchRow['device_catalogue'] == true;
    final allInvoices = await _source('invoices');
    final openingIds = {
      for (final row in allInvoices)
        if (_fixtureText(row['invoice_number']).startsWith('OPEN-'))
          _fixtureId(row['id']),
    };
    bool ordinary(_CommerceRow row) =>
        !openingIds.contains(_fixtureId(row['invoice_id']));
    final accounts = {
      for (final row in await _operational(BusinessLedger._accounts, [
        'id',
        'currency',
      ]))
        row['id'] as String: row['currency'] as String,
    };
    final parties = {
      for (final row in await _operational(DirectoryDatabase._table, [
        'id',
        'kind',
      ]))
        (row['kind'], row['id']),
    };
    final groups = {
      for (final row in await _operational(DirectoryDatabase._groupTable, [
        'id',
        'kind',
        'party_id',
      ]))
        row['id']: (row['kind'], row['party_id']),
    };

    final catalogue = {
      for (final source in await _source('product_categories'))
        _fixtureId(source['id']): {
          ..._row(source),
          'name': _fixtureText(source['name']),
          'image': _fixtureInventoryImage(source).$1,
          'active': _fixtureFlag(source['is_active']),
        },
    };
    final warehouse = await _source('warehouse_settings');
    final expiry = warehouse.singleOrNull;
    final warnDays = expiry?['expiry_warn_days'];
    _requireFixture(
      warehouse.isEmpty ||
          (expiry != null &&
              warnDays is int &&
              warnDays >= 1 &&
              warnDays <= 365),
    );
    final links = <_CommerceRow>[];
    final categoryIds = <String>{};
    for (final source in await _source('products')) {
      _requireFixture(source['branch_id'] == branch);
      final category = _fixtureOptionalId(source['category_id']);
      if (category != null) {
        _requireFixture(catalogue.containsKey(category));
        categoryIds.add(category);
        links.add({..._row(source), 'category_id': category});
      }
      products[_fixtureId(source['id'])] = {
        ..._row(source),
        'name': _fixtureText(source['name']),
        for (final key in [
          'name_ar',
          'sku',
          'barcode',
          'description',
          'unit',
          'notes',
        ])
          key: _fixtureOptionalText(source[key]),
        'image': hasCatalogue ? _fixtureInventoryImage(source).$1 : null,
        'price_minor': _fixtureMinor(source['price']),
        'cost_minor': _optionalMinor(source['cost_price']),
        'cost_currency': _optionalCurrency(source['cost_currency']),
        'min_stock_4': _optionalScaled(source['min_stock'], 4),
        'is_active': _fixtureFlag(source['is_active']),
        'is_service': _fixtureFlag(source['is_service']),
        'expiry_date': _optionalDate(source['expiry_date']),
        'created_us': _fixtureTime(source['created_at']),
        'deleted_us': _deletedTime(source),
      };
    }
    _requireFixture(
      categoryIds.length == catalogue.length &&
          (hasCatalogue || (catalogue.isEmpty && expiry == null)),
    );
    for (final source in await _source('product_units')) {
      final product = _fixtureId(source['product_id']);
      _requireFixture(products.containsKey(product));
      units[_fixtureId(source['id'])] = {
        ..._row(source),
        'product_id': product,
        'name': _fixtureText(source['name']),
        'factor_4': _scaled(source['factor'], 4),
        'family': _fixtureOptionalText(source['group']),
        'barcode': _fixtureOptionalText(source['barcode']),
        'sale_minor': _optionalMinor(source['sale_price']),
        'purchase_minor': _optionalMinor(source['purchase_price']),
        'is_base': _fixtureFlag(source['is_base']),
        'is_active': _fixtureFlag(source['is_active']),
      };
    }
    final barcodes = <_CommerceRow>[
      for (final source in await _source('product_barcodes'))
        {
          ..._row(source),
          'product_id': _fixtureId(source['product_id']),
          'unit_id': _fixtureOptionalId(source['unit_id']),
          'barcode': _fixtureText(source['barcode']),
        },
    ];
    for (final row in barcodes) {
      _requireFixture(products.containsKey(row['product_id']));
      _checkUnit(row['unit_id'] as String?, row['product_id'] as String);
    }
    final prices = <_CommerceRow>[
      for (final source in await _source('product_prices'))
        {
          ..._row(source),
          'product_id': _fixtureId(source['product_id']),
          'currency': _fixtureCurrency(source['currency']),
          'price_minor': _fixtureMinor(source['price']),
          'buy_minor': _optionalMinor(source['buy_price']),
        },
    ];
    final stock = <_CommerceRow>[
      for (final source in await _source('branch_stock'))
        {
          ..._row(source),
          'product_id': _fixtureId(source['product_id']),
          'quantity_milli': _scaled(source['quantity'], 3),
          'avg_cost_4': _scaled(source['avg_cost'], 4),
        },
    ];
    _requireFixture(
      prices.every((r) => products.containsKey(r['product_id'])) &&
          stock.every((r) => products.containsKey(r['product_id'])),
    );

    for (final source in allInvoices) {
      final id = _fixtureId(source['id']);
      if (openingIds.contains(id)) continue;
      final header = _invoice(source);
      final key = (header['party_kind'], header['party_id']);
      _requireFixture(header['party_id'] == null || parties.contains(key));
      _requireFixture(
        header['group_id'] == null || groups[header['group_id']] == key,
      );
      invoices[id] = header;
    }
    for (final source in (await _source('invoice_items')).where(ordinary)) {
      final line = _line(source);
      _requireFixture(invoices.containsKey(line['invoice_id']));
      lines[_fixtureId(source['id'])] = line;
      final product = line['product_id'] as String?;
      if (product != null) {
        invoiceProducts.add((line['invoice_id'] as String, product));
      }
    }
    final edits = [
      for (final source in (await _source(
        'invoice_item_changes',
      )).where(ordinary))
        _edit(source),
    ];
    final payments = <_CommerceRow>[];
    for (final source in (await _source('payments')).where(ordinary)) {
      final invoice = _fixtureId(source['invoice_id']);
      final currency = invoices[invoice]?['currency'] as String?;
      _requireFixture(currency != null);
      payments.add({
        ..._cutoverPayment(source, branch, invoice, currency!, accounts),
        'reference': _fixtureOptionalText(source['reference']),
        'notes': _fixtureOptionalText(source['notes']),
        'rate_source': _fixtureOptionalText(source['exchange_rate_source']),
        'rate_us': _optionalTime(source['exchange_rate_timestamp']),
        'created_by': _fixtureOptionalId(source['created_by']),
      });
    }
    final balances = <_CommerceRow>[];
    final balanceInvoices = <String>{};
    for (final (table, kind) in [
      ('customer_receivables', 'customer'),
      ('supplier_payables', 'supplier'),
    ]) {
      for (final source in (await _source(table)).where(ordinary)) {
        final invoice = _fixtureId(source['invoice_id']);
        final header = invoices[invoice];
        _requireFixture(
          header != null &&
              header['party_kind'] == kind &&
              header['party_id'] == _fixtureId(source['${kind}_id']) &&
              balanceInvoices.add(invoice),
        );
        balances.add({
          ..._row(source),
          'invoice_id': invoice,
          'amount_minor': _fixtureMinor(source['amount']),
          'paid_minor': _fixtureMinor(source['paid']),
          'status': _fixtureText(source['status']),
        });
      }
    }

    final returnLines = <_CommerceRow>[];
    for (final (headers, details, parent, type) in [
      ('invoice_returns', 'invoice_return_items', 'return_id', 'sale'),
      (
        'purchase_returns',
        'purchase_return_items',
        'purchase_return_id',
        'purchase',
      ),
    ]) {
      for (final source in await _source(headers)) {
        final invoice = _fixtureId(source['invoice_id']);
        final header = invoices[invoice];
        _requireFixture(
          header != null &&
              header['invoice_type'] == type &&
              source['purchase_order_id'] == null &&
              (type != 'purchase' ||
                  source['supplier_id'] == header['party_id']),
        );
        returns[_fixtureId(source['id'])] = {
          ..._row(source),
          'invoice_id': invoice,
          'invoice_type': type,
          'number': _fixtureText(source['return_number']),
          'date': _fixtureDate(source['return_date']),
          'status': _fixtureText(source['status']),
          'total_minor': _fixtureMinor(source['total']),
          'reason': _fixtureOptionalText(source['reason']),
          'notes': _fixtureOptionalText(source['notes']),
          'created_by': _fixtureOptionalId(source['created_by']),
          'created_us': _fixtureTime(source['created_at']),
        };
      }
      for (final source in await _source(details)) {
        final id = _fixtureId(source[parent]);
        final ret = returns[id];
        final item = _fixtureId(source['invoice_item_id']);
        final line = lines[item];
        final product = _fixtureOptionalId(source['product_id']);
        final qty = _scaled(source['quantity'], 6);
        _requireFixture(
          ret != null &&
              ret['invoice_type'] == type &&
              line != null &&
              line['invoice_id'] == ret['invoice_id'] &&
              line['product_id'] == product &&
              qty > 0,
        );
        if (ret!['status'] == 'confirmed') {
          final total = (returnedQuantities[item] ?? 0) + qty;
          _requireFixture(total <= (line!['quantity_micro'] as int));
          returnedQuantities[item] = total;
        }
        if (product != null) returnProducts.add((id, product));
        returnLines.add({
          ..._row(source),
          'return_id': id,
          'invoice_id': ret['invoice_id'],
          'item_id': item,
          'product_id': product,
          'description': _fixtureText(source['description']),
          'quantity_micro': qty,
          'unit_minor': _fixtureMinor(source['unit_price']),
          'total_minor': _fixtureMinor(source['total']),
        });
      }
    }
    final returnAmounts = <Object?, BigInt>{};
    for (final row in returnLines) {
      _addAmount(returnAmounts, row['return_id'], row['total_minor'] as int);
    }
    final returnedByInvoice = <Object?, BigInt>{};
    for (final ret in returns.values.where((r) => r['status'] == 'confirmed')) {
      final total = ret['total_minor'] as int;
      _requireFixture(returnAmounts[ret['id']] == BigInt.from(total));
      _addAmount(returnedByInvoice, ret['invoice_id'], total);
    }
    final paidByInvoice = <Object?, BigInt>{};
    for (final payment in payments) {
      _addAmount(
        paidByInvoice,
        payment['invoice_id'],
        payment['applied_minor'] as int,
      );
    }
    for (final header in invoices.values) {
      if (header['deleted_us'] != null ||
          const {'draft', 'cancelled'}.contains(header['status'])) {
        continue;
      }
      final invoiceId = header['id'];
      final paid = BigInt.from(header['paid_minor'] as int);
      final gross = paidByInvoice[invoiceId] ?? BigInt.zero;
      final refunded = gross - paid;
      // Returns keep the original gross Payment rows. The invoice holds
      // the net paid and remaining balance. Re-pricing from line totals or
      // summing those payments into invoice.paid would undo that distinction.
      _requireFixture(
        refunded >= BigInt.zero &&
            refunded <= (returnedByInvoice[invoiceId] ?? BigInt.zero),
      );
      if (!returnedByInvoice.containsKey(invoiceId)) {
        _requireFixture(
          header['balance_minor'] ==
              max(0, (header['total_minor'] as int) - paid.toInt()),
        );
      }
    }

    for (final source in await _source('inventory_lots')) {
      final lot = _lot(source);
      _requireFixture(
        lot['supplier_id'] == null ||
            parties.contains(('supplier', lot['supplier_id'])),
      );
      lots[_fixtureId(source['id'])] = lot;
    }
    final consumptions = [
      for (final source in await _source('inventory_lot_consumptions'))
        _consumption(source),
    ];
    final movements = [
      for (final source in await _source('inventory_movements'))
        _movement(source),
    ];

    final projections = <String, List<_CommerceRow>>{
      _commerceBranches: [
        {'branch_id': branch, 'name': _fixtureText(branchRow['name'])},
      ],
      _commerceCatalogue: [
        if (hasCatalogue)
          {
            'branch_id': branch,
            'expiry_enabled': expiry == null
                ? null
                : _fixtureFlag(expiry['expiry_enabled']),
            'expiry_warn_days': warnDays,
          },
      ],
      _commerceProducts: products.values.toList(),
      _commerceCategories: catalogue.values.toList(),
      _commerceCategoryLinks: links,
      _commerceUnits: units.values.toList(),
      _commerceBarcodes: barcodes,
      _commercePrices: prices,
      _commerceStock: stock,
      _commerceInvoices: invoices.values.toList(),
      _commerceLines: lines.values.toList(),
      _commerceEdits: edits,
      _commercePayments: payments,
      _commerceBalances: balances,
      _commerceReturns: returns.values.toList(),
      _commerceReturnLines: returnLines,
      _commerceLots: lots.values.toList(),
      _commerceConsumptions: consumptions,
      _commerceMovements: movements,
    };
    for (final entry in projections.entries) {
      // Don't report a unique-key error or merge a partially existing
      // branch, including a catalogue without the rest of its projection.
      _requireFixture(
        (await txn.query(
          entry.key,
          columns: ['branch_id'],
          where: 'branch_id = ?',
          whereArgs: [branch],
          limit: 1,
        )).isEmpty,
      );
    }
    final batch = txn.batch();
    for (final entry in projections.entries) {
      for (final row in entry.value) {
        batch.insert(entry.key, row);
      }
    }
    // Never turn a historical payment into a ledger command that moves cash.
    // Its ID does still have to be unavailable for future financial commands.
    for (final rows in [payments, edits, movements]) {
      for (final row in rows) {
        final id = row['id'];
        batch.insert(BusinessLedger._commands, {
          'branch_id': branch,
          'id': id,
          'fingerprint': 'cutover:${receipt.digest}',
          'result': jsonEncode({'id': id}),
        });
      }
    }
    await batch.commit(noResult: true);
    for (final entry in projections.entries) {
      final key =
          const {_commerceBranches, _commerceCatalogue}.contains(entry.key)
          ? 'branch_id'
          : 'id';
      await _verifyCutoverRows(txn, branch, entry.key, [key], entry.value);
    }
  }

  _CommerceRow _invoice(_CommerceRow source) {
    final type = _fixtureText(source['invoice_type']);
    final sale = type == 'sale';
    _requireFixture(
      (sale || type == 'purchase') &&
          source['branch_id'] == branch &&
          source[sale ? 'supplier_id' : 'customer_id'] == null,
    );
    return {
      ..._row(source),
      'number': _fixtureText(source['invoice_number']),
      'invoice_type': type,
      'party_kind': sale ? 'customer' : 'supplier',
      'party_id': _fixtureOptionalId(
        source[sale ? 'customer_id' : 'supplier_id'],
      ),
      'group_id': _fixtureOptionalId(source['debt_group_id']),
      'date': _fixtureDate(source['invoice_date']),
      'due_date': _optionalDate(source['due_date']),
      'currency': _fixtureCurrency(source['currency']),
      'status': _fixtureText(source['status']),
      'subtotal_minor': _fixtureMinor(source['subtotal']),
      'discount_type': _fixtureOptionalText(source['discount_type']),
      'discount_value_2': _fixtureMinor(source['discount_value']),
      'discount_minor': _fixtureMinor(source['discount_amount']),
      'tax_type': _fixtureOptionalText(source['tax_type']),
      'tax_rate_2': _fixtureMinor(source['tax_rate']),
      'tax_minor': _fixtureMinor(source['tax_amount']),
      'total_minor': _fixtureMinor(source['total']),
      'paid_minor': _fixtureMinor(source['paid_amount']),
      'balance_minor': _fixtureMinor(source['balance']),
      'notes': _fixtureOptionalText(source['notes']),
      'terms': _fixtureOptionalText(source['terms']),
      'idempotency_key': _fixtureOptionalText(source['idempotency_key']),
      'created_by': _fixtureOptionalId(source['created_by']),
      'created_us': _fixtureTime(source['created_at']),
      'deleted_us': _deletedTime(source),
      'confirmed_us': _optionalTime(source['confirmed_at']),
      'cancelled_us': _optionalTime(source['cancelled_at']),
    };
  }

  _CommerceRow _line(_CommerceRow source) {
    final product = _fixtureOptionalId(source['product_id']);
    final unit = _fixtureOptionalId(source['unit_id']);
    _requireFixture(product == null || products.containsKey(product));
    _checkUnit(unit, product);
    return {
      ..._row(source),
      'invoice_id': _fixtureId(source['invoice_id']),
      'product_id': product,
      'unit_id': unit,
      'unit_name': _fixtureOptionalText(source['unit_name']),
      'description': _fixtureText(source['description']),
      'quantity_micro': _scaled(source['quantity'], 6),
      'base_micro': _scaled(source['base_quantity'], 6),
      'factor_4': _optionalScaled(source['factor'], 4),
      'unit_minor': _fixtureMinor(source['unit_price']),
      'discount_minor': _fixtureMinor(source['discount']),
      'tax_rate_2': _fixtureMinor(source['tax_rate']),
      'total_minor': _fixtureMinor(source['total']),
      'is_service': _fixtureFlag(source['is_service']),
      'image': _fixtureOptionalText(source['image']),
      'cost_total_minor': _optionalMinor(source['cost_total']),
      'profit_minor': _optionalMinor(source['profit']),
      'original_minor': _optionalMinor(source['original_unit_price']),
      'price_currency': _optionalCurrency(source['price_currency']),
      'exchange_rate': _optionalExactRate(source['exchange_rate_used']),
    };
  }

  _CommerceRow _edit(_CommerceRow source) {
    final invoice = _fixtureId(source['invoice_id']);
    final item = _fixtureId(source['item_id']);
    _requireFixture(lines[item]?['invoice_id'] == invoice);
    return {
      ..._row(source),
      'invoice_id': invoice,
      'item_id': item,
      'description': _fixtureOptionalText(source['description']),
      'old_quantity_micro': _optionalScaled(source['old_quantity'], 6),
      'new_quantity_micro': _optionalScaled(source['new_quantity'], 6),
      'old_unit_minor': _optionalMinor(source['old_unit_price']),
      'new_unit_minor': _optionalMinor(source['new_unit_price']),
      'changed_by': _fixtureOptionalId(source['changed_by']),
      'created_us': _fixtureTime(source['changed_at']),
    };
  }

  _CommerceRow _lot(_CommerceRow source) {
    final product = _fixtureId(source['product_id']);
    final supplier = _fixtureOptionalId(source['supplier_id']);
    final invoice = _fixtureOptionalId(source['purchase_invoice_id']);
    final item = _fixtureOptionalId(source['invoice_item_id']);
    final unit = _fixtureOptionalId(source['unit_id']);
    _requireFixture(
      products.containsKey(product) &&
          (item == null || lines[item]?['product_id'] == product),
    );
    _requireFixture(
      invoice == null ||
          (invoices[invoice]?['invoice_type'] == 'purchase' &&
              (supplier == null ||
                  invoices[invoice]?['party_id'] == supplier) &&
              lines[item]?['invoice_id'] == invoice),
    );
    _checkUnit(unit, product);
    return {
      ..._row(source),
      'product_id': product,
      'supplier_id': supplier,
      'purchase_invoice_id': invoice,
      'item_id': item,
      'unit_id': unit,
      'received_micro': _scaled(source['received_quantity'], 6),
      'remaining_micro': _scaled(source['remaining_quantity'], 6),
      'unit_cost_4': _scaled(source['unit_cost'], 4),
      'currency': _optionalCurrency(source['currency']),
      'exchange_rate': _optionalExactRate(source['exchange_rate']),
      'purchase_date': _optionalDate(source['purchase_date']),
      'expiry_date': _optionalDate(source['expiry_date']),
      'lot_number': _fixtureOptionalText(source['lot_number']),
      'source': _fixtureOptionalText(source['source']),
      'created_us': _fixtureTime(source['created_at']),
    };
  }

  _CommerceRow _consumption(_CommerceRow source) {
    final lot = _fixtureId(source['lot_id']);
    final item = _fixtureOptionalId(source['invoice_item_id']);
    _requireFixture(
      lots.containsKey(lot) &&
          (item == null ||
              (lines[item]?['product_id'] == lots[lot]!['product_id'] &&
                  invoices[lines[item]?['invoice_id']]?['invoice_type'] ==
                      'sale')),
    );
    return {
      ..._row(source),
      'lot_id': lot,
      'item_id': item,
      'quantity_micro': _scaled(source['quantity'], 6),
      'unit_cost_4': _scaled(source['unit_cost'], 4),
      'currency': _optionalCurrency(source['currency']),
      'created_us': _fixtureTime(source['created_at']),
    };
  }

  _CommerceRow _movement(_CommerceRow source) {
    final product = _fixtureId(source['product_id']);
    final reference = _fixtureOptionalId(source['reference_id']);
    final referenceType = _fixtureOptionalText(source['reference_type']);
    _requireFixture(
      products.containsKey(product) && referenceType != 'transfer',
    );
    switch (referenceType) {
      case 'invoice':
        _requireFixture(
          reference != null && invoiceProducts.contains((reference, product)),
        );
      case 'invoice_return':
      case 'purchase_return':
        _requireFixture(
          reference != null &&
              returnProducts.contains((reference, product)) &&
              returns[reference]?['invoice_type'] ==
                  (referenceType == 'invoice_return' ? 'sale' : 'purchase'),
        );
      default:
        _requireFixture(reference == null);
    }
    return {
      ..._row(source),
      'product_id': product,
      'movement_type': _fixtureText(source['movement_type']),
      'quantity_micro': _scaled(source['quantity'], 6),
      'unit_minor': _fixtureMinor(source['unit_price']),
      'total_minor': _fixtureMinor(source['total']),
      'currency': _optionalCurrency(source['currency']),
      'reason': _fixtureOptionalText(source['reason']),
      for (final key in ['old_quantity', 'new_quantity', 'difference'])
        '${key.replaceAll('_quantity', '')}_micro': _optionalScaled(
          source[key],
          6,
        ),
      'reference_type': referenceType,
      'reference_id': reference,
      'notes': _fixtureOptionalText(source['notes']),
      'created_by': _fixtureOptionalId(source['created_by']),
      'created_us': _fixtureTime(source['created_at']),
    };
  }
}

int _scaled(Object? value, int precision) =>
    BusinessCutoverFixtureArchive._scaled(value, precision);
int? _optionalScaled(Object? value, int precision) =>
    value == null ? null : _scaled(value, precision);
int _fixtureFlag(Object? value) => _fixtureBool(value) ? 1 : 0;
String? _optionalCurrency(Object? value) =>
    value == null ? null : _fixtureCurrency(value);
String? _optionalDate(Object? value) =>
    value == null ? null : _fixtureDate(value);
int? _optionalTime(Object? value) => value == null ? null : _fixtureTime(value);
int? _deletedTime(_CommerceRow source) => _fixtureBool(source['is_deleted'])
    ? _fixtureTime(source['deleted_at'])
    : null;

void _addAmount(Map<Object?, BigInt> amounts, Object? id, int amount) {
  amounts[id] = (amounts[id] ?? BigInt.zero) + BigInt.from(amount);
}
