part of 'directory_database.dart';

enum BusinessInvoiceKind {
  sale,
  purchase;

  BusinessLedgerAction get _read => this == sale
      ? BusinessLedgerAction.readSaleInvoice
      : BusinessLedgerAction.readPurchaseInvoice;
}

/// Scoped SQLCipher readers for ordinary invoices, returns and inventory. A
/// financial row stays distinct from an opening debt, even if the party matches.
/// No reader calls the legacy API or uses the frozen archive for its values.
extension BusinessCommerceReads on BusinessLedger {
  Future<Map<String, dynamic>?> commerceInvoice(
    BusinessLedgerAccess access,
    BusinessInvoiceKind kind,
    String id,
  ) {
    final branch = _branch(access, kind._read);
    final showProfit = access._actions.contains(
      BusinessLedgerAction.readInvoiceProfit,
    );
    return _directory._transaction((txn) async {
      final header = await _commerceInvoiceHeader(txn, branch, kind, id);
      if (header == null) return null;
      final partyKind = header['party_kind'] as String;
      final detail = (await _commerceRows(
        txn,
        _commerceBalances,
        branch,
        'invoice_id',
        id,
      )).singleOrNull;
      final items = await txn.rawQuery(
        '''
        SELECT l.*, p.name AS product_name, COALESCE(rr.quantity, 0) AS returned_micro
        FROM $_commerceLines l
        LEFT JOIN $_commerceProducts p ON p.branch_id = l.branch_id AND p.id = l.product_id
        LEFT JOIN (
          SELECT d.item_id, SUM(d.quantity_micro) AS quantity FROM $_commerceReturnLines d
          JOIN $_commerceReturns r ON r.branch_id = d.branch_id AND r.id = d.return_id
          WHERE d.branch_id = ? AND d.invoice_id = ? AND r.status = 'confirmed'
          GROUP BY d.item_id
        ) rr ON rr.item_id = l.id
        WHERE l.branch_id = ? AND l.invoice_id = ? ORDER BY l.id
      ''',
        [branch, id, branch, id],
      );
      final payments = await txn.rawQuery(
        '''
        SELECT p.*, a.bank_name FROM $_commercePayments p
        LEFT JOIN ${BusinessLedger._accounts} a ON a.branch_id = p.branch_id AND a.id = p.account_id
        WHERE p.branch_id = ? AND p.invoice_id = ? ORDER BY p.created_us, p.id
      ''',
        [branch, id],
      );
      final edits = await _commerceRows(
        txn,
        _commerceEdits,
        branch,
        'invoice_id',
        id,
        order: 'created_us, id',
      );
      return <String, dynamic>{
        'id': id,
        'branch_id': branch,
        'branch_name': header['branch_name'],
        'invoice_number': header['number'],
        'invoice_type': kind.name,
        'invoice_date': header['date'],
        'due_date': header['due_date'],
        'currency': header['currency'],
        'status': header['status'],
        'debt_group_id': header['group_id'],
        '${partyKind}_id': header['party_id'],
        '${partyKind}_name': header['party_name'],
        'discount_type': header['discount_type'],
        'tax_type': header['tax_type'],
        'notes': header['notes'],
        'terms': header['terms'],
        for (final (name, column) in [
          ('subtotal', 'subtotal_minor'),
          ('discount_value', 'discount_value_2'),
          ('discount_amount', 'discount_minor'),
          ('tax_rate', 'tax_rate_2'),
          ('tax_amount', 'tax_minor'),
          ('total', 'total_minor'),
          ('paid_amount', 'paid_minor'),
          ('balance', 'balance_minor'),
        ])
          name: _commerceDecimal(header, column, 100),
        if (detail != null)
          (kind == BusinessInvoiceKind.sale ? 'receivable' : 'payable'): {
            'id': detail['id'],
            'amount': _commerceDecimal(detail, 'amount_minor', 100),
            'paid': _commerceDecimal(detail, 'paid_minor', 100),
            'status': detail['status'],
          },
        'items': [
          for (final row in items) _commerceInvoiceLine(row, showProfit),
        ],
        'item_changes': [
          for (final row in edits)
            {
              for (final key in ['id', 'item_id', 'description', 'changed_by'])
                key: row[key],
              'changed_at': _commerceDate(row['created_us']),
              'old_quantity': _commerceDecimal(
                row,
                'old_quantity_micro',
                1000000,
              ),
              'new_quantity': _commerceDecimal(
                row,
                'new_quantity_micro',
                1000000,
              ),
              'old_unit_price': _commerceDecimal(row, 'old_unit_minor', 100),
              'new_unit_price': _commerceDecimal(row, 'new_unit_minor', 100),
            },
        ],
        'payments': [
          for (final row in payments)
            {
              'id': row['id'],
              'amount': _commerceDecimal(row, 'applied_minor', 100),
              'equivalent_amount': _commerceDecimal(row, 'applied_minor', 100),
              'original_amount': _commerceDecimal(row, 'original_minor', 100),
              'payment_date': row['date'],
              'payment_method': row['method'],
              'payment_currency': row['payment_currency'],
              'invoice_currency': row['debt_currency'],
              'bank_account_id': row['account_id'],
              'bank_account_name': row['bank_name'],
              'reference': row['reference'],
              'notes': row['notes'],
              'exchange_rate': row['exchange_rate'],
              'exchange_rate_source': row['rate_source'],
              'exchange_rate_timestamp': _commerceDate(row['rate_us']),
            },
        ],
      };
    });
  }

