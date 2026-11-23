import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_money.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';
import 'support/business_sync_test_schema.dart';

String id() => const Uuid().v4();
const customer = DirectoryPartyKind.customer;
const supplier = DirectoryPartyKind.supplier;
const sale = BusinessInvoiceKind.sale;
const purchase = BusinessInvoiceKind.purchase;
const money = 'YER_OLD';
const allKinds = {
  'sale',
  'purchase',
  'sale_return',
  'purchase_return',
  'opening',
  'transfer',
  'income',
  'expense',
  'bank_withdrawal',
  'collection',
  'supplier_payment',
};

void main() {
  late Directory root;
  late DirectoryWorkspace workspace;
  late DirectoryDatabase db;
  late DirectoryAccess scope;
  late BusinessLedgerAccess auth;
  late FixtureDirectoryKeys keys;
  BusinessLedger ledger() => db.ledger;
  Set<BusinessLedgerAction> all() => BusinessLedgerAction.values.toSet();
  Future<DirectoryDatabase> open() =>
      DirectoryDatabase.open(root: root, workspace: workspace, keys: keys);
  DirectoryAccess scoped(String branch) => DirectoryAccess(
    workspace: workspace,
    branchId: branch,
    readable: {customer, supplier},
    writable: {customer, supplier},
    financialCutover: true,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('biz-device-followup-');
    keys = FixtureDirectoryKeys();
    workspace = DirectoryWorkspace(
      server: 'https://example.test/api/v1',
      accountId: id(),
      organizationId: id(),
    );
    scope = scoped(id());
    auth = BusinessLedgerAccess(scope, all());
    db = await open();
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  Future<String> party(DirectoryPartyKind kind) async =>
      (await db.create(scope, kind, name: 'Fixture ${kind.name}')).id;
  Future<String> bank(String name, int opening) async {
    final command = id();
    await ledger().createAccount(
      auth,
      commandId: command,
      bankName: name,
      accountName: name,
      accountNumber: '1',
      currency: money,
      openingMinor: opening,
    );
    return command;
  }

  Future<int> balance(String bank) async =>
      (await ledger().accounts(
            auth,
          )).singleWhere((a) => a['id'] == bank)['balance_minor']
          as int;
  Future<String> product(int qty, {String? cost, String? command}) async =>
      (await ledger().createCommerceProduct(
            auth,
            commandId: command ?? id(),
            name: 'Tea',
            unit: 'box',
            price: 10,
            costPrice: cost,
            costCurrency: money,
            stock: qty,
            prices: [
              {'currency': money, 'price': 10},
              {'currency': 'SAR', 'price': 1},
            ],
          ))['id']
          as String;
  Future<String> issue(
    BusinessInvoiceKind kind,
    String? p,
    String qty,
    int price, {
    String? contact,
    String? till,
    String? expiry,
    int? paid,
    BusinessRate? priceRate,
  }) async =>
      (await ledger().issueCommerceDocument(
            auth,
            commandId: id(),
            kind: kind,
            currency: money,
            partyId: contact,
            lines: [
              CommerceIssueLine(
                description: 'Tea box',
                quantity: qty,
                unitMinor: price,
                productId: p,
                isService: p == null,
                expiryDate: expiry,
                priceCurrency: priceRate?.from,
                priceRate: priceRate,
              ),
            ],
            payments: [
              if (till != null)
                CommerceIssuePayment(
                  accountId: till,
                  originalMinor: paid ?? (double.parse(qty) * price).round(),
                  paymentCurrency: money,
                ),
            ],
          ))['id']
          as String;
  Future<String> item(BusinessInvoiceKind kind, String invoice) async =>
      ((await ledger().commerceInvoice(auth, kind, invoice))!['items'] as List)
              .single['id']
          as String;
  Future<Map<String, dynamic>> card(String p) async =>
      (await ledger().commerceInventoryProduct(auth, p))!;

  test(
    'paid sale: abort is atomic, once debits 13,500 from 3,000 exactly once',
    () async {
      final p = await product(2, cost: '500');
      final collecting = await bank('Till', 0);
      final refund = await bank('Jeeb', 300000);
      final invoice = await issue(sale, p, '1', 1350000, till: collecting);
      final command = id();
      final line = CommerceReturnLine(
        itemId: await item(sale, invoice),
        quantity: '1',
      );
      Future<Map<String, Object?>> confirm({
        bool allow = false,
        bool always = false,
        BusinessLedgerAccess? access,
      }) => ledger().confirmCommerceReturn(
        access ?? auth,
        commandId: command,
        kind: sale,
        invoiceId: invoice,
        lines: [line],
        refundAccountId: refund,
        expectedRefundMinor: 1350000,
        allowNegative: allow,
        rememberAllowNegative: always,
      );

      await expectLater(
        confirm(),
        throwsA(
          isA<BusinessReturnOverdraft>().having(
            (e) => e.refundMinor,
            'requested amount',
            1350000,
          ),
        ),
      );
      expect(await balance(refund), 300000);
      expect(await ledger().commerceReturnsList(auth), isEmpty);
      expect((await card(p))['stock'], 1);

      final confirmed = await confirm(allow: true);
      expect(confirmed['refund_original_minor'], 1350000);
      expect(confirmed['refund_currency'], money);
      expect(await balance(refund), -1050000);
      expect((await card(p))['stock'], 2);
      expect(await ledger().savedAllowNegative(auth), isNull);
      await db.close();
      db = await open();
      expect(await confirm(allow: true), confirmed);
      expect(await balance(refund), -1050000);
      expect(
        (await ledger().statement(
          auth,
          refund,
        )).where((l) => l['reference'] == confirmed['number']),
        hasLength(1),
      );
      expect(await ledger().commerceReturnsList(auth), hasLength(1));
    },
  );

  test(
    'stale or debt-only return never quietly substitutes a cash movement',
    () async {
      final buyer = await party(customer);
      final account = await bank('Refund', 0);
      final p = await product(3);
      final inv = await issue(sale, p, '3', 450000, contact: buyer);
      final line = CommerceReturnLine(
        itemId: await item(sale, inv),
        quantity: '1',
      );
      final command = id();
      Future<Map<String, Object?>> commit(int cash) =>
          ledger().confirmCommerceReturn(
            auth,
            commandId: command,
            kind: sale,
            invoiceId: inv,
            lines: [line],
            refundAccountId: account,
            expectedRefundMinor: cash,
          );
      await expectLater(
        commit(450000),
        throwsA(
          isA<BusinessLedgerError>().having(
            (e) => e.problem,
            'reason',
            BusinessLedgerProblem.invoiceChanged,
          ),
        ),
      );
      expect((await card(p))['stock'], 0);
      expect(await ledger().commerceReturnsList(auth), isEmpty);
      final result = await commit(0);
      expect(result['applied_minor'], 450000);
      expect(result['refunded_minor'], 0);
      expect(await balance(account), 0);
      expect(await ledger().statement(auth, account), isEmpty);
    },
  );

  test(
    'always persists in this branch only; incoming supplier refunds need no overdraft',
    () async {
      final till = await bank('Till', 5000);
      final refund = await bank('Separate refund', 0);
      final p = await product(2);
      final bought = await issue(purchase, p, '1', 500, till: till);
      final sold = await issue(sale, p, '1', 2000, till: till);
      final line = CommerceReturnLine(
        itemId: await item(sale, sold),
        quantity: '1',
      );
      final confirmOnly = BusinessLedgerAccess(scope, {
        BusinessLedgerAction.confirmReturn,
      });
      expect(
        () => ledger().confirmCommerceReturn(
          confirmOnly,
          commandId: id(),
          kind: sale,
          invoiceId: sold,
          lines: [line],
          refundAccountId: refund,
          allowNegative: true,
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(
        () => ledger().confirmCommerceReturn(
          BusinessLedgerAccess(scope, {
            BusinessLedgerAction.confirmReturn,
            BusinessLedgerAction.authorizeReturnOverdraft,
          }),
          commandId: id(),
          kind: sale,
          invoiceId: sold,
          lines: [line],
          refundAccountId: refund,
          allowNegative: true,
          rememberAllowNegative: true,
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await ledger().confirmCommerceReturn(
        auth,
        commandId: id(),
        kind: sale,
        invoiceId: sold,
        lines: [line],
        refundAccountId: refund,
        allowNegative: true,
        rememberAllowNegative: true,
      );
      expect(await balance(refund), -2000);
      expect(await ledger().savedAllowNegative(auth), isTrue);
      final sibling = BusinessLedgerAccess(scoped(id()), all());
      expect(await ledger().savedAllowNegative(sibling), isNull);
      // A deposit that improves a still-negative balance is never an overdraft.
      await ledger().setAllowNegative(auth, false);
      await ledger().confirmCommerceReturn(
        auth,
        commandId: id(),
        kind: purchase,
        invoiceId: bought,
        lines: [
          CommerceReturnLine(
            itemId: await item(purchase, bought),
            quantity: '1',
          ),
        ],
        refundAccountId: refund,
      );
      expect(await balance(refund), -1500);
    },
  );

  test(
    'a failed refund posting rolls back the return, stock and always preference',
    () async {
      final p = await product(2, cost: '200');
      final refund = await bank('Refund', 300000);
      final sold = await issue(sale, p, '1', 1350000, till: await bank('Till', 0));
      final line = CommerceReturnLine(itemId: await item(sale, sold), quantity: '1');
      final command = id();
      Future<Map<String, Object?>> confirm() => ledger().confirmCommerceReturn(
        auth,
        commandId: command,
        kind: sale,
        invoiceId: sold,
        lines: [line],
        refundAccountId: refund,
        allowNegative: true,
        rememberAllowNegative: true,
        expectedRefundMinor: 1350000,
        expectedAccountCurrency: money,
      );
      Future<void> fault({required bool enable}) async {
        final raw = await databaseFactoryFfi.openDatabase(
          DirectoryDatabase.filePath(root, workspace),
          options: OpenDatabaseOptions(
            singleInstance: false,
            onConfigure: (db) => db.execute(
              'PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"',
            ),
          ),
        );
        try {
          await raw.execute(enable ? '''
            CREATE TRIGGER fixture_fail_refund BEFORE INSERT ON business_local_bank_legs
            WHEN NEW.command_id = '$command'
            BEGIN SELECT RAISE(ABORT, 'fixture interrupted refund'); END
          ''' : 'DROP TRIGGER fixture_fail_refund');
        } finally {
          await raw.close();
        }
      }
      await fault(enable: true);
      await expectLater(confirm(), throwsA(isA<DatabaseException>()));
      await db.close();
      db = await open();
      expect(await ledger().savedAllowNegative(auth), isNull);
      expect(await balance(refund), 300000);
      expect(await ledger().commerceReturnsList(auth), isEmpty);
      expect((await card(p))['stock'], 1);
      expect(((await card(p))['lots'] as List).single['remaining'], 1);
      await fault(enable: false);
      final receipt = await confirm();
      expect(await confirm(), receipt);
      expect(await ledger().savedAllowNegative(auth), isTrue);
      expect(await balance(refund), -1050000);
      expect((await card(p))['stock'], 2);
    },
  );

  test(
    'only manual entries are income/expenses; documents have original, scoped entries',
    () async {
      final account = await bank('Bank', 2000000);
      final buyer = await party(customer);
      final p = await product(2, cost: '60');
      final s = await issue(sale, p, '1', 10000, till: account);
      final b = await issue(purchase, p, '2', 5000, till: account);
      final r = await ledger().confirmCommerceReturn(
        auth,
        commandId: id(),
        kind: sale,
        invoiceId: s,
        lines: [CommerceReturnLine(itemId: await item(sale, s), quantity: '1')],
        refundAccountId: account,
      );
      final deferred = await issue(sale, p, '1', 9000, contact: buyer);
      final credit = id(), debit = id();
      await ledger().move(
        auth,
        commandId: credit,
        accountId: account,
        amountMinor: 7000,
        withdraw: false,
        description: 'Manual deposit',
      );
      await ledger().move(
        auth,
        commandId: debit,
        accountId: account,
        amountMinor: 4000,
        withdraw: true,
        expenseCategory: 'Office',
      );
      final rows = await ledger().operations(auth, allowedKinds: allKinds);
      expect(
        rows.map((r) => r['source_id']),
        unorderedEquals([account, s, b, r['id'], deferred, credit, debit]),
      );
      expect(
        await ledger().manualMovements(
          auth,
          showIncome: true,
          showExpenses: true,
        ),
        hasLength(2),
      );
      final manual = await ledger().operations(
        auth,
        allowedKinds: allKinds,
        kind: 'inout',
      );
      expect(
        manual.map((r) => r['source_id']),
        unorderedEquals([credit, debit]),
      );
      final detail = await ledger().operations(
        auth,
        allowedKinds: allKinds,
        sourceType: 'sale_return',
        sourceId: r['id'] as String,
      );
      expect(detail.single['invoice_id'], s);
      expect(
        (await ledger().operations(
          auth,
          allowedKinds: {'sale'},
          period: 'today',
          search: '${detail.single['reference']}',
        )),
        isEmpty,
      );
      expect(
        (await ledger().operations(
          auth,
          allowedKinds: {'sale'},
        )).map((r) => r['source_id']),
        unorderedEquals([deferred, s]),
      );
      expect(
        await ledger().operations(
          BusinessLedgerAccess(scoped(id()), all()),
          allowedKinds: allKinds,
          sourceType: 'invoice',
          sourceId: s,
        ),
        isEmpty,
      );
    },
  );

  test(
    'receipts only: initial, positive adjustments and purchase; FIFO and returns',
    () async {
      final p = await product(3, cost: '2');
      expect(((await card(p))['lots'] as List).single['received'], 3);
      final till = await bank('Till', 50000);
      final bought = await issue(
        purchase,
        p,
        '4',
        300,
        till: till,
        expiry: '2025-01-01',
      );
      await ledger().adjustCommerceStock(
        auth,
        productId: p,
        commandId: id(),
        mode: BusinessStockAdjustment.set,
        amountMilli: 9000,
        expectedMilli: 7000,
      );
      final sold = await issue(sale, p, '5', 1000, till: till);
      final saleItem = await item(sale, sold);
      Future<List<dynamic>> lots() async => (await card(p))['lots'] as List;
      expect((await lots()).map((l) => l['source']), [
        'initial',
        'purchase',
        'adjustment',
      ]);
      expect((await lots()).map((l) => l['remaining']), [0, 2, 2]);
      final stats = await ledger().commerceProductStats(auth, p);
      expect(stats['sales_total'], '50.00');
      expect(stats['purchases_total'], '12.00');
      expect(stats['cogs'], '12.00');
      expect(stats['profit'], '38.00');
      expect(stats['sales_count'], 1);
      expect(stats['purchases_quantity'], 4);
      final after = await ledger().commerceProductStats(
        auth,
        p,
        from: '2099-01-01',
      );
      expect(after['sales_count'], 0);
      expect(after['movements'], isEmpty);
      final noCosts = await ledger().commerceProductStats(
        BusinessLedgerAccess(scope, {BusinessLedgerAction.readInventory}),
        p,
      );
      expect(noCosts['cogs'], isNull);
      expect(noCosts['profit'], isNull);
      final noQuote = await ledger().commerceProductStats(
        auth,
        p,
        displayCurrency: 'SAR',
      );
      expect(noQuote['fx_incomplete'], isTrue);
      expect(noQuote['sales_total'], isNull);
      Future<void> undo() => ledger().confirmCommerceReturn(
        auth,
        commandId: id(),
        kind: sale,
        invoiceId: sold,
        lines: [CommerceReturnLine(itemId: saleItem, quantity: '1')],
        refundAccountId: till,
      );
      await undo();
      await undo();
      await undo();
      expect((await lots()).map((l) => l['remaining']), [1, 4, 2]);
      await ledger().confirmCommerceReturn(
        auth,
        commandId: id(),
        kind: purchase,
        invoiceId: bought,
        lines: [
          CommerceReturnLine(
            itemId: await item(purchase, bought),
            quantity: '1',
          ),
        ],
        refundAccountId: till,
      );
      expect((await lots()).map((l) => l['remaining']), [1, 3, 2]);
      expect((await lots())[1]['purchase_invoice_id'], bought);
      expect((await lots())[0]['product_name'], 'Tea');
      expect((await card(p))['stock'], 6);
      await ledger().adjustCommerceStock(
        auth,
        productId: p,
        commandId: id(),
        mode: BusinessStockAdjustment.remove,
        amountMilli: 2000,
        expectedMilli: 6000,
      );
      expect((await lots()).map((l) => l['remaining']), [0, 2, 2]);
    },
  );

  test(
    'opening receipt upgrade groups v7 covers without re-posting stock or money',
    () async {
      final p = await product(5, cost: '2');
      final till = await bank('Till', 1500);
      final sold = await issue(sale, p, '2', 600, till: till);
      final oldCover = id();
      final bought = await issue(purchase, p, '4', 200, till: till);
      await ledger().confirmCommerceReturn(
        auth,
        commandId: id(),
        kind: purchase,
        invoiceId: bought,
        lines: [
          CommerceReturnLine(
            itemId: await item(purchase, bought),
            quantity: '1',
          ),
        ],
        refundAccountId: till,
      );
      await db.close();
      // Construct the exact v7 shape in a throw-away copy: 2 used via an
      // internal cover, 3 still not attributed to any receipt.
      final sql = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(root, workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) => db.execute(
            'PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"',
          ),
        ),
      );
      try {
        await sql.transaction((tx) async {
          await removeBusinessSyncSchema(tx);
          await tx.execute('DROP TABLE business_local_party_shares');
          await tx.execute('DROP TABLE business_cash_replica');
          await tx.execute('DROP TABLE business_backup_recoveries');
          await tx.execute('DROP TABLE business_reconciliations');
          await tx.execute('DROP INDEX business_commerce_lots_receipt');
          await tx.execute(
            'ALTER TABLE business_commerce_lot_consumptions DROP COLUMN restored_micro',
          );
          await tx.execute(
            'ALTER TABLE business_commerce_lots DROP COLUMN receipt_lot_id',
          );
          await tx.rawUpdate(
            """
          UPDATE business_commerce_lots SET id = ?, source = 'opening',
            received_micro = 2000000, remaining_micro = 0, purchase_date = NULL
           WHERE product_id = ? AND source = 'initial'
        """,
            [oldCover, p],
          );
          await tx.rawUpdate(
            'UPDATE business_commerce_lot_consumptions SET lot_id = ? WHERE item_id IS NOT NULL',
            [oldCover],
          );
          // The old purchase return reduced stock and refunded the account,
          // but did not touch its batch.
          await tx.rawUpdate(
            "UPDATE business_commerce_lots SET remaining_micro = received_micro WHERE source = 'purchase'",
          );
          await tx.rawDelete(
            'DELETE FROM business_commerce_lot_consumptions WHERE item_id IS NULL',
          );
          await tx.execute('PRAGMA user_version = 7');
        });
      } finally {
        await sql.close();
      }
      db = await open();
      expect((await card(p))['stock'], 6);
      expect(await balance(till), 2100);
      final batches = (await card(p))['lots'] as List;
      expect(batches, hasLength(2));
      expect(batches[1]['received'], 4);
      expect(batches[1]['remaining'], 3);
      final lot = batches.first;
      expect(lot['received'], 5);
      expect(lot['remaining'], 3);
      expect(lot['unit_cost'], isNull); // Not today's card cost.
      await ledger().confirmCommerceReturn(
        auth,
        commandId: id(),
        kind: sale,
        invoiceId: sold,
        lines: [
          CommerceReturnLine(itemId: await item(sale, sold), quantity: '1'),
        ],
        refundAccountId: till,
      );
      final left = ((await card(p))['lots'] as List).first;
      expect(left['id'], lot['id']);
      expect(left['remaining'], 4);
      expect(await balance(till), 1500);
    },
  );

  test(
    'product stats use the saved line quote, including after reopen',
    () async {
      final p = await product(1, cost: '2');
      await issue(
        sale,
        p,
        '1',
        1000,
        till: await bank('Till', 0),
        priceRate: BusinessRate('SAR', money, '5'),
      );
      final before = await ledger().commerceProductStats(
        auth,
        p,
        displayCurrency: 'SAR',
      );
      expect(before['sales_total'], '2.00');
      expect(before['cogs'], '0.40');
      expect(before['profit'], '1.60');
      await db.close();
      db = await open();
      expect(
        await ledger().commerceProductStats(auth, p, displayCurrency: 'SAR'),
        before,
      );
    },
  );
}
