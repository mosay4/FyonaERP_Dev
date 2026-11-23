import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/network/api_client.dart';
import 'package:fyona_flutter/features/core_business/data/local_commerce/local_commerce_api.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/inventory/data/inventory_api.dart';
import 'package:fyona_flutter/features/purchases/data/purchase_api.dart';
import 'package:fyona_flutter/features/sales/data/sales_api.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

void main() {
  final workspace = DirectoryWorkspace(
    server: DirectoryPilotBuild.baseUrl,
    accountId: _id(),
    organizationId: _id(),
  );
  DirectoryAccess scope() => DirectoryAccess(
    workspace: workspace,
    branchId: _id(),
    readable: DirectoryPartyKind.values.toSet(),
    writable: DirectoryPartyKind.values.toSet(),
    financialCutover: true,
  );
  late Directory root;
  late FixtureDirectoryKeys keys;
  late DirectoryPilotStore store;
  late ApiClient client;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fyona-commerce-api-');
    keys = FixtureDirectoryKeys();
    store = DirectoryPilotStore(root: () async => root, keys: keys);
    client = ApiClient(dio: Dio());
  });

  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });

  LocalCommerceBridge bridge(DirectoryAccess? selected) =>
      LocalCommerceBridge(store, () => selected, (_) => true);

  Future<void> prepare(DirectoryAccess selected) => store.remember(selected, {
    'status': 'active',
    'business_setup_completed': true,
    'sections': {
      'business': {
        'active': true,
        'end_date': DateTime.now()
            .add(const Duration(days: 1))
            .toIso8601String(),
      },
    },
  });

  test('connected branches keep the untouched REST implementation', () async {
    final inactive = bridge(null);
    final requests = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            requests.add('${request.method} ${request.path}');
            handler.resolve(
              Response(requestOptions: request, data: {'data': []}),
            );
          },
        ),
      );
    final rest = ApiClient(dio: dio);
    final sales = localCommerceApi<SalesApi>(
      SalesApi.new,
      LocalSalesApi.new,
      rest,
      inactive,
    );
    final purchases = localCommerceApi<PurchaseApi>(
      PurchaseApi.new,
      LocalPurchaseApi.new,
      rest,
      inactive,
    );
    final inventory = localCommerceApi<InventoryApi>(
      InventoryApi.new,
      LocalInventoryApi.new,
      rest,
      inactive,
    );
    expect(await sales.bankAccounts(), isEmpty);
    expect(await purchases.bankAccounts(), isEmpty);
    expect(await inventory.listProducts(), isEmpty);
    expect(requests, [
      'GET /business/payment-options',
      'GET /business/payment-options',
      'GET /products',
    ]);
  });

  // The random account/branch fixtures need the isolated signup build. The
  // connected regression above also runs when the directory flag is off.
  if (!DirectoryPilotBuild.signupEnabled) return;

  test(
    'the device source answers the connected API shape without HTTP',
    () async {
      final access = scope();
      await prepare(access);
      final ledgerAccess = BusinessLedgerAccess(
        access,
        BusinessLedgerAction.values.toSet(),
      );
      final account = _id();
      await store.withLedger(
        ledgerAccess,
        () => access,
        (ledger) => ledger.createAccount(
          ledgerAccess,
          commandId: account,
          bankName: 'Cash',
          accountName: 'Till',
          accountNumber: '1',
          currency: 'SAR',
          openingMinor: 5000,
        ),
      );
      await store.add(
        access,
        DirectoryPartyKind.customer,
        name: 'Device buyer',
      );
      final customer = (await store.search(
        access,
        DirectoryPartyKind.customer,
        'Device buyer',
      )).single;
      final api = LocalSalesApi(client, bridge(access));

      final body = <String, dynamic>{
        'currency': 'SAR',
        'customer_id': customer.id,
        'idempotency_key': _id(),
        'items': [
          {
            'description': 'Service',
            'quantity': 2,
            'unit_price': 15.0,
            'discount': 0,
          },
        ],
        'payments': [
          {
            'bank_account_id': account,
            'amount': 10.0,
            'payment_method': 'cash',
            'currency': 'SAR',
          },
        ],
      };
      final issued = await api.issueSale(body);
      expect(issued['invoice_number'], startsWith('INV-'));
      expect(issued['customer_name'], 'Device buyer');
      expect(issued['total'], 30);
      expect(issued['paid_amount'], 10);
      expect(issued['balance'], 20);
      expect(issued['status'], 'partially_paid');

      final replay = await api.issueSale(body);
      expect(replay['id'], issued['id']);
      final documents = await api.saleInvoices();
      expect(documents, hasLength(1));
      final read = await api.getInvoice('${issued['id']}');
      expect(read['invoice_number'], issued['invoice_number']);
      final accounts = await api.bankAccounts();
      expect(accounts.single['id'], account);
      expect(accounts.single['balance'], '60.00');
    },
  );

  test('purchase documents use the same device source', () async {
    final access = scope();
    await prepare(access);
    final ledgerAccess = BusinessLedgerAccess(
      access,
      BusinessLedgerAction.values.toSet(),
    );
    final account = _id();
    await store.withLedger(
      ledgerAccess,
      () => access,
      (ledger) => ledger.createAccount(
        ledgerAccess,
        commandId: account,
        bankName: 'Cash',
        accountName: 'Till',
        accountNumber: '1',
        currency: 'SAR',
        openingMinor: 5000,
      ),
    );
    await store.add(access, DirectoryPartyKind.supplier, name: 'Device vendor');
    final vendor = (await store.search(
      access,
      DirectoryPartyKind.supplier,
      'Device vendor',
    )).single;
    final api = LocalPurchaseApi(client, bridge(access));
    final issued = await api.issuePurchase({
      'currency': 'SAR',
      'supplier_id': vendor.id,
      'idempotency_key': _id(),
      'items': [
        {
          'description': 'Service',
          'quantity': 1,
          'unit_price': 50.0,
          'discount': 0,
        },
      ],
      'payments': [
        {
          'bank_account_id': account,
          'amount': 20.0,
          'payment_method': 'cash',
          'currency': 'SAR',
        },
      ],
    });
    expect(issued['invoice_number'], startsWith('PUR-'));
    expect(issued['supplier_name'], 'Device vendor');
    expect(issued['balance'], 30);
    expect(
      (await api.purchaseInvoices()).single['invoice_number'],
      issued['invoice_number'],
    );
  });

  test(
    'product reads stay on the device and the source is chosen per scope',
    () async {
      final access = scope();
      await prepare(access);
      final active = LocalInventoryApi(client, bridge(access));
      expect(await active.listProducts(search: 'x'), isEmpty);
      expect(await active.productMovements(_id()), isEmpty);
      expect(await active.getProduct(_id()), isEmpty);
    },
  );

  test('the scoped device ledger selects local APIs', () {
    final device = bridge(scope());
    expect(
      localCommerceApi<SalesApi>(
        SalesApi.new,
        LocalSalesApi.new,
        client,
        device,
      ),
      isA<LocalSalesApi>(),
    );
    expect(
      localCommerceApi<PurchaseApi>(
        PurchaseApi.new,
        LocalPurchaseApi.new,
        client,
        device,
      ),
      isA<LocalPurchaseApi>(),
    );
    expect(
      localCommerceApi<InventoryApi>(
        InventoryApi.new,
        LocalInventoryApi.new,
        client,
        device,
      ),
      isA<LocalInventoryApi>(),
    );
  });

  test(
    'product management saves catalogue, units, barcodes and prices locally',
    () async {
      final access = scope();
      await prepare(access);
      final api = LocalInventoryApi(client, bridge(access));
      final created = await api.createProduct({
        'name': 'Fixture product',
        'unit': 'قطعة',
        'price': 12.5,
        'cost_price': 7.0,
        'cost_currency': 'SAR',
        'min_stock': 2,
        'stock': 5,
      });
      expect(created['id'], isNotEmpty);
      expect(created['name'], 'Fixture product');
      expect(created['price'], 12.5);
      expect(created['stock'], 5);
      expect(created['is_service'], isFalse);
      final base =
          (await api.productUnits('${created['id']}'))['units'] as List;
      expect(base.single['name'], 'قطعة');
      expect(base.single['factor'], 1);
      expect(base.single['is_base'], isTrue);

      final unit = await api.createUnit('${created['id']}', {
        'name': 'كرتون',
        'factor': 12.5,
      });
      expect(unit['id'], isNotEmpty);
      expect(
        (await api.productUnits('${created['id']}'))['units'],
        hasLength(2),
      );
      final code = await api.addBarcode('${created['id']}', {
        'barcode': 'FIXTURE-001',
      });
      expect(code['id'], isNotEmpty);
      await api.setProductPrices('${created['id']}', [
        {'currency': 'SAR', 'price': 12.5, 'buy_price': 7.0},
        {'currency': 'USD', 'price': 4.0, 'buy_price': 2.0},
      ]);
      final prices = await api.productPrices('${created['id']}');
      expect(prices.map((row) => row['currency']), ['SAR', 'USD']);

      await api.updateProduct('${created['id']}', {
        'name': 'Updated product',
        'price': 15.0,
      });
      final read = await api.getProduct('${created['id']}');
      expect(read['name'], 'Updated product');
      expect(read['price'], 15);
      expect(read['unit'], 'قطعة');
      expect((read['units'] as List), hasLength(2));
      expect((read['prices'] as List), hasLength(2));
      expect(await api.listProducts(search: 'Updated'), hasLength(1));

      await api.deleteProduct('${created['id']}');
      expect(await api.listProducts(search: 'Updated'), isEmpty);
      expect(await api.getProduct('${created['id']}'), isEmpty);
    },
  );

  test('duplicate codes and impossible units are refused', () async {
    final access = scope();
    await prepare(access);
    final api = LocalInventoryApi(client, bridge(access));
    final first = await api.createProduct({
      'name': 'First',
      'unit': 'قطعة',
      'price': 1,
      'barcode': 'SAME-CODE',
    });
    await expectLater(
      () => api.createProduct({
        'name': 'Second',
        'unit': 'قطعة',
        'price': 1,
        'barcode': 'SAME-CODE',
      }),
      throwsA(
        isA<BusinessLedgerError>().having(
          (error) => error.problem,
          'problem',
          BusinessLedgerProblem.duplicateProductCode,
        ),
      ),
    );
    await expectLater(
      () => api.createUnit('${first['id']}', {'name': 'كرتون', 'factor': 0}),
      throwsA(
        isA<BusinessLedgerError>().having(
          (error) => error.problem,
          'problem',
          BusinessLedgerProblem.invalidProduct,
        ),
      ),
    );
    final units = await api.productUnits('${first['id']}');
    final baseUnit = (units['units'] as List).single as Map;
    await expectLater(
      () => api.deleteUnit('${baseUnit['id']}'),
      throwsA(
        isA<BusinessLedgerError>().having(
          (error) => error.problem,
          'problem',
          BusinessLedgerProblem.invalidProduct,
        ),
      ),
    );
    // Clearing the product code frees it for another product.
    await api.updateProduct('${first['id']}', {'barcode': null});
    final second = await api.createProduct({
      'name': 'Second',
      'unit': 'قطعة',
      'price': 1,
      'barcode': 'SAME-CODE',
    });
    expect(second['id'], isNot(first['id']));
  });

  test(
    'the managed catalogue feeds the connected issue flow from the device',
    () async {
      final access = scope();
      await prepare(access);
      final ledgerAccess = BusinessLedgerAccess(
        access,
        BusinessLedgerAction.values.toSet(),
      );
      final account = _id();
      await store.withLedger(
        ledgerAccess,
        () => access,
        (ledger) => ledger.createAccount(
          ledgerAccess,
          commandId: account,
          bankName: 'Cash',
          accountName: 'Till',
          accountNumber: '1',
          currency: 'SAR',
          openingMinor: 0,
        ),
      );
      await store.add(
        access,
        DirectoryPartyKind.customer,
        name: 'Device buyer',
      );
      final customer = (await store.search(
        access,
        DirectoryPartyKind.customer,
        'Device buyer',
      )).single;
      final inventory = LocalInventoryApi(client, bridge(access));
      final product = await inventory.createProduct({
        'name': 'Stocked product',
        'unit': 'قطعة',
        'price': 20.0,
        'stock': 5,
      });
      final sales = LocalSalesApi(client, bridge(access));
      await sales.issueSale({
        'currency': 'SAR',
        'customer_id': customer.id,
        'idempotency_key': _id(),
        'items': [
          {
            'product_id': product['id'],
            'description': 'Stocked product',
            'quantity': 2,
            'unit_price': 20.0,
            'discount': 0,
          },
        ],
      });
      final after = await inventory.getProduct('${product['id']}');
      expect(after['stock'], 3);
      final movements = await inventory.productMovements('${product['id']}');
      expect(movements.single['movement_type'], 'sale');
    },
  );

  test('return screens read and write the device source', () async {
    final access = scope();
    await prepare(access);
    final ledgerAccess = BusinessLedgerAccess(
      access,
      BusinessLedgerAction.values.toSet(),
    );
    final account = _id();
    await store.withLedger(
      ledgerAccess,
      () => access,
      (ledger) => ledger.createAccount(
        ledgerAccess,
        commandId: account,
        bankName: 'Cash',
        accountName: 'Till',
        accountNumber: '1',
        currency: 'SAR',
        openingMinor: 10000,
      ),
    );
    await store.add(access, DirectoryPartyKind.customer, name: 'Device buyer');
    final customer = (await store.search(
      access,
      DirectoryPartyKind.customer,
      'Device buyer',
    )).single;
    final inventory = LocalInventoryApi(client, bridge(access));
    final product = await inventory.createProduct({
      'name': 'Returnable product',
      'unit': 'قطعة',
      'price': 20.0,
      'stock': 5,
    });
    final sales = LocalSalesApi(client, bridge(access));
    final sale = await sales.issueSale({
      'currency': 'SAR',
      'customer_id': customer.id,
      'idempotency_key': _id(),
      'items': [
        {
          'product_id': product['id'],
          'description': 'Returnable product',
          'quantity': 2,
          'unit_price': 20.0,
          'discount': 0,
        },
      ],
      'payments': [
        {
          'bank_account_id': account,
          'amount': 40.0,
          'payment_method': 'cash',
          'currency': 'SAR',
        },
      ],
    });
    final invoiceId = '${sale['id']}';
    final api = LocalReturnsApi(client, bridge(access));
    expect(await api.searchInvoices('sale', ''), hasLength(1));
    final invoice = await api.getInvoice(invoiceId);
    expect((invoice['items'] as List).single['returnable_quantity'], 2);

    final created = await api.create(invoiceId, {
      'reason': 'customer changed mind',
      'lines': [
        {
          'invoice_item_id': (invoice['items'] as List).single['id'],
          'quantity': 1,
          'restock': true,
        },
      ],
      'refund_account_id': account,
      'refund_amount': 20.0,
    });
    expect(created['return']['return_number'], startsWith('RTN-'));
    expect(created['return']['total'], 20);
    expect(created['balance'], 0);
    final listed = await api.list();
    expect(listed.single['return_number'], created['return']['return_number']);
    expect(listed.single['party'], 'Device buyer');
    expect(listed.single['items'], hasLength(1));
    final detail = await api.detail(
      'sale_return',
      '${created['return']['id']}',
    );
    expect(detail['id'], created['return']['id']);
    final after = await api.getInvoice(invoiceId);
    expect((after['items'] as List).single['returnable_quantity'], 1);
    expect(await api.searchInvoices('sale', ''), hasLength(1));

    await api.create(invoiceId, {
      'lines': [
        {
          'invoice_item_id': (invoice['items'] as List).single['id'],
          'quantity': 1,
          'restock': true,
        },
      ],
      'refund_account_id': account,
      'refund_amount': 20.0,
    });
    // Fully returned: the picker drops the document.
    expect(await api.searchInvoices('sale', ''), isEmpty);
    expect((await api.list()), hasLength(2));
  });

  test('barcode scanner and lots resolve from the device', () async {
    final access = scope();
    await prepare(access);
    final ledgerAccess = BusinessLedgerAccess(
      access,
      BusinessLedgerAction.values.toSet(),
    );
    final account = _id();
    await store.withLedger(
      ledgerAccess,
      () => access,
      (ledger) => ledger.createAccount(
        ledgerAccess,
        commandId: account,
        bankName: 'Cash',
        accountName: 'Till',
        accountNumber: '1',
        currency: 'SAR',
        openingMinor: 10000,
      ),
    );
    await store.add(access, DirectoryPartyKind.supplier, name: 'Device vendor');
    final vendor = (await store.search(
      access,
      DirectoryPartyKind.supplier,
      'Device vendor',
    )).single;
    final inventory = LocalInventoryApi(client, bridge(access));
    final product = await inventory.createProduct({
      'name': 'Scanned product',
      'unit': 'قطعة',
      'price': 20.0,
      'barcode': 'SCAN-001',
    });
    final resolved = await inventory.resolveBarcode('SCAN-001');
    expect(resolved['product']['name'], 'Scanned product');
    expect(resolved['unit']['is_base'], isTrue);
    expect(resolved['suggested_price'], 20);
    await expectLater(
      () => inventory.resolveBarcode('UNKNOWN'),
      throwsA(isA<DirectoryAccessDenied>()),
    );

    final purchases = LocalPurchaseApi(client, bridge(access));
    await purchases.issuePurchase({
      'currency': 'SAR',
      'supplier_id': vendor.id,
      'idempotency_key': _id(),
      'items': [
        {
          'product_id': product['id'],
          'description': 'Scanned product',
          'quantity': 3,
          'unit_price': 10.0,
          'discount': 0,
        },
      ],
    });
    final lots = await inventory.productLots('${product['id']}');
    expect(lots.single['received'], 3);
    expect(lots.single['remaining'], 3);
    expect(lots.single['source'], 'purchase');
  });

  test(
    'stock adjustment reaches the device ledger through the screen API',
    () async {
      final access = scope();
      await prepare(access);
      final api = LocalInventoryApi(client, bridge(access));
      final product = await api.createProduct({
        'name': 'Adjustable product',
        'unit': 'قطعة',
        'price': 3.0,
        'stock': 5,
      });
      final adjustment = {
        'product_id': product['id'],
        'mode': 'remove',
        'amount': 1.25,
        'expected_stock': 5,
        'command_id': const Uuid().v4(),
        'reason': 'damaged',
      };
      final adjusted = await api.adjustStock(adjustment);
      expect(adjusted['movement_type'], 'adjust_remove');
      expect(adjusted['new_quantity'], 3.75);
      expect(await api.adjustStock(adjustment), adjusted);
      await expectLater(
        api.adjustStock({...adjustment, 'command_id': const Uuid().v4()}),
        throwsA(
          isA<BusinessLedgerError>().having(
            (error) => error.problem,
            'problem',
            BusinessLedgerProblem.stockChanged,
          ),
        ),
      );
      final read = await api.getProduct('${product['id']}');
      expect(read['stock'], 3.75);
      final movements = await api.productMovements('${product['id']}');
      expect(movements.single['reason'], 'damaged');
    },
  );

  test(
    'an unpaid cash sale with a quick product does not leave a product or invoice',
    () async {
      final access = scope();
      await prepare(access);
      final api = LocalSalesApi(client, bridge(access));
      await expectLater(
        () => api.issueSale({
          'currency': 'SAR',
          'idempotency_key': _id(),
          'items': [
            {
              'description': 'Quick',
              'quantity': 1,
              'unit_price': 5.0,
              'discount': 0,
              'new_product': {'name': 'Quick'},
            },
          ],
        }),
        throwsA(isA<BusinessLedgerError>()),
      );
      expect(await api.saleInvoices(), isEmpty);
      expect(
        await LocalInventoryApi(client, bridge(access)).listProducts(),
        isEmpty,
      );
    },
  );

  test(
    'quick purchase and payment commit once or roll back together',
    () async {
      final access = scope();
      await prepare(access);
      final local = bridge(access);
      final purchases = LocalPurchaseApi(client, local);
      final inventory = LocalInventoryApi(client, local);
      final sale = LocalSalesApi(client, local);
      final body = <String, dynamic>{
        'currency': 'SAR',
        'idempotency_key': '1763660400000000-314159',
        'items': [
          {
            'description': 'Quick product',
            'quantity': 3,
            'unit_price': 5,
            'new_product': {
              'name': 'Quick product',
              'unit': 'قطعة',
              'barcode': 'QUICK-1234',
              'save_to_inventory': true,
              'buy_currency': 'SAR',
            },
          },
        ],
        'payments': [
          {'bank_account_id': _id(), 'currency': 'SAR', 'amount': 15},
        ],
      };
      await expectLater(
        purchases.issuePurchase(body),
        throwsA(isA<BusinessLedgerError>()),
      );
      expect(await inventory.listProducts(), isEmpty);
      expect(await purchases.purchaseInvoices(), isEmpty);
      final vendor = await purchases.createSupplier(name: 'Quick test vendor');
      body['supplier_id'] = vendor['id'];
      body.remove('payments');
      final issued = await purchases.issuePurchase(body);
      await store.close();
      final repeat = await purchases.issuePurchase(body);
      expect(repeat['id'], issued['id']);
      expect((await inventory.listProducts()).single['stock'], 3);
      final localProduct = (await sale.searchProducts('Quick')).single as Map;
      expect(localProduct['stock'], 3);
      expect(
        (await purchases.resolveBarcode('QUICK-1234'))['product']['id'],
        localProduct['id'],
      );
    },
  );

  test(
    'product and prices commit together and keep price identities on edit',
    () async {
      final access = scope();
      await prepare(access);
      final inventory = LocalInventoryApi(client, bridge(access));
      final id = _id();
      final body = <String, dynamic>{
        'command_id': id,
        'name': 'Product with prices',
        'stock': 4,
        'prices': [
          {'currency': 'YER_OLD', 'price': 500, 'buy_price': 250},
          {'currency': 'YER_OLD', 'price': 510},
        ],
      };
      await expectLater(
        inventory.createProduct(body),
        throwsA(isA<BusinessLedgerError>()),
      );
      expect(await inventory.listProducts(), isEmpty);
      body['prices'].removeLast();
      final saved = await inventory.createProduct(body);
      expect((await inventory.createProduct(body))['id'], saved['id']);
      final initialPrice = (saved['prices'] as List).single;
      final updated = await inventory.updateProduct('${saved['id']}', {
        'name': 'Renamed product',
        'prices': [
          {'currency': 'YER_OLD', 'price': 515, 'buy_price': 255},
        ],
      });
      final price = (updated['prices'] as List).single;
      expect(price['id'], initialPrice['id']);
      expect(price['price'], 515);
    },
  );

  test(
    'payment names can be chosen without bank balances or another feature permission',
    () async {
      final access = scope();
      await prepare(access);
      final grant = BusinessLedgerAccess(access, {
        BusinessLedgerAction.createBank,
      });
      await store.withLedger(
        grant,
        () => access,
        (ledger) => ledger.createAccount(
          grant,
          commandId: _id(),
          bankName: 'Capped ledger bank',
          accountName: 'Office',
          accountNumber: '',
          currency: 'YER_OLD',
          accountType: 'savings',
          openingMinor: 12000,
        ),
      );
      final limited = LocalCommerceBridge(
        store,
        () => access,
        (p) => p == 'purchases.create',
      );
      final options = await LocalPurchaseApi(client, limited).bankAccounts();
      expect(options.single['currency'], 'YER_OLD');
      expect(options.single['account_type'], 'savings');
      expect(options.single['balance_visible'], isFalse);
      expect(options.single.containsKey('balance'), isFalse);
      await expectLater(
        LocalSalesApi(client, limited).bankAccounts(),
        throwsA(isA<DirectoryAccessDenied>()),
      );
    },
  );

  test(
    'a retained local source cannot read or write after scope switches',
    () async {
      final access = scope();
      final sibling = scope();
      await prepare(access);
      await prepare(sibling);
      DirectoryAccess? current = access;
      final pinned = LocalInventoryApi(
        client,
        LocalCommerceBridge(store, () => current, (_) => true),
      );
      await pinned.createProduct({'name': 'Pinned item', 'stock': 1});
      current = sibling;
      await expectLater(
        pinned.listProducts(),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await expectLater(
        pinned.createProduct({'name': 'Not for sibling'}),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(
        await LocalInventoryApi(client, bridge(sibling)).listProducts(),
        isEmpty,
      );
      expect(
        await LocalInventoryApi(client, bridge(access)).listProducts(),
        hasLength(1),
      );
    },
  );
}