  Future<List<Map<String, dynamic>>> commerceReturns(
    BusinessLedgerAccess access,
    BusinessInvoiceKind kind,
    String invoiceId,
  ) {
    _branch(access, kind._read);
    return commerceReturnsList(access, kind: kind, invoiceId: invoiceId);
  }

  /// Unified previous-returns list in the connected return shape, across the
  /// branch's ordinary documents and both return kinds.
  Future<List<Map<String, dynamic>>> commerceReturnsList(
    BusinessLedgerAccess access, {
    BusinessInvoiceKind? kind,
    String? invoiceId,
    String? returnId,
    String? search,
  }) {
    final branch = _branch(access, BusinessLedgerAction.readReturns);
    return _directory._transaction((txn) async {
      final rows = await txn.rawQuery(
        '''
        SELECT r.*, i.number AS invoice_number, i.currency AS invoice_currency,
          i.party_kind, i.party_id, p.name AS party_name
        FROM $_commerceReturns r
        JOIN $_commerceInvoices i ON i.branch_id = r.branch_id AND i.id = r.invoice_id
        LEFT JOIN ${DirectoryDatabase._table} p
          ON p.branch_id = i.branch_id AND p.kind = i.party_kind AND p.id = i.party_id
        WHERE r.branch_id = ? AND r.status = 'confirmed'
          ${kind == null ? '' : ' AND r.invoice_type = ?'}
          ${invoiceId == null ? '' : ' AND r.invoice_id = ?'}
          ${returnId == null ? '' : ' AND r.id = ?'}
        ORDER BY r.date DESC, r.created_us DESC, r.id DESC
        ''',
        [branch, ?kind?.name, ?invoiceId, ?returnId],
      );
      final query = search?.trim().toLowerCase() ?? '';
      final result = <Map<String, dynamic>>[];
      for (final row in rows) {
        final total = _commerceDecimal(row, 'total_minor', 100)!;
        if (query.isNotEmpty &&
            !_numberMatches(row['number'], query) &&
            !_numberMatches(row['invoice_number'], query) &&
            !'${row['party_name'] ?? ''}'.toLowerCase().contains(query) &&
            !'$total'.contains(query)) {
          continue;
        }
        final items = await _commerceRows(
          txn,
          _commerceReturnLines,
          branch,
          'return_id',
          row['id'] as String,
        );
        result.add({
          'id': row['id'],
          'kind': '${row['invoice_type']}_return',
          'return_number': row['number'],
          'date': row['date'],
          'created_at': _commerceDate(row['created_us']),
          'status': row['status'],
          'reason': row['reason'],
          'party': row['party_name'],
          'total': total,
          'currency': row['invoice_currency'],
          'invoice_id': row['invoice_id'],
          'invoice_number': row['invoice_number'],
          'items': [
            for (final item in items)
              {
                'id': item['id'],
                'invoice_item_id': item['item_id'],
                'product_id': item['product_id'],
                'description': item['description'],
                'quantity': _commerceDecimal(item, 'quantity_micro', 1000000),
                'unit_price': _commerceDecimal(item, 'unit_minor', 100),
                'total': _commerceDecimal(item, 'total_minor', 100),
              },
          ],
        });
      }
      return result;
    });
  }

