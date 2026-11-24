import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:uuid/enums.dart';
import '../../../../core/services/currency/currency_engine.dart' show currencyEngineProvider;

import '../../../../core/network/api_client.dart';
import '../../../branches/data/branch_epoch.dart';
import '../../../branches/data/branch_scope.dart';
import '../../../dashboard/data/business_finance_api.dart';
import '../../../employees/data/employee_permissions.dart';
import '../../../employees/presentation/providers/employee_providers.dart';
import '../../../inventory/data/inventory_api.dart';
import '../../../invoices/data/invoices_api.dart';
import '../../../purchases/data/purchase_api.dart';
import '../../../returns/data/returns_api.dart';
import '../../../sales/data/sales_api.dart';
import '../../data/local_directory/directory_database.dart';
import '../../data/local_directory/directory_party.dart';
import '../../data/local_directory/directory_pilot.dart';
import '../../data/local_directory/directory_scope.dart';
import '../../data/local_ledger/business_money.dart';
import '../../data/local_ledger/business_debt_projection.dart';
import '../../presentation/providers/business_ledger_session.dart';

/// One device source behind the original invoice and inventory APIs. While
/// the branch's local ledger is selected, its documents and products come
/// from SQLCipher with no HTTP and no spinner; every other connected branch
/// keeps the untouched REST implementation.
final class LocalCommerceBridge {
  LocalCommerceBridge(
    this._store,
    this._scope,
    this._can, {
    void Function()? bankChanged,
    void Function()? operationsChanged,
    bool Function()? fullAccess,
    double? Function(String from, String to)? rate,
  }) : _selected = _scope(),
       _bankChanged = bankChanged,
       _operationsChanged = operationsChanged,
       _fullAccess = fullAccess ?? _notAllowed,
       _falconRate = rate;

  final DirectoryPilotStore _store;
  final DirectoryAccess? Function() _scope;
  final bool Function(String permission) _can;
  final DirectoryAccess? _selected;
  final void Function()? _bankChanged;
  final void Function()? _operationsChanged;
  final bool Function() _fullAccess;
  final double? Function(String from, String to)? _falconRate;

  static bool _notAllowed() => false;

  /// The Falcon's per-product figures for this branch, in [currency]: the
  /// same stock, prices and sales/cost/profit the product screens show.
  Future<({List<Map<String, dynamic>> items, String? category})> falconFigures(
    String scope,
    String? refId,
    String currency,
  ) async {
    final target = currency.trim().toUpperCase();
    final rows = <Map<String, dynamic>>[];
    String? category;
    if (scope == 'product' && refId != null) {
      final p = await product(refId);
      if (p != null) rows.add(p);
      category = p?['category_name']?.toString();
    } else {
      for (var offset = 0; offset < 1500; offset += 300) {
        final page = await products(
          limit: 300,
          offset: offset,
          categoryId: scope == 'category' ? refId : null,
        );
        rows.addAll(page);
        if (page.length < 300) break;
      }
      if (scope == 'category') {
        category = rows.firstOrNull?['category_name']?.toString();
      }
    }
    double number(Object? v) => double.tryParse('${v ?? ''}') ?? 0;
    double priced(Object? amount, String? from) {
      final value = number(amount);
      final source = (from ?? '').trim().toUpperCase();
      if (value == 0 || source.isEmpty || source == target) return value;
      final r = _falconRate?.call(source, target);
      return r == null || !r.isFinite || r <= 0 ? 0 : value * r;
    }

    final items = <Map<String, dynamic>>[];
    for (final p in rows) {
      final id = '${p['id']}';
      Map<String, dynamic> stats;
      try {
        stats = await productStats(id, displayCurrency: target);
      } catch (_) {
        stats = const {};
      }
      final costCurrency = p['cost_currency']?.toString();
      final listed = (p['prices'] as List? ?? const [])
          .whereType<Map>()
          .firstWhere((row) => '${row['currency']}'.toUpperCase() == target,
              orElse: () => const {});
      items.add({
        'id': id,
        'name': p['name'] ?? p['name_ar'] ?? '',
        'unit': p['unit'],
        'stock': number(p['stock']),
        'min_stock': number(p['min_stock']),
        'sell_price': listed.isNotEmpty ? number(listed['price']) : priced(p['price'], costCurrency),
        'cost_price': priced(p['avg_cost'] ?? p['cost_price'], costCurrency),
        'sales': number(stats['sales_total']),
        'qty_sold': number(stats['sales_quantity']),
        'cogs': number(stats['cogs']),
        'profit': number(stats['profit']),
        'purchases': number(stats['purchases_total']),
        'qty_purchased': number(stats['purchases_quantity']),
        'expiry_date': p['expiry_date'],
        'fx_incomplete': stats['fx_incomplete'] == true,
      });
    }
    return (items: items, category: category);
  }
  bool get canAuthorizeReturnOverdraft =>
      _fullAccess() && _current(['banks.balances']);
  bool get canRememberReturnOverdraft =>
      canAuthorizeReturnOverdraft && _current(['banks']);

  bool get active => _selected?.financialCutover == true;

  bool _current(Iterable<String> permissions) {
    final current = _scope();
    return active &&
        current?.financialCutover == true &&
        sameDirectoryScope(_selected, current) &&
        permissions.every(_can);
  }

  DirectoryAccess _require(List<String> permissions) {
    if (!_current(permissions)) throw const DirectoryAccessDenied();
    return _selected!;
  }

  Future<T> _run<T>(
    Set<BusinessLedgerAction> actions,
    List<String> permissions,
    Future<T> Function(BusinessLedger, BusinessLedgerAccess) execute, {
    bool Function()? stillAllowed,
  }) async {
    final scope = _require(permissions);
    final grant = BusinessLedgerAccess(scope, actions);
    return _store.withLedger(
      grant,
      () => _current(permissions) && (stillAllowed?.call() ?? true) ? _scope() : null,
      (ledger) => execute(ledger, grant),
    );
  }

  Future<T> _read<T>(
    Set<BusinessLedgerAction> actions,
    List<String> permissions,
    Future<T> Function(BusinessLedger, BusinessLedgerAccess) execute, {
    String? privateFieldsPermission,
  }) async {
    final allowedPrivate =
        privateFieldsPermission != null && _can(privateFieldsPermission);
    final guarded = [
      ...permissions,
      if (allowedPrivate) privateFieldsPermission,
    ];
    final result = await _run(actions, guarded, execute);
    _require(guarded);
    return result;
  }

  Future<List<dynamic>> searchParties(
    DirectoryPartyKind kind,
    String query,
  ) async {
    final permissions = ['${kind.name}s'];
    final scope = _require(permissions);
    final rows = await _store.search(scope, kind, query);
    _require(permissions);
    return rows.map(_partyMap).toList();
  }

