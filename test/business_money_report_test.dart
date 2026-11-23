import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_money.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

void main() {
  test(
    'money reads the posted branch legs, not invoices, openings or partial totals',
    () async {
      final root = await Directory.systemTemp.createTemp('fyona-money-report-');
      addTearDown(() => root.delete(recursive: true));
      final workspace = DirectoryWorkspace(
        server: 'https://money-report.fixture.test/api/v1',
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
      final other = BusinessLedgerAccess(
        sibling,
        BusinessLedgerAction.values.toSet(),
      );
      final keys = FixtureDirectoryKeys();
      Future<DirectoryDatabase> open() =>
          DirectoryDatabase.open(root: root, workspace: workspace, keys: keys);
      var db = await open();
      addTearDown(() => db.close());
      final sar = _id(), usd = _id(), otherBank = _id();
      Future<void> account(
        BusinessLedgerAccess access,
        String id,
        String currency,
        int opening,
      ) async {
        await db.ledger.createAccount(
          access,
          commandId: id,
          bankName: 'Fixture bank',
          accountName: 'Account $currency',
          accountNumber: '1',
          currency: currency,
          openingMinor: opening,
        );
      }

      await account(grant, sar, 'SAR', 12000);
      await account(grant, usd, 'USD', 5000);
      await account(other, otherBank, 'SAR', 990000);
      final inflow = _id();
      await db.ledger.move(
        grant,
        commandId: inflow,
        accountId: sar,
        amountMinor: 2000,
        withdraw: false,
      );
      await db.ledger.move(
        grant,
        commandId: _id(),
        accountId: sar,
        amountMinor: 500,
        withdraw: true,
        expenseCategory: 'Transport',
      );
      await db.ledger.move(
        grant,
        commandId: _id(),
        accountId: usd,
        amountMinor: 250,
        withdraw: true,
        expenseCategory: 'Materials',
      );
      await db.ledger.issueCommerceDocument(
        grant,
        commandId: _id(),
        kind: BusinessInvoiceKind.sale,
        currency: 'SAR',
        lines: const [
          CommerceIssueLine(
            description: 'Delivery',
            quantity: '1',
            unitMinor: 425,
            isService: true,
          ),
        ],
        payments: [
          CommerceIssuePayment(
            accountId: sar,
            paymentCurrency: 'SAR',
            originalMinor: 425,
          ),
        ],
      );
      await db.ledger.transfer(
        grant,
        commandId: _id(),
        fromId: sar,
        toId: usd,
        amountMinor: 400,
        rate: BusinessRate('SAR', 'USD', '0.25'),
      );
      final day = DateTime.now().toUtc().toIso8601String().split('T').first;
      final recon = _id();
      await db.ledger.checkBankReconciliation(
        grant,
        id: recon,
        entries: [
          (accountId: sar, actualMinor: 13000, expectedMinor: null),
          (accountId: usd, actualMinor: 5500, expectedMinor: null),
        ],
        allowed: () => true,
      );
      await db.ledger.approveBankReconciliation(
        grant,
        id: recon,
        entries: [
          (accountId: sar, actualMinor: 13000, expectedMinor: 13525),
          (accountId: usd, actualMinor: 5500, expectedMinor: 4850),
        ],
        allowed: () => true,
      );
      await db.close();
      db = await open();
      Future<Map<String, dynamic>> report({
        String? from,
        String? to,
        String? id,
      }) => db.ledger.moneyReport(
        grant,
        currency: 'USD',
        from: from,
        to: to,
        accountId: id,
      );
      final result = await report(to: day);
      expect(result['branch_ids'], [here.branchId]);
      expect(result['inflow']['total'], isNull);
      expect(result['inflow']['per_currency'], [
        {'currency': 'SAR', 'total': '20.00'},
      ]);
      expect(result['outflow']['total'], isNull);
      expect(result['outflow']['per_currency'], [
        {'currency': 'SAR', 'total': '5.00'},
        {'currency': 'USD', 'total': '2.50'},
      ]);
      expect(result['transfers']['total'], '1.00');
      expect(result['balances']['per_currency'], [
        {'currency': 'SAR', 'total': '130.00'},
        {'currency': 'USD', 'total': '55.00'},
      ]);
      expect(result['settlements']['total'], isNull);
      expect(result['settlements']['per_currency'], [
        {'currency': 'SAR', 'total': '-5.25'},
        {'currency': 'USD', 'total': '6.50'},
      ]);
      expect(result['settlements']['count'], 1);
      expect(result['settlements']['items'].single['id'], recon);
      final scoped = await report(id: sar);
      expect(scoped['expense_scoped']['total'], '5.00');
      expect(scoped['expense_scoped']['currency'], 'SAR');
      expect(
        scoped['expense_scoped']['categories'].single['category'],
        'Transport',
      );
      expect(
        scoped['settlements']['items']
            .single['settlements']
            .single['account_id'],
        sar,
      );
      final before = await report(to: '2020-03-02');
      expect(before['inflow']['total'], '0.00');
      expect(before['settlements']['items'], isEmpty);
      expect(before['balances'], result['balances']);
      await expectLater(
        report(id: otherBank),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(await db.ledger.moneyReportCurrencies(grant), {'SAR', 'USD'});

      // Recreate a bank leg whose legacy classification has not been proven;
      // a separately archived Expense still has its own exact original amount.
      await db.close();
      final sqlite = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(root, workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) => db.execute(
            'PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"',
          ),
        ),
      );
      try {
        final stamp = DateTime.now().toUtc();
        await sqlite.transaction((txn) async {
          await txn.update(
            'business_local_bank_legs',
            {'legacy': 1},
            where: 'branch_id = ? AND command_id = ?',
            whereArgs: [here.branchId, inflow],
          );
          await txn.insert('business_cutover_archives', {
            'branch_id': here.branchId,
            'snapshot_id': _id(),
            'digest': '0' * 64,
            'imported_us': stamp.microsecondsSinceEpoch,
          });
          await txn.insert('business_cutover_rows', {
            'branch_id': here.branchId,
            'table_name': 'expenses',
            'id': _id(),
            'payload': jsonEncode({
              'category': 'Rent',
              'amount': '18.00',
              'currency': 'SAR',
              'is_deleted': false,
              'expense_date': stamp.toIso8601String(),
              'bank_account_id': sar,
            }),
          });
        });
      } finally {
        await sqlite.close();
      }
      db = await open();
      final legacy = await report(id: sar);
      expect(legacy['legacy_flow_unclassified'], isTrue);
      expect(legacy['inflow']['total'], isNull);
      expect(legacy['inflow']['per_currency'], isEmpty);
      expect(legacy['expense_scoped']['total'], '23.00');
      expect(
        legacy['outflow']['per_currency'],
        result['outflow']['per_currency'],
      );
    },
  );
}