  /// Resolve one return by id across both kinds, for the return detail screen.
  Future<Map<String, dynamic>?> commerceReturnById(
    BusinessLedgerAccess access,
    String id,
  ) async {
    final rows = await commerceReturnsList(access, returnId: id);
    return rows.firstOrNull;
  }

  /// Barcode lookup for the connected scanner contract: unit barcodes win,
  /// then the product's own code, then the extra codes.
  Future<Map<String, dynamic>?> commerceResolveBarcode(
    BusinessLedgerAccess access,
    String code,
  ) {
    final branch = _branch(access, BusinessLedgerAction.readInventory);
    return _directory._transaction(
      (txn) => _commerceCodeMatch(txn, branch, code),
    );
  }

  Future<Map<String, dynamic>?> _commerceCodeMatch(
    Transaction txn,
    String branch,
    String code,
  ) async {
    final unit = (await txn.query(
      _commerceUnits,
      columns: ['product_id', 'id'],
      where: 'branch_id = ? AND barcode = ? AND is_active = 1',
      whereArgs: [branch, code],
      limit: 1,
    )).firstOrNull;
    if (unit != null) {
      return {'product_id': unit['product_id'], 'unit_id': unit['id']};
    }
    final own = (await txn.query(
      _commerceProducts,
      columns: ['id'],
      where:
          'branch_id = ? AND barcode = ? AND deleted_us IS NULL AND is_active = 1',
      whereArgs: [branch, code],
      limit: 1,
    )).firstOrNull;
    if (own != null) {
      return {'product_id': own['id'], 'unit_id': null};
    }
    final extra = (await txn.query(
      _commerceBarcodes,
      columns: ['product_id', 'unit_id'],
      where: 'branch_id = ? AND barcode = ?',
      whereArgs: [branch, code],
      limit: 1,
    )).firstOrNull;
    return extra == null
        ? null
        : {'product_id': extra['product_id'], 'unit_id': extra['unit_id']};
  }

