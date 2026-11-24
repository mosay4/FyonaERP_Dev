import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_money.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

double units(Object? decimal) => num.tryParse('$decimal')?.toDouble() ?? -1;

void main() {
  final workspace = DirectoryWorkspace(
    server: 'http://localhost:18083/api/v1',
    accountId: _id(),
    organizationId: _id(),
  );
  DirectoryAccess scope(String branch) => DirectoryAccess(
    workspace: workspace,
    branchId: branch,
    readable: {},
    writable: {},
    financialCutover: true,
  );
  final all = BusinessLedgerAction.values.toSet();
  late Directory root;
  late DirectoryDatabase db;
  late String a, b, c;
  late BusinessLedgerAccess accessA, accessB;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fyona-branch-transfer-');
    db = await DirectoryDatabase.open(
      root: root,
      workspace: workspace,
      keys: FixtureDirectoryKeys(),
    );
    a = _id();
    b = _id();
    c = _id();
    accessA = BusinessLedgerAccess(scope(a), all);
    accessB = BusinessLedgerAccess(scope(b), all);
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<String> account(
    BusinessLedgerAccess access, {
    int opening = 0,
  }) async {
    final id = _id();
    await db.ledger.createAccount(
      access,
      commandId: id,
      bankName: 'Cash',
      accountName: 'Account',
      accountNumber: '1',
      currency: 'SAR',
      openingMinor: opening,
    );
    return id;
  }

  Future<String> product(
    BusinessLedgerAccess access, {
    String? id,
    String name = 'مياه',
    String? sku,
    int stockMilli = 0,
    double costPrice = 0,
    String? expiry,
  }) async {
    final commandId = id ?? _id();
    final created = await db.ledger.createCommerceProduct(
      access,
      commandId: commandId,
      name: name,
      unit: 'قطعة',
      price: 1000,
      costPrice: costPrice,
      costCurrency: 'SAR',
      stock: stockMilli / 1000.0,
      sku: sku,
      expiryDate: expiry,
    );
    return created['id'] as String;
  }

  Future<List<Map<Object?, Object?>>> lotsOf(
    BusinessLedgerAccess access,
    String product,
  ) async {
    final detail = await db.ledger.commerceInventoryProduct(access, product);
    return [
      for (final lot in (detail?['lots'] as List? ?? const []))
        Map<Object?, Object?>.from(lot as Map),
    ];
  }

  test('money moves between two branches together or not at all', () async {
    final from = await account(accessA, opening: 10000);
    final to = await account(accessB);
    final other = await account(accessB, opening: 500);
    Future<Map<String, int>> totals() async => {
      for (final access in [accessA, accessB])
        for (final row in await db.ledger.accounts(access))
          '${row['id']}': row['balance_minor'] as int,
    };

    // The acting branch must be one of the two sides.
    await expectLater(
      db.ledger.transferBetweenBranches(
        BusinessLedgerAccess(scope(c), all),
        commandId: _id(),
        fromBranch: a,
        toBranch: b,
        fromAccountId: from,
        toAccountId: to,
        amountMinor: 100,
      ),
      throwsA(isA<BusinessLedgerError>()),
    );
    final command = _id();
    final moved = await db.ledger.transferBetweenBranches(
      accessA,
      commandId: command,
      fromBranch: a,
      toBranch: b,
      fromAccountId: from,
      toAccountId: to,
      amountMinor: 2500,
      notes: 'تحويل للفرع الثاني',
    );
    expect(moved['amount_minor'], -2500);
    expect(await totals(), {from: 7500, to: 2500, other: 500});
    final sent = await db.ledger.moneyReport(accessA, currency: 'SAR');
    final received = await db.ledger.moneyReport(accessB, currency: 'SAR');
    expect(sent['transfers']['total'], '25.00');
    expect(received['transfers']['total'], '0.00'); // company counts the out leg once
    expect(received['inflow']['total'], '0.00');
    // The same command never moves money twice.
    await db.ledger.transferBetweenBranches(
      accessA,
      commandId: command,
      fromBranch: a,
      toBranch: b,
      fromAccountId: from,
      toAccountId: to,
      amountMinor: 2500,
      notes: 'تحويل للفرع الثاني',
    );
    expect(await totals(), {from: 7500, to: 2500, other: 500});
    // An overdraft refuses and leaves both branches untouched.
    await expectLater(
      db.ledger.transferBetweenBranches(
        accessB,
        commandId: _id(),
        fromBranch: a,
        toBranch: b,
        fromAccountId: from,
        toAccountId: to,
        amountMinor: 9000,
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (e) => e.problem,
          'problem',
          BusinessLedgerProblem.insufficientBalance,
        ),
      ),
    );
    expect(await totals(), {from: 7500, to: 2500, other: 500});

    // The reversal returns exactly what left.
    final reversal = await db.ledger.reverseBranchTransfer(
      accessB,
      commandId: _id(),
      transferId: command,
    );
    expect(reversal['reversal_of'], command);
    expect(await totals(), {from: 10000, to: 0, other: 500});
    expect((await db.ledger.moneyReport(accessA, currency: 'SAR'))['transfers']['total'], '0.00');
    expect((await db.ledger.moneyReport(accessB, currency: 'SAR'))['transfers']['total'], '0.00');
    await expectLater(
      db.ledger.reverseBranchTransfer(
        accessA,
        commandId: _id(),
        transferId: command,
      ),
      throwsA(isA<BusinessLedgerError>()),
    );
    // A reversal cannot pull back money already spent.
    final second = _id();
    await db.ledger.transferBetweenBranches(
      accessA,
      commandId: second,
      fromBranch: a,
      toBranch: b,
      fromAccountId: from,
      toAccountId: to,
      amountMinor: 3000,
    );
    await db.ledger.move(
      accessB,
      commandId: _id(),
      accountId: to,
      amountMinor: 3000,
      withdraw: true,
    );
    await expectLater(
      db.ledger.reverseBranchTransfer(
        accessA,
        commandId: _id(),
        transferId: second,
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (e) => e.problem,
          'problem',
          BusinessLedgerProblem.insufficientBalance,
        ),
      ),
    );
    final rows = await db.ledger.branchTransfers(accessA, kind: 'financial');
    expect(rows.map((row) => row['status']).toSet(), {'done', 'reversed'});
  });

  test('stock travels with its batches and reverses exactly', () async {
    final itemId = _id();
    final water = await product(
      accessA,
      id: itemId,
      name: 'مياه',
      sku: 'W1',
      stockMilli: 10000,
      costPrice: 50,
      expiry: '2027-01-01',
    );
    // The destination carries the same goods under the same identity.
    await product(accessB, id: itemId, name: 'مياه', sku: 'W1');
    final scarceCommand = _id();
    final scarce = await product(
      accessA,
      id: scarceCommand,
      name: 'عصير',
      sku: 'J1',
      stockMilli: 1000,
      costPrice: 2.5,
    );
    await product(accessB, id: scarceCommand, name: 'عصير', sku: 'J1');

    // A line that cannot be covered refuses the whole transfer.
    await expectLater(
      db.ledger.transferStockBetweenBranches(
        accessA,
        commandId: _id(),
        fromBranch: a,
        toBranch: b,
        items: [
          BusinessStockTransferLine(fromProduct: water, quantityMicro: 2000000),
          BusinessStockTransferLine(fromProduct: scarce, quantityMicro: 5000000),
        ],
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (e) => e.problem,
          'problem',
          BusinessLedgerProblem.insufficientStock,
        ),
      ),
    );
    expect(units((await lotsOf(accessA, water)).single['remaining']), 10.0);

    final command = _id();
    final moved = await db.ledger.transferStockBetweenBranches(
      accessA,
      commandId: command,
      fromBranch: a,
      toBranch: b,
      items: [
        BusinessStockTransferLine(fromProduct: water, quantityMicro: 2000000),
      ],
      notes: 'تحويل مخزون',
      actor: {'name': 'قاسم', 'role': 'owner'},
    );
    final line = (moved['lines'] as List).single as Map;
    final allocations = (line['allocations'] as List).whereType<Map>().toList();
    expect(allocations, hasLength(1));
    expect(allocations.single['issue_micro'], 2000000);
    expect(allocations.single['receipt_micro'], 2000000);
    final detail = await db.ledger.branchTransferDetail(accessB, command);
    expect(detail['status'], 'done');
    expect(detail['can_reverse'], isTrue);
    expect((detail['items'] as List), hasLength(1));
    // What the details screen shows: who, how many, cost and price.
    expect(detail['actor_name'], 'قاسم');
    expect(detail['actor_role'], 'owner');
    expect(detail['exchange_rate'], isNull);
    final shown = (detail['items'] as List).single as Map;
    expect(shown['from_quantity'], 2.0);
    expect(shown['unit_cost'], 50.0);
    expect(shown['total_cost'], 100.0);
    expect(shown['currency'], 'SAR');
    expect(shown['from_product_name'], 'مياه');
    expect(shown['to_product_name'], 'مياه');
    expect((shown['sale_price'] as num) > 0, isTrue);
    expect(detail['total_cost'], 100.0);
    // The owner sees it from a third branch too (read only there).
    final accessC = BusinessLedgerAccess(scope(c), all);
    final everywhere = await db.ledger.branchTransfers(accessC, everyBranch: true);
    final listed = everywhere.singleWhere((row) => row['id'] == command);
    expect(listed['can_reverse'], isFalse);
    expect(listed['items'], hasLength(1));
    expect(await db.ledger.branchTransfers(accessC), isEmpty);
    final elsewhere = await db.ledger.branchTransferDetail(
      accessC,
      command,
      everyBranch: true,
    );
    expect(elsewhere['from_branch'], a);
    expect(elsewhere['can_reverse'], isFalse);

    // The destination batch kept the source cost, currency and expiry.
    final received = await lotsOf(accessB, water);
    final batch = received.single;
    expect(units(batch['remaining']), 2.0);
    expect(units(batch['unit_cost']), 50.0);
    expect(batch['currency'], 'SAR');
    expect(batch['expiry_date'], '2027-01-01');
    expect(batch['source'], 'transfer');
    // The source batch lost exactly the taken slice.
    expect(units((await lotsOf(accessA, water)).single['remaining']), 8.0);
    expect((await db.ledger.inventoryReport(accessA, currency: 'SAR'))['stock_value'], '402.50');
    expect((await db.ledger.inventoryReport(accessB, currency: 'SAR'))['stock_value'], '100.00');

    // A conversion that would round refuses instead of inventing quantity.
    await expectLater(
      db.ledger.transferStockBetweenBranches(
        accessA,
        commandId: _id(),
        fromBranch: a,
        toBranch: b,
        items: [
          BusinessStockTransferLine(
            fromProduct: water,
            quantityMicro: 1,
            conversionFactor4: 3333,
          ),
        ],
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (e) => e.problem,
          'problem',
          BusinessLedgerProblem.invalidAmount,
        ),
      ),
    );

    // The reversal returns the original batches and nothing else.
    await db.ledger.reverseBranchTransfer(
      accessA,
      commandId: _id(),
      transferId: command,
    );
    expect(units((await lotsOf(accessA, water)).single['remaining']), 10.0);
    expect(units((await lotsOf(accessB, water)).single['remaining']), 0.0);
    expect((await db.ledger.inventoryReport(accessA, currency: 'SAR'))['stock_value'], '502.50');
    expect((await db.ledger.inventoryReport(accessB, currency: 'SAR'))['stock_value'], '0.00');

    // One source unit becomes exactly two destination units of its twin.
    final twin = await product(accessB, name: 'مياه صغيرة', sku: 'W2');
    final converted = await db.ledger.transferStockBetweenBranches(
      accessA,
      commandId: _id(),
      fromBranch: a,
      toBranch: b,
      items: [
        BusinessStockTransferLine(
          fromProduct: water,
          toProduct: twin,
          quantityMicro: 1000000,
          conversionFactor4: 20000,
        ),
      ],
    );
    expect(
      (((converted['lines'] as List).single as Map)['receipt_micro']),
      2000000,
    );
    expect(units((await lotsOf(accessB, twin)).single['remaining']), 2.0);

    // A batch already used at the destination cannot be recalled.
    final second = _id();
    await db.ledger.transferStockBetweenBranches(
      accessA,
      commandId: second,
      fromBranch: a,
      toBranch: b,
      items: [
        BusinessStockTransferLine(fromProduct: water, quantityMicro: 3000000),
      ],
    );
    await db.ledger.adjustCommerceStock(
      accessB,
      productId: water,
      commandId: _id(),
      mode: BusinessStockAdjustment.remove,
      amountMilli: 3000,
      expectedMilli: 3000,
    );
    await expectLater(
      db.ledger.reverseBranchTransfer(
        accessA,
        commandId: _id(),
        transferId: second,
      ),
      throwsA(
        isA<BusinessLedgerError>().having(
          (e) => e.problem,
          'problem',
          BusinessLedgerProblem.invalidTransfer,
        ),
      ),
    );
    // The same transfer command never moves stock twice.
    await db.ledger.transferStockBetweenBranches(
      accessA,
      commandId: command,
      fromBranch: a,
      toBranch: b,
      items: [
        BusinessStockTransferLine(fromProduct: water, quantityMicro: 2000000),
      ],
      notes: 'تحويل مخزون',
    );
    expect(units((await lotsOf(accessA, water)).single['remaining']), 6.0);
    // A branch with no records here is never touched.
    await expectLater(
      db.ledger.transferStockBetweenBranches(
        accessA,
        commandId: _id(),
        fromBranch: a,
        toBranch: c,
        items: [
          BusinessStockTransferLine(fromProduct: water, quantityMicro: 1000000),
        ],
      ),
      throwsA(isA<BusinessLedgerError>()),
    );
  });

  test('the details carry the rate only between two currencies', () async {
    final from = await account(accessA, opening: 100000);
    final usd = _id();
    await db.ledger.createAccount(
      accessB,
      commandId: usd,
      bankName: 'Cash',
      accountName: 'Dollars',
      accountNumber: '2',
      currency: 'USD',
      openingMinor: 0,
    );
    final same = await account(accessB);
    final command = _id();
    await db.ledger.transferBetweenBranches(
      accessA,
      commandId: command,
      fromBranch: a,
      toBranch: b,
      fromAccountId: from,
      toAccountId: usd,
      amountMinor: 37500,
      rate: BusinessRate('SAR', 'USD', '0.2667'),
      actor: {'name': 'قاسم', 'role': 'owner'},
    );
    final detail = await db.ledger.branchTransferDetail(accessA, command);
    expect(detail['exchange_rate'], '0.2667');
    expect(detail['to_currency'], 'USD');
    expect(detail['actor_name'], 'قاسم');
    final plain = _id();
    await db.ledger.transferBetweenBranches(
      accessA,
      commandId: plain,
      fromBranch: a,
      toBranch: b,
      fromAccountId: from,
      toAccountId: same,
      amountMinor: 1000,
    );
    final sameDetail = await db.ledger.branchTransferDetail(accessA, plain);
    expect(sameDetail['exchange_rate'], isNull);
    // Written before the author was recorded: no name, never a crash.
    expect(sameDetail['actor_name'], isNull);
  });
}
