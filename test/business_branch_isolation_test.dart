import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();
const _customer = DirectoryPartyKind.customer;
const kinds = {'sale', 'purchase', 'sale_return', 'purchase_return', 'collection', 'payment', 'expense', 'income', 'transfer', 'opening', 'reconciliation', 'debt', 'opening_debt', 'bank_withdrawal'};

/// Every branch is its own book: nothing recorded in one branch is visible
/// from another (only "all branches" merges them, read-only).
void main() {
  final workspace = DirectoryWorkspace(
    server: 'http://localhost:18083/api/v1',
    accountId: _id(),
    organizationId: _id(),
  );
  late Directory root;
  late DirectoryDatabase db;

  DirectoryAccess scope(String branch) => DirectoryAccess(
    workspace: workspace,
    branchId: branch,
    readable: DirectoryPartyKind.values.toSet(),
    writable: DirectoryPartyKind.values.toSet(),
    financialCutover: true,
  );
  BusinessLedgerAccess grant(DirectoryAccess s) =>
      BusinessLedgerAccess(s, BusinessLedgerAction.values.toSet());

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fyona-branches-');
    db = await DirectoryDatabase.open(root: root, workspace: workspace, keys: FixtureDirectoryKeys());
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test('a branch never shows another branch\'s data', () async {
    final a = scope(_id()), b = scope(_id());
    final till = _id();
    await db.ledger.createAccount(grant(a), commandId: till, bankName: 'الصندوق',
        accountName: 'كاش', accountNumber: '1', currency: 'SAR', openingMinor: 50000);
    final customer = await db.create(a, _customer, name: 'عميل الفرع أ');
    final ref = DirectoryPartyReference(scope: a, kind: _customer, id: customer.id);
    final debt = _id();
    await db.ledger.recordOpeningDebt(grant(a), ref, commandId: debt, amountMinor: 10000, currency: 'SAR');
    await db.ledger.settle(grant(a), ref, commandId: _id(), accountId: till,
        amountMinor: 4000, currency: 'SAR', invoiceId: debt);
    await db.ledger.move(grant(a), commandId: _id(), accountId: till, amountMinor: 1000,
        withdraw: true, description: 'إيجار', expenseCategory: 'إيجار');

    // Branch A sees its own data.
    expect(await db.ledger.operations(grant(a), allowedKinds: kinds), isNotEmpty);
    expect(await db.search(a, _customer, ''), hasLength(1));

    // Branch B sees none of it.
    expect(await db.ledger.operations(grant(b), allowedKinds: kinds), isEmpty, reason: 'operations');
    expect(await db.search(b, _customer, ''), isEmpty, reason: 'customers');
    final accountsB = await db.ledger.accounts(grant(b));
    expect(accountsB.where((r) => r['id'] == till), isEmpty, reason: 'accounts');
  });

  test('categories and inventory settings belong to their branch only', () async {
    final a = scope(_id()), b = scope(_id());
    final created = await db.ledger.createCommerceCategory(grant(a), commandId: _id(), name: 'مشروبات');
    await db.ledger.setWarehouseExpiry(grant(a), commandId: _id(), enabled: true, warnDays: 30);
    expect((await db.ledger.commerceCategories(grant(a))).map((c) => c['name']), ['مشروبات']);
    expect(await db.ledger.commerceCategories(grant(b)), isEmpty);
    expect((await db.ledger.warehouseExpiry(grant(a)))?.enabled, isTrue);
    expect(await db.ledger.warehouseExpiry(grant(b)), isNull);
    // B sets its own, A keeps its own.
    await db.ledger.setWarehouseExpiry(grant(b), commandId: _id(), enabled: false, warnDays: 90);
    expect((await db.ledger.warehouseExpiry(grant(a)))?.warnDays, 30);
    await db.ledger.renameCommerceCategory(grant(a), commandId: _id(), id: '${created['id']}', name: 'عصائر');
    expect((await db.ledger.commerceCategories(grant(a))).single['name'], 'عصائر');
    await db.ledger.deleteCommerceCategory(grant(a), commandId: _id(), id: '${created['id']}');
    expect(await db.ledger.commerceCategories(grant(a)), isEmpty);
  });

  test('resetting a branch clears only that branch', () async {
    final a = scope(_id()), b = scope(_id());
    for (final s in [a, b]) {
      final till = _id();
      await db.ledger.createAccount(grant(s), commandId: till, bankName: 'الصندوق',
          accountName: 'كاش', accountNumber: '1', currency: 'SAR', openingMinor: 5000);
      final c = await db.create(s, _customer, name: 'عميل');
      await db.ledger.recordOpeningDebt(grant(s),
          DirectoryPartyReference(scope: s, kind: _customer, id: c.id),
          commandId: _id(), amountMinor: 1000, currency: 'SAR');
    }
    expect(await db.resetBranchData(a, a.branchId), greaterThan(0));
    expect(await db.ledger.operations(grant(a), allowedKinds: kinds), isEmpty);
    expect(await db.ledger.accounts(grant(a)), isEmpty);
    expect(await db.search(a, _customer, ''), isEmpty, reason: 'customers of A');
    expect(await db.search(b, _customer, ''), hasLength(1));
    expect(await db.ledger.operations(grant(b), allowedKinds: kinds), isNotEmpty);
    expect(await db.ledger.accounts(grant(b)), hasLength(1));
    // The branch keeps working after its reset.
    await db.ledger.createAccount(grant(a), commandId: _id(), bankName: 'الصندوق',
        accountName: 'كاش', accountNumber: '1', currency: 'SAR', openingMinor: 0);
    expect(await db.ledger.accounts(grant(a)), hasLength(1));
  });
}