  Future<Map<String, dynamic>?> commerceInventoryProduct(
    BusinessLedgerAccess access,
    String productId,
  ) {
    final branch = _branch(access, BusinessLedgerAction.readInventory);
    final showCost = access._actions.contains(
      BusinessLedgerAction.readInventoryCost,
    );
    return _directory._transaction((txn) async {
      final row = (await txn.query(
        _commerceProducts,
        where: 'branch_id = ? AND id = ? AND deleted_us IS NULL',
        whereArgs: [branch, productId],
      )).singleOrNull;
      if (row == null) return null;
      Future<List<_CommerceRow>> related(String table, {String order = 'id'}) =>
          _commerceRows(
            txn,
            table,
            branch,
            'product_id',
            productId,
            order: order,
          );
      final stock = (await related(_commerceStock)).singleOrNull;
      final category = await _productCategoryId(txn, branch, productId);
      return <String, dynamic>{
        'id': productId,
        'branch_id': branch,
        for (final key in [
          'name',
          'name_ar',
          'sku',
          'barcode',
          'description',
          'unit',
          'expiry_date',
          'notes',
        ])
          key: row[key],
        'image': _deviceInventoryImage(row['image']),
        'category_id': category,
        if (category != null)
          'category_name': (await _commerceCategory(
            txn,
            branch,
            category,
          ))['name'],
        'price': _commerceDecimal(row, 'price_minor', 100),
        'is_service': row['is_service'] == 1,
        'is_active': row['is_active'] == 1,
        'stock_id': stock?['id'],
        'stock': stock == null
            ? 0
            : _commerceDecimal(stock, 'quantity_milli', 1000),
        'min_stock': _commerceDecimal(row, 'min_stock_4', 10000),
        if (showCost) ...{
          'cost_price': _commerceDecimal(row, 'cost_minor', 100),
          'cost_currency': row['cost_currency'],
           'avg_cost': stock == null
               ? null
               : await _visibleStockAverage(txn, branch, productId,
                   {...stock, 'cost_currency': row['cost_currency']}),
        },
        'units': [
          for (final unit in await related(
            _commerceUnits,
            order: 'is_base DESC, name, id',
          ))
            {
              for (final key in ['id', 'name', 'barcode']) key: unit[key],
              'group': unit['family'],
              'factor': _commerceDecimal(unit, 'factor_4', 10000),
              'sale_price': _commerceDecimal(unit, 'sale_minor', 100),
              if (showCost)
                'purchase_price': _commerceDecimal(unit, 'purchase_minor', 100),
              'is_base': unit['is_base'] == 1,
              'is_active': unit['is_active'] == 1,
              'image': _deviceInventoryImage(unit['image']),
            },
        ],
        'barcodes': [
          for (final code in await related(_commerceBarcodes))
            {
              for (final key in ['id', 'unit_id', 'barcode']) key: code[key],
            },
        ],
        'prices': [
          for (final price in await related(_commercePrices, order: 'currency'))
            {
              'id': price['id'],
              'currency': price['currency'],
              'price': _commerceDecimal(price, 'price_minor', 100),
              if (showCost)
                'buy_price': _commerceDecimal(price, 'buy_minor', 100),
            },
        ],
        'lots': [
          for (final lot in await _inventoryBatches(txn, branch, productId))
            {
              for (final key in [
                'id',
                'product_id',
                'product_name',
                'purchase_invoice_id',
                'lot_number',
                'purchase_date',
                'expiry_date',
                'source',
              ])
                key: lot[key],
              'product_image': _deviceInventoryImage(lot['product_image']),
              'received': _commerceDecimal(lot, 'batch_received', 1000000),
              'remaining': _commerceDecimal(lot, 'batch_remaining', 1000000),
              if (showCost) ...{
                'unit_cost': lot['currency'] == null && lot['unit_cost_4'] == 0
                    ? null
                    : _commerceDecimal(lot, 'unit_cost_4', 10000),
                'currency': lot['currency'],
                'exchange_rate': lot['exchange_rate'],
              },
            },
        ],
      };
    });
  }

  Future<List<Map<String, dynamic>>> commerceStockMovements(
    BusinessLedgerAccess access,
    String productId, {
    int limit = 50,
  }) {
    final branch = _branch(access, BusinessLedgerAction.readInventory);
    final showCost = access._actions.contains(
      BusinessLedgerAction.readInventoryCost,
    );
    return _directory._read(
      (db) => _productMovements(
        db,
        branch,
        productId,
        showCost: showCost,
        limit: limit,
      ),
    );
  }

  Future<List<Map<String, dynamic>>> _productMovements(
    DatabaseExecutor db,
    String branch,
    String productId, {
    required bool showCost,
    required int limit,
    DateTime? from,
    DateTime? until,
  }) async {
    final rows = await db.rawQuery(
      '''
      SELECT m.*, i.invoice_type,
        COALESCE(i.number, r.number) AS reference_number
      FROM $_commerceMovements m
      LEFT JOIN $_commerceInvoices i ON m.reference_type = 'invoice'
        AND i.branch_id = m.branch_id AND i.id = m.reference_id
        AND i.deleted_us IS NULL
      LEFT JOIN $_commerceReturns r
        ON m.reference_type IN ('invoice_return', 'purchase_return')
        AND r.branch_id = m.branch_id AND r.id = m.reference_id
      WHERE m.branch_id = ? AND m.product_id = ?
        ${from == null ? '' : 'AND m.created_us >= ?'}
        ${until == null ? '' : 'AND m.created_us < ?'}
      ORDER BY m.created_us DESC, m.id DESC LIMIT ?
    ''',
      [
        branch,
        productId,
        ?from?.microsecondsSinceEpoch,
        ?until?.microsecondsSinceEpoch,
        limit.clamp(1, 200),
      ],
    );
    return [
      for (final row in rows)
        {
          for (final key in [
            'id',
            'product_id',
            'movement_type',
            'reason',
            'reference_type',
            'reference_id',
            'invoice_type',
            'reference_number',
            'notes',
            'created_by',
          ])
            key: row[key],
          'created_at': _commerceDate(row['created_us']),
          'quantity': _commerceDecimal(row, 'quantity_micro', 1000000),
          'old_quantity': _commerceDecimal(row, 'old_micro', 1000000),
          'new_quantity': _commerceDecimal(row, 'new_micro', 1000000),
          'difference': _commerceDecimal(row, 'difference_micro', 1000000),
          if (showCost ||
              !'${row['movement_type']}'.startsWith('purchase')) ...{
            'unit_price': _commerceDecimal(row, 'unit_minor', 100),
            'total': _commerceDecimal(row, 'total_minor', 100),
            'currency': row['currency'],
          },
        },
    ];
  }