  Future<Map<String, dynamic>> party(DirectoryPartyKind kind, String id) async {
    final permissions = ['${kind.name}s'];
    final row = await _store.find(_require(permissions), kind, id);
    _require(permissions);
    return _partyMap(row);
  }

  Future<Map<String, dynamic>> createParty(
    DirectoryPartyKind kind,
    String name,
    String? phone,
    String? commandId,
  ) async {
    final permissions = ['${kind.name}s.add'];
    final scope = _require(permissions);
    return _partyMap(
      await _store.add(
        scope,
        kind,
        name: name,
        phone: phone,
        id: commandId,
        stillAllowed: () => _current(permissions),
      ),
    );
  }

  Future<void> updateParty(
    DirectoryPartyKind kind,
    String id,
    String? name,
    String? phone,
  ) => _store.update(
    _require(['${kind.name}s.edit']),
    kind,
    id,
    name: name,
    phone: phone,
    stillAllowed: () => _current(['${kind.name}s.edit']),
  );

  Future<Map<String, dynamic>> partyBalance(
    DirectoryPartyKind kind,
    String id,
  ) async {
    final permissions = ['${kind.name}s.details'];
    final rows = await _run(
      {BusinessLedgerAction.readDebt},
      permissions,
      (ledger, grant) => ledger.debts(
        grant,
        DirectoryPartyReference(scope: grant.directory, kind: kind, id: id),
      ),
    );
    _require(permissions);
    final projection = BusinessDebtProjection(rows);
    return {'debts': projection.perCurrency, 'items': projection.operations};
  }

  Future<List<Map<String, dynamic>>> partyGroups(
    DirectoryPartyKind kind,
    String id,
  ) async {
    final permissions = ['${kind.name}s.details'];
    final scope = _require(permissions);
    final rows = await _store.groups(
      scope,
      DirectoryPartyReference(scope: scope, kind: kind, id: id),
    );
    _require(permissions);
    return rows;
  }

  static Map<String, dynamic> _partyMap(DirectoryParty party) => {
    'id': party.id,
    'name': party.name,
    'phone': party.phone,
    'branch_id': party.branchId,
  };

  static String _decimal(num value) {
    final text = value.toString();
    if (text.contains('e') || text.contains('E')) {
      return value.toStringAsFixed(6);
    }
    return text;
  }

  static BusinessRate? _rate(Object? raw, String from, String to) {
    if (raw == null || from == to) return null;
    return BusinessRate(from, to, _decimal(raw as num));
  }

