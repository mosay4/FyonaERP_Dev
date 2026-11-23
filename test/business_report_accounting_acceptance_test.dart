import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_money.dart';
import 'package:fyona_flutter/features/reports/data/business_report_rates.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();
String _day(DateTime at) => at.toIso8601String().split('T').first;

Map<String, dynamic> _publication(DateTime observed, String price) => {
  'global': {'USD': 1},
  'meta': {
    'global_source': 'store',
    'observations': {
      'YER_OLD': {
        'source': '2dec.net',
        'observed_at': observed.toUtc().toIso8601String(),
      },
      'YER_NEW': {
        'source': '2dec.net',
        'observed_at': observed.toUtc().toIso8601String(),
      },
    },
  },
  'yemen': {
    'source': 'store',
    'sanaa': {
      'USD': {'average': price},
    },
    'aden': {
      'USD': {'average': '1900'},
    },
  },
};

Future<Database> _fixtureSql(
  Directory root,
  DirectoryWorkspace workspace,
  FixtureDirectoryKeys keys,
) => databaseFactoryFfi.openDatabase(
  DirectoryDatabase.filePath(root, workspace),
  options: OpenDatabaseOptions(
    singleInstance: false,
    onConfigure: (db) =>
        db.execute('PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"'),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    '67,500 sale, 20,000 debt and actual lot costs survive rate change and reopen',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp(
        'fyona-report-acceptance-',
      );
      addTearDown(() => root.delete(recursive: true));
      final workspace = DirectoryWorkspace(
        server: 'https://accounting.fixture.test/api/v1',
        accountId: _id(),
        organizationId: _id(),
      );
      final scope = DirectoryAccess(
        workspace: workspace,
        branchId: _id(),
        financialCutover: true,
        readable: DirectoryPartyKind.values.toSet(),
        writable: DirectoryPartyKind.values.toSet(),
      );
      final access = BusinessLedgerAccess(
        scope,
        BusinessLedgerAction.values.toSet(),
      );
      final keys = FixtureDirectoryKeys();
      Future<DirectoryDatabase> open() =>
          DirectoryDatabase.open(root: root, workspace: workspace, keys: keys);
      var db = await open();
      addTearDown(() => db.close());
      final date = DateTime.now();
      final today = _day(date);
      final rates = BusinessReportRates(workspace.storageId);
      expect(
        await rates.refresh(
          () async =>
              _publication(date.subtract(const Duration(days: 3)), '500'),
        ),
        isTrue,
      );

      final customer = await db.create(
        scope,
        DirectoryPartyKind.customer,
        name: 'Buyer',
      );
      final supplier = await db.create(
        scope,
        DirectoryPartyKind.supplier,
        name: 'Supplier',
      );
      final yerBank = _id(), dollarBank = _id();
      for (final (id, ccy, opening) in [
        (yerBank, 'YER_OLD', 2500000),
        (dollarBank, 'USD', 2000),
      ]) {
        await db.ledger.createAccount(
          access,
          commandId: id,
          bankName: 'Cash $ccy',
          accountName: ccy,
          accountNumber: '01',
          currency: ccy,
          openingMinor: opening,
        );
      }
      final product =
          (await db.ledger.createCommerceProduct(
                access,
                commandId: _id(),
                name: 'Tea',
                unit: 'box',
                price: '25000',
                costPrice: '2000',
                costCurrency: 'YER_OLD',
                stock: '2',
              ))['id']
              as String;
      await db.ledger.issueCommerceDocument(
        access,
        kind: BusinessInvoiceKind.purchase,
        commandId: _id(),
        currency: 'USD',
        partyId: supplier.id,
        lines: [
          CommerceIssueLine(
            description: 'Tea',
            quantity: '3',
            unitMinor: 300,
            productId: product,
          ),
        ],
      );
      final sale = await db.ledger.issueCommerceDocument(
        access,
        kind: BusinessInvoiceKind.sale,
        commandId: _id(),
        currency: 'YER_OLD',
        partyId: customer.id,
        discountType: 'fixed',
        discountValue2: 500000,
        taxType: 'fixed',
        taxRate2: 250000,
        lines: [
          CommerceIssueLine(
            description: 'Tea',
            quantity: '3',
            unitMinor: 2500000,
            discountMinor: 500000,
            productId: product,
          ),
        ],
        payments: [
          CommerceIssuePayment(
            accountId: dollarBank,
            originalMinor: 9500,
            paymentCurrency: 'USD',
            rate: BusinessRate('USD', 'YER_OLD', '500'),
          ),
        ],
      );
      final saleId = sale['id'] as String;
      final saleDocument = (await db.ledger.commerceInvoice(
        access,
        BusinessInvoiceKind.sale,
        saleId,
      ))!;
      final item = saleDocument['items'].single['id'] as String;
      final income = _id(), expense = _id(), transfer = _id();
      await db.ledger.move(
        access,
        commandId: income,
        accountId: yerBank,
        amountMinor: 500000,
        withdraw: false,
      );
      await db.ledger.move(
        access,
        commandId: expense,
        accountId: yerBank,
        amountMinor: 250000,
        withdraw: true,
        expenseCategory: 'Transport',
      );
      await db.ledger.transfer(
        access,
        commandId: transfer,
        fromId: yerBank,
        toId: dollarBank,
        amountMinor: 80000,
        rate: BusinessRate('YER_OLD', 'USD', '0.0025'),
      );
      final newer = DateTime.now().add(const Duration(minutes: 5));
      expect(
        await rates.refresh(
          () async => _publication(newer, '1000'),
          now: newer,
        ),
        isTrue,
      );

      final fx = await rates.read();
      Future<Map<String, dynamic>> sales() => db.ledger.salesReport(
        access,
        currency: 'USD',
        from: today,
        to: today,
        fx: fx,
      );
      Future<Map<String, dynamic>> overview(String day) =>
          db.ledger.overviewReport(
            access,
            currency: 'USD',
            from: day,
            to: day,
            home: false,
            fx: fx,
          );
      final report = await sales();
      expect(sale['total_minor'], 6750000);
      expect(sale['balance_minor'], 2000000);
      expect(report['sales']['total'], '135.00');
      expect(report['sales']['gross']['total'], '150.00');
      expect(report['sales']['discounts']['total'], '20.00');
      expect(report['sales']['tax']['total'], '5.00');
      expect(report['sales']['net']['total'], '130.00');
      expect(report['sales']['paid'], '95.00');
      expect(report['sales']['remaining'], '20.00');
      expect(report['purchases']['total'], '9.00');
      expect(
        report['cost_of_sales']['total'],
        '11.00',
      ); // 2×2,000 YER at 500 plus $3
      expect(report['gross_profit']['total'], '119.00');
      expect(report['totals_complete'], isTrue);
      final overviewBefore = await overview(today);
      expect(overviewBefore['income']['total'], '10.00');
      expect(overviewBefore['expenses']['total'], '5.00');
      expect(overviewBefore['profit']['total'], '124.00');
      expect(overviewBefore['customer_debt']['total'], '20.00');
      expect(overviewBefore['inventory']['stock_value'], '6.00');
      final bank = await db.ledger.moneyReport(
        access,
        currency: 'USD',
        from: today,
        to: today,
        fx: fx,
      );
      expect(
        bank['inflow']['total'],
        '10.00',
      ); // not receipt, transfer or opening
      expect(bank['outflow']['total'], '5.00');
      expect(
        bank['transfers']['total'],
        '2.00',
      ); // frozen $2, not $1.60 or $0.80
      expect(bank['balances']['total'], '143.70'); // $117 + 26,700 YER at 1,000
      final debts = await db.ledger.debtReport(
        access,
        currency: 'USD',
        from: today,
        to: today,
        fx: fx,
      );
      expect(debts['customers']['total'], '20.00');
      expect(debts['suppliers']['total'], '9.00');
      expect(debts['collected']['total'], '95.00');
      final ops = await db.ledger.operations(
        access,
        allowedKinds: {'sale', 'income', 'expense', 'transfer'},
      );
      expect(
        ops.map((row) => row['kind']),
        unorderedEquals(['sale', 'income', 'expense', 'transfer']),
      );
      expect(
        ops.singleWhere((row) => row['kind'] == 'sale')['currency'],
        'YER_OLD',
      );

      final returnIds = <String>[];
      for (final (quantity, restock) in [
        ('1', true),
        ('1', true),
        ('0.75', false),
      ]) {
        final result = await db.ledger.confirmCommerceReturn(
          access,
          commandId: _id(),
          kind: BusinessInvoiceKind.sale,
          invoiceId: saleId,
          lines: [
            CommerceReturnLine(
              itemId: item,
              quantity: quantity,
              restock: restock,
            ),
          ],
          refundAccountId: dollarBank,
          refundRate: BusinessRate('USD', 'YER_OLD', '500'),
        );
        returnIds.add(result['id'] as String);
      }
      final returnDays = [
        for (final offset in [1, 2, 3])
          _day(DateTime(date.year, date.month, date.day + offset)),
      ];
      await db.close();
      final writer = await _fixtureSql(root, workspace, keys);
      try {
        // Test-only accounting dates distinguish three custom periods. The
        // amounts, command order, lots and receipts are from the real writer.
        for (final (index, id) in returnIds.indexed) {
          await writer.update(
            'business_commerce_returns',
            {'date': returnDays[index]},
            where: 'branch_id = ? AND id = ?',
            whereArgs: [scope.branchId, id],
          );
        }
      } finally {
        await writer.close();
      }
      db = await open();
      final after = await BusinessReportRates(workspace.storageId).read();
      final cashBeforeReads = await db.ledger.statement(access, dollarBank);
      for (final (index, day) in returnDays.indexed) {
        final detail = await overview(day);
        expect(detail['sales']['total'], '0.00');
        expect(
          detail['sales_returns']['total'],
          ['46.67', '46.67', '35.00'][index],
        );
        expect(
          detail['cost_of_sales']['total'],
          ['-3.00', '-4.00', '0.00'][index],
        );
        expect(
          detail['gross_profit']['total'],
          ['-43.67', '-42.67', '-35.00'][index],
        );
      }
      final reopened = await db.ledger.overviewReport(
        access,
        currency: 'USD',
        from: today,
        to: returnDays.last,
        home: false,
        fx: after,
      );
      expect(reopened['cost_of_sales']['total'], '4.00');
      expect(reopened['inventory']['stock_value'], '11.00');
      expect(reopened['customer_debt']['total'], '0.00');
      expect(await db.ledger.statement(access, dollarBank), cashBeforeReads);

      final unknown =
          (await db.ledger.createCommerceProduct(
                access,
                commandId: _id(),
                name: 'Uncosted',
                unit: 'box',
                price: '12',
                stock: '2',
              ))['id']
              as String;
      await db.ledger.issueCommerceDocument(
        access,
        kind: BusinessInvoiceKind.sale,
        commandId: _id(),
        currency: 'USD',
        partyId: customer.id,
        lines: [
          CommerceIssueLine(
            description: 'Uncosted',
            quantity: '1',
            unitMinor: 1200,
            productId: unknown,
          ),
        ],
      );
      final incomplete = await overview(today);
      expect(incomplete['sales']['total'], '147.00');
      expect(incomplete['inventory']['products'], 2);
      expect(incomplete['inventory']['stock_value'], isNull);
      expect(incomplete['profit_cost_unknown'], isTrue);
      expect(incomplete['profit']['total'], isNull);
      expect(incomplete['profit']['per_currency'], isEmpty);
    },
  );
}