  /// Product rows in the connected inventory shape, so the original product
  /// picker and lists work from the device without a network.
  Future<List<Map<String, dynamic>>> commerceProducts(
    BusinessLedgerAccess access, {
    String? search,
    int limit = 100,
    int offset = 0,
    bool activeOnly = false,
    String? stockStatus,
    String? expiry,
    int expiryDays = 30,
    String? categoryId,
    bool uncategorized = false,
  }) {
    final branch = _branch(access, BusinessLedgerAction.readInventory);
    final showCost = access._actions.contains(
      BusinessLedgerAction.readInventoryCost,
    );
    return _directory._transaction((txn) async {
      if (categoryId != null) await _commerceCategory(txn, branch, categoryId);
      final now = DateTime.now().toUtc();
      final today = BusinessLedger._date(now);
      final warehouse = expiry == 'soon'
          ? await _warehouseExpiry(txn, branch)
          : null;
      final rows = await txn.rawQuery(
        '''
        SELECT p.id, p.name, p.name_ar, p.sku, p.barcode, p.description, p.unit,
               p.expiry_date, p.notes, p.price_minor, p.min_stock_4, p.is_service,
               p.is_active, p.cost_minor, p.cost_currency,
               s.quantity_milli, s.avg_cost_4, x.category_id, c.name AS category_name
        FROM $_commerceProducts p
        LEFT JOIN $_commerceStock s ON s.branch_id = p.branch_id AND s.product_id = p.id
        LEFT JOIN $_commerceCategoryLinks x ON x.branch_id = p.branch_id AND x.id = p.id
        LEFT JOIN $_commerceCategories c ON c.branch_id = x.branch_id AND c.id = x.category_id
        WHERE p.branch_id = ? AND p.deleted_us IS NULL
          ${categoryId != null
            ? 'AND x.category_id = ?'
            : uncategorized
            ? 'AND x.category_id IS NULL'
            : ''}
          ${activeOnly || expiry == 'soon' || expiry == 'expired' ? 'AND p.is_active = 1' : ''}
          ${switch (stockStatus) {
          'out' => 'AND p.is_service = 0 AND COALESCE(s.quantity_milli, 0) <= 0',
          'low' => 'AND p.is_service = 0 AND s.quantity_milli > 0 AND s.quantity_milli * 10 <= p.min_stock_4',
          _ => '',
        }}
          ${switch (expiry) {
          'expired' => 'AND p.is_service = 0 AND p.expiry_date < ?',
          'soon' => 'AND p.is_service = 0 AND p.expiry_date BETWEEN ? AND ?',
          _ => '',
        }}
        ORDER BY p.created_us DESC, p.id
        ''',
        [
          branch,
          ?categoryId,
          if (expiry == 'expired' || expiry == 'soon') today,
          if (expiry == 'soon')
            BusinessLedger._date(
              now.add(
                Duration(
                  days: (warehouse?.warnDays ?? expiryDays).clamp(0, 365),
                ),
              ),
            ),
        ],
      );
      final query = search?.trim().toLowerCase() ?? '';
      final matching = rows
          .where(
            (row) =>
                query.isEmpty ||
                '${row['name']}'.toLowerCase().contains(query) ||
                '${row['sku'] ?? ''}'.toLowerCase().contains(query) ||
                '${row['barcode'] ?? ''}'.toLowerCase().contains(query),
          )
          .skip(offset)
          .take(limit)
          .toList();
      if (matching.isEmpty) return <Map<String, dynamic>>[];
      final matches = List.filled(matching.length, '?').join(',');
      final matchArgs = [branch, for (final row in matching) row['id']];
      // Image payloads can be large. Unmatched products and later pages
      // never need to move their blobs through the database bridge.
      final images = {
        for (final row in await txn.query(
          _commerceProducts,
          columns: ['id', 'image'],
          where: 'branch_id = ? AND id IN ($matches) AND image IS NOT NULL',
          whereArgs: matchArgs,
        ))
          row['id']: _deviceInventoryImage(row['image']),
      };
      final byProduct = <String, List<Map<String, Object?>>>{};
      final prices = await txn.query(
        _commercePrices,
        where: 'branch_id = ? AND product_id IN ($matches)',
        whereArgs: matchArgs,
        orderBy: 'currency',
      );
      for (final row in prices) {
        (byProduct[row['product_id'] as String] ??= []).add({
          'currency': row['currency'],
          'price': _commerceDecimal(row, 'price_minor', 100),
          if (showCost) 'buy_price': _commerceDecimal(row, 'buy_minor', 100),
        });
      }
      return [
        for (final row in matching)
          {
            for (final key in [
              'id',
              'name',
              'name_ar',
              'sku',
              'barcode',
              'description',
              'unit',
              'category_id',
              'category_name',
              'expiry_date',
              'notes',
            ])
              key: row[key],
            'image': images[row['id']],
            'price': _commerceDecimal(row, 'price_minor', 100),
            'stock': (row['quantity_milli'] as int? ?? 0) / 1000,
            'min_stock': _commerceDecimal(row, 'min_stock_4', 10000),
            'is_service': row['is_service'] == 1,
            'is_active': row['is_active'] == 1,
            'prices': byProduct[row['id'] as String] ?? const [],
            if (showCost) ...{
              'cost_price': _commerceDecimal(row, 'cost_minor', 100),
              'cost_currency': row['cost_currency'],
              'avg_cost': await _visibleStockAverage(txn, branch, row['id'] as String, row),
            },
          },
      ];
    });
  }

