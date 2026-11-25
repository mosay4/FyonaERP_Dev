import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_database.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_party.dart';
import 'package:fyona_flutter/features/core_business/data/local_directory/directory_scope.dart';
import 'package:uuid/uuid.dart';

import 'support/directory_test_keys.dart';

String _id() => const Uuid().v4();

void main() {
  test('party activity lists debts, invoices and later settlements once',
      () async {
    final root = await Directory.systemTemp.createTemp('fyona-party-activity-');
    addTearDown(() => root.delete(recursive: true));
    final workspace = DirectoryWorkspace(
      server: 'https://activity.fixture.test/api/v1',
      accountId: _id(),
      organizationId: _id(),
    );
    final db = await DirectoryDatabase.open(
      root: root,
      workspace: workspace,
      keys: FixtureDirectoryKeys(),
    );
    addTearDown(() => db.close());
    final scope = DirectoryAccess(
      workspace: workspace,
      branchId: _id(),
      financialCutover: true,
      readable: DirectoryPartyKind.values.toSet(),
      writable: DirectoryPartyKind.values.toSet(),
    );
    final access = BusinessLedgerAccess(scope, BusinessLedgerAction.values.toSet());
    final ledger = db.ledger;
    final customer = _id();
    await ledger.addPartyWithOpeningDebt(
      access,
      DirectoryPartyKind.customer,
      commandId: customer,
      name: 'Buyer',
      amountMinor: 10000,
      currency: 'SAR',
    );
    final account = _id();
    await ledger.createAccount(
      access,
      commandId: account,
      bankName: 'Cash',
      accountName: 'SAR',
      accountNumber: '1',
      currency: 'SAR',
      openingMinor: 0,
    );
    await ledger.issueCommerceDocument(
      access,
      kind: BusinessInvoiceKind.sale,
      commandId: _id(),
      currency: 'SAR',
      partyId: customer,
      lines: const [
        CommerceIssueLine(
          description: 'Service',
          quantity: '1',
          unitMinor: 5000,
          isService: true,
        ),
      ],
      payments: [
        CommerceIssuePayment(
          accountId: account,
          paymentCurrency: 'SAR',
          originalMinor: 1000,
        ),
      ],
    );
    final party = DirectoryPartyReference(
      scope: scope,
      kind: DirectoryPartyKind.customer,
      id: customer,
    );
    await ledger.settle(
      access,
      party,
      commandId: _id(),
      accountId: account,
      amountMinor: 3000,
      currency: 'SAR',
    );
    final rows = await ledger.partyActivity(access, party);
    final types = rows.map((r) => r['type']).toList();
    expect(types.where((t) => t == 'debt'), hasLength(1));
    expect(types.where((t) => t == 'sale'), hasLength(1));
    // The payment taken with the invoice is not a separate operation.
    final payments = rows.where((r) => r['type'] == 'payment').toList();
    expect(payments, hasLength(1));
    expect(payments.single['amount'], 30.0);
    expect(payments.single['currency'], 'SAR');
    expect((payments.single['invoices'] as List), isNotEmpty);
    final sale = rows.firstWhere((r) => r['type'] == 'sale');
    expect(sale['amount'], 50.0);
    expect(sale['number'], isNotNull);
  });
}
