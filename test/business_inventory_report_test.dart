import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

String _day(int offset) => DateTime.now()
    .add(Duration(days: offset))
    .toIso8601String()
    .split('T')
    .first;

void main() {
  test(
    'inventory report values recorded lots only and never shows a partial total',
    () async {
      final root = await Directory.systemTemp.createTemp('fyona-inventory-');
      addTearDown(() => root.delete(recursive: true));
      final workspace = DirectoryWorkspace(
        server: 'https://inventory-report.fixture.test/api/v1',
        accountId: _id(),
        organizationId: _id(),
      );
      DirectoryAccess scope() => DirectoryAccess(
        workspace: workspace,
        branchId: _id(),
        financialCutover: true,
        readable: {},
        writable: {},
      );
      final here = scope(), sibling = scope();
      final grant = BusinessLedgerAccess(
        here,
        BusinessLedgerAction.values.toSet(),
      );
      final siblingGrant = BusinessLedgerAccess(
        sibling,
        BusinessLedgerAction.values.toSet(),
      );
      final costHidden = BusinessLedgerAccess(here, {
        BusinessLedgerAction.readInventory,
      });
      final denied = BusinessLedgerAccess(here, {
        BusinessLedgerAction.manageProducts,
      });
      final keys = FixtureDirectoryKeys();
      Future<DirectoryDatabase> open() =>
          DirectoryDatabase.open(root: root, workspace: workspace, keys: keys);
      var db = await open();
      addTearDown(() => db.close());
      Future<String> make(
        BusinessLedgerAccess access,
        String name, {
        Object? cost,
        String costCurrency = 'SAR',
        int stock = 0,
        Object? minStock,
        String? expiry,
        bool isService = false,
      }) async =>
          (await db.ledger.createCommerceProduct(
                access,
                commandId: _id(),
                name: name,
                unit: 'box',
                price: 10,
                costPrice: cost,
                costCurrency: costCurrency,
                stock: stock,
                minStock: minStock,
                expiryDate: expiry,
                isService: isService,
              ))['id']
              as String;

      final low = await make(grant, 'Low', cost: '5', stock: 10, minStock: 12);
      final out = await make(grant, 'Out', cost: '2', stock: 0, minStock: 5);
      final exp = await make(
        grant,
        'Exp',
        cost: '1',
        stock: 50,
        expiry: _day(10),
      );
      final far = await make(
        grant,
        'Far',
        cost: '1',
        stock: 20,
        expiry: _day(100),
      );
      await make(grant, 'Svc', isService: true);
      await make(siblingGrant, 'Sibling', cost: '7', stock: 99);
      // Movements: Low ends at 11 boxes (moved 3, net 1), Exp at 51.5.
      await db.ledger.adjustCommerceStock(
        grant,
        productId: low,
        commandId: _id(),
        mode: BusinessStockAdjustment.add,
        amountMilli: 2000,
        expectedMilli: 10000,
      );
      await db.ledger.adjustCommerceStock(
        grant,
        productId: low,
        commandId: _id(),
        mode: BusinessStockAdjustment.remove,
        amountMilli: 1000,
        expectedMilli: 12000,
      );
      await db.ledger.adjustCommerceStock(
        grant,
        productId: exp,
        commandId: _id(),
        mode: BusinessStockAdjustment.add,
        amountMilli: 1500,
        expectedMilli: 50000,
      );

      Future<Map<String, dynamic>> report({
        String? from,
        String? to,
        int warnDays = 60,
        BusinessLedgerAccess? access,
      }) async {
        return db.ledger.inventoryReport(
          access ?? grant,
          currency: 'SAR',
          from: from,
          to: to,
          expiryWarnDays: warnDays,
        );
      }

      // ── Phase 1: single currency, recorded costs only ──
      final first = await report();
      expect(first['report'], 'inventory');
      expect(first['currency'], 'SAR');
      expect(first['branch_ids'], [here.branchId]);
      expect(first['local_valuation'], 'as_recorded');
      expect(first['stock_value_basis'], 'actual_lot_cost');
      expect(first['totals_complete'], isTrue);
      expect(first['products'], 4); // The service product is never counted.
      expect(first['categories'], isNull); // Never guessed on the device.
      expect(first['units'], 5);
      expect(first['warn_days'], 60);
      // 11×5 + 51.5×1 + 20×1 = 126.50 SAR, each lot as recorded.
      expect(first['stock_value'], '126.50');
      expect(first['uncosted_stock'], 0);
      expect(first['low_count'], 1);
      expect((first['low_stock'] as List).single, {
        'id': low,
        'name': 'Low',
        'unit': 'box',
        'stock': '11',
        'min_stock': '12',
      });
      expect(first['out_count'], 1);
      expect((first['out_of_stock'] as List).single, {
        'id': out,
        'name': 'Out',
        'unit': 'box',
        'stock': '0',
        'min_stock': '5',
      });
      expect(first['expiring_count'], 1);
      final expiring = (first['expiring_soon'] as List).single as Map;
      expect(expiring['id'], exp);
      expect(expiring['days'], 10);
      expect(expiring['expiry_date'], _day(10));
      expect(first['gaps'], isEmpty);
      expect(first['counting'], {'count': 0, 'items': []});
      expect(first['most_moved'], [
        {'name': 'Low', 'unit': 'box', 'moved': '3', 'net': '1'},
        {'name': 'Exp', 'unit': 'box', 'moved': '1.5', 'net': '1.5'},
      ]);
      // The period selects movements only; stock stays current.
      final windowed = await report(from: _day(1));
      expect(windowed['most_moved'], isEmpty);
      expect(windowed['stock_value'], '126.50');
      expect(windowed['products'], 4);
      expect((await report(warnDays: 100))['expiring_count'], 2);

      // ── Phase 2: a foreign-currency lot splits the value, never merges ──
      await make(grant, 'Usd', cost: '10', costCurrency: 'USD', stock: 3);
      final mixed = await report();
      expect(mixed['totals_complete'], isFalse);
      expect(mixed['stock_value'], isNull);
      expect(mixed['uncosted_stock'], 0);
      expect(mixed['stock_value_per_currency'], [
        {'currency': 'SAR', 'total': '126.50'},
        {'currency': 'USD', 'total': '30.00'},
      ]);
      expect(mixed['gaps'], [
        {'currency': 'USD', 'count': 1},
      ]);
      expect(await db.ledger.inventoryReportCurrencies(grant), {'SAR', 'USD'});
      expect(
        () => db.ledger.inventoryReportCurrencies(costHidden),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await make(siblingGrant, 'Large lot', cost: '700000', stock: 10000000000);
      final large = await db.ledger.inventoryReport(
        siblingGrant,
        currency: 'SAR',
      );
      expect(large['totals_complete'], isTrue);
      expect(large['stock_value'], '7000000000000693.00');

      // ── Phase 3: cost that was never recorded is unknown, not zero ──
      await make(grant, 'Free', stock: 7);
      final uncosted = await report();
      expect(uncosted['totals_complete'], isFalse);
      expect(uncosted['stock_value'], isNull);
      expect(uncosted['stock_value_per_currency'], isEmpty);
      expect(uncosted['uncosted_stock'], 1);
      expect(uncosted['products'], 6);
      expect(uncosted['units'], 7);

      // ── Phase 4: no cost permission hides value fields, not the report ──
      final hidden = await report(access: costHidden);
      expect(hidden['totals_complete'], isTrue);
      expect(hidden['stock_value'], isNull);
      expect(hidden['stock_value_per_currency'], isNull);
      expect(hidden['uncosted_stock'], 0);
      expect(hidden['products'], 6);
      expect(hidden['low_count'], 1);

      // A ledger without the inventory action cannot read the report.
      expect(
        () => db.ledger.inventoryReport(denied, currency: 'SAR'),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(
        () => db.ledger.inventoryReport(
          grant,
          currency: 'SAR',
          from: '2026-02-01',
          to: '2026-01-01',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () =>
            db.ledger.inventoryReport(grant, currency: 'SAR', from: '2026-1-1'),
        throwsA(isA<FormatException>()),
      );
      await db.close();
      db = await open();
      final reopened = await report();
      expect(reopened['stock_value'], isNull);
      expect(reopened['uncosted_stock'], 1);

      // 0.750123 base units received, then 0.123456 packs of two sold.
      // The branch projection wrote 0.750 - 0.247; the exact lots hold
      // 0.503211. Value the exact amount, not a tolerance or the rounded stock.
      final fractional = await make(siblingGrant, 'Fractional', minStock: '1');
      final unit =
          (await db.ledger.createCommerceUnit(
                siblingGrant,
                commandId: _id(),
                productId: fractional,
                name: 'Pack',
                factor: '2',
              ))['id']
              as String;
      final buyer = await db.create(
        DirectoryAccess(
          workspace: workspace,
          branchId: sibling.branchId,
          financialCutover: true,
          readable: {DirectoryPartyKind.customer},
          writable: {DirectoryPartyKind.customer},
        ),
        DirectoryPartyKind.customer,
        name: 'Fixture buyer',
      );
      final seller = await db.create(
        DirectoryAccess(
          workspace: workspace,
          branchId: sibling.branchId,
          financialCutover: true,
          readable: {DirectoryPartyKind.supplier},
          writable: {DirectoryPartyKind.supplier},
        ),
        DirectoryPartyKind.supplier,
        name: 'Fixture seller',
      );
      final documents = BusinessLedgerAccess(
        DirectoryAccess(
          workspace: workspace,
          branchId: sibling.branchId,
          financialCutover: true,
          readable: DirectoryPartyKind.values.toSet(),
          writable: DirectoryPartyKind.values.toSet(),
        ),
        BusinessLedgerAction.values.toSet(),
      );
      await db.ledger.issueCommerceDocument(
        documents,
        commandId: _id(),
        kind: BusinessInvoiceKind.purchase,
        currency: 'SAR',
        partyId: seller.id,
        lines: [
          CommerceIssueLine(
            description: 'Fractional',
            quantity: '0.750123',
            unitMinor: 100000,
            productId: fractional,
          ),
        ],
      );
      await db.ledger.issueCommerceDocument(
        documents,
        commandId: _id(),
        kind: BusinessInvoiceKind.sale,
        currency: 'SAR',
        partyId: buyer.id,
        lines: [
          CommerceIssueLine(
            description: 'Fractional',
            quantity: '0.123456',
            unitMinor: 300000,
            productId: fractional,
            unitId: unit,
          ),
        ],
      );
      final exact = await report(access: documents);
      expect(exact['totals_complete'], isTrue);
      expect(exact['low_stock'].single['stock'], '0.503211');
      expect(exact['most_moved'].first['moved'], '0.997035');
      expect(exact['most_moved'].first['net'], '0.503211');
    },
  );
}