  /// Ordinary documents in the connected invoice-list shape, newest first.
  Future<List<Map<String, dynamic>>> commerceDocuments(
    BusinessLedgerAccess access, {
    BusinessInvoiceKind? kind,
    String? search,
    int limit = 100,
    bool returnableOnly = false,
  }) {
    final branch = _branch(
      access,
      kind == BusinessInvoiceKind.purchase
          ? BusinessLedgerAction.readPurchaseInvoice
          : BusinessLedgerAction.readSaleInvoice,
    );
    if (kind == null) _branch(access, BusinessLedgerAction.readPurchaseInvoice);
    return _directory._transaction((txn) async {
      final rows = await txn.rawQuery(
        '''
        SELECT i.*, p.name AS party_name
        FROM $_commerceInvoices i
        LEFT JOIN ${DirectoryDatabase._table} p
          ON p.branch_id = i.branch_id AND p.kind = i.party_kind AND p.id = i.party_id
        WHERE i.branch_id = ? AND i.deleted_us IS NULL
          ${kind == null ? '' : 'AND i.invoice_type = ?'}
          ${returnableOnly ? '''
            AND i.status NOT IN ('draft', 'cancelled')
            AND EXISTS (
              SELECT 1 FROM $_commerceLines l
              WHERE l.branch_id = i.branch_id AND l.invoice_id = i.id
                AND l.quantity_micro > COALESCE((
                  SELECT SUM(d.quantity_micro) FROM $_commerceReturnLines d
                  JOIN $_commerceReturns r ON r.branch_id = d.branch_id AND r.id = d.return_id
                  WHERE d.branch_id = l.branch_id AND d.item_id = l.id AND r.status = 'confirmed'
                ), 0)
            )
          ''' : ''}
        ''',
        [branch, ?kind?.name],
      );
      final query = search?.trim().toLowerCase() ?? '';
      final documents = <Map<String, dynamic>>[
        for (final row in rows)
          if (query.isEmpty ||
              _numberMatches(row['number'], query) ||
              (!returnableOnly &&
                  '${row['party_name'] ?? ''}'.toLowerCase().contains(query)))
            {
              'id': row['id'],
              'invoice_number': row['number'],
              'invoice_type': row['invoice_type'],
              'status': row['status'],
              'currency': row['currency'],
              'total': _commerceDecimal(row, 'total_minor', 100),
              'paid_amount': _commerceDecimal(row, 'paid_minor', 100),
              'balance': _commerceDecimal(row, 'balance_minor', 100),
              'invoice_date': row['date'],
              'due_date': row['due_date'],
              'created_at': _commerceDate(row['created_us']),
              if (row['invoice_type'] == 'sale') ...{
                'customer_id': row['party_id'],
                'customer_name': row['party_name'],
              } else ...{
                'supplier_id': row['party_id'],
                'supplier_name': row['party_name'],
              },
            },
      ];
      documents.sort((a, b) {
        final byDate = '${b['invoice_date']}'.compareTo('${a['invoice_date']}');
        return byDate != 0 ? byDate : '${b['id']}'.compareTo('${a['id']}');
      });
      return documents.take(limit).toList();
    });
  }
}

