import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_money.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

void main() {
  test(
    'posted commerce and overview stay exact, scoped and as recorded',
    () async {
      final root = await Directory.systemTemp.createTemp('fyona-sales-report-');
      addTearDown(() => root.delete(recursive: true));
      final workspace = DirectoryWorkspace(
        server: 'https://sales-report.fixture.test/api/v1',
        accountId: _id(),
        organizationId: _id(),
      );
      DirectoryAccess branch() => DirectoryAccess(
        workspace: workspace,
        branchId: _id(),
        financialCutover: true,
        readable: DirectoryPartyKind.values.toSet(),
        writable: DirectoryPartyKind.values.toSet(),
      );
      final here = branch(), there = branch();
      BusinessLedgerAccess grant(DirectoryAccess scope) =>
          BusinessLedgerAccess(scope, BusinessLedgerAction.values.toSet());
      final local = grant(here), other = grant(there);
      final keys = FixtureDirectoryKeys();
      Future<DirectoryDatabase> open() =>
          DirectoryDatabase.open(root: root, workspace: workspace, keys: keys);
      var db = await open();
      addTearDown(() => db.close());
      final buyer = await db.create(
        here,
        DirectoryPartyKind.customer,
        name: 'Branch buyer',
      );
      final seller = await db.create(
        here,
        DirectoryPartyKind.supplier,
        name: 'Branch supplier',
      );
      final outsider = await db.create(
        there,
        DirectoryPartyKind.customer,
        name: 'Sibling buyer',
      );
      final bank = _id(), otherBank = _id();
      for (final id in [bank, otherBank]) {
        await db.ledger.createAccount(
          local,
          commandId: id,
          bankName: 'Fixture bank',
          accountName: id,
          accountNumber: id.substring(0, 8),
          currency: 'SAR',
          openingMinor: 20000,
        );
      }
      await db.ledger.move(
        local,
        commandId: _id(),
        accountId: bank,
        amountMinor: 1500,
        withdraw: false,
      );
      await db.ledger.move(
        local,
        commandId: _id(),
        accountId: bank,
        amountMinor: 700,
        withdraw: true,
        expenseCategory: 'Transport',
      );
      await db.ledger.transfer(
        local,
        commandId: _id(),
        fromId: bank,
        toId: otherBank,
        amountMinor: 900,
      );
      final item =
          (await db.ledger.createCommerceProduct(
                local,
                commandId: _id(),
                name: 'Tea',
                unit: 'box',
                price: '10',
                stock: '10',
                costPrice: '4',
              ))['id']
              as String;
      const sale = BusinessInvoiceKind.sale;
      const purchase = BusinessInvoiceKind.purchase;
      final issued = await db.ledger.issueCommerceDocument(
        local,
        commandId: _id(),
        kind: sale,
        currency: 'SAR',
        partyId: buyer.id,
        lines: [
          CommerceIssueLine(
            description: 'Tea',
            quantity: '2',
            unitMinor: 1000,
            productId: item,
          ),
        ],
        payments: [
          CommerceIssuePayment(
            accountId: bank,
            paymentCurrency: 'SAR',
            originalMinor: 800,
          ),
        ],
      );
      final invoiceId = issued['id'] as String;
      final invoice = await db.ledger.commerceInvoice(local, sale, invoiceId);
      final line = ((invoice!['items'] as List).single as Map)['id'] as String;
      final returnCommand = _id();
      Future<Map<String, Object?>> returnTea() =>
          db.ledger.confirmCommerceReturn(
            local,
            commandId: returnCommand,
            kind: sale,
            invoiceId: invoiceId,
            lines: [
              CommerceReturnLine(itemId: line, quantity: '1', restock: true),
            ],
          );
      expect(await returnTea(), await returnTea()); // exact replay, not twice
      await db.ledger.issueCommerceDocument(
        local,
        commandId: _id(),
        kind: purchase,
        currency: 'SAR',
        partyId: seller.id,
        lines: [
          CommerceIssueLine(
            description: 'Tea',
            quantity: '3',
            unitMinor: 420,
            productId: item,
          ),
        ],
      );
      await db.ledger.issueCommerceDocument(
        other,
        commandId: _id(),
        kind: sale,
        currency: 'EUR',
        partyId: outsider.id,
        lines: const [
          CommerceIssueLine(
            description: 'Not in this branch',
            quantity: '1',
            unitMinor: 990001,
            isService: true,
          ),
        ],
      );

      final day = DateTime.now().toUtc().toIso8601String().split('T').first;
      Future<Map<String, dynamic>> sales() =>
          db.ledger.salesReport(local, currency: 'SAR', from: day, to: day);
      Future<Map<String, dynamic>> overview([BusinessLedgerAccess? access]) =>
          db.ledger.overviewReport(
            access ?? local,
            currency: 'SAR',
            from: day,
            to: day,
            home: false,
          );
      final native = await sales();
      expect(native['totals_complete'], isTrue);
      expect(native['branch_ids'], [here.branchId]);
      expect(native['sales']['count'], 1);
      expect(native['sales']['total'], '20.00');
      expect(native['sales']['paid'], '8.00');
      expect(native['sales']['remaining'], '2.00');
      expect(native['sales']['returns']['total'], '10.00');
      expect(native['sales']['returns']['count'], 1);
      expect(native['purchases']['total'], '12.60');
      expect(native['sales']['chart'], [
        {'date': day, 'value': '20.00'},
      ]);
      expect((native['top_products'] as List).single['product_id'], item);
      expect(
        (native['invoices'] as List).map((i) => i['party']),
        unorderedEquals(['Branch buyer', 'Branch supplier']),
      );

      final whole = await overview();
      expect(whole['totals_complete'], isTrue);
      expect(
        whole['income']['total'],
        '15.00',
      ); // not openings, transfers or sale tender
      expect(whole['expenses']['total'], '7.00');
      expect(whole['profit']['total'], '14.00'); // 20-8-10+4+15-7
      expect(whole['customer_debt']['total'], '2.00');
      expect(whole['supplier_debt']['total'], '12.60');
      expect(whole['inventory']['stock_value'], '48.60');
      expect(whole['comparison']['sold_delta'], '20.00');
      final restricted = await overview(
        BusinessLedgerAccess(here, {BusinessLedgerAction.readOverviewReport}),
      );
      expect(restricted['profit'], isNull);
      expect(restricted['inventory']['stock_value'], isNull);
      expect(restricted['sales']['total'], '20.00');

      await db.ledger.issueCommerceDocument(
        local,
        commandId: _id(),
        kind: sale,
        currency: 'USD',
        partyId: buyer.id,
        lines: [
          CommerceIssueLine(
            description: 'Archived quote',
            quantity: '1',
            unitMinor: 200,
            isService: true,
            originalUnitMinor: 750,
            priceCurrency: 'SAR',
            priceRate: BusinessRate('SAR', 'USD', '0.26666667'),
          ),
        ],
      );
      await db.close();
      db = await open();
      final mixed = await sales();
      expect(mixed['totals_complete'], isFalse);
      expect(
        mixed['sales']['total'],
        '27.50',
      ); // preserve the frozen sale quote
      expect(
        mixed['sales']['remaining'],
        isNull,
      ); // not a current balance quote
      expect(mixed['sales']['chart'], [
        {'date': day, 'value': '27.50'},
      ]);
      expect(mixed['sales']['per_currency'], [
        {'currency': 'SAR', 'total': '20.00'},
        {'currency': 'USD', 'total': '2.00'},
      ]);
      expect(
        (mixed['top_products'] as List).singleWhere(
          (p) => p['name'] == 'Archived quote',
        )['total'],
        '7.50',
      );
      expect(await db.ledger.salesReportCurrencies(local), {'SAR', 'USD'});
      final mixedOverview = await overview();
      expect(mixedOverview['comparison']['sold_delta'], '27.50');
      expect(
        mixedOverview['profit_cost_unknown'],
        isFalse,
      ); // service, no stock cost
      expect(mixedOverview['profit']['total'], '21.50');
      expect(mixedOverview['income']['total'], '15.00');
      final tomorrow = DateTime.parse(
        '${day}T00:00:00Z',
      ).add(const Duration(days: 1)).toIso8601String().split('T').first;
      final next = await db.ledger.salesReport(
        local,
        currency: 'SAR',
        from: tomorrow,
      );
      expect(next['sales']['count'], 0);
      expect(next['sales']['returns']['count'], 0);
    },
  );
}
