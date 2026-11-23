import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/core/config/directory_pilot_build.dart';
import 'package:fyona_flutter/core/di/providers.dart' show apiClientProvider;
import 'package:fyona_flutter/features/branches/data/branch_epoch.dart';
import 'package:fyona_flutter/features/branches/data/branch_scope.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_pilot.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:fyona_flutter/features/employees/presentation/providers/employee_providers.dart';
import 'package:fyona_flutter/features/reconciliation/data/reconciliation_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

typedef _Count = ({
  String productId,
  int qtyMilli,
  String? unitId,
  List<BusinessInventoryCountPart>? parts,
});

_Count _one(String productId, int qtyMilli, [String? unitId]) =>
    (productId: productId, qtyMilli: qtyMilli, unitId: unitId, parts: null);

void main() {
  test(
    'stocktake API refuses stale scopes and checks the real equalization grant',
    () async {
      SharedPreferences.setMockInitialValues({});
      addTearDown(BranchScope.clear);
      final root = await Directory.systemTemp.createTemp(
        'fyona-stocktake-api-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = DirectoryPilotStore(
        root: () async => root,
        keys: FixtureDirectoryKeys(),
      );
      addTearDown(store.close);
      final scope = DirectoryAccess(
        workspace: DirectoryWorkspace(
          server: DirectoryPilotBuild.baseUrl,
          accountId: _id(),
          organizationId: _id(),
        ),
        branchId: _id(),
        readable: {},
        writable: {},
        financialCutover: true,
      );
      await BranchScope.save(
        token: 'fixture',
        branchId: scope.branchId,
        branchName: 'Device',
        allMode: false,
        organizationId: scope.workspace.organizationId,
      );
      await store.remember(scope, {
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
      final grant = BusinessLedgerAccess(
        scope,
        BusinessLedgerAction.values.toSet(),
      );
      final product = await store.withLedger(
        grant,
        () => scope,
        (ledger) => ledger.createCommerceProduct(
          grant,
          commandId: _id(),
          name: 'Inventory A',
          unit: 'box',
          price: '1',
          stock: '3',
        ),
      );
      final equalize = StateProvider<bool>((_) => false);
      final current = StateProvider<DirectoryAccess?>((_) => scope);
      final container = ProviderContainer(
        overrides: [
          directoryPilotStoreProvider.overrideWithValue(store),
          businessLocalLedgerScopeProvider.overrideWith(
            (ref) => ref.watch(current),
          ),
          employeeCanProvider.overrideWith(
            (ref, key) =>
                key != 'reconciliation.equalize' || ref.watch(equalize),
          ),
          apiClientProvider.overrideWith(
            (_) => fail('Device stocktake must not use REST'),
          ),
        ],
      );
      addTearDown(container.dispose);
      final api = container.read(reconciliationApiProvider);
      final id = ReconciliationApi.newOperationId();
      await api.inventoryStart(
        scope: 'product',
        productId: product['id'] as String,
        idempotencyKey: id,
      );
      final link = LocalReconciliationLink(api, id, rtype: 'inventory');
      final checked = await api
          .inventorySave(
            reconId: id,
            counts: [
              // Same shape as the original linked-count page and no header qty.
              {
                'product_id': product['id'],
                'parts': [
                  {'qty': '0'},
                ],
              },
            ],
          )
          .then((_) => api.inventoryCheck(reconId: id));
      expect(checked['status'], 'checked');
      expect((checked['lines'] as List).single['base_qty'], 0);
      Future<Map<String, dynamic>> apply([String? branch]) =>
          api.inventoryApprove(
            reconId: id,
            branchId: branch,
            settlements: [
              {'product_id': product['id'], 'expected_system': 3, 'new_qty': 0},
            ],
          );
      await expectLater(apply(), throwsA(isA<DirectoryAccessDenied>()));
      container.read(equalize.notifier).state = true;
      await expectLater(apply(_id()), throwsA(isA<DirectoryAccessDenied>()));
      expect((await apply())['status'], 'approved');
      expect((await api.archive(rtype: 'inventory')).single['id'], id);
      expect(link.matches(api), isTrue);
      container.read(current.notifier).state = null;
      container.read(branchEpochProvider.notifier).state++;
      expect(link.matches(api), isFalse);
      await expectLater(
        api.inventoryCheck(reconId: id),
        throwsA(isA<DirectoryAccessDenied>()),
      );
    },
    skip: !DirectoryPilotBuild.signupEnabled,
  );

  test(
    'device stocktake counts, checks and settles stock in one honest commit',
    () async {
      final root = await Directory.systemTemp.createTemp('fyona-stocktake-');
      addTearDown(() => root.delete(recursive: true));
      final workspace = DirectoryWorkspace(
        server: 'https://stocktake.fixture.test/api/v1',
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
      final readGrant = BusinessLedgerAccess(here, {
        BusinessLedgerAction.readInventoryReconciliation,
      });
      final siblingGrant = BusinessLedgerAccess(
        sibling,
        BusinessLedgerAction.values.toSet(),
      );
      final keys = FixtureDirectoryKeys();
      Future<DirectoryDatabase> open() =>
          DirectoryDatabase.open(root: root, workspace: workspace, keys: keys);
      var db = await open();
      addTearDown(() => db.close());
      Future<String> make(
        BusinessLedgerAccess access,
        String name, {
        Object? cost = '4',
        String costCurrency = 'SAR',
        int stock = 0,
        bool isService = false,
      }) async =>
          (await db.ledger.createCommerceProduct(
                access,
                commandId: _id(),
                name: name,
                unit: 'قطعة',
                price: 10,
                costPrice: cost,
                costCurrency: costCurrency,
                stock: stock,
                isService: isService,
              ))['id']
              as String;

      final tea = await make(grant, 'Tea', cost: '4', stock: 10);
      final rice = await make(grant, 'Rice', cost: '2', stock: 8);
      final ghost = await make(grant, 'Ghost', cost: '1', stock: 5);
      await make(grant, 'Service', isService: true);
      await make(siblingGrant, 'Sibling', stock: 99);
      final carton =
          (await db.ledger.createCommerceUnit(
                grant,
                commandId: _id(),
                productId: tea,
                name: 'كرتون',
                factor: 6,
              ))['id']
              as String;
      final halfBox =
          (await db.ledger.createCommerceUnit(
                grant,
                commandId: _id(),
                productId: rice,
                name: 'نصف',
                factor: '0.5',
              ))['id']
              as String;

      // ── start: snapshot only, never writes stock ──
      final countId = _id();
      final started = await db.ledger.inventoryReconciliationStart(
        grant,
        id: countId,
        scope: 'full',
        notes: 'جرد نهاية الشهر',
        allowed: () => true,
      );
      expect(started['status'], 'draft');
      expect(started['rtype'], 'inventory');
      expect(started['scope'], 'full');
      final lines = started['lines'] as List;
      // The service product, the sibling branch and later products never
      // enter the count.
      expect([for (final l in lines) l['name']], ['Ghost', 'Rice', 'Tea']);
      expect([for (final l in lines) l['system_qty']], [5.0, 8.0, 10.0]);
      expect([for (final l in lines) l['counted_qty']], [null, null, null]);
      final units = started['units'] as Map;
      expect((units[tea] as List).map((u) => u['name']), ['قطعة', 'كرتون']);
      expect((units[tea] as List).map((u) => u['factor']), [1.0, 6.0]);

      // A repetition carrying different data is refused, identical returns.
      expect(
        () => db.ledger.inventoryReconciliationStart(
          grant,
          id: countId,
          scope: 'product',
          productId: tea,
          allowed: () => true,
        ),
        throwsA(isA<BusinessLedgerError>()),
      );
      final same = await db.ledger.inventoryReconciliationStart(
        grant,
        id: countId,
        scope: 'full',
        notes: 'جرد نهاية الشهر',
        allowed: () => true,
      );
      expect(same['id'], countId);
      // Category stocktakes require an explicit scoped category.
      expect(
        () => db.ledger.inventoryReconciliationStart(
          grant,
          id: _id(),
          scope: 'category',
          allowed: () => true,
        ),
        throwsA(isA<BusinessReconciliationInvalid>()),
      );

      // ── save: partial counts, uncounted stay unknown ──
      // 2 cartons + 3 pieces = 15 pieces of tea.
      final saved = await db.ledger.inventoryReconciliationSave(
        grant,
        id: countId,
        counts: [
          (
            productId: tea,
            qtyMilli: 0,
            unitId: null,
            parts: [
              (qtyMilli: 2000, unitId: carton, unitName: 'كرتون'),
              (qtyMilli: 3000, unitId: null, unitName: null),
            ],
          ),
        ],
        allowed: () => true,
      );
      expect(saved['status'], 'draft');
      final savedLines = {
        for (final l in (saved['lines'] as List).cast<Map>()) l['name']: l,
      };
      expect(savedLines['Tea']!['base_qty'], 15.0);
      expect(savedLines['Tea']!['counted_qty'], 15.0);
      expect(savedLines['Tea']!['unit_id'], isNull);
      expect(savedLines['Rice']!['base_qty'], isNull);
      // 0.001 × 0.5 would land below the ledger's 0.001 precision; the whole
      // call is refused and nothing is written.
      expect(
        () => db.ledger.inventoryReconciliationSave(
          grant,
          id: countId,
          counts: [_one(rice, 1, halfBox)],
          allowed: () => true,
        ),
        throwsA(isA<BusinessLedgerError>()),
      );
      final afterSave = await db.ledger.inventoryReconciliationSave(
        grant,
        id: countId,
        counts: [_one(rice, 6000)],
        allowed: () => true,
      );
      final afterLines = {
        for (final l in (afterSave['lines'] as List).cast<Map>()) l['name']: l,
      };
      expect(afterLines['Rice']!['base_qty'], 6.0);
      expect(afterLines['Rice']!['unit_id'], isNull);
      expect(afterLines['Ghost']!['base_qty'], isNull);
      // A product outside the count's scope is never folded in.
      final stranger = await make(grant, 'Stranger', stock: 1);
      expect(
        () => db.ledger.inventoryReconciliationSave(
          grant,
          id: countId,
          counts: [_one(stranger, 1000)],
          allowed: () => true,
        ),
        throwsA(isA<BusinessReconciliationInvalid>()),
      );

      // A movement after the count began is flagged, not hidden.
      await db.ledger.adjustCommerceStock(
        grant,
        productId: tea,
        commandId: _id(),
        mode: BusinessStockAdjustment.add,
        amountMilli: 5000,
        expectedMilli: 10000,
      );

      // ── check: compares to the CURRENT quantity, applies nothing ──
      final checked = await db.ledger.inventoryReconciliationCheck(
        grant,
        id: countId,
        allowed: () => true,
      );
      expect(checked['status'], 'checked');
      final checkedLines = {
        for (final l in (checked['lines'] as List).cast<Map>()) l['name']: l,
      };
      // Tea is now 15 in system (10 + 5) and 15 counted → match, but stale.
      expect(checkedLines['Tea']!['system_qty'], 15.0);
      expect(checkedLines['Tea']!['diff'], 0.0);
      expect(checkedLines['Tea']!['status'], 'match');
      expect(checkedLines['Tea']!['stale'], isTrue);
      expect(checkedLines['Tea']!['movements_since'], 1);
      expect(
        (checkedLines['Tea']!['unit_rows'] as List).map((r) => r['system']),
        [15.0, 2.5],
      );
      // Rice counted 6 against 8 → short; Ghost uncounted → never zero.
      expect(checkedLines['Rice']!['diff'], -2.0);
      expect(checkedLines['Rice']!['status'], 'short');
      expect(checkedLines['Rice']!['stale'], isFalse);
      expect(checkedLines['Ghost']!['base_qty'], isNull);
      expect(checkedLines['Ghost']!['diff'], isNull);
      expect(checked['result'], {
        'counted': 2,
        'matched': 1,
        'short': 1,
        'surplus': 0,
        'stale': 1,
        'uncounted': 1,
      });
      final detailAfterCheck = await db.ledger.inventoryReconciliationDetail(
        readGrant,
        countId,
      );
      expect(detailAfterCheck['settlements'], isEmpty);

      // ── approve: settles every requested line in one commit ──
      final entries = [
        (productId: tea, expectedMilli: 15000, newMilli: 15000),
        (productId: rice, expectedMilli: 8000, newMilli: 6000),
      ];
      var checks = 0;
      await expectLater(
        db.ledger.inventoryReconciliationApprove(
          grant,
          id: countId,
          settlements: entries,
          allowed: () => checks++ == 0, // grant disappears just before commit
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      expect(
        (await db.ledger.commerceInventoryProduct(grant, rice))!['stock'],
        8.0,
      );
      expect(
        (await db.ledger.inventoryReconciliationDetail(
          readGrant,
          countId,
        ))['status'],
        'checked',
      );
      final approved = await db.ledger.inventoryReconciliationApprove(
        grant,
        id: countId,
        settlements: entries,
        notes: 'اعتماد الجرد',
        allowed: () => true,
      );
      expect(approved['status'], 'approved');
      expect(approved['result'], {
        'settled': 1,
        'untouched': 1,
        'ref_code': approved['ref_code'],
      });
      final settlements = {
        for (final s in (approved['settlements'] as List).cast<Map>())
          s['product_id']: s,
      };
      expect(settlements[tea]!['applied'], isFalse);
      expect(settlements[tea]!['before'], 15.0);
      expect(settlements[rice]!['applied'], isTrue);
      expect(settlements[rice]!['before'], 8.0);
      expect(settlements[rice]!['after'], 6.0);
      expect(settlements[rice]!['diff'], -2.0);
      final riceCard = await db.ledger.commerceInventoryProduct(grant, rice);
      expect(riceCard!['stock'], 6.0);
      // The shortage consumed lots FIFO; captured history stays intact.
      expect(
        ((riceCard['lots'] as List).cast<Map>()).map((l) => l['remaining']),
        [6.0],
      );
      final teaCard = await db.ledger.commerceInventoryProduct(grant, tea);
      expect(teaCard!['stock'], 15.0);

      // Idempotent re-approve returns the record and posts nothing new.
      final again = await db.ledger.inventoryReconciliationApprove(
        grant,
        id: countId,
        settlements: [
          (productId: tea, expectedMilli: 15000, newMilli: 15000),
          (productId: rice, expectedMilli: 8000, newMilli: 6000),
        ],
        notes: 'اعتماد الجرد',
        allowed: () => true,
      );
      expect(again['approved_at'], approved['approved_at']);
      final teaAgain = await db.ledger.commerceInventoryProduct(grant, tea);
      expect(teaAgain!['stock'], 15.0);
      // Different numbers on an approved count are refused.
      expect(
        () => db.ledger.inventoryReconciliationApprove(
          grant,
          id: countId,
          settlements: [
            (productId: tea, expectedMilli: 15000, newMilli: 14000),
          ],
          allowed: () => true,
        ),
        throwsA(isA<BusinessLedgerError>()),
      );

      // ── a movement after the check blocks approval even on the same
      // balance; revocation blocks the flow; drafts never settle ──
      final secondId = _id();
      await db.ledger.inventoryReconciliationStart(
        grant,
        id: secondId,
        scope: 'product',
        productId: rice,
        allowed: () => true,
      );
      await db.ledger.inventoryReconciliationSave(
        grant,
        id: secondId,
        counts: [_one(rice, 6000)],
        allowed: () => true,
      );
      await db.ledger.inventoryReconciliationCheck(
        grant,
        id: secondId,
        allowed: () => true,
      );
      await db.ledger.adjustCommerceStock(
        grant,
        productId: rice,
        commandId: _id(),
        mode: BusinessStockAdjustment.add,
        amountMilli: 2000,
        expectedMilli: 6000,
      );
      await db.ledger.adjustCommerceStock(
        grant,
        productId: rice,
        commandId: _id(),
        mode: BusinessStockAdjustment.remove,
        amountMilli: 2000,
        expectedMilli: 8000,
      );
      expect(
        () => db.ledger.inventoryReconciliationApprove(
          grant,
          id: secondId,
          settlements: [(productId: rice, expectedMilli: 6000, newMilli: 6000)],
          allowed: () => true,
        ),
        throwsA(isA<BusinessReconciliationChanged>()),
      );
      expect(
        () => db.ledger.inventoryReconciliationApprove(
          grant,
          id: secondId,
          settlements: [(productId: rice, expectedMilli: 6000, newMilli: 6000)],
          allowed: () => false,
        ),
        throwsA(isA<DirectoryAccessDenied>()),
      );
      final thirdId = _id();
      await db.ledger.inventoryReconciliationStart(
        grant,
        id: thirdId,
        scope: 'product',
        productId: rice,
        allowed: () => true,
      );
      expect(
        () => db.ledger.inventoryReconciliationApprove(
          grant,
          id: thirdId,
          settlements: [(productId: rice, expectedMilli: 6000, newMilli: 6000)],
          allowed: () => true,
        ),
        throwsA(isA<BusinessReconciliationInvalid>()),
      );
      // Saving into an approved count is refused.
      expect(
        () => db.ledger.inventoryReconciliationSave(
          grant,
          id: countId,
          counts: [_one(rice, 1000)],
          allowed: () => true,
        ),
        throwsA(isA<BusinessReconciliationInvalid>()),
      );

      // Archive lists this branch's counts only, filtered by status.
      final archive = await db.ledger.bankReconciliationArchive(
        grant,
        rtype: 'inventory',
        status: 'approved',
      );
      expect([for (final r in archive) r['id']], [countId]);
      await db.close();
      db = await open();
      final reopened = await db.ledger.inventoryReconciliationDetail(
        readGrant,
        countId,
      );
      expect(reopened['status'], 'approved');
      expect((reopened['settlements'] as List).length, 2);
    },
  );
}