  /// The connected issue body, saved through the local document engine and
  /// answered in the connected response shape.
  Future<Map<String, dynamic>> issueDocument(
    Map<String, dynamic> body, {
    required bool purchase,
  }) async {
    final items = (body['items'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final kind = purchase
        ? BusinessInvoiceKind.purchase
        : BusinessInvoiceKind.sale;
    final currency = '${body['currency']}'.toUpperCase();
    final discountType = body['discount_type'] as String?;
    final taxType = body['tax_type'] as String?;
    final partyId = body[purchase ? 'supplier_id' : 'customer_id'] as String?;
    final permissions = [
      purchase ? 'purchases.create' : 'sales.create',
      if (partyId != null) purchase ? 'suppliers' : 'customers',
      if (items.any((item) => item['product_id'] != null)) 'inventory',
      if (items.any(
        (item) =>
            item['new_product'] is Map &&
            item['new_product']['save_to_inventory'] != false,
      ))
        'inventory.add',
    ];
    final hasPayments = (body['payments'] as List?)?.isNotEmpty ?? false;
    final issued = await _run(
      {BusinessLedgerAction.issueDocument},
      permissions,
      (ledger, grant) => ledger.issueCommerceDocument(
        grant,
        kind: kind,
        commandId: _invoiceCommand(body['idempotency_key'], kind),
        currency: currency,
        partyId: partyId,
        groupId: body['debt_group_id'] as String?,
        discountType: discountType,
        discountValue2: discountType == null
            ? 0
            : BusinessMoney.minor(
                _decimal(body['discount_value'] as num? ?? 0),
              ),
        taxType: taxType,
        taxRate2: taxType == null
            ? 0
            : BusinessMoney.minor(_decimal(body['tax_rate'] as num? ?? 0)),
        notes: body['notes'] as String?,
        dueDate: body['due_date'] as String?,
        lines: [
          for (final item in items)
            CommerceIssueLine(
              description: '${item['description'] ?? ''}',
              quantity: _decimal(item['quantity'] as num? ?? 1),
              unitMinor: BusinessMoney.minor(
                _decimal(item['unit_price'] as num? ?? 0),
              ),
              discountMinor: BusinessMoney.minor(
                _decimal(item['discount'] as num? ?? 0),
              ),
              productId: item['product_id']?.toString(),
              unitId: item['unit_id']?.toString(),
              isService: item['product_id'] == null,
              expiryDate: item['expiry_date']?.toString(),
              lotNumber: item['lot_number']?.toString(),
              newProduct: item['new_product'] == null
                  ? null
                  : Map<String, Object?>.from(item['new_product'] as Map),
              originalUnitMinor: item['original_price'] == null
                  ? null
                  : BusinessMoney.minor(
                      _decimal(item['original_price'] as num),
                    ),
              priceCurrency: item['price_currency'] as String?,
              priceRate: item['price_currency'] == null
                  ? null
                  : _rate(
                      item['exchange_rate'],
                      '${item['price_currency']}',
                      currency,
                    ),
            ),
        ],
        payments: [
          for (final payment
              in (body['payments'] as List? ?? const []).whereType<Map>())
            CommerceIssuePayment(
              accountId: '${payment['bank_account_id']}',
              originalMinor: BusinessMoney.minor(
                _decimal(payment['amount'] as num? ?? 0),
              ),
              paymentCurrency: '${payment['currency'] ?? currency}'
                  .toUpperCase(),
              method: '${payment['payment_method'] ?? 'bank'}',
              rate: _rate(
                payment['exchange_rate'],
                '${payment['currency'] ?? currency}'.toUpperCase(),
                currency,
              ),
            ),
        ],
      ),
    );
    if (hasPayments && _current(const [])) _bankChanged?.call();
    if (_current(const [])) _operationsChanged?.call();
    // Issuing does not require permission to browse other invoices. The
    // response is only the receipt for the command just committed.
    final receipt = await _run(
      {
        purchase
            ? BusinessLedgerAction.readPurchaseInvoice
            : BusinessLedgerAction.readSaleInvoice,
        if (_can('inventory_profit.read'))
          BusinessLedgerAction.readInvoiceProfit,
      },
      permissions,
      (ledger, grant) => ledger.commerceInvoice(grant, kind, '${issued['id']}'),
    );
    _require(permissions);
    if (receipt == null) throw const DirectoryAccessDenied();
    return receipt;
  }

  static String _invoiceCommand(Object? key, BusinessInvoiceKind kind) {
    if (key is! String || key.isEmpty || key.length > 100) {
      throw const BusinessLedgerError(BusinessLedgerProblem.invalidInvoice);
    }
    if (isDirectoryId(key) && key == key.toLowerCase()) return key;
    // Drafts retained from older builds used an opaque timestamp/random key.
    return const Uuid().v5(
      Namespace.url.value,
      'fyona.invoice/${kind.name}/$key',
    );
  }

  /// The connected document shape, read from the device. Null when the id is
  /// not an ordinary document of this branch; opening debts stay separate.
  Future<Map<String, dynamic>?> document(String id, {required bool purchase}) {
    final kind = purchase
        ? BusinessInvoiceKind.purchase
        : BusinessInvoiceKind.sale;
    return _read(
      {
        purchase
            ? BusinessLedgerAction.readPurchaseInvoice
            : BusinessLedgerAction.readSaleInvoice,
        if (_can('inventory_profit.read'))
          BusinessLedgerAction.readInvoiceProfit,
      },
      [purchase ? 'purchases.view' : 'sales.view'],
      (ledger, grant) => ledger.commerceInvoice(grant, kind, id),
      privateFieldsPermission: 'inventory_profit.read',
    );
  }

  Future<List<dynamic>> documents({
    required bool purchase,
    String? search,
    int limit = 100,
  }) {
    final kind = purchase
        ? BusinessInvoiceKind.purchase
        : BusinessInvoiceKind.sale;
    return _read(
      {
        purchase
            ? BusinessLedgerAction.readPurchaseInvoice
            : BusinessLedgerAction.readSaleInvoice,
      },
      [purchase ? 'purchases.view' : 'sales.view'],
      (ledger, grant) => ledger.commerceDocuments(
        grant,
        kind: kind,
        search: search,
        limit: limit,
      ),
    );
  }

  /// Payment accounts in the connected picker shape. Balances stay hidden
  /// without the separate balance permission.
  Future<List<dynamic>> paymentAccounts(String permission) async {
    final visible = _can('banks.balances');
    final rows = await _run(
      {BusinessLedgerAction.readBank},
      [permission],
      (ledger, grant) =>
          ledger.managedBankAccounts(grant, includeBalances: visible),
    );
    _require([permission]);
    final includeBalances = visible && _can('banks.balances');
    return [
      for (final row in rows)
        if (row['is_active'] == 1)
          {
            'id': row['id'],
            'bank_name': row['bank_name'],
            'account_name': row['account_name'],
            if (includeBalances)
              'balance': BusinessMoney.display(row['balance_minor'] as int),
            'balance_visible': includeBalances,
            'branch_id': _selected!.branchId,
            'currency': '${row['currency']}'.toUpperCase(),
            'account_type': row['account_type'],
          },
    ];
  }

  Future<List<Map<String, dynamic>>> products({
    String? search,
    int limit = 100,
    int offset = 0,
    bool activeOnly = false,
    String? stockStatus,
    String? expiry,
    int expiryDays = 60,
    String? categoryId,
    bool uncategorized = false,
  }) => _read(
    {
      BusinessLedgerAction.readInventory,
      if (_can('inventory_cost.read')) BusinessLedgerAction.readInventoryCost,
    },
    ['inventory'],
    (ledger, grant) => ledger.commerceProducts(
      grant,
      search: search,
      limit: limit,
      offset: offset,
      activeOnly: activeOnly,
      stockStatus: stockStatus,
      expiry: expiry,
      expiryDays: expiryDays,
      categoryId: categoryId,
      uncategorized: uncategorized,
    ),
    privateFieldsPermission: 'inventory_cost.read',
  );

  Future<Map<String, dynamic>?> product(String id) => _read(
    {
      BusinessLedgerAction.readInventory,
      if (_can('inventory_cost.read')) BusinessLedgerAction.readInventoryCost,
    },
    ['inventory'],
    (ledger, grant) => ledger.commerceInventoryProduct(grant, id),
    privateFieldsPermission: 'inventory_cost.read',
  );

  Future<List<Map<String, dynamic>>> movements(String id, {int limit = 60}) =>
      _read(
        {
          BusinessLedgerAction.readInventory,
          if (_can('inventory_cost.read'))
            BusinessLedgerAction.readInventoryCost,
        },
        ['inventory'],
        (ledger, grant) =>
            ledger.commerceStockMovements(grant, id, limit: limit),
        privateFieldsPermission: 'inventory_cost.read',
      );

  Future<Map<String, dynamic>> adjustStock(Map<String, dynamic> body) async {
    final productId = '${body['product_id']}';
    final mode = switch ('${body['mode']}') {
      'add' => BusinessStockAdjustment.add,
      'remove' => BusinessStockAdjustment.remove,
      'set' => BusinessStockAdjustment.set,
      _ => throw const DirectoryAccessDenied(),
    };
    final amountMilli = (double.parse(_decimal(body['amount'] as num)) * 1000)
        .round();
    final expected = body['expected_stock'] as num?;
    final current = expected == null ? await product(productId) : null;
    if (expected == null && current == null)
      throw const DirectoryAccessDenied();
    final expectedMilli =
        ((expected ?? (current?['stock'] as num? ?? 0)) * 1000).round();
    final command = await _run(
      {BusinessLedgerAction.adjustStock},
      ['inventory.count'],
      (ledger, grant) => ledger.adjustCommerceStock(
        grant,
        productId: productId,
        commandId: '${body['command_id'] ?? const Uuid().v4()}',
        mode: mode,
        amountMilli: amountMilli,
        expectedMilli: expectedMilli,
        reason: body['reason'] as String?,
        notes: body['notes'] as String?,
      ),
    );
    return {
      'id': command['id'],
      'movement_type': 'adjust_${mode.name}',
      'product_id': productId,
      'quantity': (command['delta_milli'] as int) / 1000,
      'old_quantity': (command['old_milli'] as int) / 1000,
      'new_quantity': (command['new_milli'] as int) / 1000,
      'difference': (command['delta_milli'] as int) / 1000,
      'reason': body['reason'],
      'notes': body['notes'],
    };
  }

  /// Product management in the original body contract, with category links
  /// scoped to the same branch transaction.
  Future<Map<String, dynamic>> createProduct(Map<String, dynamic> body) async {
    const permissions = ['inventory', 'inventory.add'];
    final created = await _run(
      {BusinessLedgerAction.manageProducts},
      permissions,
      (ledger, grant) => ledger.createCommerceProduct(
        grant,
        commandId: '${body['command_id'] ?? const Uuid().v4()}',
        name: '${body['name']}',
        unit: '${body['unit'] ?? 'قطعة'}',
        price: body['price'] ?? 0,
        costPrice: body['cost_price'],
        costCurrency: '${body['cost_currency'] ?? 'SAR'}',
        minStock: body['min_stock'],
        stock: body['stock'],
        isService: body['is_service'] == true,
        barcode: body['barcode'] as String?,
        sku: body['sku'] as String?,
        description: body['description'] as String?,
        expiryDate: body['expiry_date'] as String?,
        notes: body['notes'] as String?,
        image: body['image'] as String?,
        categoryId: body['category_id'] as String?,
        prices: _formPrices(body),
        allowed: () => _current(permissions),
      ),
    );
    _require(permissions);
    _operationsChanged?.call();
    return _productRow('${created['id']}');
  }

  Future<Map<String, dynamic>> updateProduct(
    String id,
    Map<String, dynamic> body,
  ) async {
    const permissions = ['inventory', 'inventory.edit'];
    await _run(
      {BusinessLedgerAction.manageProducts},
      permissions,
      (ledger, grant) => ledger.updateCommerceProduct(
        grant,
        commandId: '${body['command_id'] ?? const Uuid().v4()}',
        productId: id,
        prices: _formPrices(body),
        allowed: () => _current(permissions),
        changes: {
          for (final key in const [
            'name',
            'unit',
            'price',
            'cost_price',
            'cost_currency',
            'min_stock',
            'is_service',
            'is_active',
            'barcode',
            'sku',
            'description',
            'expiry_date',
            'notes',
            'image',
            'category_id',
            'expected_category_id',
          ])
            if (body.containsKey(key)) key: body[key],
        },
      ),
    );
    _require(permissions);
    _operationsChanged?.call();
    return _productRow(id);
  }

  Future<void> deleteProduct(String id) => _run(
    {BusinessLedgerAction.manageProducts},
    ['inventory.delete'],
    (ledger, grant) => ledger.deleteCommerceProduct(
      grant,
      commandId: const Uuid().v4(),
      productId: id,
    ),
  );

  Future<Map<String, dynamic>> productUnits(String id) => _read(
    {
      BusinessLedgerAction.readInventory,
      if (_can('inventory_cost.read')) BusinessLedgerAction.readInventoryCost,
    },
    ['inventory'],
    (ledger, grant) => ledger.commerceProductUnits(grant, id),
    privateFieldsPermission: 'inventory_cost.read',
  );

  Future<Map<String, dynamic>> createUnit(
    String id,
    Map<String, dynamic> body,
  ) async {
    final created = await _run(
      {BusinessLedgerAction.manageProducts},
      ['inventory.edit'],
      (ledger, grant) => ledger.createCommerceUnit(
        grant,
        commandId: '${body['command_id'] ?? const Uuid().v4()}',
        productId: id,
        name: '${body['name']}',
        factor: body['factor'],
        barcode: body['barcode'] as String?,
      ),
    );
    return Map<String, dynamic>.from(created);
  }

  Future<void> deleteUnit(String unitId) => _run(
    {BusinessLedgerAction.manageProducts},
    ['inventory.edit'],
    (ledger, grant) => ledger.deleteCommerceUnit(
      grant,
      commandId: const Uuid().v4(),
      unitId: unitId,
    ),
  );

  Future<Map<String, dynamic>> addBarcode(
    String id,
    Map<String, dynamic> body,
  ) async {
    final created = await _run(
      {BusinessLedgerAction.manageProducts},
      ['inventory.edit'],
      (ledger, grant) => ledger.addCommerceBarcode(
        grant,
        commandId: '${body['command_id'] ?? const Uuid().v4()}',
        productId: id,
        barcode: '${body['barcode']}',
        unitId: body['unit_id'] as String?,
      ),
    );
    return Map<String, dynamic>.from(created);
  }

  Future<void> deleteBarcode(String barcodeId) => _run(
    {BusinessLedgerAction.manageProducts},
    ['inventory.edit'],
    (ledger, grant) => ledger.deleteCommerceBarcode(
      grant,
      commandId: const Uuid().v4(),
      barcodeId: barcodeId,
    ),
  );

  Future<List<Map<String, dynamic>>> productPrices(String id) async {
    final product = await this.product(id);
    return [
      for (final price
          in (product?['prices'] as List? ?? const []).whereType<Map>())
        Map<String, dynamic>.from(price),
    ];
  }

  Future<void> setProductPrices(String id, List<Map<String, dynamic>> prices) =>
      _run(
        {BusinessLedgerAction.manageProducts},
        ['inventory.edit'],
        (ledger, grant) => ledger.setCommercePrices(
          grant,
          commandId: const Uuid().v4(),
          productId: id,
          prices: prices,
        ),
      );

  Future<List<Map<String, dynamic>>> categories() => _read(
    {BusinessLedgerAction.readInventory}, ['inventory'],
    (ledger, grant) => ledger.commerceCategories(grant),
  );

  Future<void> classify({
    required String commandId,
    required List<String> products, required String? categoryId,
    String? expectedCategory, bool requireExpected = false,
  }) async {
    const permissions = ['inventory', 'inventory.edit'];
    await _run(
      {BusinessLedgerAction.manageProducts}, permissions,
      (ledger, grant) => ledger.classifyCommerceProducts(grant,
        commandId: commandId, productIds: products, categoryId: categoryId,
        expectedCategory: expectedCategory, requireExpected: requireExpected,
        allowed: () => _current(permissions),
      ),
    );
    _require(permissions);
    _operationsChanged?.call();
  }

  Future<Map<String, dynamic>> createCategory(String name) =>
      _catalogWrite(['inventory', 'inventory.add'], (ledger, grant, allowed) =>
          ledger.createCommerceCategory(grant, commandId: const Uuid().v4(), name: name, allowed: allowed));

  Future<Map<String, dynamic>> renameCategory(String id, String name) =>
      _catalogWrite(['inventory', 'inventory.edit'], (ledger, grant, allowed) =>
          ledger.renameCommerceCategory(grant, commandId: const Uuid().v4(), id: id, name: name, allowed: allowed));

  Future<Map<String, dynamic>> deleteCategory(String id) =>
      _catalogWrite(['inventory', 'inventory.delete'], (ledger, grant, allowed) =>
          ledger.deleteCommerceCategory(grant, commandId: const Uuid().v4(), id: id, allowed: allowed));

  Future<Map<String, dynamic>> setWarehouseExpiry(bool enabled, int warnDays) =>
      _catalogWrite(['inventory', 'inventory.edit'], (ledger, grant, allowed) =>
          ledger.setWarehouseExpiry(grant, commandId: const Uuid().v4(), enabled: enabled,
              warnDays: warnDays, allowed: allowed));

  Future<Map<String, dynamic>> _catalogWrite(
    List<String> permissions,
    Future<Map<String, Object?>> Function(BusinessLedger, BusinessLedgerAccess, bool Function()) write,
  ) async {
    final result = await _run(
      {BusinessLedgerAction.manageProducts}, permissions,
      (ledger, grant) => write(ledger, grant, () => _current(permissions)),
    );
    _require(permissions);
    _operationsChanged?.call();
    return Map<String, dynamic>.from(result as Map);
  }

  Future<BusinessWarehouseExpiry?> warehouseExpiry() => _read(
    {BusinessLedgerAction.readInventory}, ['inventory'],
    (ledger, grant) => ledger.warehouseExpiry(grant),
  );

  List<Map<String, Object?>>? _formPrices(Map<String, dynamic> body) =>
      (body['prices'] as List?)
          ?.map((row) => Map<String, Object?>.from(row as Map))
          .toList();

  Future<Map<String, dynamic>> _productRow(String id) async {
    return await product(id) ?? <String, dynamic>{'id': id};
  }

  /// Previous returns in the connected list/detail shape.
  Future<List<dynamic>> returns({
    String? kind,
    String? search,
    String? invoiceId,
  }) {
    final parsed = _returnKind(kind);
    final permitted = BusinessInvoiceKind.values
        .where(
          (type) =>
              (parsed == null || type == parsed) &&
              _can(_returnsPermission(type)),
        )
        .toList();
    if (permitted.isEmpty) throw const DirectoryAccessDenied();
    return _read(
      {BusinessLedgerAction.readReturns},
      ['returns', ...permitted.map(_returnsPermission)],
      (ledger, grant) => ledger.commerceReturnsList(
        grant,
        kind: permitted.length == 1 ? permitted.single : null,
        invoiceId: invoiceId,
        search: search,
      ),
    );
  }

  Future<Map<String, dynamic>> returnDetail(String kind, String id) async {
    final parsed = _returnKind(kind);
    if (parsed == null) throw const DirectoryAccessDenied();
    final permissions = ['returns', _returnsPermission(parsed)];
    final rows = await _run(
      {BusinessLedgerAction.readReturns},
      permissions,
      (ledger, grant) =>
          ledger.commerceReturnsList(grant, kind: parsed, returnId: id),
    );
    _require(permissions);
    return rows.singleOrNull ?? (throw const DirectoryAccessDenied());
  }

  /// Confirm a return through the local return engine and answer with the
  /// refreshed document plus its return receipt, like the connected call.
  Future<Map<String, dynamic>> createReturn(
    String invoiceId,
    Map<String, dynamic> body,
  ) async {
    final invoice = await returnableDocument(invoiceId);
    final kind = _returnKind(invoice?['invoice_type'] as String?);
    if (kind == null) throw const DirectoryAccessDenied();
    final permissions = ['returns', _returnsPermission(kind)];
    final ableToAuthorize =
        kind == BusinessInvoiceKind.sale && canAuthorizeReturnOverdraft;
    final allowing = body['allow_negative'] == true;
    final remember = body['remember_allow_negative'] == true;
    if ((allowing && !ableToAuthorize) ||
        (remember && (!allowing || !canRememberReturnOverdraft))) {
      throw const DirectoryAccessDenied();
    }
    final result = await _run(
      {
        BusinessLedgerAction.confirmReturn,
        if (ableToAuthorize) BusinessLedgerAction.authorizeReturnOverdraft,
        if (remember) BusinessLedgerAction.changeNegativePolicy,
      },
      [
        ...permissions,
        if (ableToAuthorize) 'banks.balances',
        if (remember) 'banks',
      ],
      (ledger, grant) => ledger.confirmCommerceReturn(
        grant,
        commandId: '${body['command_id'] ?? const Uuid().v4()}',
        kind: kind,
        invoiceId: invoiceId,
        reason: body['reason'] as String?,
        refundAccountId: body['refund_account_id'] as String?,
        refundOriginalMinor: body['refund_amount'] == null
            ? null
            : BusinessMoney.minor(_decimal(body['refund_amount'] as num)),
        refundRate: body['refund_currency'] == null
            ? null
            : _rate(
                body['refund_exchange_rate'],
                '${body['refund_currency']}'.toUpperCase(),
                '${invoice!['currency']}',
              ),
        allowNegative: allowing,
        rememberAllowNegative: remember,
        expectedRefundMinor: body['expected_refund_minor'] as int?,
        expectedAccountCurrency: body['refund_currency'] as String?,
        lines: [
          for (final line
              in (body['lines'] as List? ?? const []).whereType<Map>())
            CommerceReturnLine(
              itemId: '${line['invoice_item_id']}',
              quantity: _decimal(line['quantity'] as num),
              restock: line['restock'] != false,
            ),
        ],
      ),
      stillAllowed: () =>
          (!ableToAuthorize || canAuthorizeReturnOverdraft) &&
          (!remember || canRememberReturnOverdraft),
    );
    if (result['refunded_minor'] != 0 && _current(const []))
      _bankChanged?.call();
    if (_current(const [])) _operationsChanged?.call();
    final refreshed = await _returnInvoice(kind, invoiceId);
    return <String, dynamic>{
      ...?refreshed,
      'return': {
        'id': result['id'],
        'return_number': result['number'],
        'total': (result['total_minor'] as int) / 100,
        'kind': '${kind.name}_return',
      },
    };
  }

  /// Invoice picker for the return flow: only documents with a line that is
  /// not fully returned yet, exactly like the connected returnable filter.
  Future<List<dynamic>> returnableInvoices(String invoiceType, String search) {
    final kind = _returnKind(invoiceType);
    if (kind == null) throw const DirectoryAccessDenied();
    return _read(
      {_invoiceRead(kind)},
      ['returns', _returnsPermission(kind)],
      (ledger, grant) => ledger.commerceDocuments(
        grant,
        kind: kind,
        search: search,
        limit: 20,
        returnableOnly: true,
      ),
    );
  }

  Future<Map<String, dynamic>?> returnableDocument(String id) async {
    for (final kind in BusinessInvoiceKind.values) {
      if (!_can(_returnsPermission(kind))) continue;
      final invoice = await _returnInvoice(kind, id);
      if (invoice != null) return invoice;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _returnInvoice(
    BusinessInvoiceKind kind,
    String id,
  ) async {
    final permissions = ['returns', _returnsPermission(kind)];
    final invoice = await _run(
      {_invoiceRead(kind)},
      permissions,
      (ledger, grant) => ledger.commerceInvoice(grant, kind, id),
    );
    _require(permissions);
    return invoice;
  }

  static BusinessInvoiceKind? _returnKind(String? label) => switch (label) {
    'sale' || 'sale_return' => BusinessInvoiceKind.sale,
    'purchase' || 'purchase_return' => BusinessInvoiceKind.purchase,
    _ => null,
  };

  static String _returnsPermission(BusinessInvoiceKind kind) =>
      kind == BusinessInvoiceKind.purchase
      ? 'purchases.returns'
      : 'sales.returns';

  static BusinessLedgerAction _invoiceRead(BusinessInvoiceKind kind) =>
      kind == BusinessInvoiceKind.purchase
      ? BusinessLedgerAction.readPurchaseInvoice
      : BusinessLedgerAction.readSaleInvoice;

  Future<List<Map<String, dynamic>>> lots(String id) async {
    final productRow = await product(id);
    return [
      for (final lot
          in (productRow?['lots'] as List? ?? const []).whereType<Map>())
        Map<String, dynamic>.from(lot),
    ];
  }

  Future<Map<String, dynamic>> productStats(
    String id, {String? from, String? to, String? displayCurrency}
  ) async {
    final cost = _can('inventory_cost.read');
    final profit = _can('inventory_profit.read');
    final permissions = [
      'inventory',
      if (cost) 'inventory_cost.read',
      if (profit) 'inventory_profit.read',
    ];
    final result = await _run(
      {
        BusinessLedgerAction.readInventory,
        if (cost) BusinessLedgerAction.readInventoryCost,
        if (profit) BusinessLedgerAction.readInventoryProfit,
      },
      permissions,
      (ledger, grant) => ledger.commerceProductStats(grant, id,
          from: from, to: to, displayCurrency: displayCurrency),
    );
    _require(permissions);
    return result;
  }

  Future<List<Map<String, dynamic>>> operations({
    required Set<String> kinds,
    String? kind,
    String? period,
    String? search,
    String? dateFrom,
    String? dateTo,
    String? sourceType,
    String? sourceId,
    int limit = 100,
  }) async {
    final visible = <String>{};
    final permissions = <String>{'transactions'};
    for (final entry in businessOperationPermissions.entries) {
      if (kinds.contains(entry.key) && entry.value.every(_can)) {
        visible.add(entry.key);
        permissions.addAll(entry.value);
      }
    }
    return _read(
      {BusinessLedgerAction.readOperations}, permissions.toList(),
      (ledger, grant) => ledger.operations(
        grant, allowedKinds: visible, kind: kind, period: period, search: search,
        dateFrom: dateFrom, dateTo: dateTo, sourceId: sourceId,
        sourceType: sourceType, limit: limit,
      ),
    );
  }

  /// Barcode → product/unit in the connected scanner contract.
  Future<Map<String, dynamic>> resolveBarcode(String code) async {
    final hit = await _run(
      {BusinessLedgerAction.readInventory},
      ['inventory'],
      (ledger, grant) => ledger.commerceResolveBarcode(grant, code),
    );
    if (hit == null) throw const DirectoryAccessDenied();
    final productRow = await product('${hit['product_id']}');
    if (productRow == null) throw const DirectoryAccessDenied();
    final units = (productRow['units'] as List? ?? const []).whereType<Map>();
    final wanted = hit['unit_id'];
    Map<String, dynamic>? unit;
    for (final row in units) {
      if (wanted == null ? row['is_base'] == true : '${row['id']}' == wanted) {
        unit = Map<String, dynamic>.from(row);
        break;
      }
    }
    unit ??= units.isEmpty ? null : Map<String, dynamic>.from(units.first);
    return {
      'product': {
        for (final key in ['id', 'name', 'stock', 'unit', 'is_service'])
          key: productRow[key],
        'price': productRow['price'],
      },
      'unit': unit == null
          ? null
          : {
              for (final key in ['id', 'name', 'is_base']) key: unit[key],
              'factor': unit['factor'],
            },
      'suggested_quantity': 1,
      'suggested_price': unit?['sale_price'] ?? productRow['price'],
    };
  }
}

final localCommerceBridgeProvider = Provider<LocalCommerceBridge>((ref) {
  ref.watch(branchEpochProvider);
  final store = ref.watch(directoryPilotStoreProvider);
  ref.watch(businessLocalLedgerScopeProvider);
  final branch = BranchScope.branchId;
  final org = BranchScope.organizationId;
  final container = ref.container;
  var alive = true;
  ref.onDispose(() => alive = false);
  return LocalCommerceBridge(
    store,
    () =>
        alive &&
            !BranchScope.readOnly &&
            BranchScope.branchId == branch &&
            BranchScope.organizationId == org
        ? container.read(businessLocalLedgerScopeProvider)
        : null,
    (permission) => alive && container.read(employeeCanProvider(permission)),
    bankChanged: () {
      if (alive) container.read(businessBankRevisionProvider.notifier).state++;
    },
    operationsChanged: () {
      if (alive) container.read(businessOperationsRevisionProvider.notifier).state++;
    },
    fullAccess: () =>
        alive &&
        (container.read(employeeWorkspaceCompanyProvider) == null ||
            employeeHasFullAccess(container.read(employeePermissionsProvider))),
    rate: (from, to) => container.read(currencyEngineProvider).getRate(from, to),
  );
});

const businessOperationPermissions = <String, List<String>>{
  'sale': ['sales.view'],
  'purchase': ['purchases.view'],
  'sale_return': ['returns', 'sales.returns'],
  'purchase_return': ['returns', 'purchases.returns'],
  'collection': ['customers.details'],
  'supplier_payment': ['suppliers.details'],
  'income': ['income'],
  'expense': ['expenses'],
  'bank_withdrawal': ['expenses'],
  'withdrawal_reversal': ['expenses'],
  'transfer': ['transfers'],
  'transfer_reversal': ['transfers'],
  'opening': ['banks.balances'],
  'reconciliation': ['reconciliation'],
};

// A local API never receives the real transport. Inherited paths not yet
// migrated cannot send a device identifier or become the second writer.
final _deviceOnlyClient = ApiClient(
  dio: Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          handler.reject(
            DioException(
              requestOptions: request,
              type: DioExceptionType.cancel,
              error: const DirectoryAccessDenied(),
            ),
          );
        },
      ),
    ),
);

final class LocalBusinessFinanceApi extends BusinessFinanceApi {
  LocalBusinessFinanceApi(ApiClient _, this.bridge) : super(_deviceOnlyClient);
  final LocalCommerceBridge bridge;

