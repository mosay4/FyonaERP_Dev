import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/business_cash_test_checkpoint.dart';
import 'support/business_commerce_test_schema.dart';
import 'support/directory_test_keys.dart';

/// v14-only tables, dropped to emulate an older archive or schema.
const v14LedgerTables = [
  'business_employee_grants',
  'business_employee_payroll',
  'business_employee_debts',
  'business_employee_debt_legs',
  'business_employee_receipts',
  'business_cash_suspended',
  'business_branch_transfers',
  'business_branch_transfer_lines',
];

String _id() => const Uuid().v4();

void main() {
  test(
    'encrypted branch snapshot preserves the ledger without replay or cloned grants',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'fyona-business-backup-',
      );
      addTearDown(() => scratch.delete(recursive: true));
      final workspace = DirectoryWorkspace(
        server: 'https://backup.fixture.test/api/v1',
        accountId: _id(),
        organizationId: _id(),
      );
      DirectoryAccess selection(String branch, {DirectoryWorkspace? owner}) =>
          DirectoryAccess(
            workspace: owner ?? workspace,
            branchId: branch,
            readable: DirectoryPartyKind.values.toSet(),
            writable: DirectoryPartyKind.values.toSet(),
            financialCutover: true,
          );
      final scope = selection(_id());
      final sibling = selection(_id());
      final sid = _id();
      final access = BusinessLedgerAccess(
        scope,
        BusinessLedgerAction.values.toSet(),
        cashSessionId: sid,
      );
      final other = BusinessLedgerAccess(
        sibling,
        BusinessLedgerAction.values.toSet(),
      );
      final root = await scratch.createTemp('source-');
      final keys = FixtureDirectoryKeys();
      final db = await DirectoryDatabase.open(
        root: root,
        workspace: workspace,
        keys: keys,
      );
      addTearDown(db.close);
      final ledger = db.ledger;
      final teller = _id(), shared = _id(), siblingBank = _id();
      final opening = _id(),
          debtPayment = _id(),
          sale = _id(),
          pending = _id(),
          accepted = _id();
      Future<void> bank(
        BusinessLedger at,
        BusinessLedgerAccess grant,
        String id, {
        int balance = 10000,
      }) async => at.createAccount(
        grant,
        commandId: id,
        bankName: 'Fixture bank',
        accountName: 'Test account',
        accountNumber: '1',
        currency: 'SAR',
        openingMinor: balance,
      );
      await bank(ledger, access, teller);
      await bank(ledger, access, shared, balance: 5000);
      await bank(ledger, other, siblingBank, balance: 800);
      final checkpoint = cashTestCheckpoint(scope, shared, balance: 5000);
      await ledger.cashSync.provision(
        access,
        shared,
        grantVersion: 1,
        allowNegative: false,
      );
      await ledger.cashSync.bindReplica(
        access,
        sessionId: sid,
        checkpoint: checkpoint,
      );
      await ledger.move(
        access,
        commandId: accepted,
        accountId: shared,
        amountMinor: 150,
        withdraw: true,
      );
      await ledger.cashSync.decide(
        access,
        commandId: accepted,
        sequence: 1,
        decision: BusinessCashDecision.accepted,
      );
      await ledger.move(
        access,
        commandId: pending,
        accountId: shared,
        amountMinor: 250,
        withdraw: true,
      );

      final buyer = await db.create(
        scope,
        DirectoryPartyKind.customer,
        name: 'فاتورة تجريبية خاصة',
      );
      final otherBuyer = await db.create(
        sibling,
        DirectoryPartyKind.customer,
        name: 'Other branch only',
      );
      final party = DirectoryPartyReference(
        scope: scope,
        kind: buyer.kind,
        id: buyer.id,
      );
      await ledger.recordOpeningDebt(
        access,
        party,
        commandId: opening,
        amountMinor: 1000,
        currency: 'SAR',
      );
      await ledger.settle(
        access,
        party,
        commandId: debtPayment,
        accountId: teller,
        amountMinor: 300,
        currency: 'SAR',
      );
      final stock = await ledger.createCommerceProduct(
        access,
        commandId: _id(),
        name: 'Fixture stock',
        unit: 'Box',
        price: '2.50',
        costPrice: '1.10',
        stock: '5',
        barcode: '00100300',
      );
      final product = stock['id'] as String;
      Future<Map<String, Object?>> issue(BusinessLedger target) =>
          target.issueCommerceDocument(
            access,
            commandId: sale,
            kind: BusinessInvoiceKind.sale,
            currency: 'SAR',
            partyId: buyer.id,
            lines: [
              CommerceIssueLine(
                description: 'Unshared item',
                quantity: '2',
                unitMinor: 250,
                productId: product,
              ),
            ],
            payments: const [],
          );
      final invoice = await issue(ledger);
      final reconId = _id();
      final checked = await ledger.checkBankReconciliation(
        access,
        id: reconId,
        entries: [(accountId: teller, actualMinor: 10700, expectedMinor: null)],
        allowed: () => true,
      );
      final invoiceId = invoice['id'] as String;
      final invoiceRows =
          (await ledger.commerceInvoice(
                access,
                BusinessInvoiceKind.sale,
                invoiceId,
              ))!['items']
              as List;
      final soldItem = (invoiceRows.single as Map)['id'] as String;
      final returnCommand = _id();
      Future<Map<String, Object?>> undoOne(BusinessLedger target) =>
          target.confirmCommerceReturn(
            access,
            commandId: returnCommand,
            kind: BusinessInvoiceKind.sale,
            invoiceId: invoiceId,
            lines: [CommerceReturnLine(itemId: soldItem, quantity: '1')],
          );
      final returned = await undoOne(ledger);
      final expectedStock = await ledger.commerceInventoryProduct(
        access,
        product,
      );
      final expectedMovements = await ledger.commerceStockMovements(
        access,
        product,
      );
      final key = await ledger.trackShare(access, party);
      await ledger.saveShareStatus(access, key, {
        'status': 'accepted',
      }, 'fixture-hash');

      final file = File('${scratch.path}/ledger.fyona');
      final code = BusinessBackupCode.generate();
      final backupId = _id();
      await ledger.captureBackup(
        access,
        id: backupId,
        destination: file,
        code: code,
        allowed: () => true,
      );
      final bytes = await file.readAsBytes();
      expect(bytes, isNotEmpty);
      final header = String.fromCharCodes(bytes.take(16));
      expect(header, isNot(startsWith('SQLite format 3')));
      expect(String.fromCharCodes(bytes), isNot(contains('Unshared item')));

      final restoreRoot = await scratch.createTemp('target-');
      final newKeys = FixtureDirectoryKeys();
      Future<DirectoryDatabase> reopen() => DirectoryDatabase.open(
        root: restoreRoot,
        workspace: workspace,
        keys: newKeys,
      );
      var target = await reopen();
      addTearDown(() => target.close());
      await bank(target.ledger, other, siblingBank, balance: 800);
      await target.create(
        sibling,
        DirectoryPartyKind.customer,
        name: 'Preserve target sibling',
      );
      const problem = BusinessBackupProblem.invalidArchive;
      final invalid = isA<BusinessBackupRejected>().having(
        (e) => e.problem,
        'problem',
        problem,
      );
      Future<BusinessBackupRestore> restore({
        File? picked,
        BusinessBackupCode? recoveryCode,
        bool Function()? allowed,
      }) => target.ledger.restoreBackup(
        access,
        source: picked ?? file,
        code: recoveryCode ?? BusinessBackupCode.parse(code.text),
        allowed: allowed ?? () => true,
      );
      await expectLater(
        restore(recoveryCode: BusinessBackupCode.generate()),
        throwsA(invalid),
      );
      final damage = File('${scratch.path}/damaged.fyona');
      final modified = bytes.sublist(0, bytes.length - 12);
      await damage.writeAsBytes(modified, flush: true);
      await expectLater(restore(picked: damage), throwsA(invalid));
      await expectLater(
        target.ledger.restoreBackup(
          other,
          source: file,
          code: code,
          allowed: () => true,
        ),
        throwsA(invalid),
      );
      final unrelated = DirectoryWorkspace(
        server: workspace.server,
        accountId: _id(),
        organizationId: workspace.organizationId,
      );
      final wrongScope = selection(scope.branchId, owner: unrelated);
      final otherAccount = await DirectoryDatabase.open(
        root: restoreRoot,
        workspace: unrelated,
        keys: newKeys,
      );
      try {
        await expectLater(
          otherAccount.ledger.restoreBackup(
            BusinessLedgerAccess(wrongScope, {
              BusinessLedgerAction.manageBackup,
            }),
            source: file,
            code: code,
            allowed: () => true,
          ),
          throwsA(invalid),
        );
      } finally {
        await otherAccount.close();
      }
      expect(await target.ledger.accounts(access), isEmpty);
      var allowedChecks = 0;
      await expectLater(
        restore(allowed: () => allowedChecks++ < 2),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(await target.ledger.accounts(access), isEmpty);
      final raw = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(restoreRoot, workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) => db.execute(
            'PRAGMA key = "x\'${newKeys.memory[workspace.storageId]}\'"',
          ),
        ),
      );
      try {
        await raw.execute('''
        CREATE TRIGGER fixture_stop_restore BEFORE INSERT ON business_backup_recoveries
        BEGIN SELECT RAISE(ABORT, 'fixture failure at final receipt'); END
      ''');
        await expectLater(restore(), throwsA(invalid));
        expect(await target.ledger.accounts(access), isEmpty);
        expect(await target.search(scope, buyer.kind, ''), isEmpty);
        await raw.execute('DROP TRIGGER fixture_stop_restore');
      } finally {
        await raw.close();
      }
      expect(await restore(), (alreadyRestored: false, hasSharedHistory: true));
      await target.close();
      target = await reopen();
      expect(
        newKeys.memory[workspace.storageId],
        isNot(keys.memory[workspace.storageId]),
      );
      expect(
        await target.ledger.cashSync.replicaCheckpoint(access, sid),
        isNull,
      );
      expect(
        (await target.ledger.cashSync.pending(access)).single['command_id'],
        pending,
      );
      expect(
        await target.ledger.trackedShares(access, forTransport: true),
        isEmpty,
      );
      expect(
        (await target.ledger.trackedShares(
          access,
          party: party,
        )).single['party_key'],
        key,
      );
      await expectLater(
        target.ledger.cashSync.bindReplica(
          access,
          sessionId: sid,
          checkpoint: checkpoint,
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await expectLater(
        target.ledger.trackShare(access, party),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(await issue(target.ledger), invoice);
      expect(
        await target.ledger.bankReconciliationDetail(access, reconId),
        checked,
      );
      expect(await undoOne(target.ledger), returned);
      expect(
        await target.ledger.commerceInventoryProduct(access, product),
        expectedStock,
      );
      expect(
        await target.ledger.commerceStockMovements(access, product),
        expectedMovements,
      );
      expect(
        (await target.ledger.accounts(access)).map((r) => r['balance_minor']),
        unorderedEquals([10300, 4600]),
      );
      expect(
        (await target.ledger.statement(
          access,
          shared,
        )).map((r) => r['command_id']),
        [pending, accepted, shared],
      );
      expect((await target.ledger.accounts(other)).single['id'], siblingBank);
      expect(
        (await target.search(sibling, buyer.kind, '')).single.name,
        'Preserve target sibling',
      );
      expect(
        (await target.search(scope, buyer.kind, '')).map((r) => r.id),
        isNot(contains(otherBuyer.id)),
      );

      await target.ledger.move(
        access,
        commandId: _id(),
        accountId: teller,
        amountMinor: 100,
        withdraw: true,
      );
      expect(await restore(), (alreadyRestored: true, hasSharedHistory: true));
      expect(
        (await target.ledger.accounts(access)).map((r) => r['balance_minor']),
        unorderedEquals([10200, 4600]),
      );
      final anotherFile = File('${scratch.path}/new-id.fyona');
      await ledger.captureBackup(
        access,
        id: _id(),
        destination: anotherFile,
        code: code,
        allowed: () => true,
      );
      await expectLater(
        restore(picked: anotherFile),
        throwsA(
          isA<BusinessBackupRejected>().having(
            (e) => e.problem,
            'problem',
            BusinessBackupProblem.notEmpty,
          ),
        ),
      );
    },
  );

  test(
    'v9/v11 databases upgrade in place and v10/v11 encrypted archives restore',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'fyona-backup-upgrade-',
      );
      addTearDown(() => scratch.delete(recursive: true));
      final source = await scratch.createTemp('source-');
      final workspace = DirectoryWorkspace(
        server: 'https://upgrade.fixture.test/api/v1',
        accountId: _id(),
        organizationId: _id(),
      );
      final scope = DirectoryAccess(
        workspace: workspace,
        branchId: _id(),
        readable: {},
        writable: {},
        financialCutover: true,
      );
      final access = BusinessLedgerAccess(
        scope,
        BusinessLedgerAction.values.toSet(),
        cashSessionId: _id(),
      );
      final keys = FixtureDirectoryKeys();
      Future<DirectoryDatabase> open() => DirectoryDatabase.open(
        root: source,
        workspace: workspace,
        keys: keys,
      );
      var db = await open();
      addTearDown(() => db.close());
      final account = _id(), private = _id(), pending = _id();
      for (final id in [account, private]) {
        await db.ledger.createAccount(
          access,
          commandId: id,
          currency: 'SAR',
          bankName: 'Cash',
          accountName: 'Fixture',
          accountNumber: '1',
          openingMinor: 5000,
        );
      }
      final cashPoint = cashTestCheckpoint(scope, account, balance: 5000);
      await db.ledger.cashSync.provision(
        access,
        account,
        grantVersion: 1,
        allowNegative: false,
      );
      await db.ledger.cashSync.bindReplica(
        access,
        sessionId: access.cashSessionId!,
        checkpoint: cashPoint,
      );
      await db.ledger.move(
        access,
        commandId: pending,
        accountId: account,
        amountMinor: 250,
        withdraw: true,
      );
      await db.close();
      Future<Database> raw(String path, String key) =>
          databaseFactoryFfi.openDatabase(
            path,
            options: OpenDatabaseOptions(
              singleInstance: false,
              onConfigure: (sql) async {
                await sql.execute('PRAGMA key = "x\'$key\'"');
              },
            ),
          );
      final old = await raw(
        DirectoryDatabase.filePath(source, workspace),
        keys.memory[workspace.storageId]!,
      );
      try {
        await old.transaction((txn) async {
          await txn.execute('DROP TABLE business_cash_link_preparations');
          for (final table in inventoryCatalogueTables) {
            await txn.execute('DROP TABLE $table');
          }
          await txn.execute('DROP TABLE business_backup_recoveries');
          await txn.execute('DROP TABLE business_cash_v3_replicas');
          await txn.execute('DROP TABLE business_cash_equalizations');
          await txn.execute('DROP TABLE business_reconciliations');
          for (final table in v14LedgerTables) {
            await txn.execute('DROP TABLE $table');
          }
          await txn.execute('PRAGMA user_version = 9');
        });
      } finally {
        await old.close();
      }
      db = await open();
      expect(
        await db.ledger.cashSync.replicaCheckpoint(
          access,
          access.cashSessionId!,
        ),
        cashPoint,
      );
      expect(
        (await db.ledger.cashSync.pending(access)).single['command_id'],
        pending,
      );
      expect(await db.ledger.bankReconciliationArchive(access), isEmpty);
      final recon = _id();
      await db.ledger.checkBankReconciliation(
        access,
        id: recon,
        entries: [(accountId: private, actualMinor: 5000, expectedMinor: 5000)],
        allowed: () => true,
      );
      await db.close();
      final v11 = await raw(
        DirectoryDatabase.filePath(source, workspace),
        keys.memory[workspace.storageId]!,
      );
      try {
        await v11.transaction((txn) async {
          await txn.execute('DROP TABLE business_cash_link_preparations');
          await txn.execute('DROP TABLE business_cash_v3_replicas');
          await txn.execute('DROP TABLE business_cash_equalizations');
          for (final table in inventoryCatalogueTables) {
            await txn.execute('DROP TABLE $table');
          }
          for (final table in v14LedgerTables) {
            await txn.execute('DROP TABLE $table');
          }
          await txn.execute('PRAGMA user_version = 11');
        });
      } finally {
        await v11.close();
      }
      db = await open();
      expect(
        (await db.ledger.bankReconciliationArchive(access)).single['id'],
        recon,
      );

      await db.close();
      final v12 = await raw(
        DirectoryDatabase.filePath(source, workspace),
        keys.memory[workspace.storageId]!,
      );
      try {
        await v12.transaction((txn) async {
          await txn.execute('DROP TABLE business_cash_link_preparations');
          await txn.execute('DROP TABLE business_cash_v3_replicas');
          await txn.execute('DROP TABLE business_cash_equalizations');
          for (final table in v14LedgerTables) {
            await txn.execute('DROP TABLE $table');
          }
          await txn.execute('PRAGMA user_version = 12');
        });
      } finally {
        await v12.close();
      }
      db = await open();
      expect(await db.ledger.cashSync.supportsEqualization(access), isFalse);
      expect(
        (await db.ledger.bankReconciliationArchive(access)).single['id'],
        recon,
      );

      await db.close();
      final v14 = await raw(
        DirectoryDatabase.filePath(source, workspace),
        keys.memory[workspace.storageId]!,
      );
      try {
        await v14.transaction((txn) async {
          await txn.execute('DROP TABLE business_cash_link_preparations');
          await txn.execute('PRAGMA user_version = 14');
        });
      } finally {
        await v14.close();
      }
      db = await open();
      expect(
        (await db.ledger.cashSync.pending(access)).single['command_id'],
        pending,
      );
      expect(
        (await db.ledger.bankReconciliationArchive(access)).single['id'],
        recon,
      );

      for (final schema in [10, 11, 12, 13, 14]) {
        final file = File('${scratch.path}/made-by-v$schema.fyonabiz');
        final code = BusinessBackupCode.generate();
        await db.ledger.captureBackup(
          access,
          id: _id(),
          destination: file,
          code: code,
          allowed: () => true,
        );
        final rawKey = base64Url
            .decode(base64Url.normalize(code.text))
            .map((value) => value.toRadixString(16).padLeft(2, '0'))
            .join();
        final archive = await raw(file.path, rawKey);
        try {
          await archive.transaction((txn) async {
            const header = 'fyona_business_backup_manifest';
            final manifest =
                jsonDecode(
                      (await txn.query(header)).single['payload'] as String,
                    )
                    as Map;
            manifest['schema'] = schema;
            for (final table in [
              if (schema < 14) ...v14LedgerTables,
              if (schema < 13) 'business_cash_equalizations',
              if (schema < 12) ...inventoryCatalogueTables,
              if (schema == 10) 'business_reconciliations',
            ]) {
              (manifest['counts'] as Map).remove(table);
              await txn.execute('DROP TABLE $table');
            }
            await txn.update(header, {'payload': jsonEncode(manifest)});
          });
        } finally {
          await archive.close();
        }
        final copy = await DirectoryDatabase.open(
          root: await scratch.createTemp('recovery-'),
          workspace: workspace,
          keys: FixtureDirectoryKeys(),
        );
        try {
          expect(
            await copy.ledger.restoreBackup(
              access,
              source: file,
              code: code,
              allowed: () => true,
            ),
            (alreadyRestored: false, hasSharedHistory: true),
          );
          expect(
            await copy.ledger.cashSync.replicaCheckpoint(
              access,
              access.cashSessionId!,
            ),
            isNull,
          );
          final rows = await copy.ledger.accounts(access);
          expect(
            {for (final row in rows) row['id']: row['balance_minor']},
            {account: 4750, private: 5000},
          );
          expect(
            (await copy.ledger.cashSync.pending(access)).single['command_id'],
            pending,
          );
          expect(
            (await copy.ledger.bankReconciliationArchive(
              access,
            )).map((row) => row['id']),
            [if (schema >= 11) recon],
          );
          expect(await copy.ledger.hasInventoryCatalogue(access), isFalse);
        } finally {
          await copy.close();
        }
      }
    },
  );
}