Future<_CommerceRow?> _commerceInvoiceHeader(
  Transaction txn,
  String branch,
  BusinessInvoiceKind kind,
  String id,
) async => (await txn.rawQuery(
  '''
    SELECT i.*, p.name AS party_name, b.name AS branch_name FROM $_commerceInvoices i
    LEFT JOIN ${DirectoryDatabase._table} p
      ON p.branch_id = i.branch_id AND p.kind = i.party_kind AND p.id = i.party_id
    LEFT JOIN $_commerceBranches b ON b.branch_id = i.branch_id
    WHERE i.branch_id = ? AND i.invoice_type = ? AND i.id = ? AND i.deleted_us IS NULL
  ''',
  [branch, kind.name, id],
)).singleOrNull;

Future<List<_CommerceRow>> _commerceRows(
  Transaction txn,
  String table,
  String branch,
  String column,
  String id, {
  String order = 'id',
}) => txn.query(
  table,
  where: 'branch_id = ? AND $column = ?',
  whereArgs: [branch, id],
  orderBy: order,
);

double? _commerceDecimal(_CommerceRow row, String key, int scale) {
  final value = row[key] as int?;
  return value == null ? null : value / scale;
}

String? _commerceDate(Object? time) => time == null
    ? null
    : DateTime.fromMicrosecondsSinceEpoch(
        time as int,
        isUtc: true,
      ).toIso8601String();

Map<String, dynamic> _commerceInvoiceLine(
  _CommerceRow row,
  bool showProfit,
) => {
  for (final key in [
    'id',
    'product_id',
    'product_name',
    'unit_id',
    'unit_name',
    'description',
    'image',
    'price_currency',
  ])
    key: row[key],
  'quantity': _commerceDecimal(row, 'quantity_micro', 1000000),
  'returned_quantity': _commerceDecimal(row, 'returned_micro', 1000000),
  'returnable_quantity':
      max(0, (row['quantity_micro'] as int) - (row['returned_micro'] as int)) /
      1000000,
  'base_quantity': _commerceDecimal(row, 'base_micro', 1000000),
  'factor': _commerceDecimal(row, 'factor_4', 10000),
  'unit_price': _commerceDecimal(row, 'unit_minor', 100),
  'discount': _commerceDecimal(row, 'discount_minor', 100),
  'tax_rate': _commerceDecimal(row, 'tax_rate_2', 100),
  'total': _commerceDecimal(row, 'total_minor', 100),
  'is_service': row['is_service'] == 1,
  'original_unit_price': _commerceDecimal(row, 'original_minor', 100),
  'exchange_rate_used': row['exchange_rate'],
  if (showProfit) ...{
    'cost_total': _commerceDecimal(row, 'cost_total_minor', 100),
    'profit': _commerceDecimal(row, 'profit_minor', 100),
  },
};

/// A number matches its full stored form or the short form people see.
bool _numberMatches(Object? number, String query) =>
    '$number'.toLowerCase().contains(query) ||
    shortDocumentNumber(number).toLowerCase().contains(query);