  @override
  Future<List<Map<String, dynamic>>> listTransactions({
    String? kind,
    String? period,
    String? search,
    String? dateFrom,
    String? dateTo,
    bool includeDocLegs = false,
  }) => bridge.operations(
    kinds: businessOperationPermissions.keys.toSet(), kind: kind, period: period,
    search: search, dateFrom: dateFrom, dateTo: dateTo,
  );

  @override
  Future<Map<String, dynamic>?> getTransaction(String sourceType, String sourceId) async =>
      (await bridge.operations(
        kinds: businessOperationPermissions.keys.toSet(), sourceType: sourceType,
        sourceId: sourceId, limit: 1,
      )).singleOrNull;
}

final class LocalSalesApi extends SalesApi {
  LocalSalesApi(ApiClient _, this._bridge) : super(_deviceOnlyClient);
  final LocalCommerceBridge _bridge;

  @override
  Future<List<dynamic>> searchCustomers(String query) =>
      _bridge.searchParties(DirectoryPartyKind.customer, query);

  Future<Map<String, dynamic>> customer(String id) =>
      _bridge.party(DirectoryPartyKind.customer, id);

  @override
  Future<Map<String, dynamic>> createCustomer({
    required String name,
    String? phone,
    String? commandId,
  }) =>
      _bridge.createParty(DirectoryPartyKind.customer, name, phone, commandId);

