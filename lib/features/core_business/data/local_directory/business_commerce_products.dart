part of 'directory_database.dart';

/// Local product management for the original Inventory screens. Products,
/// their units, barcodes and per-currency prices live on the device with the
/// same identities and constraints as the connected catalogue.
extension BusinessCommerceProducts on BusinessLedger {
  /// Resolve a quick-added line inside the issue transaction. A
  /// failed payment or stock write must not leave an orphaned catalogue row.
  Future<(String, String)> _quickCommerceProduct(
    Transaction txn,
    String branch,
    String commandId,
    int index,
    String currency,
    CommerceIssueLine line,
    Map<String, Object?> input,
    DateTime now, {
    required bool purchase,
  }) async {
    final name = _commerceName('${input['name'] ?? ''}');
    final unit = _commerceName('${input['unit'] ?? 'قطعة'}');
    final rawCode = (input['barcode'] as String?)?.trim();
    final code = rawCode == null || rawCode.isEmpty
        ? null
        : _commerceName(rawCode);
    final category = input['category_id'] as String?;
    final hit = code == null
        ? null
        : await _commerceCodeMatch(txn, branch, code);
    final matching = hit == null
        ? await txn.query(
            _commerceProducts,
            columns: ['id'],
            where:
                'branch_id = ? AND lower(name) = lower(?) AND deleted_us IS NULL',
            whereArgs: [branch, name],
            limit: 2,
          )
        : const <Map<String, Object?>>[];
    if (matching.length > 1) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
    }
    final existing =
        hit?['product_id'] as String? ??
        matching.singleOrNull?['id'] as String?;
    final productId =
        existing ?? const Uuid().v5(commandId, 'quick-product:$index');
    if (existing == null) {
      await _requireUniqueCode(txn, branch, code, null);
      final costCurrency = businessCurrency(
        '${input['buy_currency'] ?? currency}',
      );
      final costMinor =
          line.priceCurrency == costCurrency && line.originalUnitMinor != null
          ? line.originalUnitMinor!
          : line.unitMinor;
      final sellPrice = _commerceMinor(input['sell_price'] ?? 0);
      BusinessLedger._amount(sellPrice, zero: true);
      await txn.insert(_commerceProducts, {
        'branch_id': branch,
        'id': productId,
        'name': name,
        'unit': unit,
        'price_minor': sellPrice,
        'cost_minor': purchase ? costMinor : 0,
        'cost_currency': costCurrency,
        'min_stock_4': _commerceScaledInput(input['min_stock'] ?? 0, 4),
        'is_service': 0,
        'is_active': 1,
        'barcode': code,
        'expiry_date': input['expiry_date'],
        'created_us': now.toUtc().microsecondsSinceEpoch,
      });
      if (category != null) {
        await _setProductCategory(txn, branch, productId, category);
      }
      if (input['sell_currency'] != null) {
        await _replaceCommercePrices(txn, branch, commandId, productId, [
          {'currency': input['sell_currency'], 'price': sellPrice / 100},
        ], identity: 'quick:$index');
      }
    }
    final previousUnits = await _commerceUnitMap(txn, branch, productId);
    final foundUnit =
        hit?['unit_id'] ??
        previousUnits.values
            .where((row) => row['name'] == unit && row['is_active'] == 1)
            .firstOrNull?['id'];
    final unitId =
        foundUnit as String? ?? const Uuid().v5(commandId, 'quick-unit:$index');
    if (foundUnit == null) {
      await txn.insert(_commerceUnits, {
        'branch_id': branch,
        'id': unitId,
        'product_id': productId,
        'name': unit,
        'factor_4': 10000,
        'is_base': existing == null ? 1 : 0,
        'is_active': 1,
      });
    }
    if (existing != null && code != null && hit == null) {
      await _requireUniqueCode(txn, branch, code, null);
      await txn.insert(_commerceBarcodes, {
        'branch_id': branch,
        'id': const Uuid().v5(commandId, 'quick-barcode:$index'),
        'product_id': productId,
        'unit_id': unitId,
        'barcode': code,
      });
    }
    return (productId, unitId);
  }

  Future<Map<String, Object?>> createCommerceProduct(
    BusinessLedgerAccess access, {
    required String commandId,
    required String name,
    required String unit,
    required Object? price,
    Object? costPrice,
    String costCurrency = 'SAR',
    Object? minStock,
    Object? stock,
    bool isService = false,
    String? barcode,
    String? sku,
    String? description,
    String? expiryDate,
    String? notes,
    String? image,
    String? categoryId,
    List<Map<String, Object?>>? prices,
    bool Function()? allowed,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageProducts);
    final clean = _commerceName(name);
    final baseUnit = _commerceName(unit);
    final priceMinor = _commerceMinor(price);
    final costMinor = costPrice == null ? 0 : _commerceMinor(costPrice);
    final minStock4 = minStock == null ? 0 : _commerceScaledInput(minStock, 4);
    final stockMilli = stock == null ? 0 : _commerceScaledInput(stock, 3);
    BusinessLedger._amount(priceMinor, zero: true);
    BusinessLedger._amount(costMinor, zero: true);
    if (image != null) _checkInventoryImage(image);
    if (stockMilli < 0 ||
        stockMilli > 99999999999999 ||
        (isService && stockMilli != 0)) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
    }
    return _commit(
      branch,
      commandId,
      [
        'create_product',
        clean,
        baseUnit,
        priceMinor,
        costMinor,
        costCurrency,
        minStock4,
        stockMilli,
        isService,
        barcode,
        sku,
        description,
        expiryDate,
        notes,
        if (image != null || prices != null)
          ['form', _imageDigest(image), prices],
        if (categoryId != null) ['category', categoryId],
      ],
      (txn, now) async {
        await _requireUniqueCode(txn, branch, barcode, sku);
        final id = const Uuid().v5(commandId, 'fyona.commerce.product.v1');
        await txn.insert(_commerceProducts, {
          'branch_id': branch,
          'id': id,
          'name': clean,
          'unit': baseUnit,
          'price_minor': priceMinor,
          'cost_minor': costPrice == null ? null : costMinor,
          'cost_currency': businessCurrency(costCurrency),
          'min_stock_4': minStock4,
          'is_service': isService ? 1 : 0,
          'is_active': 1,
          'barcode': barcode,
          'sku': sku,
          'description': description,
          'expiry_date': expiryDate,
          'notes': notes,
          'image': image,
          'created_us': now.toUtc().microsecondsSinceEpoch,
        });
        if (categoryId != null) {
          await _setProductCategory(txn, branch, id, categoryId);
        }
        await txn.insert(_commerceUnits, {
          'branch_id': branch,
          'id': const Uuid().v5(commandId, 'fyona.commerce.unit.v1:base'),
          'product_id': id,
          'name': baseUnit,
          'factor_4': 10000,
          'is_base': 1,
          'is_active': 1,
        });
        if (stockMilli > 0) {
          await txn.insert(_commerceStock, {
            'branch_id': branch,
            'id': const Uuid().v5(commandId, 'fyona.commerce.stock.v1'),
            'product_id': id,
            'quantity_milli': stockMilli,
            'avg_cost_4': costMinor * 100,
          });
          await _receiveInventoryBatch(
            txn,
            branch: branch,
            id: const Uuid().v5(id, 'fyona.commerce.initial-batch.v1'),
            product: id,
            quantity: stockMilli * 1000,
            source: 'initial',
            now: now,
            cost4: costPrice == null ? null : costMinor * 100,
            currency: businessCurrency(costCurrency),
            expiryDate: expiryDate,
          );
        }
        if (prices != null) {
          await _replaceCommercePrices(txn, branch, commandId, id, prices);
        }
        return {'id': id};
      },
      allowed: allowed,
    );
  }

  /// Apply only the keys present in [changes]; an explicit null clears the
  /// field, exactly like the connected product update contract.
  Future<Map<String, Object?>> updateCommerceProduct(
    BusinessLedgerAccess access, {
    required String commandId,
    required String productId,
    required Map<String, Object?> changes,
    List<Map<String, Object?>>? prices,
    bool Function()? allowed,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageProducts);
    if (changes['image'] case final String image) _checkInventoryImage(image);
    return _commit(
      branch,
      commandId,
      [
        'update_product',
        productId,
        for (final entry in changes.entries) ...[
          entry.key,
          entry.key == 'image'
              ? _imageDigest(entry.value as String?)
              : entry.value,
        ],
        if (prices != null) ['form_prices', prices],
      ],
      (txn, now) async {
        await _commerceProductRow(txn, branch, productId);
        final fields = <String, Object?>{};
        void put(String column, Object? value) {
          if (value != null || changes.containsKey(column)) {
            fields[column] = value;
          }
        }

        if (changes.containsKey('name')) {
          fields['name'] = _commerceName('${changes['name']}');
        }
        if (changes.containsKey('unit')) {
          fields['unit'] = _commerceName('${changes['unit']}');
        }
        if (changes.containsKey('price')) {
          fields['price_minor'] = _commerceMinor(changes['price']);
        }
        if (changes.containsKey('cost_price')) {
          fields['cost_minor'] = changes['cost_price'] == null
              ? null
              : _commerceMinor(changes['cost_price']);
        }
        if (changes.containsKey('cost_currency')) {
          fields['cost_currency'] = changes['cost_currency'] == null
              ? null
              : businessCurrency('${changes['cost_currency']}');
        }
        if (changes.containsKey('min_stock')) {
          fields['min_stock_4'] = _commerceScaledInput(changes['min_stock'], 4);
        }
        if (changes.containsKey('is_service')) {
          fields['is_service'] = _fixtureFlag(changes['is_service']);
        }
        if (changes.containsKey('is_active')) {
          fields['is_active'] = _fixtureFlag(changes['is_active']);
        }
        put('barcode', changes['barcode']);
        put('sku', changes['sku']);
        put('description', changes['description']);
        put('expiry_date', changes['expiry_date']);
        put('notes', changes['notes']);
        put('image', changes['image']);
        final hasCategory = changes.containsKey('category_id');
        if (hasCategory &&
            changes.containsKey('expected_category_id') &&
            await _productCategoryId(txn, branch, productId) !=
                changes['expected_category_id']) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.commandConflict,
          );
        }
        if (fields.isEmpty && !hasCategory && prices == null) {
          throw const BusinessLedgerError(BusinessLedgerProblem.noChanges);
        }
        await _requireUniqueCode(
          txn,
          branch,
          fields['barcode'] as String?,
          fields['sku'] as String?,
          except: productId,
        );
        if (fields.isNotEmpty) {
          await txn.update(
            _commerceProducts,
            fields,
            where: 'branch_id = ? AND id = ?',
            whereArgs: [branch, productId],
          );
        }
        if (hasCategory) {
          await _setProductCategory(
            txn,
            branch,
            productId,
            changes['category_id'] as String?,
          );
        }
        if (fields['unit'] != null) {
          await txn.update(
            _commerceUnits,
            {'name': fields['unit']},
            where: 'branch_id = ? AND product_id = ? AND is_base = 1',
            whereArgs: [branch, productId],
          );
        }
        if (prices != null) {
          await _replaceCommercePrices(
            txn,
            branch,
            commandId,
            productId,
            prices,
          );
        }
        return {'id': productId};
      },
      allowed: allowed,
    );
  }

  Future<void> deleteCommerceProduct(
    BusinessLedgerAccess access, {
    required String commandId,
    required String productId,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageProducts);
    return _commit(branch, commandId, ['delete_product', productId], (
      txn,
      now,
    ) async {
      await _commerceProductRow(txn, branch, productId);
      await txn.update(
        _commerceProducts,
        {'is_active': 0, 'deleted_us': now.toUtc().microsecondsSinceEpoch},
        where: 'branch_id = ? AND id = ?',
        whereArgs: [branch, productId],
      );
      return {'id': productId};
    });
  }

  Future<Map<String, Object?>> createCommerceUnit(
    BusinessLedgerAccess access, {
    required String commandId,
    required String productId,
    required String name,
    required Object? factor,
    String? barcode,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageProducts);
    final clean = _commerceName(name);
    final factor4 = _commerceScaledInput(factor, 4);
    if (factor4 <= 0) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
    }
    return _commit(
      branch,
      commandId,
      ['create_unit', productId, clean, factor4, barcode],
      (txn, now) async {
        await _commerceProductRow(txn, branch, productId);
        await _requireUniqueCode(txn, branch, barcode, null);
        final duplicate = await txn.query(
          _commerceUnits,
          columns: ['id'],
          where: 'branch_id = ? AND product_id = ? AND name = ?',
          whereArgs: [branch, productId, clean],
          limit: 1,
        );
        if (duplicate.isNotEmpty) {
          throw const BusinessLedgerError(
            BusinessLedgerProblem.duplicateProductCode,
          );
        }
        final id = const Uuid().v5(commandId, 'fyona.commerce.unit.v1');
        await txn.insert(_commerceUnits, {
          'branch_id': branch,
          'id': id,
          'product_id': productId,
          'name': clean,
          'factor_4': factor4,
          'barcode': barcode,
          'is_base': 0,
          'is_active': 1,
        });
        return {'id': id};
      },
    );
  }

  Future<void> deleteCommerceUnit(
    BusinessLedgerAccess access, {
    required String commandId,
    required String unitId,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageProducts);
    return _commit(branch, commandId, ['delete_unit', unitId], (
      txn,
      now,
    ) async {
      final unit = (await txn.query(
        _commerceUnits,
        where: 'branch_id = ? AND id = ?',
        whereArgs: [branch, unitId],
      )).singleOrNull;
      if (unit == null || unit['is_base'] == 1) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
      }
      final used = await txn.query(
        _commerceLines,
        columns: ['id'],
        where: 'branch_id = ? AND unit_id = ?',
        whereArgs: [branch, unitId],
        limit: 1,
      );
      final held = await txn.query(
        _commerceLots,
        columns: ['id'],
        where: 'branch_id = ? AND unit_id = ?',
        whereArgs: [branch, unitId],
        limit: 1,
      );
      if (used.isNotEmpty || held.isNotEmpty) {
        // Historical documents and lots keep their frozen unit snapshot.
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
      }
      await txn.delete(
        _commerceUnits,
        where: 'branch_id = ? AND id = ?',
        whereArgs: [branch, unitId],
      );
      return {'id': unitId};
    });
  }

  Future<Map<String, Object?>> addCommerceBarcode(
    BusinessLedgerAccess access, {
    required String commandId,
    required String productId,
    required String barcode,
    String? unitId,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageProducts);
    final code = _commerceName(barcode);
    return _commit(
      branch,
      commandId,
      ['add_barcode', productId, code, unitId],
      (txn, now) async {
        await _commerceProductRow(txn, branch, productId);
        final units = await _commerceUnitMap(txn, branch, productId);
        if (unitId != null && units[unitId]?['product_id'] != productId) {
          throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
        }
        await _requireUniqueCode(txn, branch, code, null);
        final id = const Uuid().v5(commandId, 'fyona.commerce.barcode.v1');
        await txn.insert(_commerceBarcodes, {
          'branch_id': branch,
          'id': id,
          'product_id': productId,
          'unit_id': unitId,
          'barcode': code,
        });
        return {'id': id};
      },
    );
  }

  Future<void> deleteCommerceBarcode(
    BusinessLedgerAccess access, {
    required String commandId,
    required String barcodeId,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageProducts);
    return _commit(branch, commandId, ['delete_barcode', barcodeId], (
      txn,
      now,
    ) async {
      final deleted = await txn.delete(
        _commerceBarcodes,
        where: 'branch_id = ? AND id = ?',
        whereArgs: [branch, barcodeId],
      );
      if (deleted != 1) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
      }
      return {'id': barcodeId};
    });
  }

  /// Per-currency prices replace the product's saved price set in one command.
  Future<void> setCommercePrices(
    BusinessLedgerAccess access, {
    required String commandId,
    required String productId,
    required List<Map<String, Object?>> prices,
  }) {
    final branch = _branch(access, BusinessLedgerAction.manageProducts);
    return _commit(
      branch,
      commandId,
      [
        'set_prices',
        productId,
        for (final price in prices)
          [price['currency'], price['price'], price['buy_price']],
      ],
      (txn, now) async {
        await _commerceProductRow(txn, branch, productId);
        await _replaceCommercePrices(txn, branch, commandId, productId, prices);
        return {'id': productId};
      },
    );
  }

  Future<void> _replaceCommercePrices(
    Transaction txn,
    String branch,
    String commandId,
    String productId,
    List<Map<String, Object?>> prices, {
    String identity = '',
  }) async {
    final seen = <String>{};
    final existing = {
      for (final row in await _commerceRows(
        txn,
        _commercePrices,
        branch,
        'product_id',
        productId,
      ))
        row['currency']: row['id'],
    };
    final rows = <Map<String, Object?>>[];
    for (final price in prices) {
      final currency = businessCurrency('${price['currency']}');
      if (!seen.add(currency)) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
      }
      final sell = _commerceMinor(price['price']);
      final buy = price['buy_price'] == null
          ? null
          : _commerceMinor(price['buy_price']);
      if (sell < 0 || (buy ?? 0) < 0) {
        throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
      }
      rows.add({
        'branch_id': branch,
        'id':
            existing[currency] ??
            const Uuid().v5(
              commandId,
              'fyona.commerce.price.v1:$currency$identity',
            ),
        'product_id': productId,
        'currency': currency,
        'price_minor': sell,
        'buy_minor': buy,
      });
    }
    await txn.delete(
      _commercePrices,
      where: 'branch_id = ? AND product_id = ?',
      whereArgs: [branch, productId],
    );
    for (final row in rows) {
      await txn.insert(_commercePrices, row);
    }
  }

  /// Units in the connected response shape for the existing unit screens.
  Future<Map<String, dynamic>> commerceProductUnits(
    BusinessLedgerAccess access,
    String productId,
  ) async {
    final branch = _branch(access, BusinessLedgerAction.readInventory);
    final showCost = access._actions.contains(
      BusinessLedgerAction.readInventoryCost,
    );
    return _directory._transaction((txn) async {
      final units = await _commerceUnitMap(txn, branch, productId);
      return {
        'units': [
          for (final unit in units.values)
            {
              for (final key in ['id', 'name', 'barcode']) key: unit[key],
              'group': unit['family'],
              'factor': _commerceDecimal(unit, 'factor_4', 10000),
              'sale_price': _commerceDecimal(unit, 'sale_minor', 100),
              if (showCost)
                'purchase_price': _commerceDecimal(unit, 'purchase_minor', 100),
              'is_base': unit['is_base'] == 1,
              'is_active': unit['is_active'] == 1,
            },
        ],
      };
    });
  }

  Future<Map<String, Object?>> _commerceProductRow(
    Transaction txn,
    String branch,
    String productId,
  ) async {
    final row = (await txn.query(
      _commerceProducts,
      where: 'branch_id = ? AND id = ? AND deleted_us IS NULL',
      whereArgs: [branch, productId],
    )).singleOrNull;
    if (row == null) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
    }
    return row;
  }

  Future<Map<String, Map<String, Object?>>> _commerceUnitMap(
    Transaction txn,
    String branch,
    String productId,
  ) async {
    final rows = await txn.query(
      _commerceUnits,
      where: 'branch_id = ? AND product_id = ?',
      whereArgs: [branch, productId],
      orderBy: 'is_base DESC, name, id',
    );
    return {for (final row in rows) row['id'] as String: row};
  }

  Future<void> _requireUniqueCode(
    Transaction txn,
    String branch,
    String? barcode,
    String? sku, {
    String? except,
  }) async {
    if (barcode == null && sku == null) return;
    if (barcode != null) {
      final hits = await txn.rawQuery(
        '''
        SELECT 1 FROM $_commerceProducts
          WHERE branch_id = ? AND barcode = ? AND deleted_us IS NULL ${except == null ? '' : ' AND id <> ?'}
        UNION ALL
        SELECT 1 FROM $_commerceUnits WHERE branch_id = ? AND barcode = ? ${except == null ? '' : ' AND product_id <> ?'}
        UNION ALL
        SELECT 1 FROM $_commerceBarcodes WHERE branch_id = ? AND barcode = ? ${except == null ? '' : ' AND product_id <> ?'}
        LIMIT 1
        ''',
        [
          branch,
          barcode,
          ?except,
          branch,
          barcode,
          ?except,
          branch,
          barcode,
          ?except,
        ],
      );
      if (hits.isNotEmpty) {
        throw const BusinessLedgerError(
          BusinessLedgerProblem.duplicateProductCode,
        );
      }
    }
    if (sku != null) {
      final hits = await txn.query(
        _commerceProducts,
        columns: ['id'],
        where:
            'branch_id = ? AND sku = ? AND deleted_us IS NULL'
            '${except == null ? '' : ' AND id <> ?'}',
        whereArgs: [branch, sku, ?except],
        limit: 1,
      );
      if (hits.isNotEmpty) {
        throw const BusinessLedgerError(
          BusinessLedgerProblem.duplicateProductCode,
        );
      }
    }
  }
}

String _commerceName(String value) {
  final clean = value.trim();
  if (clean.isEmpty || clean.runes.length > 200) {
    throw const BusinessLedgerError(BusinessLedgerProblem.invalidProduct);
  }
  return clean;
}

String? _imageDigest(String? image) =>
    image == null ? null : sha256.convert(utf8.encode(image)).toString();

int _commerceMinor(Object? value) =>
    BusinessMoney.minor(_commerceDecimalInput(value));

int _commerceScaledInput(Object? value, int precision) {
  final text = _commerceDecimalInput(value);
  final pattern = '^(\\d+)(?:\\.(\\d{1,$precision}))?\$';
  final match = RegExp(pattern).firstMatch(text);
  if (match == null) {
    throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
  }
  final fraction = (match[2] ?? '').padRight(precision, '0');
  return int.parse('${match[1]}$fraction');
}

String _commerceDecimalInput(Object? value) {
  if (value is String) return value.trim();
  if (value is num) {
    final text = value.toString();
    return text.contains('e') || text.contains('E')
        ? value.toStringAsFixed(6)
        : text;
  }
  throw const BusinessLedgerError(BusinessLedgerProblem.invalidAmount);
}
