import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_ledger/business_money.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/business_commerce_test_schema.dart';
import 'support/directory_test_keys.dart';

const _server = 'https://cutover.example.test/api/v1';
const _tables = [
  'branches',
  'customers',
  'suppliers',
  'bank_accounts',
  'bank_transactions',
  'expenses',
  'debt_groups',
  'invoices',
  'invoice_items',
  'invoice_item_changes',
  'payments',
  'customer_receivables',
  'supplier_payables',
  'invoice_returns',
  'invoice_return_items',
  'purchase_returns',
  'purchase_return_items',
  'products',
  'product_units',
  'product_barcodes',
  'product_prices',
  'branch_stock',
  'inventory_lots',
  'inventory_lot_consumptions',
  'inventory_movements',
];

String _id() => const Uuid().v4();
String _digest(List<int> bytes) => sha256.convert(bytes).toString();

DirectoryAccess _scope(DirectoryWorkspace workspace, String branch) =>
    DirectoryAccess(
      workspace: workspace,
      branchId: branch,
      readable: DirectoryPartyKind.values.toSet(),
      writable: DirectoryPartyKind.values.toSet(),
    );

Future<(List<int>, String, Map<String, dynamic>)> _fixtureExport(
  String path, {
  String stem = 'snapshot',
}) async {
  if (!RegExp(
    r'^/tmp/opencode/fyona-cutover-[a-zA-Z0-9]+/handoff$',
  ).hasMatch(path)) {
    fail('A disposable Business cutover export is required');
  }
  final payload = await File('$path/$stem.json').readAsBytes();
  final digest = (await File('$path/$stem.sha256').readAsString()).trim();
  return (
    payload,
    digest,
    jsonDecode(utf8.decode(payload)) as Map<String, dynamic>,
  );
}

DirectoryWorkspace _fixtureWorkspace(Map<String, dynamic> body) =>
    DirectoryWorkspace(
      server: _server,
      accountId: body['account_id'] as String,
      organizationId: body['organization_id'] as String,
    );