  @override
  Future<Map<String, dynamic>> customerBalance(String id) =>
      _bridge.partyBalance(DirectoryPartyKind.customer, id);

  @override
  Future<List<dynamic>> searchProducts(String query) =>
      _bridge.products(search: query, limit: 20, activeOnly: true);

  @override
  Future<Map<String, dynamic>> productUnits(String id) =>
      _bridge.productUnits(id);

  @override
  Future<Map<String, dynamic>> resolveBarcode(String code) =>
      _bridge.resolveBarcode(code);

  @override
  Future<Map<String, dynamic>> issueSale(Map<String, dynamic> body) =>
      _bridge.issueDocument(body, purchase: false);

  @override
  Future<Map<String, dynamic>> getInvoice(String id) async =>
      await _bridge.document(id, purchase: false) ?? <String, dynamic>{};

  @override
  Future<List<dynamic>> saleInvoices({String? search, int page = 1}) =>
      _bridge.documents(purchase: false, search: search);

  @override
  Future<List<dynamic>> bankAccounts() =>
      _bridge.paymentAccounts('sales.create');
}

final class LocalPurchaseApi extends PurchaseApi {
  LocalPurchaseApi(ApiClient _, this._bridge) : super(_deviceOnlyClient);
  final LocalCommerceBridge _bridge;

  @override
  Future<List<dynamic>> bankAccounts() =>
      _bridge.paymentAccounts('purchases.create');

  @override
  Future<List<dynamic>> searchSuppliers(String query) =>
      _bridge.searchParties(DirectoryPartyKind.supplier, query);

  Future<Map<String, dynamic>> supplier(String id) =>
      _bridge.party(DirectoryPartyKind.supplier, id);

  @override
  Future<Map<String, dynamic>> createSupplier({
    required String name,
    String? phone,
    String? commandId,
  }) =>
      _bridge.createParty(DirectoryPartyKind.supplier, name, phone, commandId);

  @override
  Future<Map<String, dynamic>> supplierBalance(String id) =>
      _bridge.partyBalance(DirectoryPartyKind.supplier, id);

  @override
  Future<List<dynamic>> searchCustomers(String query) =>
      _bridge.searchParties(DirectoryPartyKind.customer, query);

  @override
  Future<Map<String, dynamic>> createCustomer({
    required String name,
    String? phone,
  }) => _bridge.createParty(DirectoryPartyKind.customer, name, phone, null);

  @override
  Future<Map<String, dynamic>> customerBalance(String id) =>
      _bridge.partyBalance(DirectoryPartyKind.customer, id);

  @override
  Future<Map<String, dynamic>> updateSupplier(
    String id, {
    String? name,
    String? phone,
  }) async {
    await _bridge.updateParty(DirectoryPartyKind.supplier, id, name, phone);
    return {'id': id};
  }