void main() {
  test(
    'late parity failure rolls back every row and the import receipt',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'business-cutover-archive-',
      );
      addTearDown(() => root.delete(recursive: true));
      final keys = FixtureDirectoryKeys();
      final workspace = DirectoryWorkspace(
        server: _server,
        organizationId: _id(),
        accountId: _id(),
      );
      final access = _scope(workspace, _id());
      final other = _scope(workspace, _id());
      final account = _id();
      final invoice = _id();
      final product = _id();
      final snapshot = _id();
      final controls = <String, List<List<Object?>>>{
        'accounts': [
          [account, 'SAR', -417],
        ],
        'invoices': [
          [invoice, 'SAR', 3025, 500, 2525],
        ],
        'stock': [
          [product, 4000, 100000],
        ],
      };
      final doc = <String, Object?>{
        'version': 1,
        'snapshot_id': snapshot,
        'server': _server,
        'organization_id': workspace.organizationId,
        'account_id': workspace.accountId,
        'branch_id': access.branchId,
        'tables': {
          for (final table in _tables) table: <Map<String, Object?>>[],
          'branches': [
            {
              'id': access.branchId,
              'organization_id': workspace.organizationId,
            },
          ],
          'bank_accounts': [
            {
              'id': account,
              'branch_id': access.branchId,
              'currency': 'SAR',
              'balance': '-4.17',
            },
          ],
          'invoices': [
            {
              'id': invoice,
              'branch_id': access.branchId,
              'currency': 'SAR',
              'total': '30.25',
              'paid_amount': '5.00',
              'balance': '25.25',
            },
          ],
          'branch_stock': [
            {
              'id': _id(),
              'branch_id': access.branchId,
              'product_id': product,
              'quantity': '4.000',
              'avg_cost': '10.0000',
            },
          ],
        },
        'controls': controls,
      };
      var db = await DirectoryDatabase.open(
        root: root,
        keys: keys,
        workspace: workspace,
      );
      addTearDown(() => db.close());
      const kind = DirectoryPartyKind.customer;
      final onDevice = await db.create(
        access,
        kind,
        name: 'Device data already present',
      );

      Future<BusinessCutoverReceipt> send(
        DirectoryAccess a,
        Map<String, Object?> body,
      ) {
        final bytes = utf8.encode(jsonEncode(body));
        return db.importCutoverFixture(
          a,
          payload: bytes,
          expectedDigest: _digest(bytes),
        );
      }

      final invalid = {
        ...doc,
        'controls': {
          ...controls,
          // A difference of 0.001 in inventory cannot be silently rounded away.
          'stock': [
            [product, 3999, 100000],
          ],
        },
      };
      await expectLater(
        send(access, invalid),
        throwsA(isA<BusinessCutoverImportRejected>()),
      );
      expect(await db.cutoverFixtureReceipt(access), isNull);
      await expectLater(
        send(other, doc),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      final badAccount = _scope(
        DirectoryWorkspace(
          server: _server,
          accountId: _id(),
          organizationId: workspace.organizationId,
        ),
        access.branchId,
      );
      await expectLater(
        send(badAccount, doc),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await expectLater(
        db.importCutoverFixture(
          access,
          payload: utf8.encode(jsonEncode(doc)),
          expectedDigest: '0' * 64,
        ),
        throwsA(isA<BusinessCutoverImportRejected>()),
      );

      final committed = await send(access, doc);
      expect(committed.snapshotId, snapshot);
      expect(await send(access, doc), committed);
      await expectLater(
        send(access, {...doc, 'snapshot_id': _id()}),
        throwsA(isA<BusinessCutoverImportRejected>()),
      );
      expect(await db.cutoverFixtureReceipt(other), isNull);
      await db.close();
      db = await DirectoryDatabase.open(
        root: root,
        keys: keys,
        workspace: workspace,
      );
      expect(await db.cutoverFixtureReceipt(access), committed);
      expect(await db.cutoverFixtureControls(access), controls);
      expect((await db.find(access, kind, onDevice.id)).name, onDevice.name);
      expect(access.financialCutover, isFalse);
      final ledgerAccess = BusinessLedgerAccess(access, {
        BusinessLedgerAction.readBank,
      });
      expect(await db.ledger.accounts(ledgerAccess), isEmpty);
      await expectLater(
        db.projectFixtureBanking(access, committed),
        throwsA(isA<BusinessCutoverImportRejected>()), // V1 lacked the policy.
      );
    },
  );

  final handoff = Platform.environment['FYONA_TEST_CUTOVER_EXPORT_DIR'];
  test(
    'verified catalogue projects, counts and restores without fetching old references',
    () async {
      final folder = handoff!;
      final (payload, digest, doc) = await _fixtureExport(
        folder,
        stem: 'catalogue',
      );
      final workspace = _fixtureWorkspace(doc);
      final access = DirectoryAccess(
        workspace: workspace,
        branchId: doc['branch_id'] as String,
        readable: DirectoryPartyKind.values.toSet(),
        writable: DirectoryPartyKind.values.toSet(),
        financialCutover: true,
      );
      final grant = BusinessLedgerAccess(
        access,
        BusinessLedgerAction.values.toSet(),
      );
      final sibling = BusinessLedgerAccess(
        _scope(workspace, _id()),
        BusinessLedgerAction.values.toSet(),
      );
      final reader = BusinessLedgerAccess(access, {
        BusinessLedgerAction.readInventory,
      });
      final root = await Directory.systemTemp.createTemp(
        'business-cutover-catalogue-',
      );
      addTearDown(() => root.delete(recursive: true));
      final keys = FixtureDirectoryKeys();
      Future<DirectoryDatabase> open() =>
          DirectoryDatabase.open(root: root, keys: keys, workspace: workspace);
      var db = await open();
      addTearDown(() => db.close());

      final tables = doc['tables'] as Map<String, dynamic>;
      final srcCat =
          (tables['product_categories'] as List).single as Map<String, dynamic>;
      final products = (tables['products'] as List)
          .cast<Map<String, dynamic>>();
      final srcProduct = products.singleWhere((p) => p['device_image'] != null);
      final id = srcProduct['id'] as String;
      final extra =
          products.singleWhere((p) => p['device_image'] == null)['id']
              as String;
      final category = srcCat['id'] as String;
      final productPhoto = srcProduct['device_image'] as String;
      final categoryPhoto = srcCat['device_image'] as String;

      // The archive receipt itself is withheld, not just the later
      // operational projection, if authorization or references are missing.
      final malformed = [
        {...tables, 'product_categories': []},
        {
          ...tables,
          'product_categories': [
            {...srcCat, 'organization_id': _id()},
          ],
        },
        {
          ...tables,
          'product_categories': [
            srcCat,
            {...srcCat, 'id': _id()},
          ],
        },
        {
          ...tables,
          'product_categories': [
            {...srcCat, 'device_image_sha256': '0' * 64},
          ],
        },
        {
          ...tables,
          'product_categories': [
            {...srcCat, 'image': null},
          ],
        },
        {
          ...tables,
          'products': [
            for (final row in products) {...row, 'branch_id': _id()},
          ],
        },
      ];
      for (final altered in malformed) {
        final bytes = utf8.encode(jsonEncode({...doc, 'tables': altered}));
        await expectLater(
          db.importCutoverFixture(
            access,
            payload: bytes,
            expectedDigest: _digest(bytes),
          ),
          throwsA(isA<BusinessCutoverImportRejected>()),
        );
        expect(await db.cutoverFixtureReceipt(access), isNull);
      }
      Future<BusinessCutoverReceipt> receive() => db.importCutoverFixture(
        access,
        payload: payload,
        expectedDigest: digest,
      );
      final receipt = await receive();
      expect(await receive(), receipt);

      final sql = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(root, workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (sql) => sql.execute(
            'PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"',
          ),
        ),
      );
      try {
        await sql.execute('''
          CREATE TRIGGER drop_catalogue_photo AFTER INSERT ON business_commerce_categories
          BEGIN
            UPDATE business_commerce_categories SET image = NULL
            WHERE branch_id = NEW.branch_id AND id = NEW.id;
          END
        ''');
        await expectLater(
          db.projectFixtureCommerce(access, receipt),
          throwsA(isA<BusinessCutoverImportRejected>()),
        );
        expect(await db.ledger.commerceProducts(grant), isEmpty);
        expect(await db.ledger.accounts(grant), isEmpty);
        expect(await db.ledger.hasInventoryCatalogue(grant), isFalse);
        expect(await db.cutoverFixtureReceipt(access), receipt);
        await sql.execute('DROP TRIGGER drop_catalogue_photo');
      } finally {
        await sql.close();
      }
      expect(await db.projectFixtureCommerce(access, receipt), receipt);
      await db.close();
      db = await open();
      expect(await db.cutoverFixtureReceipt(access), receipt);
      expect(await db.projectFixtureCommerce(access, receipt), receipt);
      final catalogue = (await db.ledger.commerceCategories(reader)).single;
      expect(catalogue, containsPair('id', category));
      expect(catalogue, containsPair('image', categoryPhoto));
      expect(catalogue, containsPair('products_count', 1));
      expect(await db.ledger.commerceCategories(sibling), isEmpty);
      await expectLater(
        db.ledger.commerceProducts(sibling, categoryId: category),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      final otherAccount = BusinessLedgerAccess(
        _scope(
          DirectoryWorkspace(
            server: _server,
            accountId: _id(),
            organizationId: workspace.organizationId,
          ),
          access.branchId,
        ),
        {BusinessLedgerAction.readInventory},
      );
      expect(
        () => db.ledger.commerceCategories(otherAccount),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      final row = (await db.ledger.commerceProducts(
        reader,
        categoryId: category,
      )).single;
      expect(row['image'], productPhoto);
      expect(row['category_name'], srcCat['name']);
      expect(row, isNot(contains('cost_price')));
      final unbundled = (await db.ledger.commerceProducts(
        reader,
        uncategorized: true,
      )).single;
      expect(unbundled['id'], extra);
      expect(
        unbundled['image'],
        isNull,
      ); // A URL alone is not an offline photo.
      expect(await db.ledger.warehouseExpiry(reader), (
        enabled: true,
        warnDays: 17,
      ));
      final report = await db.ledger.inventoryReport(
        reader,
        currency: 'SAR',
        today: DateTime.utc(2030, 1, 1),
        expiryWarnDays: 1,
      );
      expect(report['categories'], 1);
      expect(report['warn_days'], 17);
      expect(report['expiring_count'], 1);
      expect(
        (await db.ledger.inventoryReport(
          sibling,
          currency: 'SAR',
        ))['categories'],
        isNull,
      );

      final countId = _id();
      Future<Map<String, dynamic>> start([String? chosen]) =>
          db.ledger.inventoryReconciliationStart(
            grant,
            id: countId,
            scope: 'category',
            categoryId: chosen ?? category,
            allowed: () => true,
          );
      final started = await start();
      expect(await start(), started);
      await expectLater(start(_id()), throwsA(isA<BusinessLedgerError>()));
      expect((started['scope_json'] as Map)['category_name'], srcCat['name']);
      final line = (started['lines'] as List).single as Map;
      expect(line['product_id'], id);
      expect(line['counted_qty'], isNull);
      expect(line, isNot(contains('image')));
      expect(
        await db.ledger.inventoryReconciliationPhoto(
          grant,
          id: countId,
          productId: id,
        ),
        productPhoto,
      );
      expect(
        await db.ledger.inventoryReconciliationPhoto(
          grant,
          id: countId,
          productId: extra,
        ),
        isNull,
      );
      expect(
        await db.ledger.inventoryReconciliationPhoto(
          sibling,
          id: countId,
          productId: id,
        ),
        isNull,
      );
      await db.ledger.inventoryReconciliationSave(
        grant,
        id: countId,
        counts: [(productId: id, qtyMilli: 3750, unitId: null, parts: null)],
        allowed: () => true,
      );

      final classify = _id();
      Future<void> attach(
        String cmd, {
        bool Function()? allowed,
        List<String>? ids,
      }) => db.ledger.classifyCommerceProducts(
        grant,
        commandId: cmd,
        productIds: ids ?? [extra],
        categoryId: category,
        expectedCategory: null,
        requireExpected: true,
        allowed: allowed,
      );
      var checks = 0;
      await expectLater(
        attach(classify, allowed: () => checks++ == 0),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(
        (await db.ledger.commerceProducts(
          grant,
          uncategorized: true,
        )).single['id'],
        extra,
      );
      await expectLater(
        attach(classify, ids: [extra, _id()]),
        throwsA(isA<BusinessLedgerError>()),
      );
      await attach(classify);
      Future<Map<String, dynamic>> check() =>
          db.ledger.inventoryReconciliationCheck(
            grant,
            id: countId,
            allowed: () => true,
          );
      await expectLater(
        check(),
        throwsA(isA<BusinessInventoryCategoryChanged>()),
      );
      Future<void> detach() => db.ledger.classifyCommerceProducts(
        grant,
        commandId: _id(),
        productIds: [extra],
        categoryId: null,
        expectedCategory: category,
        requireExpected: true,
      );
      await detach();
      await attach(classify); // The lost response must not replay an old edit.
      expect((await check())['status'], 'checked');
      Future<Map<String, dynamic>> approve({
        bool Function()? allowed,
        int newQty = 3750,
      }) => db.ledger.inventoryReconciliationApprove(
        grant,
        id: countId,
        settlements: [(productId: id, expectedMilli: 4000, newMilli: newQty)],
        allowed: allowed ?? () => true,
      );
      await attach(
        _id(),
      ); // A new member added after the check invalidates approval.
      await expectLater(
        approve(),
        throwsA(isA<BusinessInventoryCategoryChanged>()),
      );
      await detach();
      var approvalChecks = 0;
      await expectLater(
        approve(allowed: () => approvalChecks++ == 0),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(
        (await db.ledger.commerceInventoryProduct(grant, id))!['stock'],
        4,
      );
      final approved = await approve();
      expect(approved['status'], 'approved');
      expect(
        (await db.ledger.commerceInventoryProduct(grant, id))!['stock'],
        3.75,
      );
      expect((await db.ledger.accounts(grant)).single['balance_minor'], 7500);

      // Both current catalogue and scoped count survive backup recovery in
      // a different encrypted database. Authorization is provided by the test.
      await Directory('${root.path}/restored').create();
      final destination = File('${root.path}/catalogue.fyonabiz');
      final code = BusinessBackupCode.generate(), backupId = _id();
      await db.ledger.captureBackup(
        grant,
        id: backupId,
        destination: destination,
        code: code,
        allowed: () => true,
      );
      final restoreKeys = FixtureDirectoryKeys();
      Future<DirectoryDatabase> openRestored() => DirectoryDatabase.open(
        root: Directory('${root.path}/restored'),
        workspace: workspace,
        keys: restoreKeys,
      );
      var restored = await openRestored();
      try {
        Future<BusinessBackupRestore> restore() =>
            restored.ledger.restoreBackup(
              grant,
              source: destination,
              code: code,
              expectedId: backupId,
              allowed: () => true,
            );
        expect((await restore()).alreadyRestored, isFalse);
        await restored.close();
        restored = await openRestored();
        expect((await restore()).alreadyRestored, isTrue);
        expect(
          (await restored.ledger.commerceCategories(reader)).single,
          catalogue,
        );
        expect(await restored.ledger.warehouseExpiry(grant), (
          enabled: true,
          warnDays: 17,
        ));
        expect(
          await restored.ledger.inventoryReconciliationDetail(grant, countId),
          approved,
        );
        expect(
          await restored.ledger.inventoryReconciliationPhoto(
            grant,
            id: countId,
            productId: id,
          ),
          productPhoto,
        );
        expect(
          (await restored.ledger.commerceInventoryProduct(grant, id))!['stock'],
          3.75,
        );
        expect(await restored.ledger.commerceCategories(sibling), isEmpty);
        expect(await restored.cutoverFixtureReceipt(access), receipt);
      } finally {
        await restored.close();
      }
      await db.close();
      db = await open();
      expect(
        await approve(),
        approved,
      ); // Lost response after commit, then restart.
      await expectLater(
        approve(newQty: 3500),
        throwsA(isA<BusinessLedgerError>()),
      );
      final saved = (await db.cutoverFixtureReceipt(access))!;
      await File('$folder/catalogue-receipt.json').writeAsString(
        jsonEncode({'snapshot_id': saved.snapshotId, 'digest': saved.digest}),
      );
    },
    skip: handoff == null,
  );
  test(
    'frozen PostgreSQL commerce and opening balances become operational without replay',
    () async {
      final fixturePath = handoff!;
      final (payload, digest, doc) = await _fixtureExport(fixturePath);
      final root = await Directory.systemTemp.createTemp(
        'business-cutover-pg-',
      );
      addTearDown(() => root.delete(recursive: true));
      final keys = FixtureDirectoryKeys();
      final workspace = _fixtureWorkspace(doc);
      final access = _scope(workspace, doc['branch_id'] as String);
      final banking = BusinessLedgerAccess(
        access,
        BusinessLedgerAction.values.toSet(),
      );
      final existingRoot = await Directory.systemTemp.createTemp(
        'cutover-existing-',
      );
      addTearDown(() => existingRoot.delete(recursive: true));
      final existing = await DirectoryDatabase.open(
        root: existingRoot,
        keys: FixtureDirectoryKeys(),
        workspace: workspace,
      );
      try {
        final directoryId =
            (doc['tables']['customers'] as List).single['id'] as String;
        const kind = DirectoryPartyKind.customer;
        await existing.create(
          access,
          kind,
          id: directoryId,
          name: 'Existing device card',
        );
        final saved = await existing.importCutoverFixture(
          access,
          payload: payload,
          expectedDigest: digest,
        );
        await expectLater(
          existing.projectFixtureCommerce(access, saved),
          throwsA(isA<BusinessCutoverImportRejected>()),
        );
        expect(
          (await existing.find(access, kind, directoryId)).name,
          'Existing device card',
        );
        expect(await existing.ledger.accounts(banking), isEmpty);
      } finally {
        await existing.close();
      }
      var db = await DirectoryDatabase.open(
        root: root,
        keys: keys,
        workspace: workspace,
      );
      addTearDown(() => db.close());
      final imported = await db.importCutoverFixture(
        access,
        payload: payload,
        expectedDigest: digest,
      );
      expect(await db.ledger.accounts(banking), isEmpty);
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
        // Fail the final parity check, not an early validation. Nothing from
        // the operational projection (including the saved policy) may survive.
        await sql.execute('''
        CREATE TRIGGER drift_leg AFTER INSERT ON business_local_bank_legs
        BEGIN
          UPDATE business_local_bank_legs SET balance_minor = balance_minor + 1
          WHERE sequence = NEW.sequence;
        END
      ''');
        await expectLater(
          db.projectFixtureCommerce(access, imported),
          throwsA(isA<BusinessCutoverImportRejected>()),
        );
        expect(await db.ledger.accounts(banking), isEmpty);
        expect(await db.ledger.savedAllowNegative(banking), isNull);
        expect(await sql.query('business_bank_projection_receipts'), isEmpty);
        expect(await db.cutoverFixtureReceipt(access), imported);
        await sql.execute('DROP TRIGGER drift_leg');
        await sql.execute('''
          CREATE TRIGGER drift_opening_payment AFTER INSERT ON business_imported_opening_payments
          BEGIN
            UPDATE business_imported_opening_payments SET applied_minor = applied_minor + 1
            WHERE branch_id = NEW.branch_id AND id = NEW.id;
          END
        ''');
        await expectLater(
          db.projectFixtureCommerce(access, imported),
          throwsA(isA<BusinessCutoverImportRejected>()),
        );
        expect(await db.ledger.accounts(banking), isEmpty);
        expect(
          await db.search(access, DirectoryPartyKind.customer, ''),
          isEmpty,
        );
        expect(await sql.query('business_bank_projection_receipts'), isEmpty);
        expect(
          await sql.query('business_opening_projection_receipts'),
          isEmpty,
        );
        expect(await sql.query('business_imported_opening_payments'), isEmpty);
        await sql.execute('DROP TRIGGER drift_opening_payment');
        await sql.execute('''
          CREATE TRIGGER drift_lot AFTER INSERT ON business_commerce_lots
          BEGIN
            UPDATE business_commerce_lots SET remaining_micro = remaining_micro - 1000
            WHERE branch_id = NEW.branch_id AND id = NEW.id;
          END
        ''');
        await expectLater(
          db.projectFixtureCommerce(access, imported),
          throwsA(isA<BusinessCutoverImportRejected>()),
        );
        for (final table in [
          'business_commerce_projection_receipts',
          'business_commerce_lots',
          'business_commerce_stock',
          'business_commerce_invoices',
          'business_commerce_invoice_payments',
          'business_opening_projection_receipts',
          'business_bank_projection_receipts',
          'business_local_bank_legs',
        ]) {
          expect(await sql.query(table), isEmpty, reason: table);
        }
        expect(await db.ledger.accounts(banking), isEmpty);
        expect(await db.cutoverFixtureReceipt(access), imported);
        await sql.execute('DROP TRIGGER drift_lot');
      } finally {
        await sql.close();
      }
      final projected = await db.projectFixtureCommerce(access, imported);
      expect(projected, imported);
      await db.close();
      db = await DirectoryDatabase.open(
        root: root,
        keys: keys,
        workspace: workspace,
      );
      expect(await db.cutoverFixtureReceipt(access), imported);
      final controls = await db.cutoverFixtureControls(access);
      expect(controls, doc['controls']);
      expect(controls['accounts']!.single.last, 7500);
      expect(controls['stock']!.single[1], 4000);
      final id = controls['accounts']!.single.first as String;
      expect((await db.ledger.accounts(banking)).single['balance_minor'], 7500);
      final source = (doc['tables']['bank_transactions'] as List)
          .cast<Map<String, dynamic>>();
      final history = await db.ledger.bankHistory(banking, [
        id,
      ], includeBalances: true);
      expect(
        history.map((row) => row['id']),
        unorderedEquals(source.map((row) => row['id'])),
      );
      for (final row in history) {
        final original = source.singleWhere(
          (entry) => entry['id'] == row['id'],
        );
        for (final key in [
          'tx_type',
          'amount',
          'currency',
          'description',
          'reference',
          'running_balance',
        ]) {
          expect(row[key], original[key], reason: key);
        }
      }
      List<Map<String, dynamic>> archived(String name) =>
          (doc['tables'][name] as List).cast<Map<String, dynamic>>();
      Map<String, dynamic> oneFor(String table, String invoice) =>
          archived(table).singleWhere((row) => row['invoice_id'] == invoice);
      const saleKind = BusinessInvoiceKind.sale;
      const purchaseKind = BusinessInvoiceKind.purchase;
      final saleId = archived('invoice_returns').single['invoice_id'] as String;
      final saleDoc = (await db.ledger.commerceInvoice(
        banking,
        saleKind,
        saleId,
      ))!;
      expect(saleDoc['invoice_type'], 'sale');
      expect(saleDoc['branch_name'], 'Freeze branch');
      expect(saleDoc['customer_name'], 'Buyer A');
      expect(saleDoc['total'], 40);
      expect(saleDoc['paid_amount'], 20);
      expect(saleDoc['balance'], 0);
      final saleLine = (saleDoc['items'] as List).single as Map;
      final sourceSaleLine = oneFor('invoice_items', saleId);
      expect(saleLine['id'], sourceSaleLine['id']);
      expect(saleLine['original_unit_price'], 5);
      expect(saleLine['price_currency'], 'USD');
      expect(saleLine['exchange_rate_used'], '4.00000000');
      expect(saleLine['cost_total'], 20);
      expect(saleLine['profit'], 20);
      expect(saleLine['returned_quantity'], 1);
      expect(saleLine['returnable_quantity'], 1);
      final salePayment = (saleDoc['payments'] as List).single as Map;
      expect(salePayment['id'], oneFor('payments', saleId)['id']);
      expect(salePayment['bank_account_id'], id);
      expect(salePayment['original_amount'], 40);
      expect(history.any((row) => row['id'] == salePayment['id']), isFalse);
      final saleReturn = (await db.ledger.commerceReturns(
        banking,
        saleKind,
        saleId,
      )).single;
      expect(saleReturn['id'], archived('invoice_returns').single['id']);
      expect(saleReturn['kind'], 'sale_return');
      expect(saleReturn['total'], 20);
      final receiptLine = (saleReturn['items'] as List).single as Map;
      expect(receiptLine['id'], archived('invoice_return_items').single['id']);
      expect(receiptLine['invoice_item_id'], saleLine['id']);

      final lot = archived('inventory_lots').single;
      final productId = lot['product_id'] as String;
      final purchaseId = lot['purchase_invoice_id'] as String;
      final purchaseDoc = (await db.ledger.commerceInvoice(
        banking,
        purchaseKind,
        purchaseId,
      ))!;
      expect(purchaseDoc['total'], 50);
      expect(purchaseDoc['supplier_name'], 'Vendor A');
      expect(
        (purchaseDoc['items'] as List).single['id'],
        lot['invoice_item_id'],
      );
      final serviceId =
          archived('purchase_returns').single['invoice_id'] as String;
      final serviceReturn = (await db.ledger.commerceReturns(
        banking,
        purchaseKind,
        serviceId,
      )).single;
      expect(serviceReturn['id'], archived('purchase_returns').single['id']);
      expect(serviceReturn['kind'], 'purchase_return');
      expect(serviceReturn['total'], 17);
      final serviceDoc = (await db.ledger.commerceInvoice(
        banking,
        purchaseKind,
        serviceId,
      ))!;
      expect(serviceDoc['balance'], 0);
      expect(
        serviceDoc['payable']['id'],
        oneFor('supplier_payables', serviceId)['id'],
      );
      expect(serviceDoc['payable']['status'], 'paid');
      final product = (await db.ledger.commerceInventoryProduct(
        banking,
        productId,
      ))!;
      expect(product['stock_id'], archived('branch_stock').single['id']);
      expect(product['stock'], 4);
      expect(product['avg_cost'], 10);
      expect((product['units'] as List).single['id'], saleLine['unit_id']);
      expect(
        (product['barcodes'] as List).single['barcode'],
        'FIXTURE-BASE-001',
      );
      expect((product['prices'] as List).single['buy_price'], 2.5);
      expect((product['lots'] as List).single, containsPair('id', lot['id']));
      expect((product['lots'] as List).single, containsPair('remaining', 4));
      expect((product['lots'] as List).single, containsPair('received', 5));
      expect(
        (product['lots'] as List).single,
        containsPair('expiry_date', '2030-06-01'),
      );
      final moves = await db.ledger.commerceStockMovements(banking, productId);
      expect(
        moves.map((row) => row['id']),
        unorderedEquals(
          archived('inventory_movements').map((row) => row['id']),
        ),
      );
      expect(
        moves
            .where((row) => row['reference_id'] == saleReturn['id'])
            .single['quantity'],
        1,
      );
      final employee = BusinessLedgerAccess(access, {
        BusinessLedgerAction.readSaleInvoice,
        BusinessLedgerAction.readInventory,
      });
      final visibleSale = (await db.ledger.commerceInvoice(
        employee,
        saleKind,
        saleId,
      ))!;
      expect((visibleSale['items'] as List).single, isNot(contains('profit')));
      expect(
        (visibleSale['items'] as List).single,
        isNot(contains('cost_total')),
      );
      final visibleProduct = (await db.ledger.commerceInventoryProduct(
        employee,
        productId,
      ))!;
      expect(visibleProduct, isNot(contains('avg_cost')));
      expect(
        (visibleProduct['lots'] as List).single,
        isNot(contains('unit_cost')),
      );
      expect(
        (visibleProduct['prices'] as List).single,
        isNot(contains('buy_price')),
      );
      expect(
        () => db.ledger.commerceInvoice(employee, purchaseKind, purchaseId),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(
        () => db.ledger.commerceReturns(employee, saleKind, saleId),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(
        await db.ledger.commerceInvoice(banking, purchaseKind, saleId),
        isNull,
      );
      final opening = archived('invoices').singleWhere(
        (row) =>
            row['invoice_type'] == 'sale' &&
            (row['invoice_number'] as String).startsWith('OPEN-'),
      );
      final invoice = opening['id'] as String;
      final contact = DirectoryPartyReference(
        scope: access,
        kind: DirectoryPartyKind.customer,
        id: opening['customer_id'] as String,
      );
      final sibling = _scope(workspace, _id());
      expect(await db.search(sibling, contact.kind, ''), isEmpty);
      await expectLater(
        db.projectFixtureOpeningLedger(sibling, imported),
        throwsA(isA<BusinessCutoverImportRejected>()),
      );
      expect((await db.find(access, contact.kind, contact.id)).name, 'Buyer A');
      final folder = (await db.groups(access, contact.kind, contact.id)).single;
      expect(folder['id'], opening['debt_group_id']);
      expect(folder['count'], 1);
      expect(folder['kind'], 'auto');
      expect(folder['period'], '2026-11');
      final debts = await db.ledger.debts(banking, contact);
      expect(debts.map((row) => row['id']), unorderedEquals([invoice, saleId]));
      final openingDebt = debts.singleWhere((row) => row['id'] == invoice);
      expect(openingDebt['remaining_minor'], 2525);
      expect(
        debts.singleWhere((row) => row['id'] == saleId)['remaining_minor'],
        0,
      );
      final supplier = archived('suppliers').single;
      final supplierOpening =
          archived('invoices').singleWhere(
                (row) =>
                    row['invoice_type'] == 'purchase' &&
                    (row['invoice_number'] as String).startsWith('OPEN-'),
              )['id']
              as String;
      final supplierDebts = await db.ledger.debts(
        banking,
        DirectoryPartyReference(
          scope: access,
          kind: DirectoryPartyKind.supplier,
          id: supplier['id'] as String,
        ),
      );
      expect(
        supplierDebts.map((row) => row['id']),
        unorderedEquals([supplierOpening, purchaseId, serviceId]),
      );
      expect(
        supplierDebts.singleWhere(
          (row) => row['id'] == supplierOpening,
        )['remaining_minor'],
        750,
      );
      final target = DirectoryDebtInvoiceReference(party: contact, id: invoice);
      expect(
        await db.ledger.commerceInvoice(banking, saleKind, invoice),
        isNull,
      );
      final siblingAccess = BusinessLedgerAccess(
        sibling,
        BusinessLedgerAction.values.toSet(),
      );
      expect(
        await db.ledger.commerceInvoice(siblingAccess, saleKind, saleId),
        isNull,
      );
      expect(
        await db.ledger.commerceInventoryProduct(siblingAccess, productId),
        isNull,
      );
      final before = await db.ledger.openingDebtOperation(banking, target);
      expect(before['remaining'], opening['balance']);
      expect(before['revision'], 1);
      final item = (before['items'] as List).single as Map;
      final itemId = oneFor('invoice_items', invoice)['id'] as String;
      expect(item['id'], itemId);
      expect(item['qty'], '1.25');
      expect(item['price'], '24.20');
      final change = (before['item_changes'] as List).single as Map;
      expect(change['id'], oneFor('invoice_item_changes', invoice)['id']);
      expect(change['item_id'], itemId);
      expect(change['old_quantity'], '1');
      expect(change['new_quantity'], '1.25');
      final legacy = (before['payments'] as List).single as Map;
      final payment = oneFor('payments', invoice);
      expect(legacy['id'], payment['id']);
      expect(legacy['amount'], '5.00');
      expect(legacy['date'], payment['payment_date']);
      expect(history.any((row) => row['id'] == payment['id']), isFalse);
      expect(await db.ledger.cashSync.pending(banking), isEmpty);
      await expectLater(
        db.ledger.move(
          banking,
          commandId: payment['id'] as String,
          accountId: id,
          amountMinor: 500,
          withdraw: false,
        ),
        throwsA(
          isA<BusinessLedgerError>().having(
            (error) => error.problem,
            'problem',
            BusinessLedgerProblem.commandConflict,
          ),
        ),
      );
      await expectLater(
        db.ledger.editBankAccount(
          banking,
          accountId: id,
          commandId: _id(),
          currency: 'USD',
        ),
        throwsA(
          isA<BusinessLedgerError>().having(
            (error) => error.problem,
            'problem',
            BusinessLedgerProblem.currencyHasPayments,
          ),
        ),
      );

      expect(access.financialCutover, isFalse); // Neither receipt is a grant.
      await expectLater(
        db.projectFixtureCommerce(access, (
          snapshotId: imported.snapshotId,
          digest: '0' * 64,
        )),
        throwsA(isA<BusinessCutoverImportRejected>()),
      );
      await expectLater(
        db.ledger.move(
          banking,
          commandId: _id(),
          accountId: id,
          amountMinor: 7501,
          withdraw: true,
        ),
        throwsA(
          isA<BusinessLedgerError>().having(
            (error) => error.problem,
            'problem',
            BusinessLedgerProblem.insufficientBalance,
          ),
        ),
      );
      // Continue from the imported balance, with no opening-balance replay.
      await db.ledger.move(
        banking,
        commandId: _id(),
        accountId: id,
        amountMinor: 100,
        withdraw: true,
      );
      expect(await db.projectFixtureCommerce(access, imported), imported);
      expect((await db.ledger.accounts(banking)).single['balance_minor'], 7400);
      expect(
        await db.ledger.bankHistory(banking, [id], includeBalances: false),
        hasLength(history.length + 1),
      );
      final edit = await db.ledger.editOpeningDebt(
        banking,
        target,
        commandId: _id(),
        itemId: itemId,
        revision: 1,
        line: BusinessOpeningDebtLine('1.5', '10.25'),
      );
      expect(edit['revision'], 2);
      final command = _id();
      await db.ledger.settle(
        banking,
        contact,
        commandId: command,
        accountId: id,
        amountMinor: 125,
        currency: 'SAR',
        groupId: folder['id'] as String,
        invoiceId: invoice,
      );
      final document = await db.ledger.openingInvoice(banking, target);
      expect((document['items'] as List).single['id'], itemId);
      expect((document['payments'] as List).map((row) => row['id']), [
        payment['id'],
        command,
      ]);
      expect(document['total'], '15.38');
      expect(document['paid_amount'], '6.25');
      expect(document['balance'], '9.13');
      final cancel = _id();
      for (var i = 0; i < 2; i++) {
        await db.ledger.deleteOpeningDebt(
          banking,
          target,
          commandId: cancel,
          revision: 3,
        );
      }
      // 75.00 - 1.00 + 1.25 - (5.00 + 1.25). Earlier sale and return
      // movements stay posted; neither payment is counted twice.
      expect((await db.ledger.accounts(banking)).single['balance_minor'], 6900);
      expect((await db.ledger.debts(banking, contact)).single['id'], saleId);
      expect(await db.projectFixtureCommerce(access, imported), imported);
      expect((await db.ledger.debts(banking, contact)).single['id'], saleId);
      expect(
        await db.ledger.commerceInvoice(banking, saleKind, saleId),
        saleDoc,
      );

      final remove = _id();
      Future<Map<String, Object?>> deduct({int expected = 5250}) =>
          db.ledger.adjustCommerceStock(
            banking,
            productId: productId,
            commandId: remove,
            mode: BusinessStockAdjustment.remove,
            amountMilli: 2000,
            expectedMilli: expected,
            reason: 'damaged',
          );
      expect(
        () => db.ledger.adjustCommerceStock(
          employee,
          productId: productId,
          commandId: _id(),
          mode: BusinessStockAdjustment.add,
          amountMilli: 1250,
          expectedMilli: 4000,
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      await expectLater(
        db.ledger.adjustCommerceStock(
          siblingAccess,
          productId: productId,
          commandId: _id(),
          mode: BusinessStockAdjustment.set,
          amountMilli: 0,
          expectedMilli: 4000,
        ),
        throwsA(
          isA<BusinessLedgerError>().having(
            (error) => error.problem,
            'problem',
            BusinessLedgerProblem.invalidProduct,
          ),
        ),
      );
      await db.ledger.adjustCommerceStock(
        banking,
        productId: productId,
        commandId: _id(),
        mode: BusinessStockAdjustment.add,
        amountMilli: 1250,
        expectedMilli: 4000,
        reason: 'increase',
      );
      await expectLater(
        deduct(expected: 4000),
        throwsA(
          isA<BusinessLedgerError>().having(
            (error) => error.problem,
            'problem',
            BusinessLedgerProblem.stockChanged,
          ),
        ),
      );
      final beforeRemove = await db.ledger.commerceInventoryProduct(
        banking,
        productId,
      );
      expect(beforeRemove!['stock'], 5.25);
      final guard = await databaseFactoryFfi.openDatabase(
        DirectoryDatabase.filePath(root, workspace),
        options: OpenDatabaseOptions(
          singleInstance: false,
          onConfigure: (db) => db.execute(
            'PRAGMA key = "x\'${keys.memory[workspace.storageId]}\'"',
          ),
        ),
      );
      try {
        final carriedIds = await guard.query(
          'business_local_debts',
          columns: ['id', 'legacy_receivable_id'],
          where: 'branch_id = ?',
          whereArgs: [access.branchId],
        );
        expect(
          {
            for (final row in carriedIds)
              row['id']: row['legacy_receivable_id'],
          },
          {
            invoice: oneFor('customer_receivables', invoice)['id'],
            supplierOpening: oneFor('supplier_payables', supplierOpening)['id'],
          },
        );
        await guard.execute('''
          CREATE TRIGGER fail_stock_audit BEFORE INSERT ON business_commerce_stock_movements
          WHEN NEW.movement_type = 'adjust_remove'
          BEGIN SELECT RAISE(ABORT, 'fixture stock write interrupted'); END
        ''');
        await expectLater(deduct(), throwsA(isA<DatabaseException>()));
        expect(
          await db.ledger.commerceInventoryProduct(banking, productId),
          beforeRemove,
        );
        expect(
          (await db.ledger.commerceStockMovements(banking, productId)).length,
          moves.length + 1,
        );
        await guard.execute('DROP TRIGGER fail_stock_audit');
      } finally {
        await guard.close();
      }
      final adjustment = await deduct();
      expect(adjustment['new_milli'], 3250);
      await db.close();
      db = await DirectoryDatabase.open(
        root: root,
        keys: keys,
        workspace: workspace,
      );
      expect(await deduct(), adjustment);
      final afterRemove = (await db.ledger.commerceInventoryProduct(
        banking,
        productId,
      ))!;
      expect(afterRemove['stock_id'], product['stock_id']);
      expect(afterRemove['stock'], 3.25);
      expect(afterRemove['avg_cost'], 10);
      final quantities = {
        for (final row
            in (afterRemove['lots'] as List).cast<Map<String, dynamic>>())
          row['source']: row['remaining'],
      };
      expect(quantities, {'purchase': 2, 'adjustment': 1.25});
      final afterMoves = await db.ledger.commerceStockMovements(
        banking,
        productId,
      );
      final audit = afterMoves.singleWhere((row) => row['id'] == remove);
      expect(afterMoves, hasLength(moves.length + 2));
      expect(audit['old_quantity'], 5.25);
      expect(audit['new_quantity'], 3.25);
      expect(audit['difference'], -2);
      expect(audit['reason'], 'damaged');
      expect((await db.ledger.accounts(banking)).single['balance_minor'], 6900);
      expect(await db.projectFixtureCommerce(access, imported), imported);
      expect(
        await db.ledger.commerceInventoryProduct(banking, productId),
        afterRemove,
      );

      // Post the remaining unit against the original invoice, item, lot and
      // cash IDs. Imported payments and the first return must not be replayed
      // or replaced by this local operation.
      final returnCommand = _id();
      Future<Map<String, Object?>> returnRemainder() =>
          db.ledger.confirmCommerceReturn(
            banking,
            commandId: returnCommand,
            kind: saleKind,
            invoiceId: saleId,
            refundAccountId: id,
            lines: [
              CommerceReturnLine(
                itemId: sourceSaleLine['id'] as String,
                quantity: '1',
              ),
            ],
          );
      final returned = await returnRemainder();
      expect(returned['total_minor'], 2000);
      expect(returned['refunded_minor'], 2000);
      await db.close();
      db = await DirectoryDatabase.open(
        root: root,
        keys: keys,
        workspace: workspace,
      );
      expect(await returnRemainder(), returned);
      expect(await db.projectFixtureCommerce(access, imported), imported);
      expect((await db.ledger.accounts(banking)).single['balance_minor'], 4900);
      final restocked = (await db.ledger.commerceInventoryProduct(
        banking,
        productId,
      ))!;
      expect(restocked['stock'], 4.25);
      expect(
        (restocked['lots'] as List).singleWhere(
          (row) => row['id'] == lot['id'],
        )['remaining'],
        3,
      );
      final saleAfter = (await db.ledger.commerceInvoice(
        banking,
        saleKind,
        saleId,
      ))!;
      expect(saleAfter['paid_amount'], 0);
      expect((saleAfter['payments'] as List).single['id'], salePayment['id']);
      expect((saleAfter['items'] as List).single['returnable_quantity'], 0);
      final returnsAfter = await db.ledger.commerceReturns(
        banking,
        saleKind,
        saleId,
      );
      expect(
        returnsAfter.map((row) => row['id']),
        unorderedEquals([saleReturn['id'], returned['id']]),
      );

      await File('$fixturePath/device-receipt.json').writeAsString(
        jsonEncode({
          'snapshot_id': imported.snapshotId,
          'digest': imported.digest,
        }),
        flush: true,
      );
    },
    skip: handoff == null,
  );

  test(
    'a return referring to an item of another invoice rolls back the whole commerce slice',
    () async {
      final (_, _, doc) = await _fixtureExport(handoff!);
      final workspace = _fixtureWorkspace(doc);
      final access = _scope(workspace, doc['branch_id'] as String);
      final sale =
          (doc['tables']['invoice_returns'] as List).single['invoice_id']
              as String;
      final invoiceItems = (doc['tables']['invoice_items'] as List).cast<Map>();
      // Known item and product, but on the purchase, not the returned sale.
      final wrong = invoiceItems.singleWhere(
        (row) => row['invoice_id'] != sale && row['product_id'] != null,
      );
      (doc['tables']['invoice_return_items'] as List)
              .single['invoice_item_id'] =
          wrong['id'];
      final bytes = utf8.encode(jsonEncode(doc));
      final root = await Directory.systemTemp.createTemp(
        'commerce-invalid-dependency-',
      );
      addTearDown(() => root.delete(recursive: true));
      final db = await DirectoryDatabase.open(
        root: root,
        keys: FixtureDirectoryKeys(),
        workspace: workspace,
      );
      addTearDown(db.close);
      final receipt = await db.importCutoverFixture(
        access,
        payload: bytes,
        expectedDigest: _digest(bytes),
      );
      await expectLater(
        db.projectFixtureCommerce(access, receipt),
        throwsA(isA<BusinessCutoverImportRejected>()),
      );
      expect(await db.cutoverFixtureReceipt(access), receipt);
      final ledgerAccess = BusinessLedgerAccess(
        access,
        BusinessLedgerAction.values.toSet(),
      );
      expect(await db.ledger.accounts(ledgerAccess), isEmpty);
      expect(
        await db.ledger.commerceInvoice(
          ledgerAccess,
          BusinessInvoiceKind.sale,
          sale,
        ),
        isNull,
      );
      expect(await db.search(access, DirectoryPartyKind.customer, ''), isEmpty);
    },
    skip: handoff == null,
  );

  test(
    'v6 opening-only branch upgrades without reimporting or merging frozen balances',
    () async {
      final (bytes, digest, doc) = await _fixtureExport(handoff!);
      final workspace = _fixtureWorkspace(doc);
      final access = _scope(workspace, doc['branch_id'] as String);
      final ledgerAccess = BusinessLedgerAccess(
        access,
        BusinessLedgerAction.values.toSet(),
      );
      final root = await Directory.systemTemp.createTemp(
        'commerce-upgrade-v6-',
      );
      addTearDown(() => root.delete(recursive: true));
      final keys = FixtureDirectoryKeys();
      Future<DirectoryDatabase> open() =>
          DirectoryDatabase.open(root: root, keys: keys, workspace: workspace);
      var db = await open();
      addTearDown(() => db.close());
      final receipt = await db.importCutoverFixture(
        access,
        payload: bytes,
        expectedDigest: digest,
      );
      await db.projectFixtureOpeningLedger(access, receipt);
      final account =
          (await db.ledger.accounts(ledgerAccess)).single['id'] as String;
      await db.ledger.move(
        ledgerAccess,
        commandId: _id(),
        accountId: account,
        amountMinor: 100,
        withdraw: true,
      );
      await db.close();
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
        await sql.transaction((txn) async {
          await removeCommerceFixtureSchema(txn);
          await txn.execute('PRAGMA user_version = 6');
        });
      } finally {
        await sql.close();
      }
      db = await open();
      expect(await db.projectFixtureOpeningLedger(access, receipt), receipt);
      await expectLater(
        db.projectFixtureCommerce(access, receipt),
        throwsA(isA<BusinessCutoverImportRejected>()),
      );
      expect((await db.ledger.accounts(ledgerAccess)).single['id'], account);
      expect(
        (await db.ledger.accounts(ledgerAccess)).single['balance_minor'],
        7400,
      );
      final product =
          (doc['tables']['products'] as List).single['id'] as String;
      expect(
        await db.ledger.commerceInventoryProduct(ledgerAccess, product),
        isNull,
      );
    },
    skip: handoff == null,
  );
}