  @override
  Future<Map<String, dynamic>> updateCustomer(
    String id, {
    String? name,
    String? phone,
  }) async {
    await _bridge.updateParty(DirectoryPartyKind.customer, id, name, phone);
    return {'id': id};
  }

  @override
  Future<List<dynamic>> searchProducts(String query) =>
      _bridge.products(search: query, limit: 20, activeOnly: true);

  @override
  Future<Map<String, dynamic>> productUnits(String id) =>
      _bridge.productUnits(id);

  @override
  Future<Map<String, dynamic>> resolveBarcode(String code) =>
      _bridge.resolveBarcode(code);

  @override
  Future<Map<String, dynamic>> issuePurchase(Map<String, dynamic> body) =>
      _bridge.issueDocument(body, purchase: true);

  @override
  Future<Map<String, dynamic>> getInvoice(String id) async =>
      await _bridge.document(id, purchase: true) ?? <String, dynamic>{};

  @override
  Future<List<dynamic>> purchaseInvoices({String? search, int page = 1}) =>
      _bridge.documents(purchase: true, search: search);
}

final class LocalInventoryApi extends InventoryApi {
  LocalInventoryApi(ApiClient network, this._bridge)
    : _network = network,
      super(_deviceOnlyClient);

  /// Only the Falcon's analysis goes to the server (the figures come from
  /// this phone; the server keeps no stock data).
  final ApiClient _network;

  Future<Map<String, dynamic>> _falcon(String path, Map<String, dynamic> body,
      String scope, String? refId, String? reportCurrency) async {
    final currency = (reportCurrency ?? 'USD').toUpperCase();
    final figures = await _bridge.falconFigures(scope, refId, currency);
    final r = await _network.post(path, data: {
      ...body,
      'scope': scope,
      if (refId != null) 'ref_id': refId,
      'report_currency': currency,
      'device_items': figures.items,
      if (figures.category != null) 'device_category': figures.category,
    });
    final data = r.data;
    final inner = data is Map && data['data'] is Map ? data['data'] : data;
    return inner is Map ? Map<String, dynamic>.from(inner) : <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> falconAnalyze(String scope, String? refId,
          {String? reportCurrency}) =>
      _falcon('/inventory/falcon/analyze', const {}, scope, refId, reportCurrency);

  @override
  Future<Map<String, dynamic>> falconChat(String scope, String? refId,
          String question, List<Map<String, dynamic>> history,
          {String? reportCurrency}) =>
      _falcon('/inventory/falcon/chat', {'question': question, 'history': history},
          scope, refId, reportCurrency);
  final LocalCommerceBridge _bridge;

  @override
  Future<List<Map<String, dynamic>>> listProducts({
    String search = '',
    String? stockStatus,
    String? expiry,
    int expiryDays = 30,
    String? categoryId,
    bool uncategorized = false,
    int page = 1,
    int perPage = 50,
  }) async {
    return _bridge.products(
      search: search,
      stockStatus: stockStatus,
      expiry: expiry,
      expiryDays: 60,
      categoryId: categoryId,
      uncategorized: uncategorized,
      limit: perPage,
      offset: (page - 1) * perPage,
    );
  }

  @override
  Future<Map<String, dynamic>> getProduct(String id) async =>
      await _bridge.product(id) ?? <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> createProduct(Map<String, dynamic> body) =>
      _bridge.createProduct(body);

  @override
  Future<Map<String, dynamic>> updateProduct(
    String id,
    Map<String, dynamic> body,
  ) => _bridge.updateProduct(id, body);

  @override
  Future<void> deleteProduct(String id) => _bridge.deleteProduct(id);

  @override
  Future<List<Map<String, dynamic>>> categories() => _bridge.categories();

  // Categories and settings are this branch's own (its own inventory).
  @override
  Future<Map<String, dynamic>> createCategory(String name) => _bridge.createCategory(name);

  @override
  Future<Map<String, dynamic>> updateCategory(String id, String name) =>
      _bridge.renameCategory(id, name);

  @override
  Future<void> deleteCategory(String id) async => _bridge.deleteCategory(id);

  Future<void> classifyProducts(
    List<String> products, {required String commandId, String? categoryId, String? removingFrom}
  ) => _bridge.classify(commandId: commandId, products: products, categoryId: categoryId,
    expectedCategory: removingFrom, requireExpected: removingFrom != null);

  Future<BusinessWarehouseExpiry?> warehouseExpiry() => _bridge.warehouseExpiry();

  @override
  Future<void> setWarehouseSettings({
    required bool expiryEnabled, required int warnDays,
  }) async => _bridge.setWarehouseExpiry(expiryEnabled, warnDays);

  @override
  Future<Map<String, dynamic>> productUnits(String id) =>
      _bridge.productUnits(id);

  @override
  Future<Map<String, dynamic>> createUnit(
    String id,
    Map<String, dynamic> body,
  ) => _bridge.createUnit(id, body);

  @override
  Future<void> deleteUnit(String unitId) => _bridge.deleteUnit(unitId);

  @override
  Future<Map<String, dynamic>> addBarcode(
    String id,
    Map<String, dynamic> body,
  ) => _bridge.addBarcode(id, body);

  @override
  Future<void> deleteBarcode(String barcodeId) =>
      _bridge.deleteBarcode(barcodeId);

  @override
  Future<List<Map<String, dynamic>>> productPrices(String id) =>
      _bridge.productPrices(id);

  @override
  Future<void> setProductPrices(String id, List<Map<String, dynamic>> prices) =>
      _bridge.setProductPrices(id, prices);

  @override
  Future<List<Map<String, dynamic>>> productMovements(
    String id, {
    int limit = 60,
  }) => _bridge.movements(id, limit: limit);

  @override
  Future<List<Map<String, dynamic>>> productLots(String id) => _bridge.lots(id);

  @override
  Future<Map<String, dynamic>> productStats(
    String id, {String? from, String? to, String? displayCurrency}
  ) => _bridge.productStats(id, from: from, to: to,
      displayCurrency: displayCurrency);

  @override
  Future<Map<String, dynamic>> resolveBarcode(String code) =>
      _bridge.resolveBarcode(code);

  @override
  Future<Map<String, dynamic>> adjustStock(Map<String, dynamic> body) =>
      _bridge.adjustStock(body);

  @override
  Future<Map<String, dynamic>> uploadImage(
    String id,
    String filePath, {
    required Dio dio,
  }) async => throw const DirectoryAccessDenied();

  @override
  Future<Map<String, dynamic>> uploadCategoryImage(
    String id,
    String filePath, {
    required Dio dio,
  }) => _rejectSharedWrite('inventory.edit');

  @override
  Future<void> deleteCategoryImage(String id) => _rejectSharedWrite('inventory.edit');

  Future<Never> _rejectSharedWrite(String permission) async {
    _bridge._require([permission]);
    throw const SharedCatalogReadOnly();
  }
}

final class LocalReturnsApi extends ReturnsApi {
  LocalReturnsApi(ApiClient _, this._bridge) : super(_deviceOnlyClient);
  final LocalCommerceBridge _bridge;

  bool get canRememberOverdraft => _bridge.canRememberReturnOverdraft;

  @override
  Future<List<dynamic>> list({
    String? kind,
    String? search,
    String? invoiceId,
    int page = 1,
  }) => _bridge.returns(kind: kind, search: search, invoiceId: invoiceId);

  @override
  Future<Map<String, dynamic>> detail(String kind, String id) =>
      _bridge.returnDetail(kind, id);

  @override
  Future<Map<String, dynamic>> create(
    String invoiceId,
    Map<String, dynamic> body,
  ) => _bridge.createReturn(invoiceId, body);

  @override
  Future<List<dynamic>> searchInvoices(String invoiceType, String search) =>
      _bridge.returnableInvoices(invoiceType, search);

  @override
  Future<Map<String, dynamic>> getInvoice(String id) async =>
      await _bridge.returnableDocument(id) ??
      (throw const DirectoryAccessDenied());

  @override
  Future<List<dynamic>> bankAccounts() => _bridge.paymentAccounts(
    _bridge._can('sales.returns') ? 'sales.returns' : 'purchases.returns',
  );
}

final class LocalInvoicesApi extends InvoicesApi {
  LocalInvoicesApi(ApiClient _, this._bridge) : super(_deviceOnlyClient);
  final LocalCommerceBridge _bridge;

  @override
  Future<List<dynamic>> list({
    String? type,
    String? search,
    int perPage = 100,
  }) async {
    final rows = <dynamic>[];
    for (final kind in BusinessInvoiceKind.values) {
      if (type != null && type != kind.name) continue;
      if (!_bridge._can(
        kind == BusinessInvoiceKind.sale ? 'sales.view' : 'purchases.view',
      ))
        continue;
      rows.addAll(
        await _bridge.documents(
          purchase: kind == BusinessInvoiceKind.purchase,
          search: search,
          limit: perPage,
        ),
      );
    }
    rows.sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));
    return rows.take(perPage).toList();
  }

  @override
  Future<Map<String, dynamic>> getInvoice(String id) async {
    for (final purchase in [false, true]) {
      if (!_bridge._can(purchase ? 'purchases.view' : 'sales.view')) continue;
      final found = await _bridge.document(id, purchase: purchase);
      if (found != null) return found;
    }
    throw const DirectoryAccessDenied();
  }
}

/// Build the API for the currently selected branch source. Connected scopes
/// keep the exact REST implementation; a local ledger scope swaps in the
/// device implementation only for the paths it owns.
T localCommerceApi<T>(
  T Function(ApiClient client) connected,
  T Function(ApiClient client, LocalCommerceBridge bridge) local,
  ApiClient client,
  LocalCommerceBridge bridge,
) => bridge.active ? local(client, bridge) : connected(client);
